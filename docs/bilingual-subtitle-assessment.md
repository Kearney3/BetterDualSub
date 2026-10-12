# 双语字幕与视频时间同步评估

评估日期：2026-10-10。项目基线：`8291e5e`。本次仅研究，未修改应用代码。

## 结论

可以在现有架构上支持双语字幕，并让两种语言跟随 Apple TV 视频的播放时间；不需要新增视频播放器或翻译服务。但当前版本尚未完整支持双语显示，也不能承诺逐帧精度。

| 需求 | 当前能力 | 评估 |
| --- | --- | --- |
| 一个 SRT，每条含中文和英文 | 解析保留两行，渲染会合并普通换行 | 小改动可支持 |
| 两个独立语言的 SRT 同时显示 | 只能选择一个文件，后一次加载覆盖前一次 | 需要增加主、副字幕轨道 |
| 字幕跟随视频播放进度 | 已接入系统媒体时间，并用 50ms 定时器推进 | 可复用，但需修正同步缺陷 |
| 主、副字幕分别校准延迟 | 仅一个全局毫秒偏移 | 需要每轨独立偏移 |
| 自动翻译或自动识别语音 | 没有相关功能 | 属于额外需求 |
| 导出校准后的双语 SRT／烧录视频 | 没有导出、视频处理流程 | 属于额外需求 |

## 现有实现和证据

- `BetterDualSub/ContentView.swift:15`：字幕包含起止毫秒和文本，适合复用为两轨字幕的条目模型。
- `ContentView.swift:127`：仅读取 UTF-8 SRT，用 `\n\n` 分块，将条目内多行用 `\n` 拼接；没有语言字段，也没有第二个字幕数组。
- `ContentView.swift:212`：文本交给 AppKit HTML importer。普通换行被当成 HTML 空白，不能确保上下两行显示。
- `ContentView.swift:298`：文件选择禁止多选；`loadSRT` 将解析结果直接覆盖 `subtitles`。
- `ContentView.swift:48`：接收 `MediaController` 系统媒体消息，读取 `isPlaying` 和 `currentElapsedTime`。
- `ContentView.swift:87`：播放时每 50ms 使用 `systemUptime` 的增量推进位置。
- `ContentView.swift:106`：按 `视频位置 - 字幕延迟` 查找第一个匹配条目，正延迟会让字幕晚显示。
- `ContentView.swift:380`：每 100ms 跟随 TV 窗口位置，用独立透明窗口覆盖视频。这是 macOS TV.app 外挂字幕，不是 Apple TV 硬件端插件。

