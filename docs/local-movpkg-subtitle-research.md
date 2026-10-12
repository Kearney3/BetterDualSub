# Apple TV 本地 movpkg 字幕提取研究

研究日期：2026-10-11。下面先记录指定本地包的提取验证，再列出 Apple 开发者文档与 HLS 标准依据。官方资料不作为本地文件状态的替代证据。

## 指定包的结论

**可以从此次指定的 `.movpkg` 中直接提取英中字幕。**字幕是独立、明文 WebVTT 分片，虽然文件扩展名是 `.frag`。不需要下载网络资源、读取账号凭据或解密视频。该结论适用于此包，不能保证其他剧集或下载版本的轨道相同。

检查源路径：`/Users/kearney/Movies/Videos/Media.localized/TV Shows/Slow Horses/Season 6/Resurrection.movpkg`。文件夹名称按用户给出的路径记录，未通过额外目录服务确认实际季号。源包仅被读取，没有修改。

### 目录及轨道证据

- `root.xml` 标记为 HLS MoviePackage，指向 `boot.xml`。
- 主包有 96 个 stream：94 个字幕流目录、1 个视频流和 1 个音频流。`InterstitialAssets` 中另有资源，本次没有混入字幕输出。
- `Data/*master.m3u8` 列出 94 条 `TYPE=SUBTITLES` rendition。`STABLE-RENDITION-ID` 可与各字幕目录 `StreamInfoBoot.xml` 的 `UniqueIdentifier` 对应，能准确区分普通、Forced 和 SDH 字幕，避免根据随机目录名猜语言。
- 选择的 6 条英中非 Forced 轨均标记 `Complete=YES`，每条含 11 个本地 segment。其播放列表没有 `EXT-X-KEY`，分片按 XML 中的 PATH/Off/Len 读取后以 `WEBVTT` 开头，可直接解析。
- 视频/音频播放列表有 SAMPLE-AES/保护标记；未解析、导出或解密其媒体内容。字幕明文与视频受保护并不冲突。
- 每条轨道的主体是第 2 号分片：本地包起点 55170 ms，持续 2910761 ms（48 分 30.761 秒）。前两段合计 55.170 秒。后续短片段多数无可见文字。

### 实际导出结果

输出目录：[Resurrection 字幕](</Users/kearney/Movies/Subtitles/Resurrection-0C86D031-1286-48D1-B839-68944C3A3128>)。

| 轨道 | Stable rendition ID | 主体段字幕条数 | 包时间版本条数 |
| --- | --- | ---: | ---: |
| 英文普通 | `s0pllf5u1` | 682 | 699 |
| 简体中文普通 | `7chdqy79v` | 677 | 695 |
| 繁体中文普通 | `e1yiqsin1` | 678 | 696 |
| 英文 SDH | `0kafljzaa` | 793 | 810 |
| 简体中文 SDH | `bnlkt0oyo` | 788 | 806 |
| 繁体中文 SDH | `ydvsuu5v2` | 789 | 807 |

每轨导出两种时间版本，共 12 份 SRT：

- `*-episode.srt`：仅主体最长段，保留其自身的起止时间；普通英文首条起点 25901 ms。
- `*-package-timeline.srt`：按每段在本地包中的 `SEG Tim` 拼入包时间轴；主体英文首条起点因此为 81071 ms，另包含前两段的可见文字。

本次样本的 11 段之间均有 `EXT-X-DISCONTINUITY`，各段的 `X-TIMESTAMP-MAP` 都是 `MPEGTS:900000,LOCAL:00:00:00.000`，说明时间原点每段重置。包时间版本是在确认这些独立 period 的相同映射原点后用 XML 的 `SEG Tim` 定位；这是本包验证过的规则，不应套到连续 WebVTT 分段上机械累加时长。

导出使用项目现有 `SubtitleDocument.swift` 解析与 SRT 输出；每份 SRT 均重新解析并逐条核对起止时间及文本相等。读取片段时验证了 UTF-8、字节范围、已确认的 timestamp map 和本样本 cue 范围。完整计数及时间边界保存在输出目录 `verification.json`。未在报告中复制字幕对白，也未将字幕或带授权参数的资源 URL 上传到外部服务。

### BetterDualSub 接入结果与未验证边界

已在应用中加入“从本地 .movpkg 提取”窗口。提取层按 stable rendition ID 匹配字幕轨，忽略未完整下载、缺失或带加密标记的轨道，限制路径只能落在所选包内，并检查每个分片的字节范围、WebVTT 时间映射和 cue 时间。入口预选普通英文与简体中文；用户可以只显示一轨或组合两轨，也可选择单集主体时间或 movpkg 累计时间。两种模式都会导出 SRT 到 `~/Movies/Subtitles/` 并加载到现有双轨管理器。

在指定的 `Resurrection.movpkg` 上，界面列出 94 条完整字幕轨，成功提取并加载 682 条英文及 677 条简体中文 cue；SRT 行号复核计数与解析探针一致。默认选择“单集主体时间”；另有可选 movpkg 整体时间模式。独立的“字幕外观”窗口分别提供两轨字体、字重、大小、文字色、描边色和描边粗细；状态栏菜单与全局快捷键均提供主轨、第二轨延迟调整及重置。

应用已通过 Xcode Debug 构建，现有 SwiftPM 测试为 13 项通过、1 项按需联网测试跳过。真实 `.movpkg` 选轨、英中加载和样式窗口已通过界面操作验证。四个 Carbon 全局快捷键均成功注册（返回 `noErr`），但本次 CUA 合成按键没有触发系统级快捷键事件。**仍未在 TV.app 实际播放该集并对照画面时间点，因此 MediaRemote 的 elapsed time 对应单集主体、完整包还是含 interstitial 的集成时间轴尚未实证；真实键盘触发也需在本机确认。**提取可用性已经证明，直接同步效果仍应在 TV.app 播放时用多个对白时间点核对，并检查暂停和拖动。

