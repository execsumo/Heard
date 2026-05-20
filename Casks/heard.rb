cask "heard" do
  version "0.2.1"
  # Run scripts/dmg.sh to build the release DMG, then fill in the SHA256 it prints.
  sha256 "c59e1c41a7e49b46923d7f8e7cf6bb5edbc75f4ef056768ee447b94e172872f6"

  url "https://github.com/execsumo/heard/releases/download/v#{version}/Heard-#{version}.dmg"
  name "Heard"
  desc "Menu bar app that auto-records and transcribes Microsoft Teams meetings on-device"
  homepage "https://github.com/execsumo/heard"

  # macOS 15 Sequoia or later required (uses CATapDescription process tap)
  depends_on macos: ">= :sequoia"

  app "Heard.app"

  zap trash: [
    "~/Library/Application Support/Heard",
    "~/Library/Preferences/com.execsumo.heard.plist",
  ]
end
