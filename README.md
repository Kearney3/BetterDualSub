<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub icon"></p>

<h1 align="center">BetterDualSub</h1>

<p align="center">Bilingual external subtitles for the Apple TV app on macOS.</p>

<p align="center"><strong>English</strong> | <a href="README.zh-CN.md">简体中文</a></p>

The Apple TV app on the Mac shows one subtitle language at a time and cannot load your own subtitle files. BetterDualSub shows one or two subtitle tracks in a floating overlay above the video and keeps them in step with the playing movie, so you can watch with, for example, English and Chinese at once.

## Features

- **Three subtitle sources** (plus transcribing speech): download tracks from an Apple TV movie link, extract them from an episode downloaded in the TV app (`.movpkg`) or from a video file's embedded text tracks (`.mkv`, `.webm`, `.mp4`, `.m4v`, `.mov`), or open your own `.srt`, `.vtt`, `.ass` or `.ssa` files.
- **Two tracks at once**, each with its own font, color, outline and line layout.
- **Follows playback** of the Apple TV app, or of any other player that reports Now Playing (IINA, VLC, QuickTime Player, browsers…), including pauses, seeks and playback speed. A manual clock takes over when nothing is playing.
- **Visible sync status** in the menu bar, on the overlay and in the app, with a one-click fix when subtitles are not following the right player.
- **Timing tools**: per-track delays, global shortcuts, and alignment by picking the line you hear. Timing is remembered per title.
- **Translation**: create a second language from the first with macOS on-device translation, a local language model (Ollama, LM Studio) or any OpenAI-compatible service. Sentences split over several lines are translated whole and shared back over their timing, and a per-show glossary keeps names and terms consistent.
- **Merge subtitles**: merge two subtitle files, or a whole season paired by episode, into bilingual SRT or ASS files, with the timing lined up and a constant offset detected.
- **Batch translation**: translate a season's subtitle files in one go with a shared glossary that is saved for the next season, writing translated and/or bilingual files.
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

Homebrew only installs casks from third-party taps that you trust; `brew trust` allows this one cask and nothing else from the tap. The app updates itself (see below), so `brew upgrade` skips it; `brew upgrade --greedy --cask betterdualsub` upgrades it with Homebrew instead.

### Manual

