import SwiftUI
import AppKit

public struct TranscriptLibraryView: View {
    @ObservedObject public var model: AppModel
    @StateObject private var library = TranscriptLibrary()
    @State private var filterText = ""
    @State private var sortOrder: [KeyPathComparator<TranscriptRecord>] = [
        KeyPathComparator(\.date, order: .reverse)
    ]
    @State private var selection: Set<URL> = []
    @State private var showTrashAlert = false
    @State private var fileToTrash: URL?

    public init(model: AppModel) {
        self.model = model
    }

    private var outputDirectoryURL: URL {
        URL(fileURLWithPath: model.settingsStore.settings.outputDirectory, isDirectory: true)
    }

    private var filteredRecords: [TranscriptRecord] {
        let text = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty {
            return library.records
        } else {
            return library.records.filter {
                $0.title.lowercased().contains(text) ||
                $0.participants.contains(where: { $0.lowercased().contains(text) })
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.md) {
                HStack(spacing: HeardTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(HeardTheme.Paper.mute)
                            .font(.system(size: 12))
                        TextField("Search transcripts", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(HeardTheme.Paper.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                    .frame(width: 200)

                    Spacer()

                    Button {
                        library.refresh(directory: outputDirectoryURL)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HeardTheme.Paper.mute)
                }
            }
            .padding(HeardTheme.Spacing.lg)
            .background(HeardTheme.Paper.bg)

            HeardTheme.Paper.border.frame(height: 0.5)

            if !FileManager.default.fileExists(atPath: outputDirectoryURL.path) {
                missingFolderState
            } else if library.records.isEmpty && filterText.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .background(HeardTheme.Paper.bg)
        .onAppear {
            library.refresh(directory: outputDirectoryURL)
        }
        .onChange(of: model.settingsStore.settings.outputDirectory) {
            library.refresh(directory: outputDirectoryURL)
        }
        .alert("Move to Trash?", isPresented: $showTrashAlert, presenting: fileToTrash) { url in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    library.refresh(directory: outputDirectoryURL)
                } catch {
                    print("Failed to trash item: \(error)")
                }
            }
        } message: { url in
            Text("Are you sure you want to move \"\(url.lastPathComponent)\" to the Trash?")
        }
    }

    var missingFolderState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(HeardTheme.Paper.mute)
            Text("Output folder not found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HeardTheme.Paper.ink)
            Text("Please choose a valid save location in the Recording tab.")
                .font(.system(size: 12))
                .foregroundStyle(HeardTheme.Paper.mute)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Paper.bg)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(HeardTheme.Paper.mute)
            Text("No transcripts yet — they'll appear here after your first recorded meeting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HeardTheme.Paper.ink)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Paper.bg)
    }

    var table: some View {
        Table(filteredRecords.sorted(using: sortOrder),
              selection: $selection,
              sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { record in
                HStack(spacing: 8) {
                    Text(record.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(record.url)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HeardTheme.Paper.accent)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(HeardTheme.Paper.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            TableColumn("Date", value: \.date) { record in
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 100, ideal: 120, max: 150)
            TableColumn("Duration", value: \.sortableDuration) { record in
                if let duration = record.duration {
                    Text(SettingsView.durationText(duration)).monospacedDigit()
                } else {
                    Text("—")
                }
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Participants", value: \.sortableParticipants) { record in
                Text(record.sortableParticipants)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.count == 1, let url = urls.first {
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    fileToTrash = url
                    showTrashAlert = true
                }
            }
        } primaryAction: { urls in
            if urls.count == 1, let url = urls.first {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension TranscriptRecord {
    var sortableDuration: TimeInterval {
        duration ?? -1
    }
    
    var sortableParticipants: String {
        participants.joined(separator: ", ")
    }
}
