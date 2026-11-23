import FluidAudio
import Foundation

/// English Unified batch engine (Parakeet Unified EN 0.6B) model files.
///
/// The required set mirrors `UnifiedAsrManager.loadModels` with its default int8
/// offline encoder, so the readiness check and the loader agree on "downloaded".
public enum UnifiedModelAssets {
    private static let family: UnifiedModelFamily = .parakeetEnglish
    private static let encoderPrecision: UnifiedEncoderPrecision = .int8

    /// Files that must exist in `cacheDirectory` for the engine to load.
    public static var requiredFiles: [String] {
        [
            family.offlineEncoderFile(precision: encoderPrecision),
            family.decoderFile,
            family.jointDecisionFile,
            family.vocab,
        ]
    }

    /// Directory `UnifiedAsrManager.loadModels` uses when no directory is passed.
    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(family.repo.folderName, isDirectory: true)
    }

    /// True when every required file is present in `directory`.
    public static func isComplete(at directory: URL) -> Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// True when the default cache holds a complete engine set.
    public static var isCached: Bool {
        isComplete(at: cacheDirectory)
    }
}