1. Download the DMG from [Releases](https://github.com/Kearney3/BetterDualSub/releases) and drag BetterDualSub to Applications.
2. BetterDualSub is not notarized by Apple, so macOS blocks it until you run this once in Terminal:

   ```sh
   xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app
   ```

The Homebrew cask does the equivalent for you.

When a new version is out, **Settings** › **General** offers **Install Update…**, which downloads it, checks its signature and relaunches the app. This works the same for Homebrew installs. The same place sets how often the app checks (every day, week or month) and has **Install updates automatically**, which downloads a new version in the background and installs it when you quit the app.

## Quick start

1. On first launch a welcome screen walks through the three steps; **Load Subtitles** takes you to the loading page (reopen it any time from **Help** › **BetterDualSub Guide**). Open **Load Subtitles**. Drop one or two subtitle files, a video file or a `.movpkg` package, or paste a movie link and click **Choose source**.
2. Load the selected tracks. For movie links, find subtitles first, then select the edition and languages.
3. Play the same title and edition in TV.app, with its built-in subtitles turned off.
4. On **Now Playing**, the **Getting Started** checklist ticks off loading, following the player and seeing the overlay as they happen, and offers the fix for whichever step is open.
5. Adjust with Control-Option-← / → (250 ms), or **Align by Line**.

## Using BetterDualSub

The control window has three groups:

| Group | Pages |
| --- | --- |
| Subtitles | **Now Playing**: tracks, sync status, timing and translation for what is loaded. **Load Subtitles**: every way to load subtitles. |
| Tools | **Align by Line**, **Merge Subtitles**, **Batch Translate** |
| Settings | **Appearance**, **Translation**, **Keyboard Shortcuts**, **General** |

The menu bar icon offers the same loading, timing and display commands.

### Loading subtitles

| Source | What you provide | Notes |
| --- | --- | --- |
| Movie link | An Apple TV movie page link | Lists the subtitle tracks of the chosen version. **Download only…** saves SRT files without showing them. |
| Local video | A video file with embedded text subtitles (`.mkv`, `.webm`, `.mp4`, `.m4v`, `.mov`: SRT, ASS/SSA, WebVTT or tx3g tracks), or a `.movpkg` package downloaded by the TV app, usually in `~/Movies/Videos/Media.localized/TV Shows` | For a `.movpkg`, choose the episode timeline or the whole package's. A video file is read once for all its text tracks, so switching tracks on Now Playing is instant. Blu-ray picture subtitles (PGS, in `.mkv`) are listed as **OCR** tracks: their text is read from the pictures on this Mac, only for the tracks you choose, which takes a few minutes for a film (VobSub and other picture formats are not supported). A video with no subtitle track, or any video, can have its speech transcribed instead (see below). For Track 2, pick another track, none, or **Translate from Track 1** to extract only Track 1 and translate the second language right away on Now Playing. **Export SRT files…** saves copies without showing them. |
| Subtitle file | One or two `.srt`, `.vtt`, `.ass` or `.ssa` files | UTF-8, UTF-16 and common legacy encodings (GB18030, Big5, Shift JIS, EUC-KR) are detected. ASS/SSA styling is ignored; bold, italic, underline and colors written in the cue text (HTML-style tags, WebVTT classes, `{\i1}`-style overrides) are shown. A file name ending in `(-1500ms)` sets the delay. |

After a successful load the window switches to **Now Playing**. Movie downloads and local extraction remember your chosen languages. Unsupported links offer local file and local episode alternatives.

### Picture subtitles and speech

- **Picture subtitles (OCR)**: Blu-ray rips carry subtitles as pictures (PGS). A track marked **OCR** is read with the system's text recognition: names and unusual words can be misread, so look over the result. Identical pictures are read once, so a long film is mostly a matter of a few minutes.
- **Transcribe speech**: for a video file (`.mp4`, `.m4v`, `.mov`, and `.mkv`/`.webm` with AAC audio), **Local video** offers **Transcribe and Load**, or **Transcribe and Export SRT…**. The speech is recognized on this Mac with the system speech analyzer, in the language you pick (the file's own audio language is offered first). A language's speech model is downloaded once. Only the first audio track is read. Expect mistakes with names, noise and music, and no speaker labels; the lines are cut at sentences and pauses. When **Translate from Track 1** is chosen as Track 2, the transcript is translated right away.

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
- **Correct drift**: when a file made for another frame rate drifts further off the longer the movie plays, align a line near the start first, then select a line at least 30 seconds later and click **Correct drift with this line** (on **Align by Line** or on the overlay's control bar) while it is being spoken. The file is stretched to fit, for example ×1.0427 for 23.976 fps played at 25 fps; lines that imply a ratio outside ×0.9–×1.1 are rejected. Only this action changes the ratio, a plain delay keeps it, and **Reset to 1:1** removes it. The correction is saved with the delays.
- Delays are saved by subtitle content and source edition, then restored with a notice. Legacy per-title timing is migrated once so a different edition cannot repeatedly inherit it.

### Translating a second language

On **Now Playing**, **Translate Track 2** creates a second track from Track 1. The source language is detected automatically. You can correct the source language and **Preview 8 cues** without replacing Track 2. After a full translation, **Undo track replacement** restores the previous track. Results can be exported as SRT and are retained in Recent Watching.

Choose the **Engine**:

- **On-device (macOS)**: the system translator. Languages that are not installed yet are offered as a system download. Subtitle text never leaves your Mac.
- **Language model**: set it up under **Settings** › **Translation**. Pick **Ollama** or **LM Studio** for a model running on this Mac, or **OpenAI**, **DeepSeek** or **Custom** for any service with an OpenAI-compatible `/v1/chat/completions` API (OpenRouter, SiliconFlow, Qwen, llama.cpp…). **Fetch Models** next to the model field lists the service's models to pick from. The API key is kept in your login keychain, for that address only. Requests carry a batch of sentences together with the sentences before and after it, so names and tone stay consistent; you can add your own instructions, such as the show's premise. Under **Prompt**, pick the translator's role and style: **Standard**, **Faithful** (close to the original wording, for following along) or **Localized** (idioms and jokes adapted for the audience), or your own. **View…** shows a built-in prompt and the whole prompt it makes with the current settings; **Duplicate to Edit** or **New…** saves your own, where `{source}` and `{target}` stand for the languages. The rules for cues, the glossary, context and the reply format are always added by the app, so any prompt keeps translations working. Under **Names and Style**, people's names and place names can be kept as written in the original instead of translated, honorifics such as -san, -kun and oppa kept, and swearing toned down.
- **Parallel requests**: with an online service, several batches are sent at once (3 by default; 1–4 under **Settings** › **Translation**), which translates a long file much faster. A model on this Mac gets one request at a time unless you raise it. Batches sent together see less of the translation before them as context, and a service with a low rate limit may need a lower setting.
- **Extra request parameters**: a JSON object added to every request, for options your service documents beyond the common API, such as `{"reasoning_effort": "low"}` to speed up a reasoning model. The model, messages and stream fields cannot be changed.

Timing:

- A sentence split over several cues ("I don't think" / "we should go.") is translated as one sentence and shared back over the same cues. A language model returns the parts itself; the on-device translator's result is split at punctuation or between words, in proportion to the original lines.
- **Split long translated lines over their time** breaks a translation longer than two lines into parts shown one after another within the original cue.
- **Subtitle punctuation**, for Chinese and Japanese, drops full stops and commas from the translation and puts a space where a pause falls inside a line, as subtitles in those languages usually do.

Glossary:

- Each show has a glossary per target language, named after the title without episode numbers (`Show.Name.S01E02` → `Show Name`), so every episode uses it. **Edit…** opens it; entries can be imported and exported as tab-separated text (`original<TAB>translation<TAB>kind<TAB>note`, `#` for comments; `original → translation` lines are also read).
- With a language model, **Find Terms**, or **Find names and terms before translating**, collects the names of people, places and organizations and the show's own terms. Entries you have written or edited are never replaced. When people's or place names are kept in the original, the ones it found stay in the glossary but are not used; your own entries still are.
- Glossary translations are sent with every request that uses them. After translating, lines that still miss a glossary term are translated once more; any left are reported. With the on-device translator, glossary translations are written into the source text before translating, which works best for names.
- **Save As…** keeps a copy of a glossary under a new name, for example to start the next season from this one's names.

### Merging subtitles

**Tools** › **Merge Subtitles** writes two subtitle files as one, without loading them for playback. Drop files or choose them; **Swap Tracks** exchanges the two.

- **Season** takes two lists of files or folders and pairs them by the episode in their names (`S01E02`, `1x02`, `EP02`, `第2集`); files without a partner are listed and left out.
- **Additional secondary delay** moves Track 2; **Auto-detect** finds a constant offset from the lines that match (for a season, each episode is detected on its own). **Line up with Track 1** moves Track 2 lines that start or end within that many milliseconds of a Track 1 line onto it.
- **Write** one bilingual file, or two synced files: Track 1 as it is and Track 2 with its delay and line-up applied, each in its own file. **Format** SRT or ASS; ASS keeps each language in its own style, Track 2 smaller. The preview shows the merged lines of the first pair.
- A season is saved next to its sources or in a chosen folder, named by a pattern (`{name}`, `{lang}`, `{episode}`). An existing file is skipped, kept beside the new one or replaced as you choose; the source files are never replaced.

### Batch translation

**Tools** › **Batch Translate** translates many subtitle files with the engine, languages and options of the Now Playing translation card; a change on either page applies to both. The source language is detected from the first file.

- One glossary is shared by every file, named after the show. With a language model and **Find names and terms before translating**, each file's names are found before it is translated and added to the glossary, so later episodes use them, and the glossary is saved as it grows.
- Write the **Translated subtitles**, **Bilingual subtitles** (SRT or ASS, either language on top), or both, next to the sources or in a chosen folder. Files whose outputs already exist are skipped unless you choose otherwise, so a run can be resumed.
- A file that fails does not stop the run; **Retry Failed** translates only those again. The run keeps going when you leave the page.

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

- Picture subtitles are read only for PGS in Matroska files, and speech transcription needs AAC audio in a Matroska file (AC-3, DTS, Opus and others are not read yet). Both are limited by how well the system recognizes text and speech.
- Online downloading supports Apple TV **movie pages with iTunes offers**. Apple TV+ subscription titles and show, season or episode links are not supported; for episodes downloaded in the TV app, use **Local video**.
- Available languages depend on the page's country and the movie version. Only external text subtitle tracks are listed; captions embedded in the video cannot be downloaded. Forced tracks usually contain only selected dialogue.
- Encrypted, discontinuous, byte-range and initialization-map subtitle playlists are rejected with an error.
- BetterDualSub does not identify the movie that is playing; load subtitles for the same title and version. A different version may still need a delay.

## Privacy

- **Network**: BetterDualSub contacts Apple's TV website only when you look up or download subtitles, and GitHub at most once a day for the latest version number (turn this off under **General**). Nothing else is sent.
- **Account**: requests are anonymous. The optional DSID field is used only after an eligible request fails and is kept in memory only.
- **Picture subtitles and speech** are read on this Mac. Downloading a language for speech recognition is done by the system.
- **Translation** runs on device with the macOS translator or a language model on this Mac. With an online language model service, the subtitle text is sent to that service, as the translation card and **Settings** › **Translation** point out. API keys are stored in the login keychain. Glossaries are stored in `~/Library/Application Support/BetterDualSub/Glossaries/`.
- **Files**: downloaded and extracted subtitles are kept in `~/Library/Application Support/BetterDualSub/Subtitles/`; **General** can move this folder to the Trash. Files you export yourself are never touched. Settings and timing are stored in the app's preferences. Self-contained recent subtitles, translations and configuration are stored in `~/Library/Application Support/BetterDualSub/RecentWatching/` (one file per session and an index); clear these using Recent Watching. Clearing the download cache keeps recent-session copies.

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

The file was made for another frame rate. Use **Align by Line** on one line near the start and **Correct drift with this line** on another at least 30 seconds later (see [Timing](#timing)). If the file was made for a different cut of the movie, no single ratio fits; download a subtitle file that matches your version.
</details>

<details>
<summary>No subtitle tracks are found for a movie link</summary>

See [Limitations](#limitations). Apple TV+ titles and TV show links are not supported, and the page's country decides which languages exist. Try the link of another country's store.
</details>

<details>
<summary>Translation asks for a download or fails</summary>

macOS needs the language pair installed. Accept the download offer, or manage languages in System Settings › General › Language & Region › Translation Languages.

With a language model, use **Test Connection** under **Settings** › **Translation**. A local server must be running with the model downloaded (`ollama pull <model>`). If a small model often leaves out lines, lower **Sentences per request**.
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

Parsing, timing, translation planning, playback tracking and downloading logic live in `BetterDualSub/Core/`, which is both part of the app and the `BetterDualSubCore` Swift package, built with the app's concurrency settings. A file added to that folder is picked up by both. The tests run without the TV app:

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
| `BetterDualSub/Core/SubtitleDocument.swift` | Subtitle model, SRT/WebVTT/ASS parsing, timing math |
| `BetterDualSub/Core/PlaybackTracking.swift` | Now Playing tracking, sync status, saved timing |
| `BetterDualSub/Core/DualTrackTiming.swift`, `SubtitleDrift.swift` | Delays, drift correction and the track link of the two tracks, as plain tested arithmetic |
| `BetterDualSub/Core/ViewingSession.swift`, `ViewingHistory.swift` | Recent sessions: the on-disk store (a folder with an index and a file per session) and the interface-facing history |
| `BetterDualSub/Core/MovieSubtitleDownloader.swift`, `MovpkgSubtitleExtractor.swift`, `VideoSubtitleExtractor.swift` | Apple TV download, `.movpkg` extraction, and Matroska / MP4 embedded subtitle extraction |
| `BetterDualSub/SubtitleManager.swift`, `Core/PlaybackCoordinator.swift` | Loaded subtitles and the observable state the interface reads; playback coordination and listener recovery. `SubtitleTimers.swift` and `SyncSettings.swift` hold its timers and sync-source settings |
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

CI also runs a mechanical check on the Swift sources (no tabs, trailing whitespace or lines over 220 characters). Run it before pushing:

```sh
./script/lint.sh
```

### Releasing

Push a `v*` tag, such as `v1.1.0`. The release workflow runs the tests, builds an arm64 DMG, publishes the GitHub release with a signed Sparkle `appcast.xml`, and updates the version and checksum in the Homebrew cask.

In-app updates are signed with a Sparkle EdDSA key kept in the `SPARKLE_PRIVATE_KEY` repository secret; the workflow stops if it is missing. To set it up once, after Xcode has resolved the packages:

```sh
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' -type d | head -1)"
"$SPARKLE_BIN/generate_keys"                      # creates the key in your login keychain
"$SPARKLE_BIN/generate_keys" -x sparkle-key.txt   # exports it
gh secret set SPARKLE_PRIVATE_KEY < sparkle-key.txt && rm sparkle-key.txt
```

Keep the key in your keychain: updates signed with another key are refused by installed copies. The public key is derived from the secret at build time, so local builds have none and offer the download page instead.

## Acknowledgments

- The Apple TV movie API discovery follows [iSubRip](https://github.com/MichaelYochpaz/iSubRip) (MIT), reimplemented natively in Swift. See [`ThirdPartyNotices.txt`](BetterDualSub/ThirdPartyNotices.txt) and [`docs/isubrip-download-research.md`](docs/isubrip-download-research.md).
- Playback information is read with [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter).
- In-app updates use [Sparkle](https://sparkle-project.org) (MIT).

BetterDualSub is not affiliated with or endorsed by Apple. Apple TV is a trademark of Apple Inc.
