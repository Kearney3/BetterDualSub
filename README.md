<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub icon"></p>

<h1 align="center">BetterDualSub</h1>

<p align="center">Bilingual external subtitles for the Apple TV app on macOS.</p>

<p align="center"><strong>English</strong> | <a href="README.zh-CN.md">简体中文</a></p>

The Apple TV app on the Mac shows one subtitle language at a time and cannot load your own subtitle files. BetterDualSub shows one or two subtitle tracks in a floating overlay above the video and keeps them in step with the playing movie, so you can watch with, for example, English and Chinese at once.

## Features

- **Three subtitle sources**: download tracks from an Apple TV movie link, extract them from an episode downloaded in the TV app (`.movpkg`), or open your own `.srt`, `.vtt`, `.ass` or `.ssa` files.
- **Two tracks at once**, each with its own font, color, outline and line layout.
- **Follows playback** of the Apple TV app, or of any other player that reports Now Playing (IINA, VLC, QuickTime Player, browsers…), including pauses, seeks and playback speed. A manual clock takes over when nothing is playing.
- **Visible sync status** in the menu bar, on the overlay and in the app, with a one-click fix when subtitles are not following the right player.
- **Timing tools**: per-track delays, global shortcuts, and alignment by picking the line you hear. Timing is remembered per title.
- **On-device translation**: create a second language from the first with macOS translation. Subtitle text never leaves your Mac.
- **Bilingual export**: merge two subtitle files into one bilingual SRT.
- Interface in English and Simplified Chinese.

## Requirements

- A Mac with Apple silicon running macOS 26 or later.
- The Apple TV app, or another player that reports Now Playing information.

## Install

### Homebrew (recommended)

```sh
brew tap kearney3/betterdualsub https://github.com/Kearney3/BetterDualSub
brew trust --cask kearney3/betterdualsub/betterdualsub
brew install --cask betterdualsub
```

Homebrew only installs casks from third-party taps that you trust; `brew trust` allows this one cask and nothing else from the tap. Upgrade with `brew upgrade --cask betterdualsub`. The app also tells you when a new version is out.

### Manual

