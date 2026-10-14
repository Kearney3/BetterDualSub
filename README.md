<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub icon"></p>

# BetterDualSub - External Subtitle for Apple TV app on MacOS

**English** | [简体中文](README.zh-CN.md)

A Mac app provides the ability to add external subtitles to the Apple TV app.

## How to install

Requires macOS 26.0 or later on Apple silicon.

### With Homebrew

```sh
brew tap kearney3/betterdualsub https://github.com/Kearney3/BetterDualSub
brew install --cask betterdualsub
```

The cask removes the download quarantine for you, so the Terminal step of the manual install is not needed. Upgrade later with `brew upgrade --cask betterdualsub`.

### Manually

1. Download and move BetterDualSub.app to /Applications folder

2. Open terminal and run this code 

`xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app`

## How to use

1. Open BetterDualSub to see the control window. **Now Playing** is the home page: before anything is loaded it shows how to get started; afterwards it shows the loaded tracks, the sync status, timing and translation in one place. **Load Subtitles** is the single place to load subtitles, with three sources: **Movie link**, **Local episode** and **Subtitle file**. After a successful load the window returns to **Now Playing**. **Tools** holds **Align by Line** and **Bilingual Export**; **Settings** holds **Appearance**, **Keyboard Shortcuts** and **General**.

2. For an online movie, choose **Movie link**, paste its `https://tv.apple.com/{country}/movie/.../umc.cmc...` URL and click **Find subtitles**. Select the movie version and one or two language tracks, then click **Download and show**. Online movie downloads are saved as SRT under `~/Library/Application Support/BetterDualSub/Subtitles/`.

3. For a downloaded TV episode, choose **Local episode** and select its `.movpkg` package. Select one or two external text tracks and choose either the episode timeline or the full package timeline, then extract and show them. App-managed SRT files are saved under `~/Library/Application Support/BetterDualSub/Subtitles/Local/`. Use **Export tracks** to save copies in a folder you choose. Your own UTF-8 or legacy-encoded `.srt` / `.vtt` / `.ass` / `.ssa` files load from **Subtitle file**; for ASS/SSA only the text and timing are used, not their styling. The **General** page can move the app-managed cache to Trash without touching files you exported yourself.

4. Play the matching movie or episode in TV.app, and turn off TV.app's own subtitles if they overlap. The sync status on **Now Playing**, in the menu bar and on the overlay's control bar shows whether subtitles follow a player, are waiting for one, use the manual clock or lost the playback connection, and offers the matching fix (for example, following the app that is actually playing).

5. Adjust timing on **Now Playing** or with global shortcuts. Positive delays show subtitles later. **Align by Line** sets the delay from a line you hear; aligning a second line at least 30 seconds later also corrects the speed of files made for another frame rate. Timing is saved per title and restored, with a notice, the next time the same title is loaded. If only one language is available, **Now Playing** can create Track 2 with on-device macOS translation; subtitle text never leaves the Mac.

6. Use **Appearance** to preview and tune both subtitle tracks. **General** chooses the player to follow, switches the interface between Simplified Chinese and English, controls the menu-bar icon and the daily update check (which only asks GitHub for the latest version number), and sets the shortcut delay step from 1 to 60,000 ms. **Keyboard Shortcuts** lets you record custom global shortcuts for moving either track earlier or later and for resetting each track to 0. Defaults are Control-Option-Left/Right for the primary track, Control-Option-Shift-Left/Right for the secondary track, Control-Option-0 to reset the primary delay, and Control-Option-Shift-0 to reset the secondary delay.

### Supported links and limitations

- Online downloading supports Apple TV **movie pages with iTunes movie offers**. Apple TV+ subscription-only titles and show, season or episode page links are not supported by the online downloader. Local `.movpkg` extraction supports downloaded episodes when they contain complete external text subtitle tracks.
- Available languages depend on the page's country and film version. Only external HLS text subtitle tracks are listed. Embedded video closed captions cannot be downloaded through this path. Forced tracks usually contain only selected dialogue.
- Requests are anonymous first. The optional DSID field is used only after an eligible iTunes playlist request fails and is kept only in memory. It does not provide a general account login or guarantee access to a purchased/rented title.
- Complete, unencrypted WebVTT playlists are supported. Encrypted, discontinuous, byte-range and initialization-map subtitle playlists are rejected with an error.
- Subtitle segments are merged with their WebVTT timestamp maps. Film-version differences can still require a manual offset; the application does not automatically identify the page for the currently playing film.

## Build and verify

For contribution and commit message rules, see [Commit convention](docs/commit-convention.md).

Use the project build-and-run script to build and launch the macOS app:

```sh
./script/build_and_run.sh
```

Or open `BetterDualSub.xcodeproj` in Xcode. A Release build can also be created with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BetterDualSub.xcodeproj -scheme BetterDualSub -configuration Release build
```

The parser, playback-clock calculations and downloader can be tested without starting TV.app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

An optional live test downloads English and Chinese subtitles from a supplied supported movie link:

```sh
BETTERDUALSUB_LIVE_MOVIE_URL='https://tv.apple.com/hk/movie/spider-man-into-the-spider-verse/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter testLiveAppleMovieLinkWhenRequested
```

The Apple movie API discovery follows [iSubRip](https://github.com/MichaelYochpaz/iSubRip); this application uses a native Swift implementation and does not require Python or iSubRip to be installed. See `BetterDualSub/ThirdPartyNotices.txt` and `docs/isubrip-download-research.md` for attribution and source analysis.
