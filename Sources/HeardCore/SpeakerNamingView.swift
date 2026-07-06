import AVFoundation
import SwiftUI

// MARK: - Speaker Naming Prompt Window

public struct SpeakerNamingView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [UUID: String] = [:]
    @State private var playingCandidateID: UUID?
    @State private var playingClipIndex: Int?
    @State private var audioPlayer: AVAudioPlayer?
    @Environment(\.dismissWindow) private var dismissWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(HeardTheme.Paper.accentSoft)
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(HeardTheme.Paper.accent)
                }

                Text("New Speakers Detected")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HeardTheme.Paper.ink)

                Text("Listen to each voice clip and enter their name. If a candidate's samples are clearly different voices, use Split voices to name each one, or Discard to drop it. Take your time — nothing is saved until you choose. Closing this window keeps the speakers pending; reopen it anytime from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(HeardTheme.Paper.mute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, HeardTheme.Spacing.lg)
            .padding(.bottom, HeardTheme.Spacing.md)

            HeardTheme.Paper.borderSoft.frame(height: 0.5)

            ScrollView {
                VStack(spacing: HeardTheme.Spacing.sm) {
                    ForEach(model.namingCandidates) { candidate in
                        speakerRow(candidate)
                    }
                }
                .padding(HeardTheme.Spacing.lg)
            }
            .background(HeardTheme.Paper.bg)

            HeardTheme.Paper.borderSoft.frame(height: 0.5)

            HStack {
                Button("Skip All") {
                    stopAudio()
                    model.skipNaming()
                    dismissWindow(id: "speaker-naming")
                }
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(HeardTheme.Paper.ink2)

                Spacer()

                Button("Save & Close") {
                    stopAudio()
                    saveAll()
                    dismissWindow(id: "speaker-naming")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(HeardTheme.Spacing.lg)
            .background(HeardTheme.Paper.surface)
        }
        .frame(width: 560)
        .background(HeardTheme.Paper.bg)
        .onDisappear { stopAudio() }
        .onChange(of: model.namingCandidates) { _, candidates in
            if candidates.isEmpty {
                stopAudio()
                dismissWindow(id: "speaker-naming")
            }
        }
    }

    private func speakerRow(_ candidate: NamingCandidate) -> some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            clipButtons(for: candidate)

            VStack(alignment: .leading, spacing: HeardTheme.Spacing.xs) {
                Text(candidate.temporaryName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HeardTheme.Paper.mute)
                if !candidate.suggestedNames.isEmpty {
                    suggestionChips(for: candidate)
                }
                TextField(
                    candidate.suggestedName ?? "Enter speaker name",
                    text: binding(for: candidate)
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveSingle(candidate) }
            }

            VStack(spacing: 4) {
                Button("Save") { saveSingle(candidate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftText(for: candidate).isEmpty)
                if candidate.audioClipURLs.count >= 2 {
                    Button("Split voices") { splitSingle(candidate) }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .foregroundStyle(HeardTheme.Paper.mute)
                        .help("The samples are different people? Split this candidate into one entry per sample so each voice can be named (or discarded) separately.")
                }
                Button("Discard") { discardSingle(candidate) }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .foregroundStyle(HeardTheme.Paper.mute)
                    .help("Drop this candidate without saving — keeps the speaker database clean and leaves the transcript labeled Speaker N.")
            }
        }
        .padding(HeardTheme.Spacing.md)
        .background(HeardTheme.Paper.surface)
        .clipShape(RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: HeardTheme.Radius.card)
                .stroke(HeardTheme.Paper.border, lineWidth: 0.5)
        )
        .contextMenu {
            if candidate.audioClipURLs.count >= 2 {
                Button("Split into separate voices") { splitSingle(candidate) }
            }
            Button("Discard candidate") { discardSingle(candidate) }
        }
    }

    /// Tappable roster-name chips. Every unmatched roster name is offered on every
    /// candidate — with several unknown voices there is no reliable way to pre-pair
    /// a specific name to a specific voice, so the user picks by ear. Tapping a chip
    /// fills the name field; Save still commits.
    private func suggestionChips(for candidate: NamingCandidate) -> some View {
        HStack(spacing: 4) {
            Text("maybe:")
                .font(.system(size: 10))
                .foregroundStyle(HeardTheme.Paper.mute)
            ForEach(candidate.suggestedNames.prefix(3), id: \.self) { name in
                Button {
                    drafts[candidate.id] = name
                } label: {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(HeardTheme.Paper.warn)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HeardTheme.Paper.warnSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Fill the name field with \(name)")
            }
            if candidate.suggestedNames.count > 3 {
                Text("+\(candidate.suggestedNames.count - 3) more")
                    .font(.system(size: 10))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }
        }
    }

    @ViewBuilder
    private func clipButtons(for candidate: NamingCandidate) -> some View {
        if candidate.audioClipURLs.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(HeardTheme.Paper.surfaceAlt)
                    .frame(width: 38, height: 38)
                Image(systemName: "play.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }
            .help("No audio clip available")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Samples")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(HeardTheme.Paper.mute)
                HStack(spacing: 4) {
                    ForEach(Array(candidate.audioClipURLs.enumerated()), id: \.offset) { index, url in
                        clipButton(candidateID: candidate.id, index: index, url: url)
                    }
                }
            }
        }
    }

    private func clipButton(candidateID: UUID, index: Int, url: URL) -> some View {
        let isPlaying = playingCandidateID == candidateID && playingClipIndex == index
        let tint = isPlaying ? HeardTheme.Paper.bad : HeardTheme.Paper.accent
        return Button {
            togglePlayback(candidateID: candidateID, index: index, url: url)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Play sample \(index + 1)")
    }

    // MARK: Playback

    private func togglePlayback(candidateID: UUID, index: Int, url: URL) {
        if playingCandidateID == candidateID && playingClipIndex == index {
            stopAudio(); return
        }
        stopAudio()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
            playingCandidateID = candidateID
            playingClipIndex = index
            Task {
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                if playingCandidateID == candidateID && playingClipIndex == index {
                    playingCandidateID = nil
                    playingClipIndex = nil
                }
            }
        } catch {
            NSLog("Heard: Failed to play audio clip: \(error)")
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingCandidateID = nil
        playingClipIndex = nil
    }

    // MARK: Drafts

    private func binding(for candidate: NamingCandidate) -> Binding<String> {
        Binding(
            get: { drafts[candidate.id] ?? candidate.suggestedName ?? "" },
            set: { drafts[candidate.id] = $0 }
        )
    }

    private func draftText(for candidate: NamingCandidate) -> String {
        (drafts[candidate.id] ?? candidate.suggestedName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveSingle(_ candidate: NamingCandidate) {
        let name = draftText(for: candidate)
        guard !name.isEmpty else { return }
        model.saveSpeakerName(candidate: candidate, name: name)
        drafts.removeValue(forKey: candidate.id)
    }

    private func discardSingle(_ candidate: NamingCandidate) {
        stopAudio()
        model.discardCandidate(candidate)
        drafts.removeValue(forKey: candidate.id)
    }

    private func splitSingle(_ candidate: NamingCandidate) {
        stopAudio()
        model.splitCandidate(candidate)
        drafts.removeValue(forKey: candidate.id)
    }

    private func saveAll() {
        for candidate in model.namingCandidates {
            let name = draftText(for: candidate)
            if !name.isEmpty { model.saveSpeakerName(candidate: candidate, name: name) }
        }
        if !model.namingCandidates.isEmpty { model.skipNaming() }
    }
}

// MARK: - Speaker Voice Cell (Speakers tab playback)

@MainActor
final class SpeakerClipController: ObservableObject {
    @Published private(set) var playingSpeakerID: UUID?
    @Published private(set) var playingClipIndex: Int?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(speakerID: UUID, clipIndex: Int, clipURL: URL) {
        if playingSpeakerID == speakerID && playingClipIndex == clipIndex {
            stop(); return
        }
        stop()
        guard FileManager.default.fileExists(atPath: clipURL.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: clipURL)
            p.play()
            player = p
            playingSpeakerID = speakerID
            playingClipIndex = clipIndex
            let duration = p.duration
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.1))
                guard let self, !Task.isCancelled else { return }
                if self.playingSpeakerID == speakerID && self.playingClipIndex == clipIndex {
                    self.stop()
                }
            }
        } catch {
            NSLog("Heard: Failed to play speaker clip: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        stopTask?.cancel()
        stopTask = nil
        playingSpeakerID = nil
        playingClipIndex = nil
    }
}

struct SpeakerVoiceCell: View {
    let speaker: SpeakerProfile
    @ObservedObject var controller: SpeakerClipController

    private var availableClips: [(index: Int, url: URL)] {
        speaker.audioClipURLs.enumerated().compactMap { index, url in
            FileManager.default.fileExists(atPath: url.path) ? (index, url) : nil
        }
    }

    var body: some View {
        let clips = availableClips
        if clips.isEmpty {
            Image(systemName: "play.slash")
                .font(.system(size: 11))
                .foregroundStyle(HeardTheme.Paper.mute)
                .frame(width: 22, height: 20)
                .help("No voice sample saved")
        } else {
            HStack(spacing: 3) {
                ForEach(clips, id: \.index) { clip in
                    clipButton(index: clip.index, url: clip.url)
                }
            }
        }
    }

    private func clipButton(index: Int, url: URL) -> some View {
        let isPlaying = controller.playingSpeakerID == speaker.id && controller.playingClipIndex == index
        let tint = isPlaying ? HeardTheme.Paper.bad : HeardTheme.Paper.accent
        return Button {
            controller.toggle(speakerID: speaker.id, clipIndex: index, clipURL: url)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Play sample \(index + 1)")
    }
}

