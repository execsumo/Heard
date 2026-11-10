import Darwin
import Foundation

/// Repairs interrupted PCM WAV headers without ever editing the source in place.
public enum WAVHeaderFinalizer {
    public struct Layout: Equatable, Sendable {
        public var riffSize: UInt32
        public var blockAlign: Int
        public var dataHeaderOffset: Int
        public var dataSize: UInt32
        public var formatTag: UInt16
        public var dataOffset: Int { dataHeaderOffset + 8 }
    }

    public struct Repair: Equatable, Sendable {
        public var previousDataSize: UInt32
        public var dataSize: UInt32
    }

    public struct ReadingSource {
        public let url: URL
        public let ownsTemporary: Bool

        public func cleanup() {
            guard ownsTemporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public enum RecoveryError: LocalizedError {
        case invalidHeader(String)
        case unsupportedSize(String)
        case operationFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .invalidHeader(let path):
                return "Cannot safely recover the WAV header at \(path); the original was preserved."
            case .unsupportedSize(let path):
                return "The WAV at \(path) exceeds the RIFF size limit and cannot be safely recovered; the original was preserved."
            case .operationFailed(let path, let reason):
                return "Could not recover the WAV at \(path): \(reason). The original was preserved."
            }
        }
    }

    /// Injection points also exercise clone and interrupted-write failures in tests.
    public struct Operations {
        public var clone: (URL, URL) throws -> Void
        public var writeSize: (FileHandle, UInt64, Data) throws -> Void

        public init(clone: @escaping (URL, URL) throws -> Void,
                    writeSize: @escaping (FileHandle, UInt64, Data) throws -> Void) {
            self.clone = clone
            self.writeSize = writeSize
        }

        public static var standard: Operations {
            Operations(clone: { source, destination in
                let result = source.path.withCString { src in
                    destination.path.withCString { dst in clonefile(src, dst, 0) }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }, writeSize: { handle, offset, bytes in
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: bytes)
            })
        }
    }

    /// Stops at the first data chunk; unfinalized PCM must not be parsed as chunks.
    public static func layout(in header: Data) -> Layout? {
        guard header.count >= 12,
              header.prefix(4) == Data("RIFF".utf8),
              header.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        var pos = 12
        var blockAlign = 0
        var formatTag: UInt16 = 0
        while pos + 8 <= header.count {
            let chunkSize = Int(u32(header, pos + 4))
            let id = header.subdata(in: pos..<(pos + 4))
            if id == Data("fmt ".utf8), chunkSize >= 16, pos + 24 <= header.count {
                formatTag = u16(header, pos + 8)
                blockAlign = Int(u16(header, pos + 20))
                // WAVE_FORMAT_EXTENSIBLE: only accept PCM or IEEE float subformats.
                if formatTag == 0xfffe, chunkSize >= 40, pos + 48 <= header.count {
                    let subformat = header.subdata(in: (pos + 32)..<(pos + 48))
                    let pcmSuffix = Data([0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71])
                    if subformat.dropFirst(2) == pcmSuffix { formatTag = u16(header, pos + 32) }
                }
            }
            if id == Data("data".utf8) {
                guard blockAlign > 0 else { return nil }
                return Layout(riffSize: u32(header, 4), blockAlign: blockAlign,
                              dataHeaderOffset: pos, dataSize: u32(header, pos + 4), formatTag: formatTag)
            }
            let step = 8 + chunkSize + (chunkSize & 1)
            guard step <= header.count - pos else { return nil }
            pos += step
        }
        return nil
    }

    /// Retained as a convenience for callers inspecting ordinary short RIFFs.
    public static func repairedDataSize(fileSize: Int, layout: Layout) -> UInt32? {
        guard fileSize > layout.dataOffset, fileSize > Int(layout.riffSize) + 8,
              layout.blockAlign > 0 else { return nil }
        let payload = fileSize - layout.dataOffset
        guard payload > Int(layout.dataSize), payload % layout.blockAlign == 0,
              UInt64(fileSize - 8) <= UInt64(UInt32.max), payload <= Int(UInt32.max) else { return nil }
        return UInt32(payload)
    }

