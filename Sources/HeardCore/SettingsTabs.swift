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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                            Spacer()
                            TextField("Used as speaker label in transcripts", text: settingsBinding(\.userName))
                                .textFieldStyle(.roundedBorder)
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
                        isLast: true,
                        isOn: Binding(
                            get: { model.settingsStore.settings.showDockIcon },
                            set: { model.setDockIconVisible($0) }
                        )
                    )
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
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
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.addVocabularyTerm() }
                            Button("Add") { model.addVocabularyTerm() }
                                .disabled(model.vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        }
                    }
                    if !model.settingsStore.settings.customVocabulary.isEmpty {
                        CardRow {
                            FlowLayout(model.settingsStore.settings.customVocabulary, id: \.self) { term in
                                HStack(spacing: 5) {
                                    Text(term).font(.system(size: 12))
                                        .foregroundStyle(HeardTheme.Paper.ink)
                                    Button {
                                        model.removeVocabularyTerm(term)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(HeardTheme.Paper.mute)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(HeardTheme.Paper.surfaceAlt, in: Capsule())
                            }
                        }
                    }
                    CardRow(isLast: true) {
                        Text("\(model.settingsStore.settings.customVocabulary.count) / 50 entries")
                            .font(.system(size: 11))
                            .foregroundStyle(HeardTheme.Paper.mute)
                    }
                }
            }

            sectionGroup("Meeting Notes") {
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack {
                            Text("Meeting Note Hotkey")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                            Spacer()
                            Text(model.settingsStore.settings.meetingNoteHotkey.displayString)
                                .font(.system(size: 11, design: .monospaced).weight(.medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(HeardTheme.Paper.surfaceAlt,
                                            in: RoundedRectangle(cornerRadius: 5))
                            Button("Set Hotkey") { hotkeyTarget = .meetingNote }
                                .controlSize(.small)
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                            Spacer()
                            Text(model.settingsStore.settings.outputDirectory)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HeardTheme.Paper.mute)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .trailing)
                            Button("Choose…") { model.chooseOutputDirectory() }
                                .controlSize(.small)
                            Button("Open") { model.openOutputDirectory() }
                                .controlSize(.small)
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                            Spacer()
                            Text(model.settingsStore.settings.dictationHotkey.displayString)
                                .font(.system(size: 11, design: .monospaced).weight(.medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(HeardTheme.Paper.surfaceAlt,
                                            in: RoundedRectangle(cornerRadius: 5))
                            Button("Set Hotkey") { hotkeyTarget = .dictation }
                                .controlSize(.small)
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
                                .font(.system(size: 12))
                                .foregroundStyle(HeardTheme.Paper.mute)
                        }
                    } else {
                        ForEach(cmds) { cmd in
                            CardRow(isLast: false) {
                                HStack {
                                    Text(cmd.spoken)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(HeardTheme.Paper.ink)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(HeardTheme.Paper.mute)
                                    Text(cmd.written.replacingOccurrences(of: "\n", with: "\\n"))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(HeardTheme.Paper.mute)
                                    Spacer()
                                    Button {
                                        model.removeFormattingCommand(id: cmd.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(HeardTheme.Paper.mute)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    CardRow(isLast: true) {
                        HStack(spacing: 8) {
                            TextField("Spoken (e.g. 'new paragraph')", text: $commandSpokenDraft)
                                .textFieldStyle(.roundedBorder)
                            TextField("Written (e.g. '\\n\\n')", text: $commandWrittenDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let written = commandWrittenDraft.replacingOccurrences(of: "\\n", with: "\n")
                                model.addFormattingCommand(spoken: commandSpokenDraft, written: written)
                                commandSpokenDraft = ""
                                commandWrittenDraft = ""
                            }
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
                                StatusDot(color: HeardTheme.Paper.bad, pulsing: true)
                                Text("Dictating…")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(HeardTheme.Paper.ink)
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
                                    .foregroundStyle(HeardTheme.Paper.bad)
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(HeardTheme.Paper.mute)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Speakers

    var speakersSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.md) {
                if !model.namingCandidates.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(HeardTheme.Paper.warn)
                            .font(.system(size: 12))
                        Text("New speakers detected — open the speaker naming window to identify them")
                            .font(.system(size: 12))
                            .foregroundStyle(HeardTheme.Paper.warn)
                        Spacer()
                    }
                    .padding(12)
                    .background(HeardTheme.Paper.warnSoft,
                                in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                }

                HStack(spacing: HeardTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(HeardTheme.Paper.mute)
                            .font(.system(size: 12))
                        TextField("Search speakers", text: $model.speakerFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(HeardTheme.Paper.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                    .frame(width: 160)

                    Spacer()

                    Button("Merge Selected") { model.mergeSelectedSpeakers() }
                        .disabled(model.mergeSelection.count != 2)
                }
            }
            .padding(HeardTheme.Spacing.lg)
            .background(HeardTheme.Paper.bg)

            HeardTheme.Paper.border.frame(height: 0.5)

            Table(model.filteredSpeakers.sorted(using: tableSortOrder),
                  selection: $model.mergeSelection,
                  sortOrder: $tableSortOrder) {
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
                TableColumn("Time in Meetings") { speaker in
                    let hours = Int(speaker.totalMeetingDuration) / 3600
                    let minutes = (Int(speaker.totalMeetingDuration) % 3600) / 60
                    if hours > 0 {
                        Text("\(hours)h \(minutes)m").monospacedDigit()
                    } else {
                        Text("\(minutes)m").monospacedDigit()
                    }
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

            HeardTheme.Paper.border.frame(height: 0.5)

            HStack(spacing: HeardTheme.Spacing.sm) {
                Text("Archive inactive speakers after")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HeardTheme.Paper.ink)
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }
            .padding(.horizontal, HeardTheme.Spacing.lg)
            .padding(.vertical, HeardTheme.Spacing.sm)
            .background(HeardTheme.Paper.bg)
        }
        .background(HeardTheme.Paper.bg)
    }

    // MARK: Advanced

    var advancedSection: some View {
        paneScroll {
            // Hero card (dark gradient)
            let readyCount = model.modelCatalog.statuses.filter { $0.availability == .ready }.count
            let totalCount = model.modelCatalog.statuses.count

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(readyCount) of \(totalCount) models ready")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "F5EFE4"))
                    Text(model.downloadManager.allBatchModelsReady
                         ? "Ready to transcribe"
                         : "Some models need downloading")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "F5EFE4").opacity(0.65))
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
            .background(
                LinearGradient(
                    colors: [Color(hex: "2E3338"), Color(hex: "1C2024")],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: HeardTheme.Radius.card)
                    .stroke(Color(hex: "3A3F47"), lineWidth: 0.5)
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
                            Spacer()
                            TextField("Minutes", value: settingsBinding(\.modelKeepAlive), format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 40)
                                .padding(4)
                                .background(Color.black.opacity(0.05))
                                .cornerRadius(4)
                            Text("minutes")
                                .font(.system(size: 12))
                                .foregroundStyle(HeardTheme.Paper.mute)
                        }
                    }
                    CardRow(isLast: true) {
                        Text("Keeping models loaded speeds up back-to-back meetings and dictation, but uses ~800 MB RAM. Set to 0 to unload immediately.")
                            .font(.system(size: 11))
                            .foregroundStyle(HeardTheme.Paper.mute)
                    }
                }
            }

            sectionGroup("Diarization") {
                SettingsCard {
                    CardRow(isLast: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speaker separation")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(HeardTheme.Paper.ink)
                                Spacer()
                                Text(String(format: "%.2f", model.settingsStore.settings.diarizationClusteringSimilarity))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(HeardTheme.Paper.mute)
                            }
                            HStack(spacing: 8) {
                                Text("Fewer speakers")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HeardTheme.Paper.mute)
                                Slider(
                                    value: settingsBinding(\.diarizationClusteringSimilarity),
                                    in: 0.40...0.85,
                                    step: 0.05
                                )
                                Text("More speakers")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HeardTheme.Paper.mute)
                            }
                        }
                    }
                    CardRow(isLast: false) {
                        Text("Cosine-similarity threshold for clustering voice embeddings. Higher values err on the side of splitting one person across two profiles (which you can merge in the Speakers tab); lower values may collapse two voices into one (harder to recover from). Default: 0.65.")
                            .font(.system(size: 11))
                            .foregroundStyle(HeardTheme.Paper.mute)
                    }
                    CardRow(isLast: true) {
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                model.settingsStore.settings.diarizationClusteringSimilarity =
                                    AppSettings.default.diarizationClusteringSimilarity
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HeardTheme.Paper.accent)
                        }
                    }
                }
            }

            sectionGroup("Memory") {
                SettingsCard {
                    CardRow {
                        HStack {
                            Text("Low Memory Mode")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HeardTheme.Paper.ink)
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
                            .font(.system(size: 11))
                            .foregroundStyle(HeardTheme.Paper.mute)
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
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(HeardTheme.Paper.ink)
                        Text("Version \(model.updateChecker.currentVersion)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(HeardTheme.Paper.mute)
                    }
                    .padding(.top, 20)

                    if let version = model.updateChecker.availableVersion,
                       let url = model.updateChecker.releaseURL {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("v\(version) is available — click to download")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HeardTheme.Paper.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(HeardTheme.Paper.accentSoft, in: RoundedRectangle(cornerRadius: 8))
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
                            .font(.system(size: 12))
                            .foregroundStyle(HeardTheme.Paper.mute)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.updateChecker.isChecking)
                        .padding(.top, 8)
                    }

                    Text("Automatic meeting detection, dual-track recording,\non-device transcription and speaker diarization.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(HeardTheme.Paper.ink2)
                        .font(.system(size: 12))
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
                .background(HeardTheme.Paper.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeardTheme.Paper.bg)
    }

}
