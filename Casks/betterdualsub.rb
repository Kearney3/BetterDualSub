cask "betterdualsub" do
  version "1.2.0"
  sha256 "3c0ca9105c48a00193cd42ab5300a4f7222e177c9d6de57dca8a933b5301280d"

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
