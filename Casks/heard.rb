cask "heard" do
  version "0.2.5"
  # Run scripts/dmg.sh to build the release DMG, then fill in the SHA256 it prints.
  sha256 "43c12ca1c433c3cf1815f8825311e1941fc940c1ddbaf05188b5acf2df745cba"

  url "https://github.com/execsumo/heard/releases/download/v#{version}/Heard-#{version}.dmg"
  name "Heard"
  desc "Menu bar app that auto-records and transcribes Microsoft Teams meetings on-device"
  homepage "https://github.com/execsumo/heard"

  # macOS 15 Sequoia or later required (uses CATapDescription process tap)
  depends_on macos: ">= :sequoia"

  app "Heard.app"

  # Quit the running menu bar app before uninstalling so the bundle isn't replaced
  # under a live process (stale TCC/permission state otherwise survives the swap).
  uninstall quit: "com.execsumo.heard"

  # `brew uninstall --zap heard` removes all app data. Note: a plain `brew uninstall`
  # intentionally keeps these so settings/speaker profiles survive an upgrade.
  zap trash: [
    "~/Library/Application Support/FluidAudio", # on-device ML model cache (can be several GB)
    "~/Library/Application Support/Heard",
    "~/Library/Caches/com.execsumo.heard",
    "~/Library/HTTPStorages/com.execsumo.heard",
    "~/Library/Preferences/com.execsumo.heard.plist", # UserDefaults incl. cached TCC-granted flags
    "~/Library/Saved Application State/com.execsumo.heard.savedState",
  ]
end