1. Download the DMG from [Releases](https://github.com/Kearney3/BetterDualSub/releases) and drag BetterDualSub to Applications.
2. BetterDualSub is not notarized by Apple, so macOS blocks it until you run this once in Terminal:

   ```sh
   xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app
   ```

The Homebrew cask does the equivalent for you.

## Quick start

1. Open **Load Subtitles**. Drop one or two subtitle files or a `.movpkg` package, or paste a movie link and click **Choose source**.
2. Load the selected tracks. For movie links, find subtitles first, then select the edition and languages.
3. Play the same title and edition in TV.app, with its built-in subtitles turned off.
4. On **Now Playing**, use **Ready to Watch** to confirm subtitles are loaded, the player is connected and the overlay is visible.
5. Adjust with Control-Option-← / → (250 ms), or **Align by Line**.

## Using BetterDualSub

The control window has three groups:

| Group | Pages |
| --- | --- |
| Subtitles | **Now Playing**: tracks, sync status, timing and translation for what is loaded. **Load Subtitles**: every way to load subtitles. |
| Tools | **Align by Line**, **Bilingual Export** |
| Settings | **Appearance**, **Keyboard Shortcuts**, **General** |

The menu bar icon offers the same loading, timing and display commands.

### Loading subtitles

| Source | What you provide | Notes |
| --- | --- | --- |
| Movie link | An Apple TV movie page link | Lists the subtitle tracks of the chosen version. **Download only…** saves SRT files without showing them. |
| Local episode | A `.movpkg` package downloaded by the TV app, usually in `~/Movies/Videos/Media.localized/TV Shows` | Choose the episode timeline or the whole package's. **Export SRT files…** saves copies without showing them. |
| Subtitle file | One or two `.srt`, `.vtt`, `.ass` or `.ssa` files | UTF-8, UTF-16 and common legacy encodings (GB18030, Big5, Shift JIS, EUC-KR) are detected. ASS/SSA styling is ignored; bold, italic, underline and colors written in the cue text (HTML-style tags, WebVTT classes, `{\i1}`-style overrides) are shown. A file name ending in `(-1500ms)` sets the delay. |

After a successful load the window switches to **Now Playing**. Movie downloads and local extraction remember your chosen languages. Unsupported links offer local file and local episode alternatives.

### Recent Watching

**Now Playing** keeps up to 10 sessions within a 100 MiB total archive, including self-contained subtitle copies, translations, track delays and appearance. Older sessions are removed first when the archive reaches its limit; a single oversized session is rejected without changing saved history. **Restore** opens them without the original files or another download, following the player’s current position without seeking the video. Remove individual sessions or clear the list; original and exported files are kept.

### Sync status

| Status | Meaning |
| --- | --- |
| Following · Playing / Paused | Subtitles follow the chosen player. |
| Waiting for … to play | The chosen player reports no playback; the manual clock is used meanwhile. If another app is playing, you can follow it with one click. |
| Manual clock | You chose manual timing; use the progress bar shown when hovering over the subtitles. |
| Connecting to playback | Waiting for the listener's first report; unsuccessful connections retry automatically with a bounded delay. |
| Playback connection lost | Reading system playback information stopped; BetterDualSub reconnects automatically. |

Choose which player to follow under **General** › **Sync source**. A connected clock does not confirm a matching subtitle edition. The page distinguishes available text, dialogue gaps and positions outside subtitle coverage, with actions to align or change subtitles.

**Export diagnostics…** writes a local JSON containing versions, clock state, cue counts, offsets and recent state events. It excludes subtitle text, titles, file paths, source URLs and account identifiers, and is never uploaded automatically.

### Timing

- **Delay**: positive values show subtitles later. Set them on **Now Playing**, on the overlay's control bar or with shortcuts. Track 2 follows Track 1 unless you unlink them.
- **Align by Line**: while a line is being spoken, select it in the list and click **Align to current time**; the delay is calculated for you. The line that should be showing at the current delay is marked, and **Current line** scrolls back to it. It also works from the overlay: click the target button on its control bar.
- **Playback speed**: subtitle time runs 1:1 with video time. At 2× the video and the subtitles both move two seconds per second; the overlay shows the player's speed.
- Delays are saved by subtitle content and source edition, then restored with a notice. Legacy per-title timing is migrated once so a different edition cannot repeatedly inherit it.

### Translating a second language

On **Now Playing**, **Translate Track 2** creates a second track from Track 1 with the macOS on-device translator. The source language is detected automatically. Languages that are not installed yet are offered as a system download. You can correct the source language and **Preview 8 cues** without replacing Track 2. After a full translation, **Undo track replacement** restores the previous track. Results keep line timing, can be exported as SRT and are retained in Recent Watching.

### Overlay

Drag the subtitles anywhere on screen. Hovering shows a control bar with playback, delay and alignment controls; right-click for appearance, lock, hide and reset. While locked, the overlay ignores the mouse so the apps underneath stay usable. **Appearance** sets fonts, colors, outlines (drawn around the letters, never over them), a soft shadow, background and whether lines are kept as authored, joined into one or balanced over two.

Choose a fixed display or the current main display under **General** › **Subtitle Display**. Each display remembers its position and font sizes; disconnected displays fall back to an available screen.

### Keyboard shortcuts

These work in any app and can be changed under **Keyboard Shortcuts**, along with the delay step (1–60,000 ms, default 250 ms).

| Action | Default |
| --- | --- |
| Track 1 earlier / later | Control-Option-← / → |
| Track 2 earlier / later | Control-Option-Shift-← / → |
| Reset Track 1 / Track 2 delay | Control-Option-0 / Control-Option-Shift-0 |
| Play / pause | Control-Option-Command-Space |
| Back / forward 10 seconds | Control-Option-Command-← / → |
| Lock / unlock overlay | Control-Option-L |

Play, pause and seeking control the followed player, or the manual clock when nothing is followed.

## Limitations

- Online downloading supports Apple TV **movie pages with iTunes offers**. Apple TV+ subscription titles and show, season or episode links are not supported; for episodes downloaded in the TV app, use **Local episode**.
- Available languages depend on the page's country and the movie version. Only external text subtitle tracks are listed; captions embedded in the video cannot be downloaded. Forced tracks usually contain only selected dialogue.
- Encrypted, discontinuous, byte-range and initialization-map subtitle playlists are rejected with an error.
- BetterDualSub does not identify the movie that is playing; load subtitles for the same title and version. A different version may still need a delay.

## Privacy

- **Network**: BetterDualSub contacts Apple's TV website only when you look up or download subtitles, and GitHub at most once a day for the latest version number (turn this off under **General**). Nothing else is sent.
- **Account**: requests are anonymous. The optional DSID field is used only after an eligible request fails and is kept in memory only.
- **Translation** runs on device.
- **Files**: downloaded and extracted subtitles are kept in `~/Library/Application Support/BetterDualSub/Subtitles/`; **General** can move this folder to the Trash. Files you export yourself are never touched. Settings and timing are stored in the app's preferences. Self-contained recent subtitles, translations and configuration are stored in `~/Library/Application Support/BetterDualSub/RecentWatching.json`; clear these using Recent Watching. Clearing the download cache keeps recent-session copies.

To remove everything installed with Homebrew, run `brew uninstall --zap --cask betterdualsub`.

## Troubleshooting

<details>
<summary>macOS says BetterDualSub is damaged or can't be opened</summary>

The app is not notarized. Install it with Homebrew, or run the Terminal command from [Manual](#manual) once.
</details>

<details>
<summary>The subtitles stay still while the movie plays</summary>

Check the sync status on **Now Playing** or in the menu bar. If it names another app that is playing, choose **Follow** for it, or pick the player under **General** › **Sync source**. If it shows **Manual clock**, switch back to automatic.
</details>

<details>
<summary>The subtitles get further off as the movie goes on</summary>

The file was made for another frame rate or a different cut of the movie. BetterDualSub keeps subtitle time 1:1 with video time, so download a subtitle file that matches your version.
</details>

<details>
<summary>No subtitle tracks are found for a movie link</summary>

See [Limitations](#limitations). Apple TV+ titles and TV show links are not supported, and the page's country decides which languages exist. Try the link of another country's store.
</details>

<details>
<summary>Translation asks for a download or fails</summary>

macOS needs the language pair installed. Accept the download offer, or manage languages in System Settings › General › Language & Region › Translation Languages.
</details>

## Development

Open `BetterDualSub.xcodeproj` in Xcode 26, or build and launch from the command line:

```sh
./script/build_and_run.sh
```

A Release build:

```sh
xcodebuild -project BetterDualSub.xcodeproj -scheme BetterDualSub -configuration Release build
```

### Tests

Parsing, timing, translation planning, playback tracking and downloading logic live in the `BetterDualSubCore` Swift package and run without the TV app:

```sh
swift test
```

An optional live test downloads English and Chinese subtitles from a real movie link:

```sh
BETTERDUALSUB_LIVE_MOVIE_URL='https://tv.apple.com/hk/movie/spider-man-into-the-spider-verse/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x' \
  swift test --filter testLiveAppleMovieLinkWhenRequested
```

If more than one Xcode is installed, prefix the commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### Project layout

| Path | Contents |
| --- | --- |
| `BetterDualSub/SubtitleDocument.swift` | Subtitle model, SRT/WebVTT/ASS parsing, timing math |
| `BetterDualSub/PlaybackTracking.swift` | Now Playing tracking, sync status, saved timing |
| `BetterDualSub/MovieSubtitleDownloader.swift`, `MovpkgSubtitleExtractor.swift` | Apple TV download and `.movpkg` extraction |
| `BetterDualSub/SubtitleManager.swift`, `PlaybackCoordinator.swift` | Subtitle sessions, playback coordination and listener recovery |
| `BetterDualSub/ContentView.swift` | Subtitle rendering and overlay interaction |
| `BetterDualSub/*View.swift` | Control window pages |
| `Tests/` | Unit tests for the core package |
| `Casks/betterdualsub.rb` | Homebrew cask |
| `docs/` | Research notes and the commit convention |

### Contributing

Commits follow [Conventional Commits](docs/commit-convention.md). Enable the message check once per clone:

```sh
git config core.hooksPath .githooks
```

### Releasing

Push a `v*` tag, such as `v1.1.0`. The release workflow runs the tests, builds an arm64 DMG, publishes the GitHub release and updates the version and checksum in the Homebrew cask.

## Acknowledgments

- The Apple TV movie API discovery follows [iSubRip](https://github.com/MichaelYochpaz/iSubRip) (MIT), reimplemented natively in Swift. See [`ThirdPartyNotices.txt`](BetterDualSub/ThirdPartyNotices.txt) and [`docs/isubrip-download-research.md`](docs/isubrip-download-research.md).
- Playback information is read with [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter).

BetterDualSub is not affiliated with or endorsed by Apple. Apple TV is a trademark of Apple Inc.