依赖锁定在 `mediaremote-adapter` 的 `cf30c4f1af29b5829d859f088f8dbdf12611a046`。
其 [TrackInfo.swift](https://github.com/ejbills/mediaremote-adapter/blob/cf30c4f1af29b5829d859f088f8dbdf12611a046/Sources/MediaRemoteAdapter/TrackInfo.swift) 提供 `bundleIdentifier`、`playbackRate`、时间快照和快照时间戳；`currentElapsedTime` 已使用快照时间与播放速率计算当前位置。
其 [README](https://github.com/ejbills/mediaremote-adapter/blob/cf30c4f1af29b5829d859f088f8dbdf12611a046/README.md) 说明依赖私有 MediaRemote.framework，因此系统版本兼容性需要实机验证。

## 已验证的问题

### 双语换行

使用本机 Swift / AppKit 执行与项目相同的 HTML 导入：

```text
输入："你好，世界\nHello, world"
当前输出："你好，世界 Hello, world"
将换行转成 <br> 后："你好，世界\nHello, world"
```

从项目提取原始 SRT 解析逻辑执行样例，确认文本中的中文、英文和换行均被保留，起止时间为 1000ms、3000ms。因此此问题发生在显示层。保留现有 HTML 格式支持时，需要显式处理换行；两轨方案可分别渲染两个文本视图。

### 时间同步

1. **倍速不正确**：内部定时器始终按 1 倍速推进，没有读取 `playbackRate`。如果视频以 2 倍速播放且 10 秒内没有新媒体回调，字幕时间会落后约 10 秒；这是逻辑推演，未实机播放验证。
2. **停顿后会丢失时间**：当定时器间隔达到 200ms 或以上，代码直接丢弃增量。没有后续媒体回调校准时，误差会持续。
3. **未限定媒体来源**：TV 窗口识别和系统媒体时间是两条独立链路，没有用 `bundleIdentifier` 校验时间来自 TV.app；其他播放器成为系统当前媒体来源时，存在错配风险。
4. **窗口可见性影响播放状态**：找不到 TV 窗口时直接设置 `isPlaying = false`。窗口重新出现而媒体未发新消息时，可能无法自动恢复推进。
5. **缺少有效时间时继续推进**：有媒体对象但 `currentElapsedTime` 缺失时，仅更新播放状态，可能沿用旧位置；监听终止、解码错误也未在应用侧处理。
6. **边界和重叠条目**：匹配区间为两端包含，且只取第一条。测试确认相邻字幕在 3000ms 的交界点仍选上一条；重叠字幕也只会显示第一条。

50ms 是查询调度间隔，200ms 是回调校准阈值，两者都不是实测同步精度。系统媒体时间也不是解码后视频帧的 PTS，不能据此承诺逐帧同步。

## 建议实施范围

先修正双语换行和共享时间轴，再增加双轨；继续复用现有 SwiftUI、AppKit 和媒体依赖。

1. **共享视频时钟**：每次有效 TV 媒体消息保存视频位置、单调时钟锚点、播放速率和播放状态。每次刷新从锚点直接计算位置，避免累加丢失时间；暂停固定位置，跳转和速率变化重新锚定。TV 来源需按实际 bundle identifier 验证。时间缺失、来源切换、监听失败时停止使用旧时间并显示明确状态。窗口显隐只控制覆盖窗口。
2. **主、副轨**：各自保存字幕条目、文件名和毫秒偏移。新增“加载主字幕”“加载副字幕”“关闭副字幕”，允许仅使用主轨。
3. **按时间独立查找**：两轨使用同一视频位置，各自计算 `有效字幕时间 = 视频位置 - 全局延迟 - 本轨延迟`；使用 `[start, end)` 区间。不要按条目编号配对，两种语言可能有不同的切分和持续时间。
4. **显示**：上下两组字幕视图，支持固定语言顺序和副轨字号；按双轨、多行内容调整窗口高度，验证小窗口和全屏不裁切。单个已合并的双语 SRT 则显式保留换行，不自动猜测语言。
5. **载入质量**：读取或解析失败给出反馈，校验时间范围及排序；明确编码支持，避免当前静默失败。重叠字幕处理需有明确规则。

若字幕和视频只是整体早晚，毫秒偏移足够。如果片源帧率、剪辑或片头长度不同，可能需要时间缩放或分段校准；单一延迟不能解决随播放时间增长的漂移，也不能自动匹配不同版本影片。

## 验收和限制

后续至少验证：双语 SRT 换行、双轨分句不同、某轨无字幕时另一轨正常、正负独立延迟、暂停继续、前后拖动、长时间播放、支持倍速的来源、主线程延迟、其他播放器抢占、窗口隐藏恢复、全屏、小窗口和多显示器。

本次完成源码审查、锁定依赖源码核查、SRT 解析样例和 AppKit 换行复现。未运行完整应用，也未实测 TV 播放同步。当前仅有 Command Line Tools，`xcodebuild` 提示需要完整 Xcode；未发现 Xcode.app，因此未进行完整构建。

## 2026-10-11 构建验证补充

安装 Xcode 27.0（27A266a）后，已执行 `xcodebuild -runFirstLaunch`，安装初次运行所需组件，解决 CoreSimulator.framework 缺失导致的构建工具启动失败。

使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 指定工具链，并保持现有依赖锁定在 `cf30c4f`。Debug、Release 均完成 macOS 构建并输出 `BUILD SUCCEEDED`；两个应用均通过 `codesign --verify --deep --strict` 验证。此次产物为 arm64，最低系统版本为 macOS 14.0，使用本地 ad-hoc 签名。

Release 产物：`/Users/kearney/Library/Developer/Xcode/DerivedData/BetterDualSub-Codex/Build/Products/Release/BetterDualSub.app`。

复现命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project BetterDualSub.xcodeproj -scheme BetterDualSub \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /Users/kearney/Library/Developer/Xcode/DerivedData/BetterDualSub-Codex \
  -onlyUsePackageVersionsFromResolvedFile build
```

将 `Release` 换成 `Debug` 可复现 Debug 构建。构建日志分别在 `/tmp/BetterDualSub-debug-build.log`、`/tmp/BetterDualSub-release-build.log`。唯一构建警告为未依赖 AppIntents.framework 而跳过相关元数据提取。

此次未修改应用源代码或依赖锁文件，尚未实施双语功能，也未启动应用验证实际播放同步；构建成功不代表这些功能已通过运行验收。
