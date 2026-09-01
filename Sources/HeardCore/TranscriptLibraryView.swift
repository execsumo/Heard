import SwiftUI
import AppKit

private struct TranscriptLibraryRow: Identifiable {
    let record: TranscriptRecord
    let visibleParticipants: String

    var id: URL { record.id }
    var title: String { record.title }
    var date: Date { record.date }
    var sortableDuration: TimeInterval { record.duration ?? -1 }
}

public struct TranscriptLibraryView: View {
    @ObservedObject public var model: AppModel
    @StateObject private var library = TranscriptLibrary()
    @State private var filterText = ""
    @State private var sortOrder: [KeyPathComparator<TranscriptLibraryRow>] = [
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
                TranscriptLibrary.participantsExcludingCurrentUser(
                    $0.participants,
                    userName: model.settingsStore.settings.userName
                ).contains(where: { $0.lowercased().contains(text) })
            }
        }
    }

    private var tableRows: [TranscriptLibraryRow] {
        filteredRecords.map { record in
            let participants = TranscriptLibrary.participantsExcludingCurrentUser(
                record.participants,
                userName: model.settingsStore.settings.userName
            )
            return TranscriptLibraryRow(
                record: record,
                visibleParticipants: participants.joined(separator: ", ")
            )
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.md) {
                HStack(spacing: HeardTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(HeardTheme.Terminal.mute)
                            .font(.system(size: 12))
                        TextField("Search transcripts", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(HeardFont.body)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                    .overlay(
                        Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline)
                    )
                    .frame(width: 200)

                    Spacer()

                    Button {
                        library.refresh(directory: outputDirectoryURL)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HeardTheme.Terminal.mute)
                }
            }
            .padding(HeardTheme.Spacing.lg)
            .background(HeardTheme.Terminal.bg)

            HeardTheme.Terminal.border.frame(height: HeardTheme.Stroke.hairline)

            if !FileManager.default.fileExists(atPath: outputDirectoryURL.path) {
                missingFolderState
            } else if library.records.isEmpty && filterText.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .background(HeardTheme.Terminal.bg)
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
                .foregroundStyle(HeardTheme.Terminal.mute)
            Text("Output folder not found")
                .font(HeardFont.title)
                .foregroundStyle(HeardTheme.Terminal.ink)
            Text("Please choose a valid save location in the Recording tab.")
                .font(HeardFont.body)
                .foregroundStyle(HeardTheme.Terminal.mute)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Terminal.bg)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(HeardTheme.Terminal.mute)
            Text("No transcripts yet — they'll appear here after your first recorded meeting")
                .font(HeardFont.title)
                .foregroundStyle(HeardTheme.Terminal.ink)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Terminal.bg)
    }

    var table: some View {
        Table(tableRows.sorted(using: sortOrder),
              selection: $selection,
              sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(HeardFont.bodyMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(row.record.url)
                    }
                    .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                }
            }
            TableColumn("Date", value: \.date) { row in
                Text(row.date.formatted(date: .abbreviated, time: .shortened))
                    .font(HeardFont.value)
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 120, max: 150)
            TableColumn("Duration", value: \.sortableDuration) { row in
                if let duration = row.record.duration {
                    Text(SettingsView.durationText(duration))
                        .font(HeardFont.value)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(HeardFont.value)
                }
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Participants", value: \.visibleParticipants) { row in
                Text(row.visibleParticipants)
                    .font(HeardFont.body)
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
}