    /// Atomically replace the original only after both size fields were written to
    /// and synced on a clone. A crash or write failure cannot leave half a header.
    @discardableResult
    public static func finalize(at url: URL, operations: Operations = .standard) throws -> Repair? {
        guard let plan = try repairPlan(for: url) else { return nil }
        let staged = temporarySibling(of: url)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try operations.clone(url, staged)
            try patch(staged, plan: plan, operations: operations)
            let result = staged.path.withCString { src in url.path.withCString { dst in rename(src, dst) } }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return plan.repair
        } catch {
            throw RecoveryError.operationFailed(url.path, error.localizedDescription)
        }
    }

    /// Returns a repaired same-volume clone or throws; never falls back to a
    /// known-short source. The caller must keep the source alive until cleanup.
    public static func readingURL(for url: URL, operations: Operations = .standard) throws -> ReadingSource {
        guard let plan = try repairPlan(for: url) else {
            return ReadingSource(url: url, ownsTemporary: false)
        }
        let clone = temporarySibling(of: url)
        do {
            try operations.clone(url, clone)
            try patch(clone, plan: plan, operations: operations)
            return ReadingSource(url: clone, ownsTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: clone)
            throw RecoveryError.operationFailed(url.path, error.localizedDescription)
        }
    }

    private struct Plan {
        let layout: Layout
        let riffSize: UInt32
        let repair: Repair
    }

    private static func repairPlan(for url: URL) throws -> Plan? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 65_536) ?? Data()
        // Let AVAudioFile report errors for non-RIFF inputs.
        guard header.prefix(4) == Data("RIFF".utf8) else { return nil }
        guard let parsed = layout(in: header), size >= UInt64(parsed.dataOffset) else {
            throw RecoveryError.invalidHeader(url.path)
        }
        let riffEnd = UInt64(parsed.riffSize) + 8
        let dataEnd = UInt64(parsed.dataOffset) + UInt64(parsed.dataSize)
        guard dataEnd <= size, riffEnd <= size else { throw RecoveryError.invalidHeader(url.path) }

        // A complete RIFF may legitimately contain chunks after data. Walk them
        // before treating a short data field as an interrupted header update.
        if riffEnd == size {
            if dataEnd == size { return nil }
            if try trailingChunksValid(handle, from: dataEnd, dataSize: parsed.dataSize, end: size) { return nil }
        }
        guard parsed.formatTag == 1 || parsed.formatTag == 3 else { throw RecoveryError.invalidHeader(url.path) }
        let payload = size - UInt64(parsed.dataOffset)
        guard payload % UInt64(parsed.blockAlign) == 0 else { throw RecoveryError.invalidHeader(url.path) }
        guard size >= 8, size - 8 <= UInt64(UInt32.max), payload <= UInt64(UInt32.max) else {
            throw RecoveryError.unsupportedSize(url.path)
        }
        return Plan(layout: parsed, riffSize: UInt32(size - 8),
                    repair: Repair(previousDataSize: parsed.dataSize, dataSize: UInt32(payload)))
    }

    private static func trailingChunksValid(_ handle: FileHandle, from dataEnd: UInt64, dataSize: UInt32, end: UInt64) throws -> Bool {
        var offset = dataEnd + UInt64(dataSize & 1)
        guard offset <= end else { return false }
        while offset < end {
            guard end - offset >= 8 else { return false }
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { return false }
            // Chunk IDs are printable FourCCs. PCM is not normally a chunk list.
            guard chunk.prefix(4).allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return false }
            let length = UInt64(u32(chunk, 4))
            guard length + (length & 1) <= end - offset - 8 else { return false }
            offset += 8 + length + (length & 1)
        }
        return offset == end
    }

    private static func patch(_ url: URL, plan: Plan, operations: Operations) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try operations.writeSize(handle, 4, le32(plan.riffSize))
        try operations.writeSize(handle, UInt64(plan.layout.dataHeaderOffset + 4), le32(plan.repair.dataSize))
        try handle.synchronize()
    }

    private static func temporarySibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".heard-wav-\(UUID().uuidString).wav")
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func le32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }
}
