<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub 图标"></p>

<h1 align="center">BetterDualSub</h1>

<p align="center">为 macOS 版 Apple TV 应用添加外挂双语字幕。</p>

<p align="center"><a href="README.md">English</a> | <strong>简体中文</strong></p>

Mac 上的 Apple TV 应用（TV.app）一次只能显示一种字幕，也不能加载自己的字幕文件。BetterDualSub 在视频上方的浮层中显示一到两条字幕，并跟随正在播放的影片同步，例如可以同时显示英文和中文。

## 功能

- **三种字幕来源**：从 Apple TV 电影链接下载、从 TV.app 下载的剧集（`.movpkg`）中提取，或打开自己的 `.srt`、`.vtt`、`.ass`、`.ssa` 文件。
- **两条字幕同时显示**，各自设置字体、颜色、描边和换行方式。
- **跟随播放**：跟随 TV.app，或任何会上报“正在播放”信息的播放器（IINA、VLC、QuickTime Player、浏览器等），包括暂停、拖动进度和倍速。没有播放时改用手动时钟。
- **同步状态可见**：菜单栏、字幕浮层和控制窗口都会显示同步状态；没有跟随正确的播放器时，可一键修正。
- **时间校准**：每条轨道单独设置延迟、全局快捷键微调、选中正在播放的台词自动对齐，并能自动校正帧率不同的字幕文件的速度。校准按片名保存。
- **端侧翻译**：用 macOS 端侧翻译由第一轨生成第二种语言，字幕内容不会离开你的 Mac。
- **双语导出**：把两个字幕文件合并为一个双语 SRT。
- 界面支持简体中文和英文。

## 系统要求

- 搭载 Apple 芯片、运行 macOS 26 或更高版本的 Mac。
- TV.app，或其他会上报“正在播放”信息的播放器。

## 安装

### Homebrew（推荐）

```sh
brew tap kearney3/betterdualsub https://github.com/Kearney3/BetterDualSub
brew trust --cask kearney3/betterdualsub/betterdualsub
brew install --cask betterdualsub
```

Homebrew 只安装你信任的第三方 tap 中的 cask；`brew trust` 只放行这一个 cask，不会放行该 tap 中的其他内容。用 `brew upgrade --cask betterdualsub` 升级。有新版本时，应用也会提示。

### 手动安装