临时探针位于 `/tmp/betterdualsub-local-movpkg/`（`tracks.json`、`Extract.swift` 和编译后探针）。其中只对所选明文字幕分片进行本地读取。

## Apple 官方资料依据

## 媒体选择与离线包

- Apple 的 `AVAssetDownloadTask` 面向 HLS 离线下载。Apple 当前的下载配置允许为 asset 指定 `AVAssetDownloadContentConfiguration.mediaSelections`；如果不指定，系统采用自动媒体选择。Apple 的离线 HLS 演讲也演示用户选择音频和字幕 rendition 后下载，并以下载所得的 AVAsset/位置进行离线播放。见 [AVAssetDownloadTask](https://developer.apple.com/documentation/avfoundation/avassetdownloadtask)、[mediaSelections](https://developer.apple.com/documentation/avfoundation/avassetdownloadcontentconfiguration/mediaselections) 和 [WWDC20 离线 HLS](https://developer.apple.com/videos/play/wwdc2020/10655/)。
- Apple HLS 文档提到 `movpkg` 作为已有离线下载位置，可将额外 rendition 下载到该位置；因此它是系统离线 HLS 包的路径格式，不应当成普通单一视频文件来处理。[HLS 离线下载规范附录](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes)
- AVFoundation 也区分可选 WebVTT subtitle rendition 与视频媒体段内嵌的 closed captions。Apple 的 HLS authoring spec 列出的可用 caption 格式包含 CEA-608、CEA-708、WebVTT 和 IMSC1，并规定 closed captions 位于 video media segments；标准 HLS 的 `CLOSED-CAPTIONS` 使用 `INSTREAM-ID` 标识嵌入流，且不带外部 `URI`。[Apple HLS accessibility 规范](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/) [Apple alternate media playlist 规范](https://developer.apple.com/documentation/http-live-streaming/adding-alternate-media-to-a-playlist)

## 保护状态不能从一个轨道推断

HLS 可加密媒体段，也可要求用户认证；`EXT-X-KEY` 描述适用于后续媒体段的加密方式，playlist 没有 `EXT-X-KEY` 时，RFC 8216 规定这些段未加密。[Apple HLS 概览](https://developer.apple.com/documentation/HTTP-Live-Streaming) [RFC 8216：加密标记](https://www.rfc-editor.org/rfc/rfc8216.html#section-4.3.2.4)

所以，应把“本地可读的独立 WebVTT 文件”和“受保护的视频/音频媒体段”分别判断：读到明文 WebVTT 只能说明该字幕段本身可读，不能推出视频也未加密、其他 rendition 已离线下载、或存在可绕过的 FairPlay 密钥。反过来，视频受保护也不能单凭这一点断言一个独立 WebVTT 轨道必然加密。先通过 HLS playlist 和 AVFoundation 可用媒体选择确认轨道类型，再依据各段的 key/URI 与 entitlement 边界判断。

## 保持时间映射与广告区间

- Apple HLS authoring spec 要求 WebVTT subtitle 文件带 `X-TIMESTAMP-MAP`；RFC 8216 §3.5 定义它将 VTT 的 `LOCAL` cue 时间映射到同一 variant 的 MPEG-2 PES 时间戳，并提醒处理 33 位 MPEG 时间戳回绕。[Apple HLS WebVTT 规范](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/) [RFC 8216 §3.5](https://www.rfc-editor.org/rfc/rfc8216.html#section-3.5)
- HLS WebVTT segment 中的 cue 时间是 cue 的总显示时间，即使部分 cue 超出该 segment 对应的 `EXTINF` 时长也一样。因此合并字幕时应保留 cue 时间并应用 timestamp map；不可仅因 playlist segment 顺序就把每段 cue 时间再加上累计 `EXTINF`，否则会产生重复偏移。[RFC 8216 §3.5](https://www.rfc-editor.org/rfc/rfc8216.html#section-3.5)
- 插播广告会使“主内容时间”和“集成播放时间”不同。Apple 将 interstitial event 的 `time` 定义在 primary content 时间线上，并提供 `resumptionOffset`、`AVPlayerItemIntegratedTimeline` 和 segment `timeMapping` 来描述 interstitial 与主内容的映射；下载配置默认跳过 interstitial 资源，只有设置 `downloadsInterstitialAssets = true` 才下载它们。[Interstitial event 时间](https://developer.apple.com/documentation/avfoundation/avplayerinterstitialevent/time) [AVPlayerInterstitialEvent](https://developer.apple.com/documentation/avfoundation/avplayerinterstitialevent) [Segment timeMapping](https://developer.apple.com/documentation/avfoundation/avplayeritemsegment/timemapping) [下载 interstitial 资源](https://developer.apple.com/documentation/avfoundation/avassetdownloadconfiguration/downloadsinterstitialassets)

**对字幕同步的建议：**如果字幕显示绑定当前播放器，优先使用 AVPlayer 的媒体选择和播放时钟；若读出 VTT 另存为 SRT，则保留并应用每段 `X-TIMESTAMP-MAP`，并确认字幕时间属于主内容还是含广告的集成时间线。不要把内嵌 `CC1` 标签当成 WebVTT URI。

以上官方资料由研究代理独立核对；本地文件状态和提取结果由主任务单独实测，记录在本文前半部分。
