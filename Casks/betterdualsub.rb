cask "betterdualsub" do
  version "1.3.1"
  sha256 "8142b8e2ff46f076644b7d3cbe3e7beed17953813962632c05e0c915fa094b2f"

  url "https://github.com/Kearney3/BetterDualSub/releases/download/v#{version}/BetterDualSub-v#{version}-arm64.dmg"
  name "BetterDualSub"
  desc "External bilingual subtitles for the Apple TV app"
  homepage "https://github.com/Kearney3/BetterDualSub"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "BetterDualSub.app"

  # The app is ad-hoc signed and not notarized, so Gatekeeper would refuse to open a quarantined copy.
  # Removing an attribute that is already gone fails, which is fine.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/BetterDualSub.app"],
        must_succeed: false
  end

  zap trash: [
    "~/Library/Application Support/BetterDualSub",
    "~/Library/Preferences/studio.bbit.betterdualsub.plist",
  ]
end