1. 从 [Releases](https://github.com/Kearney3/BetterDualSub/releases) 下载 DMG，把 BetterDualSub 拖到「应用程序」文件夹。
2. BetterDualSub 未经 Apple 公证，需要先在终端中运行一次以下命令，macOS 才允许打开：

   ```sh
   xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app
   ```

通过 Homebrew 安装时会自动完成这一步。

## 快速开始

1. 打开 BetterDualSub，选择 **加载字幕** › **影片链接**。
2. 粘贴影片的 Apple TV 页面链接，如 `https://tv.apple.com/us/movie/…/umc.cmc.…`，点击 **查找字幕**。
3. 选择版本、第一种语言，以及可选的第二种语言，点击 **下载并显示**。
4. 在 TV.app 中播放同一部影片，并关闭 TV.app 自带的字幕。浮层中的字幕会跟随播放。
5. 字幕偏早或偏晚时，按 Control-Option-← 或 →（每次 250 毫秒），或使用 **按字幕对齐**。

## 使用说明

控制窗口分为三组：

| 分组 | 页面 |
| --- | --- |
| 字幕 | **正在播放**：当前字幕的轨道、同步状态、时间校准和翻译。**加载字幕**：所有加载字幕的方式。 |
| 工具 | **按字幕对齐**、**双语导出** |
| 设置 | **外观**、**快捷键**、**通用** |

菜单栏图标也提供加载、时间和显示相关的命令。

### 加载字幕

| 来源 | 需要提供 | 说明 |
| --- | --- | --- |
| 影片链接 | Apple TV 电影页面链接 | 列出所选版本的字幕轨道。**仅下载保存…** 只保存 SRT 文件，不显示。 |
| 本地剧集 | TV.app 下载的 `.movpkg` 包，通常位于 `~/Movies/Videos/Media.localized/TV Shows` | 可选择单集时间线或整个包的时间线。**导出 SRT 文件…** 只保存副本，不显示。 |
| 字幕文件 | 一到两个 `.srt`、`.vtt`、`.ass`、`.ssa` 文件 | 自动识别 UTF-8、UTF-16 及常见旧编码（GB18030、Big5、Shift JIS、EUC-KR）。ASS/SSA 的样式会被忽略。文件名以 `(-1500ms)` 结尾时会自动设置延迟。 |

加载成功后，窗口会切换到 **正在播放**。

### 同步状态

| 状态 | 含义 |
| --- | --- |
| 正在跟随 · 播放中 / 已暂停 | 字幕跟随所选播放器。 |
| 等待 … 播放 | 所选播放器没有在播放，期间使用手动时钟。如果有其他应用正在播放，可以一键改为跟随它。 |
| 手动时钟 | 你选择了手动计时，可使用鼠标悬停在字幕上时出现的进度条。 |
| 播放信息连接中断 | 读取系统播放信息中断，BetterDualSub 会自动重连。 |

在 **通用** › **同步来源** 中选择要跟随的播放器。

### 时间校准

- **延迟**：正数表示字幕延后。可在 **正在播放**、浮层控制条或用快捷键设置。除非取消关联，第二轨会与第一轨保持一致。
- **按字幕对齐**：某句台词正在播放时，在列表中选中它并点击 **对齐到当前播放时间**，延迟会自动算出。
- **速度校正**：如果字幕越往后偏得越多，在第一句至少 30 秒之后再对齐一句，BetterDualSub 会同时校正速度。例如 23.976 fps 的字幕在 25 fps 的片源上播放时为 ×1.0427。
- 延迟和速度按片名保存，下次加载同一影片时会自动恢复并提示。

### 翻译生成第二语言

在 **正在播放** 中，**翻译生成第二轨** 会用 macOS 端侧翻译由第一轨生成第二轨，并自动识别源语言。尚未安装的语言会弹出系统下载提示。生成的字幕保留每句的时间，并可导出为 SRT。

### 字幕浮层

字幕可以拖到屏幕任意位置。鼠标悬停时会出现控制条，可控制播放、延迟和对齐；右键可打开外观设置、锁定、隐藏或重置位置。锁定后浮层不响应鼠标，不影响下方的应用。**外观** 中可设置字体、颜色、描边、背景，以及保持原样、合并为单行或平衡为两行。

### 快捷键

以下快捷键在任何应用中都可用，可在 **快捷键** 中修改，也可设置延迟步长（1 到 60,000 毫秒，默认 250 毫秒）。

| 操作 | 默认快捷键 |
| --- | --- |
| 第一轨提前 / 推迟 | Control-Option-← / → |
| 第二轨提前 / 推迟 | Control-Option-Shift-← / → |
| 重置第一轨 / 第二轨延迟 | Control-Option-0 / Control-Option-Shift-0 |
| 播放 / 暂停 | Control-Option-Command-Space |
| 后退 / 前进 10 秒 | Control-Option-Command-← / → |
| 锁定 / 解锁浮层 | Control-Option-L |

播放、暂停和跳转作用于正在跟随的播放器；没有跟随的播放器时，作用于手动时钟。

## 限制

- 在线下载仅支持带有 iTunes 购买或租赁选项的 Apple TV **电影页面**。不支持 Apple TV+ 订阅内容，也不支持剧集、季或单集链接；TV.app 中下载的剧集请使用 **本地剧集**。
- 可用语言取决于页面所在的国家或地区以及影片版本。只会列出外挂文本字幕轨道，无法下载视频内嵌的字幕。强制字幕通常只包含部分对白。
- 加密、不连续、字节范围以及带初始化映射的字幕播放列表会被拒绝并报错。
- BetterDualSub 不会识别正在播放的影片，请加载同一片名、同一版本的字幕。版本不同时可能仍需调整延迟。

## 隐私

- **网络**：只有在你查找或下载字幕时才会访问 Apple TV 网站；每天最多一次向 GitHub 查询最新版本号（可在 **通用** 中关闭）。除此之外不发送任何内容。
- **账号**：请求默认匿名。可选的 DSID 字段仅在符合条件的请求失败后使用，且只保存在内存中。
- **翻译** 全部在本机完成。
- **文件**：下载和提取的字幕保存在 `~/Library/Application Support/BetterDualSub/Subtitles/`，可在 **通用** 中移到废纸篓；你自己导出的文件不会被改动。设置和按片名保存的校准存放在应用的偏好设置中。

通过 Homebrew 安装的，运行 `brew uninstall --zap --cask betterdualsub` 可移除全部内容。

## 常见问题

<details>
<summary>macOS 提示 BetterDualSub 已损坏或无法打开</summary>

应用未经 Apple 公证。请用 Homebrew 安装，或运行一次[手动安装](#手动安装)中的终端命令。
</details>

<details>
<summary>影片在播放，字幕却不动</summary>

查看 **正在播放** 或菜单栏中的同步状态。如果提示另一个应用正在播放，点击 **改为跟随**，或在 **通用** › **同步来源** 中选择播放器。如果显示 **手动时钟**，请切换回自动。
</details>

<details>
<summary>字幕越往后偏得越多</summary>

字幕文件的帧率与片源不同。用 **按字幕对齐** 在开头附近对齐一句，再在后段对齐一句，速度会自动校正。
</details>

<details>
<summary>影片链接找不到字幕轨道</summary>

请查看[限制](#限制)。不支持 Apple TV+ 内容和剧集链接，且可用语言取决于页面所在的国家或地区，可以换用其他国家或地区商店的链接试试。
</details>

<details>
<summary>翻译提示需要下载或翻译失败</summary>

macOS 需要安装对应的语言。接受下载提示，或在“系统设置 › 通用 › 语言与地区 › 翻译语言”中管理。
</details>

## 开发

用 Xcode 26 打开 `BetterDualSub.xcodeproj`，或在命令行中构建并启动：

```sh
./script/build_and_run.sh
```

构建 Release 版本：

```sh
xcodebuild -project BetterDualSub.xcodeproj -scheme BetterDualSub -configuration Release build
```

### 测试

字幕解析、时间计算、翻译规划、播放跟踪和下载逻辑都在 `BetterDualSubCore` Swift 包中，无需启动 TV.app 即可测试：

```sh
swift test
```

另有一个可选的在线测试，会从真实电影链接下载英文和中文字幕：

```sh
BETTERDUALSUB_LIVE_MOVIE_URL='https://tv.apple.com/hk/movie/spider-man-into-the-spider-verse/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x' \
  swift test --filter testLiveAppleMovieLinkWhenRequested
```

如果安装了多个 Xcode，请在命令前加上 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

### 项目结构

| 路径 | 内容 |
| --- | --- |
| `BetterDualSub/SubtitleDocument.swift` | 字幕模型、SRT/WebVTT/ASS 解析、时间计算 |
| `BetterDualSub/PlaybackTracking.swift` | “正在播放”跟踪、同步状态、校准保存 |
| `BetterDualSub/MovieSubtitleDownloader.swift`、`MovpkgSubtitleExtractor.swift` | Apple TV 下载与 `.movpkg` 提取 |
| `BetterDualSub/ContentView.swift` | `SubtitleManager` 与字幕浮层 |
| `BetterDualSub/*View.swift` | 控制窗口各页面 |
| `Tests/` | 核心包的单元测试 |
| `Casks/betterdualsub.rb` | Homebrew cask |
| `docs/` | 调研笔记与提交规范 |

### 参与开发

提交信息遵循 [Conventional Commits](docs/commit-convention.md)。每次克隆后启用一次本地校验：

```sh
git config core.hooksPath .githooks
```

### 发布

推送 `v*` 标签，如 `v1.1.0`。发布流程会运行测试、构建 arm64 DMG、发布 GitHub Release，并更新 Homebrew cask 中的版本和校验值。

## 致谢

- Apple TV 电影接口的发现流程参考了 [iSubRip](https://github.com/MichaelYochpaz/iSubRip)（MIT），并用 Swift 原生重新实现。署名与源码分析见 [`ThirdPartyNotices.txt`](BetterDualSub/ThirdPartyNotices.txt) 和 [`docs/isubrip-download-research.md`](docs/isubrip-download-research.md)。
- 播放信息通过 [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) 读取。

BetterDualSub 与 Apple 无关联，也未获 Apple 认可。Apple TV 是 Apple Inc. 的商标。
