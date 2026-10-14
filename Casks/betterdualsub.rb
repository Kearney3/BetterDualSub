cask "betterdualsub" do
  version "1.1.0"
  sha256 "aff30c03be87dc504b313ef63792dc8ebbe168b772241e1062dec76e6b7773ce"

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
