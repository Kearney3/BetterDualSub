cask "betterdualsub" do
  version "1.3.2"
  sha256 "d7a20469a5c297891c7666bb1bd5b6ade3cb02b0e88a7a14a54ba52870dda665"

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
