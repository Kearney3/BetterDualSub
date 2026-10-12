<p align="center"><img src="docs/images/icon.png" width="128" alt="BetterDualSub 图标"></p>

# BetterDualSub - 为 macOS 版 Apple TV 应用添加外挂双语字幕

[English](README.md) | **简体中文**

一款 Mac 应用,可以为 Apple TV(TV.app)添加外挂字幕,并支持同时显示两种语言。

## 安装

需要 macOS 26.0 或更高版本。

1. 下载 BetterDualSub.app,并移动到「应用程序」(/Applications)文件夹。

2. 打开终端,运行以下命令:

`xattr -cr /Applications/BetterDualSub.app && codesign --force --deep --sign - /Applications/BetterDualSub.app`

## 使用方法

1. 打开 BetterDualSub,会看到一个控制窗口。通过侧边栏在 **影片页面**、**本地剧集**、**外观**、**快捷键** 和 **通用** 之间切换。**外观** 页面带有中英文示例文字的实时双语预览;如果不希望在加载字幕之前,Apple TV 的浮层上显示示例字幕,可以关闭该页面的开关。

2. 在线影片:打开 **影片页面**,粘贴 `https://tv.apple.com/{国家或地区}/movie/.../umc.cmc...` 格式的链接,点击 **查找字幕**。选择影片版本以及一到两条语言轨道,然后点击 **下载并显示**。两条轨道都会跟随 TV 的播放时钟。正偏移表示字幕延后;第二条轨道还有独立的额外偏移。

3. 已下载的剧集:打开 **本地剧集**,选择对应的 `.movpkg` 包。选择一到两条外挂文本轨道,选择使用单集时间线或整个包的时间线,然后提取并显示。应用管理的 SRT 文件保存在 `~/Library/Application Support/BetterDualSub/Subtitles/Local/`；通过 **导出轨道** 可另存到自选文件夹。

4. 在 TV.app 中播放对应的影片或剧集。如果 TV.app 自带字幕与外挂字幕重叠,请关闭 TV.app 自带字幕。在线下载的影片字幕会单独以 SRT 保存在 `~/Library/Application Support/BetterDualSub/Subtitles/`。可在 **通用** 页面将应用管理的缓存移到废纸篓，不会清理自行导出的文件。

5. 在 **外观** 中预览并调整两条字幕的样式。**通用** 可切换界面语言(简体中文 / English)、控制菜单栏图标,并设置快捷键延迟步进(1 到 60,000 毫秒)。可在影片页面或剧集页面把任一轨道重置为 0,也可在 **通用** 中同时重置两条轨道。**快捷键** 支持录制自定义全局快捷键,用于将任一轨道提前或延后,以及将各轨道重置为 0。默认值:主轨道为 Control-Option-左/右方向键,第二轨道为 Control-Option-Shift-左/右方向键,重置主轨道延迟为 Control-Option-0,重置第二轨道延迟为 Control-Option-Shift-0。

仍然支持本地 UTF-8 SRT 文件,可通过菜单栏项 **打开字幕文件…** 导入。

### 支持的链接与限制

- 在线下载仅支持带有 iTunes 电影购买/租赁选项的 Apple TV **电影页面**。不支持 Apple TV+ 订阅专享内容,也不支持剧集、季或单集页面的链接。本地 `.movpkg` 提取支持已下载、且包含完整外挂文本字幕轨道的剧集。
- 可用语言取决于页面所在的国家/地区和影片版本。只会列出外挂的 HLS 文本字幕轨道,无法通过此方式下载视频内嵌的隐藏式字幕(CC)。强制字幕通常只包含部分对白。
- 请求默认以匿名方式发起。可选的 DSID 字段仅在符合条件的 iTunes 播放列表请求失败后才会使用,并且只保存在内存中。它不提供通用的账号登录功能,也不保证能访问已购买或已租赁的影片。
- 支持完整、未加密的 WebVTT 播放列表。加密、不连续、字节范围以及带初始化映射的字幕播放列表会被拒绝并报错。
- 字幕分片会根据其 WebVTT 时间戳映射合并。影片版本差异仍可能需要手动调整偏移;应用不会自动识别当前正在播放的影片对应哪个页面。

## 构建与验证

参与开发和提交信息规范请参阅[提交规范](docs/commit-convention.md)。

使用项目自带的构建运行脚本来构建并启动 macOS 应用:

```sh
./script/build_and_run.sh
```

也可以在 Xcode 中打开 `BetterDualSub.xcodeproj`。还可以用下面的命令构建 Release 版本:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BetterDualSub.xcodeproj -scheme BetterDualSub -configuration Release build
```

解析器、播放时钟计算和下载器无需启动 TV.app 即可测试:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

另有一个可选的在线测试,会从你提供的受支持电影链接下载英文和中文字幕:

```sh
BETTERDUALSUB_LIVE_MOVIE_URL='https://tv.apple.com/hk/movie/spider-man-into-the-spider-verse/umc.cmc.4a2ypxddplsdsahwxrc5fkz4x' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter testLiveAppleMovieLinkWhenRequested
```

Apple 电影 API 的发现流程参考了 [iSubRip](https://github.com/MichaelYochpaz/iSubRip);本应用使用原生 Swift 实现,无需安装 Python 或 iSubRip。署名与源码分析请见 `BetterDualSub/ThirdPartyNotices.txt` 和 `docs/isubrip-download-research.md`。
