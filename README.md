<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub icon"></p>

# BetterDualSub - External Subtitle for Apple TV app on MacOS

**English** | [简体中文](README.zh-CN.md)

A Mac app provides the ability to add external subtitles to the Apple TV app.

## How to install

1. Download and move BetterDualSub.app to /Applications folder

2. Open terminal and run this code 

`xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app`

## How to use

1. Open BetterDualSub to see the single control window. Use its sidebar to move between **Movie page**, **Local episode**, **Appearance**, **Keyboard Shortcuts** and **General**. **Appearance** includes a live bilingual preview with sample English and Chinese text; turn off its toggle if you do not want a sample shown in the Apple TV overlay before loading subtitles.

2. For an online movie, open **Movie page**, paste its `https://tv.apple.com/{country}/movie/.../umc.cmc...` URL and click **Find subtitles**. Select the movie version and one or two language tracks, then click **Download and show**. Both tracks follow the TV playback clock. Positive offsets delay subtitles; the secondary track has an additional independent offset.

3. For a downloaded TV episode, open **Local episode** and choose its `.movpkg` package. Select one or two external text tracks and choose either the episode timeline or the full package timeline, then extract and show them. Extracted SRT files are saved under `~/Movies/Subtitles/`.

4. Play the matching movie or episode in TV.app. Turn off TV.app's own subtitles if they overlap the external subtitles. Online movie downloads are saved separately as SRT under `~/Library/Application Support/BetterDualSub/Subtitles/`.

5. Use **Appearance** to preview and tune both subtitle tracks. **General** switches the interface between Simplified Chinese and English, controls the menu-bar icon, and sets the shortcut delay step from 1 to 60,000 ms. You can reset either track to 0 from the movie or episode page, or reset both tracks in **General**. **Keyboard Shortcuts** lets you record custom global shortcuts for moving either track earlier or later and for resetting each track to 0. Defaults are Control-Option-Left/Right for the primary track, Control-Option-Shift-Left/Right for the secondary track, Control-Option-0 to reset the primary delay, and Control-Option-Shift-0 to reset the secondary delay.

Local UTF-8 SRT files remain supported from the menu-bar item **Open subtitle file…**.

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
