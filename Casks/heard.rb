cask "heard" do
  version "0.2.2"
  # Run scripts/dmg.sh to build the release DMG, then fill in the SHA256 it prints.
  sha256 "65a620aa747a55121c4d82cfeab598bfc5f0796c4f402cebed7b91a0c6f906b3"

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
