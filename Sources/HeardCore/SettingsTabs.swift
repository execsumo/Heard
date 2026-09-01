import AVFoundation
import SwiftUI

extension SettingsView {
    // MARK: General

    var generalSection: some View {
        paneScroll {
            sectionGroup("Profile") {
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack {
                            Text("Your Name")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            TextField("Used as speaker label in transcripts", text: settingsBinding(\.userName))
                                .textFieldStyle(TerminalTextFieldStyle())
                                .frame(width: 160)
                        }
                    }
                }
            }

            sectionGroup("Behavior") {
                SettingsCard {
                    ToggleRow(
                        title: "Launch at Login",
                        isOn: Binding(
                            get: { model.settingsStore.settings.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    ToggleRow(
                        title: "Show Dock Icon",
                        isOn: Binding(
                            get: { model.settingsStore.settings.showDockIcon },
                            set: { model.setDockIconVisible($0) }
                        )
                    )
                    CardRow(isLast: true) {
                        HStack {
                            Text("Appearance")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Picker("", selection: settingsBinding(\.appearance)) {
                                ForEach(AppAppearance.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                    }
                }
            }

            sectionGroup("Advanced") {
                SettingsCard {
                    ToggleRow(
                        title: "Show Advanced Settings",
                        subtitle: "Reveals models, performance, diarization, and debugging options.",
                        isLast: true,
                        isOn: settingsBinding(\.showAdvancedSettings)
                    )
                }
            }

            sectionGroup("Permissions") {
                SettingsCard {
                    let perms = model.permissionCenter.statuses
                    ForEach(Array(perms.enumerated()), id: \.offset) { _, perm in
                        CardRow(isLast: true) {
                            PermissionRow(permission: perm, model: model)
                        }
                    }
                }
            }
        }
    }

    // MARK: Recording

    var recordingSection: some View {
        paneScroll {
            sectionGroup("Meeting Detection") {
                SettingsCard {
                    ToggleRow(title: "Microsoft Teams", isOn: settingsBinding(\.enableTeamsDetection))
                    ToggleRow(title: "Zoom", isOn: settingsBinding(\.enableZoomDetection))
                    ToggleRow(title: "Webex", isOn: settingsBinding(\.enableWebexDetection))
                    ToggleRow(
                        title: "Auto-Watch & Record Meetings",
                        isLast: true,
                        isOn: Binding(
                            get: { model.settingsStore.settings.autoWatch },
                            set: { model.setAutoWatch($0) }
                        )
                    )
                }
            }

            sectionGroup("Microphone") {
                SettingsCard {
                    CardRow(isLast: true) {
                        MicrophonePickerRow(
                            selectedUID: model.settingsStore.settings.selectedInputDeviceUID,
                            onSelect: { model.setInputDeviceUID($0) }
                        )
                    }
                }
            }

            sectionGroup("Language") {
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack {
                            Text("Language")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Picker("", selection: settingsBinding(\.transcriptionModel)) {
                                ForEach(TranscriptionModel.allCases) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .frame(width: 160)
                        }
                    }
                }
            }

            sectionGroup("Custom Vocabulary") {
                SettingsCard {
                    CardRow {
                        HStack(spacing: 8) {
                            TextField("Term or phrase (e.g. AI, flip phone)", text: $model.vocabularyDraft)
                                .textFieldStyle(TerminalTextFieldStyle())
                                .onSubmit { model.addVocabularyTerm() }
                            Button("Add") { model.addVocabularyTerm() }
                                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                                .disabled(model.vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        }
                    }
                    if !model.settingsStore.settings.customVocabulary.isEmpty {
                        CardRow {
                            FlowLayout(model.settingsStore.settings.customVocabulary, id: \.self) { term in
                                HStack(spacing: 5) {
                                    Text(term).font(HeardFont.mono(11))
                                        .foregroundStyle(HeardTheme.Terminal.ink)
                                    Button {
                                        model.removeVocabularyTerm(term)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(HeardFont.mono(10))
                                            .foregroundStyle(HeardTheme.Terminal.mute)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                                .overlay(Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline))
                            }
                        }
                    }
                    CardRow(isLast: true) {
                        Text("\(model.settingsStore.settings.customVocabulary.count) / 50 entries")
                            .font(HeardFont.value)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                }
            }

            sectionGroup("Meeting Notes") {
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack {
                            Text("Meeting Note Hotkey")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Text(model.settingsStore.settings.meetingNoteHotkey.displayString)
                                .font(HeardFont.mono(11, .medium))
                                .foregroundStyle(HeardTheme.Terminal.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                                .overlay(Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline))
                            Button("Set Hotkey") { hotkeyTarget = .meetingNote }
                                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                        }
                    }
                }
            }

            sectionGroup("Meeting Chat") {
                SettingsCard {
                    ToggleRow(
                        title: "Include Meeting Chat in Transcript",
                        subtitle: "Off by default: this captures other participants' chat messages, not just your own notes.",
                        isLast: true,
                        isOn: settingsBinding(\.includeMeetingChat)
                    )
                }
            }

            sectionGroup("Output") {
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack {
                            Text("Save Location")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Text(model.settingsStore.settings.outputDirectory)
                                .font(HeardFont.value)
                                .foregroundStyle(HeardTheme.Terminal.mute)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .trailing)
                            Button("Choose…") { model.chooseOutputDirectory() }
                                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                            Button("Open") { model.openOutputDirectory() }
                                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                        }
                    }
                }
            }
        }
    }

    // MARK: Dictation

    var dictationSection: some View {
        paneScroll {
            sectionGroup("Dictation") {
                SettingsCard {
                    ToggleRow(
                        title: "Enable Dictation",
                        subtitle: "Press the hotkey to start/stop dictating into any text field.",
                        isOn: Binding(
                            get: { model.settingsStore.settings.dictationEnabled },
                            set: { model.setDictationEnabled($0) }
                        )
                    )
                    ToggleRow(
                        title: "Show Dictation Indicator",
                        subtitle: "A floating pill appears on screen when dictation is active.",
                        isLast: true,
                        isOn: settingsBinding(\.showDictationHUD)
                    )
                    .disabled(!model.settingsStore.settings.dictationEnabled)
                }
            }

            sectionGroup("Hotkey") {
                SettingsCard {
                    ToggleRow(
                        title: "Push to Talk",
                        subtitle: "Hold the hotkey to dictate, release to stop.",
                        isLast: false,
                        isOn: Binding(
                            get: { model.settingsStore.settings.pushToTalk },
                            set: { model.setPushToTalk($0) }
                        )
                    )
                    .disabled(!model.settingsStore.settings.dictationEnabled)

                    CardRow(isLast: true) {
                        HStack {
                            Text("Dictation Hotkey")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Text(model.settingsStore.settings.dictationHotkey.displayString)
                                .font(HeardFont.mono(11, .medium))
                                .foregroundStyle(HeardTheme.Terminal.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                                .overlay(Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline))
                            Button("Set Hotkey") { hotkeyTarget = .dictation }
                                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                                .disabled(!model.settingsStore.settings.dictationEnabled)
                        }
                    }
                }
            }

            sectionGroup("Custom Formatting Commands") {
                SettingsCard {
                    let cmds = model.settingsStore.settings.formattingCommands
                    if cmds.isEmpty {
                        CardRow {
                            Text("No custom formatting commands.")
                                .font(HeardFont.body)
                                .foregroundStyle(HeardTheme.Terminal.mute)
                        }
                    } else {
                        ForEach(cmds) { cmd in
                            CardRow(isLast: false) {
                                HStack {
                                    Text(cmd.spoken)
                                        .font(HeardFont.mono(11))
                                        .foregroundStyle(HeardTheme.Terminal.ink)
                                    Image(systemName: "arrow.right")
                                        .font(HeardFont.mono(10))
                                        .foregroundStyle(HeardTheme.Terminal.mute)
                                    Text(cmd.written.replacingOccurrences(of: "\n", with: "\\n"))
                                        .font(HeardFont.mono(11))
                                        .foregroundStyle(HeardTheme.Terminal.mute)
                                    Spacer()
                                    Button {
                                        model.removeFormattingCommand(id: cmd.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(HeardTheme.Terminal.mute)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    CardRow(isLast: true) {
                        HStack(spacing: 8) {
                            TextField("Spoken (e.g. 'new paragraph')", text: $commandSpokenDraft)
                                .textFieldStyle(TerminalTextFieldStyle())
                            TextField("Written (e.g. '\\n\\n')", text: $commandWrittenDraft)
                                .textFieldStyle(TerminalTextFieldStyle())
                            Button("Add") {
                                let written = commandWrittenDraft.replacingOccurrences(of: "\\n", with: "\n")
                                model.addFormattingCommand(spoken: commandSpokenDraft, written: written)
                                commandSpokenDraft = ""
                                commandWrittenDraft = ""
                            }
                            .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                            .disabled(
                                commandSpokenDraft.trimmingCharacters(in: .whitespaces).isEmpty ||
                                commandWrittenDraft.trimmingCharacters(in: .whitespaces).isEmpty
                            )
                        }
                    }
                }
            }

            if model.isDictating {
                sectionGroup("Status") {
                    SettingsCard {
                        CardRow(isLast: true) {
                            HStack(spacing: 8) {
                                StatusDot(color: HeardTheme.Terminal.bad, pulsing: true)
                                Text("Dictating…")
                                    .font(HeardFont.bodyMedium)
                                    .foregroundStyle(HeardTheme.Terminal.ink)
                            }
                        }
                    }
                }
            }

            if let error = model.dictationError {
                sectionGroup("Error") {
                    SettingsCard {
                        CardRow(isLast: true) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(HeardTheme.Terminal.bad)
                                Text(error)
                                    .font(HeardFont.caption)
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Meetings

    var meetingsSection: some View {
        TranscriptLibraryView(model: model)
    }

    // MARK: Speakers

    var speakersSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.md) {
                if !model.namingCandidates.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(HeardTheme.Terminal.warn)
                            .font(HeardFont.body)
                        Text("\(model.namingCandidates.count) new speaker\(model.namingCandidates.count == 1 ? "" : "s") waiting to be named")
                            .font(HeardFont.body)
                            .foregroundStyle(HeardTheme.Terminal.warn)
                        Spacer()
                        Button("Name Speakers…") {
                            openWindow(id: "speaker-naming")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                    }
                    .padding(12)
                    .background(Rectangle().fill(HeardTheme.Terminal.warnSoft))
                    .overlay(Rectangle().stroke(HeardTheme.Terminal.warn.opacity(0.4), lineWidth: HeardTheme.Stroke.hairline))
                }

                HStack(spacing: HeardTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(HeardTheme.Terminal.mute)
                            .font(HeardFont.body)
                        TextField("Search speakers", text: $model.speakerFilter)
                            .textFieldStyle(.plain)
                            .font(HeardFont.body)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                    .overlay(Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline))
                    .frame(width: 160)

                    Spacer()

                    if !model.mergeSelection.isEmpty {
                        Text("\(model.mergeSelection.count) selected")
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }

                    Button("Merge Selected") { model.mergeSelectedSpeakers() }
                        .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
                        .disabled(model.mergeSelection.count < 2)
                }
            }
            .padding(HeardTheme.Spacing.lg)
            .background(HeardTheme.Terminal.bg)

            HeardTheme.Terminal.border.frame(height: HeardTheme.Stroke.hairline)

            Table(model.filteredSpeakers.sorted(using: tableSortOrder),
                  selection: $model.mergeSelection,
                  sortOrder: $tableSortOrder) {
                TableColumn("Select") { speaker in
                    Button {
                        if model.mergeSelection.contains(speaker.id) {
                            model.mergeSelection.remove(speaker.id)
                        } else {
                            model.mergeSelection.insert(speaker.id)
                        }
                    } label: {
                        Image(systemName: model.mergeSelection.contains(speaker.id)
                              ? "checkmark.square.fill"
                              : "square")
                            .foregroundStyle(model.mergeSelection.contains(speaker.id)
                                             ? HeardTheme.Terminal.accent
                                             : HeardTheme.Terminal.muteSoft)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .help("Select this speaker for merging")
                    .accessibilityLabel("Select \(speaker.name) for merging")
                    .accessibilityValue(model.mergeSelection.contains(speaker.id) ? "Selected" : "Not selected")
                }
                .width(min: 44, ideal: 50, max: 56)
                TableColumn("Voice") { speaker in
                    SpeakerVoiceCell(speaker: speaker, controller: clipPlayer)
                }
                .width(min: 80, ideal: 100, max: 130)
                TableColumn("Name", value: \.name) { speaker in
                    InlineEditableText(value: speaker.name) { newValue in
                        model.renameSpeaker(id: speaker.id, to: newValue)
                    }
                }
                TableColumn("Meetings", value: \.meetingCount) { speaker in
                    Text("\(speaker.meetingCount)").monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Time in Meetings", value: \.totalMeetingDuration) { speaker in
                    Text(Self.durationText(speaker.totalMeetingDuration)).monospacedDigit()
                }
                TableColumn("Speaking Time", value: \.totalSpeakingTime) { speaker in
                    Text(Self.durationText(speaker.totalSpeakingTime)).monospacedDigit()
                }
                TableColumn("Last Seen", value: \.lastSeen) { speaker in
                    Text(speaker.lastSeen.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Delete Speaker", role: .destructive) {
                        clipPlayer.stop()
                        model.speakerStore.delete(id: id)
                    }
                }
            }

            HeardTheme.Terminal.border.frame(height: HeardTheme.Stroke.hairline)

            HStack(spacing: HeardTheme.Spacing.sm) {
                Text("Archive inactive speakers after")
                    .font(HeardFont.bodyMedium)
                    .foregroundStyle(HeardTheme.Terminal.ink)
                Picker("", selection: settingsBinding(\.speakerRetentionDays)) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("Unseen profiles are removed on next launch.")
                    .font(HeardFont.caption)
                    .foregroundStyle(HeardTheme.Terminal.mute)
            }
            .padding(.horizontal, HeardTheme.Spacing.lg)
            .padding(.vertical, HeardTheme.Spacing.sm)
            .background(HeardTheme.Terminal.bg)
        }
        .background(HeardTheme.Terminal.bg)
    }

    /// Compact duration for the speaker-stats columns: "2h 05m", "14m", "38s".
    static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }

    // MARK: Advanced

    var advancedSection: some View {
        paneScroll {
            // Hero card — flat recordingBg fill, 1px border (DESIGN.md: backgrounds stay flat)
            let readyCount = model.modelCatalog.statuses.filter { $0.availability == .ready }.count
            let totalCount = model.modelCatalog.statuses.count

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(readyCount) of \(totalCount) models ready")
                        .font(HeardFont.title)
                        .foregroundStyle(HeardTheme.Terminal.recordingInk)
                    Text(model.downloadManager.allBatchModelsReady
                         ? "Ready to transcribe"
                         : "Some models need downloading")
                        .font(HeardFont.caption)
                        .foregroundStyle(HeardTheme.Terminal.recordingInk.opacity(0.65))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if !model.downloadManager.allBatchModelsReady {
                        Button("Download Missing") {
                            model.downloadManager.downloadAllModels()
                        }
                        .buttonStyle(HeroButtonStyle())
                    }
                    Button("Unload All") {
                        model.pipelineProcessor.unloadPipelineModels()
                        model.dictationManager.unloadModels()
                    }
                    .buttonStyle(HeroButtonStyle(isDanger: true))
                    .disabled(model.pipelineProcessor.isProcessing || model.isDictating)
                }
            }
            .padding(14)
            .background(HeardTheme.Terminal.recordingBg)
            .overlay(
                Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline)
            )

            sectionGroup("Models on Disk") {
                SettingsCard {
                    ForEach(Array(model.modelCatalog.statuses.enumerated()), id: \.offset) { index, item in
                        CardRow(isLast: index == model.modelCatalog.statuses.count - 1) {
                            ModelStatusRow(item: item, downloadManager: model.downloadManager)
                        }
                    }
                }
            }

            sectionGroup("Model Keep-Alive") {
                SettingsCard {
                    CardRow(isLast: false) {
                        HStack {
                            Text("Keep models loaded for")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            TextField("Minutes", value: settingsBinding(\.modelKeepAlive), format: .number)
                                .textFieldStyle(.plain)
                                .font(HeardFont.value)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 40)
                                .padding(4)
                                .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
                                .overlay(Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline))
                            Text("minutes")
                                .font(HeardFont.body)
                                .foregroundStyle(HeardTheme.Terminal.mute)
                        }
                    }
                    CardRow(isLast: true) {
                        Text("Keeping models loaded speeds up back-to-back meetings and dictation, but uses ~800 MB RAM. Set to 0 to unload immediately.")
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                }
            }

            sectionGroup("Diarization") {
                SettingsCard {
                    CardRow(isLast: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speaker separation")
                                    .font(HeardFont.bodyMedium)
                                    .foregroundStyle(HeardTheme.Terminal.ink)
                                Spacer()
                                Text(String(format: "%.2f", model.settingsStore.settings.diarizationClusteringSimilarity))
                                    .font(HeardFont.value)
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                            }
                            HStack(spacing: 8) {
                                Text("Fewer speakers")
                                    .font(HeardFont.mono(10))
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                                Slider(
                                    value: settingsBinding(\.diarizationClusteringSimilarity),
                                    in: 0.40...0.85,
                                    step: 0.05
                                )
                                Text("More speakers")
                                    .font(HeardFont.mono(10))
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                            }
                        }
                    }
                    CardRow(isLast: false) {
                        Text("Cosine-similarity threshold for clustering voice embeddings. Higher values err on the side of splitting one person across two profiles (which you can merge in the Speakers tab); lower values may collapse two voices into one (harder to recover from). Default: 0.65.")
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                    CardRow(isLast: true) {
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                model.settingsStore.settings.diarizationClusteringSimilarity =
                                    AppSettings.default.diarizationClusteringSimilarity
                            }
                            .buttonStyle(TerminalButtonStyle(.ghost, size: .sm))
                        }
                    }
                }
            }

            sectionGroup("Voice Matching") {
                SettingsCard {
                    CardRow(isLast: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Match strictness")
                                    .font(HeardFont.bodyMedium)
                                    .foregroundStyle(HeardTheme.Terminal.ink)
                                Spacer()
                                Text(String(format: "%.2f", model.settingsStore.settings.speakerMatchThreshold))
                                    .font(HeardFont.value)
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                            }
                            HStack(spacing: 8) {
                                Text("Stricter")
                                    .font(HeardFont.mono(10))
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                                Slider(
                                    value: settingsBinding(\.speakerMatchThreshold),
                                    in: 0.15...0.45,
                                    step: 0.05
                                )
                                Text("Looser")
                                    .font(HeardFont.mono(10))
                                    .foregroundStyle(HeardTheme.Terminal.mute)
                            }
                        }
                    }
                    CardRow(isLast: false) {
                        Text("How close a voice must be to a saved profile to be recognized as the same person across meetings. Stricter asks you to name people more often but almost never mislabels; looser recognizes more voices automatically at some risk of matching the wrong profile. Default: 0.30.")
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                    CardRow(isLast: true) {
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                model.settingsStore.settings.speakerMatchThreshold =
                                    AppSettings.default.speakerMatchThreshold
                            }
                            .buttonStyle(TerminalButtonStyle(.ghost, size: .sm))
                        }
                    }
                }
            }

            sectionGroup("Memory") {
                SettingsCard {
                    CardRow {
                        HStack {
                            Text("Low Memory Mode")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            Picker("", selection: settingsBinding(\.memoryMode)) {
                                ForEach(MemoryMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .frame(width: 160)
                        }
                    }
                    CardRow(isLast: true) {
                        Text(memoryModeSubtitle)
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                }
            }

            sectionGroup("Debugging") {
                SettingsCard {
                    ToggleRow(
                        title: "Developer Mode",
                        subtitle: "Shows simulate meeting buttons for testing",
                        isLast: true,
                        isOn: settingsBinding(\.developerMode)
                    )
                }
            }
        }
    }

    // MARK: About

    var aboutSection: some View {
        ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 40)
                    HeardMark(size: 72)
                    VStack(spacing: 4) {
                        Text("Heard")
                            .font(HeardFont.headlineLG)
                            .foregroundStyle(HeardTheme.Terminal.ink)
                        Text("Version \(model.updateChecker.currentVersion)")
                            .font(HeardFont.value)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                    .padding(.top, 20)

                    if let version = model.updateChecker.availableVersion,
                       let url = model.updateChecker.releaseURL {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("v\(version) is available — click to download")
                            }
                            .font(HeardFont.bodyMedium)
                            .foregroundStyle(HeardTheme.Terminal.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Rectangle().fill(HeardTheme.Terminal.accentSoft))
                            .overlay(Rectangle().stroke(HeardTheme.Terminal.accent.opacity(0.4), lineWidth: HeardTheme.Stroke.hairline))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    } else {
                        Button {
                            Task { await model.updateChecker.check() }
                        } label: {
                            HStack(spacing: 5) {
                                if model.updateChecker.isChecking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(model.updateChecker.isChecking ? "Checking…" : "Check for updates")
                            }
                            .font(HeardFont.body)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.updateChecker.isChecking)
                        .padding(.top, 8)
                    }

                    Text("Automatic meeting detection, dual-track recording,\non-device transcription and speaker diarization.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(HeardTheme.Terminal.ink2)
                        .font(HeardFont.body)
                        .padding(.top, 12)

                    HStack(spacing: HeardTheme.Spacing.sm) {
                        AboutBadge(icon: "lock.shield", text: "On-device")
                        AboutBadge(icon: "icloud.slash", text: "No cloud")
                        AboutBadge(icon: "brain.head.profile", text: "No LLM")
                    }
                    .padding(.top, 16)

                    Spacer().frame(height: 40)
                }
                .frame(minWidth: 500, minHeight: 500)
                .background(HeardTheme.Terminal.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Terminal.bg)
    }

}
