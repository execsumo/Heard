cask "heard" do
  version "0.3.2"
  # Run scripts/dmg.sh to build the release DMG, then fill in the SHA256 it prints.
  sha256 "6c6e12fafd4bfa2db4af8049fd2abb4c4c11546107db6628d0ed1f9f6498816b"

  url "https://github.com/execsumo/heard/releases/download/v#{version}/Heard-#{version}.dmg"
  name "Heard"
  desc "Menu bar app that auto-records and transcribes Microsoft Teams meetings on-device"
  homepage "https://github.com/execsumo/heard"

  # The app bundle declares macOS 15.0 as LSMinimumSystemVersion.
  # Keep the cask free of the deprecated macOS dependency stanza.
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
