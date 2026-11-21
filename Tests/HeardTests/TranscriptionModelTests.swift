import Foundation
import HeardCore

// MARK: - Transcription model selection: default, engine mapping, saved-setting compatibility

private func tmFreshDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "heard.tests.transcriptionModel.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private func tmScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("heard-tm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func runTranscriptionModelTests() {
    print("\n🎚️ Transcription Model Tests")

    test("English Unified is the default for new settings") {
        try expectEqual(AppSettings.default.transcriptionModel, .unified)
    }

    test("saved v2 and v3 selections keep their value") {
        for model in [TranscriptionModel.v2, .v3] {
            let (defaults, suite) = tmFreshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(model.rawValue, forKey: "transcriptionModel")
            try expectEqual(SettingsStore(defaults: defaults).settings.transcriptionModel, model)
        }
    }

    test("saved unified selection decodes") {
        let (defaults, suite) = tmFreshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unified", forKey: "transcriptionModel")
        try expectEqual(SettingsStore(defaults: defaults).settings.transcriptionModel, .unified)
    }

    test("missing saved key falls back to English Unified") {
        let (defaults, suite) = tmFreshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try expectEqual(SettingsStore(defaults: defaults).settings.transcriptionModel, .unified)
    }

    test("unknown saved value falls back to English Unified") {
        let (defaults, suite) = tmFreshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("parakeet-future", forKey: "transcriptionModel")
        try expectEqual(SettingsStore(defaults: defaults).settings.transcriptionModel, .unified)
    }

    test("loading settings does not rewrite the saved model key") {
        let (saved, savedSuite) = tmFreshDefaults()
        defer { saved.removePersistentDomain(forName: savedSuite) }
        saved.set("v2", forKey: "transcriptionModel")
        _ = SettingsStore(defaults: saved)
        try expectEqual(saved.string(forKey: "transcriptionModel"), "v2")

        let (missing, missingSuite) = tmFreshDefaults()
        defer { missing.removePersistentDomain(forName: missingSuite) }
        _ = SettingsStore(defaults: missing)
        try expect(missing.object(forKey: "transcriptionModel") == nil, "Init must not persist a default model")
    }

    test("only English Unified uses the Unified engine") {
        try expect(TranscriptionModel.unified.usesUnifiedEngine, "unified should use the Unified engine")
        try expect(!TranscriptionModel.v2.usesUnifiedEngine, "v2 should not")
        try expect(!TranscriptionModel.v3.usesUnifiedEngine, "v3 should not")
    }

    test("dictation runs English (Optimized) while Unified is selected") {
        try expectEqual(TranscriptionModel.unified.dictationEngine, .v2)
        try expectEqual(TranscriptionModel.v2.dictationEngine, .v2)
        try expectEqual(TranscriptionModel.v3.dictationEngine, .v3)
    }

    test("blank token IDs: unified and v2 use 1024, v3 uses 8192") {
        try expectEqual(TranscriptionModel.unified.blankId, 1024)
        try expectEqual(TranscriptionModel.v2.blankId, 1024)
        try expectEqual(TranscriptionModel.v3.blankId, 8192)
    }

    test("display names and picker order") {
        try expectEqual(TranscriptionModel.unified.displayName, "English Unified (Beta)")
        try expectEqual(TranscriptionModel.v2.displayName, "English (Optimized)")
        try expectEqual(TranscriptionModel.v3.displayName, "European Languages (Beta)")
        try expectEqual(TranscriptionModel.allCases.first, .unified)
    }

    test("Unified required files match FluidAudio's int8 offline bundle set") {
        try expectEqual(UnifiedModelAssets.requiredFiles, [
            "parakeet_unified_encoder_int8.mlmodelc",
            "parakeet_unified_decoder.mlmodelc",
            "parakeet_unified_joint_decision_single_step.mlmodelc",
            "vocab.json",
        ])
        try expectEqual(UnifiedModelAssets.cacheDirectory.lastPathComponent, "parakeet-unified-en-0.6b-coreml")
    }

    test("Unified readiness requires every file") {
        let dir = try tmScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try expect(!UnifiedModelAssets.isComplete(at: dir), "empty directory must not be ready")

        for name in UnifiedModelAssets.requiredFiles.dropLast() {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try expect(!UnifiedModelAssets.isComplete(at: dir), "missing vocab.json must not be ready")

        try Data("{}".utf8).write(to: dir.appendingPathComponent("vocab.json"))
        try expect(UnifiedModelAssets.isComplete(at: dir), "full set must be ready")
    }

    test("dictation's v2 check reads only FluidAudio's default cache") {
        try expectEqual(DictationManager.englishOptimizedCacheDirectory, AsrModels.defaultCacheDirectory(for: .v2))
        let dir = try tmScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try expect(!DictationManager.englishOptimizedCached(at: dir), "an empty directory must not count as cached")
    }

    test("batch detail adds dictation state only for Unified with dictation on") {
        try expectEqual(ModelDownloadManager.batchDetail(readiness: "Ready", selected: .unified, dictationEnabled: false), "Ready")
        try expectEqual(ModelDownloadManager.batchDetail(readiness: "Ready", selected: .v3, dictationEnabled: true), "Ready")
        try expectEqual(ModelDownloadManager.batchDetail(readiness: "Ready", selected: .v2, dictationEnabled: true), "Ready")
        let detail = ModelDownloadManager.batchDetail(readiness: "Ready", selected: .unified, dictationEnabled: true)
        try expect(detail.hasPrefix("Ready · dictation: English (Optimized) "), "unexpected detail: \(detail)")
    }
}
