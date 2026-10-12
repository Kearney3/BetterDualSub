# iSubRip 如何取得 Apple TV 电影字幕

本文依据 iSubRip 源码快照 `b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1`。下方 GitHub 链接均固定到该提交，便于复查实现。

## 下载链路

1. **Apple TV 电影 URL → 地区与影片 ID。** 解析 `/movie/umc.cmc.…`，读取 URL 国家代码并映射到 Apple Storefront ID；省略国家代码时用 US。随后访问 Apple TV UTS v3 影片 API：`GET https://tv.apple.com/api/uts/v3/movies/{movieId}`。[URL 解析和地区分发](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L34-L42) [API 路由](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L337-L342) [分发逻辑](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L450-L470)

2. **配置请求参数。** 基础 query 参数是 `utscf=OjAAAAAAAAA~`、`caller=web`、`v=96`、`pfm=web`。程序先请求 `/configurations`，从 `applicationProps.routes` 找电影路由对应的 `requiredParamsType`，再从 `requiredParamsMap` 取参数；添加 `sf={storefrontId}` 和受该 storefront 支持的 `locale`。locale 优先 `en_US`、`en_GB`，否则用 storefront 默认值。因此 API 所需参数以苹果运行时返回的配置为准，未必只限这几个固定 query 项。[基础参数、配置和路由参数选择](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L70-L76) [动态参数和 locale](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L211-L284) [配置端点](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L286-L317)

3. **影片 API → iTunes HLS 主播放列表。** 从 `data.playables` 选 `channelId=tvs.sbd.9001`（iTunes）的项，读取 `itunesMediaApiData.id` 和 `offers[].hlsUrl`。多个有效 offer 会作为候选 URL 保存；同时提取 `canonicalMetadata.movieTitle`、`releaseDate`、offer 时长。`hlsUrl` 是 iTunes 的 master `.m3u8` 地址，不是视频文件下载地址。代码也提供直接 iTunes 电影 URL 的兼容入口：先请求对应 Apple TV 电影 URL 获取 redirect，再交由同一元数据路径处理。[playable 筛选](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L337-L384) [HLS URL 和影片元数据字段](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L386-L439) [iTunes URL redirect](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L111-L180)

4. **HLS master → 字幕 rendition → VTT 分片。** 解析 master playlist 的 `TYPE=SUBTITLES` rendition，依据 `GROUP-ID`、`LANGUAGE` 等字段筛选；可将用户指定语言码作为 filter。iSubRip 还限定 Apple 已知的 subtitle group 名称，并将同一 rendition 的 Apple CDN mirror 分组，某个候选下载失败时顺序尝试其他镜像。[Apple subtitle group 过滤](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L28-L78) [rendition 去重与分组](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L87-L109) [语言筛选和候选分组](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/scraper.py#L698-L731)

   rendition URI 通常返回另一个 m3u8；程序并发下载其中的 VTT segment，再按 playlist 顺序解析、拼接字幕块。输出默认为 WebVTT，可选转成 SRT（重新编号 cue、把毫秒分隔符改为逗号）。[分片并发下载及拼接](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/scraper.py#L552-L644) [VTT 解析及去除后续分片头部](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/subtitle_formats/webvtt.py#L197-L308) [SRT 输出](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/subtitle_formats/subrip.py#L28-L38)

## 字幕类型、地区与访问限制

- 地区代码决定 metadata 请求用哪个 storefront，进而影响该地区返回哪些 playable 和 offer。subtitle rendition 的语言则来自 HLS `LANGUAGE`，可按语言码筛选；二者是不同维度。[Storefront 映射与 URL 国家码](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L42-L68) [HLS 语言筛选](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/scraper.py#L703-L711)
- `FORCED=YES` 会标记为 Forced；`CHARACTERISTICS` 含 `public.accessibility` 会标记为 CC。代码会保留 `LANGUAGE` 及 rendition 名称，也会从显示名称剥掉 `(forced)`；没有单独的 SDH 分类器，SDH 是否显示为 CC 取决于 Apple 实际给出的 characteristics。[Forced/CC 标记](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/scraper.py#L533-L550) [名称处理](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L328-L335)
- 默认匿名请求。仅对指定 Apple master-manifest host/path 的 401、403、404，才可追加用户配置的数字 DSID 重试；匿名成功时不会发送 DSID。非 entitlement 类错误不触发此 fallback，并且不会自动获取账号标识。README 也说明 manifest API 未公开，401/403/404 不能单独证明必须登录。[仅认定的 Apple manifest 地址](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L49-L52) [匿名优先及错误限定的 DSID fallback](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L182-L327) [README 的 DSID 说明](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/README.md#L88-L95)

## 已知边界，以及对 BetterDualSub 的参考价值

- 适合借鉴的是分层链路和数据模型：Apple TV URL/storefront/API 解析器 → iTunes offer/master playlist 解析器 → 通用 HLS subtitle rendition/segment 下载器 → VTT 解析和可选 SRT 转换。它也给出可复用的语言码、forced/CC 元数据和 CDN mirror fallback 思路。
- 这份源码证明存在一条通过 Apple TV 网站端接口和 HLS manifest 取字幕的网络路径；它不证明 TV.app 本地接口可用或不可用，也不排除其他提取途径。
- 此快照没有实现 Apple TV+ 原创剧集下载：`tvs.sbd.4000` 会明确报不支持；episode、season、show 方法也直接抛 `NotImplementedError`，即便类标记 `is_series_scraper=True`。[Apple TV+ channel 限制](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L118-L129) [不支持 Apple TV+ playable](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L344-L352) [系列方法未实现](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L441-L448)
- 时间戳需要谨慎移植：VTT parser 只识别 cue timing、comments、REGION、STYLE；`X-TIMESTAMP-MAP` 不匹配这些分支，因此 MPEGTS/LOCAL 映射会被忽略。合并逻辑逐段读取 cue 自带的时间戳并直接追加，也没有依据 segment 的 `EXTINF` 累加偏移。因此应先用有多段 VTT 的样本校验 cue 是否处于同一片内时间轴、拼接后有无重复/重叠，再决定是否复用其合并策略。[时间戳解析与已处理区块](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/subtitle_formats/webvtt.py#L197-L275) [segment 追加](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/scraper.py#L559-L565)
- 它没有绕过加密，也没有下载影片；实现依赖 `httpx2`、`m3u8`、Pydantic 等，项目用 MIT License，但项目说明用户需自行确保访问内容符合适用条款。若移植源码或实质部分，保留 MIT 版权和许可声明。[运行依赖](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/pyproject.toml#L33-L44) [MIT notice 条件](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/LICENSE#L1-L14) [项目使用责任说明](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/README.md#L176-L184)

## 验证范围

以上是对指定提交源码、README、许可证和已有 mock 测试定义的追踪，不代表当前 Apple API、manifest、CDN 仍可实际下载。此研究没有登录账号、获取 DSID、请求电影 manifest 或下载影片。

2026-10-11 在 `/tmp` 的独立虚拟环境运行上游 `test_appletv_scraper.py`、`test_hls_playlist.py`、`test_dsid_release.py`：**135 passed in 0.74s**。这些是模拟响应测试，不是苹果服务端验收。测试日志为 `/tmp/isubrip-research-tests.log`。

## BetterDualSub 接入建议

可以先让用户粘贴 Apple TV 电影链接，选择返回的英文和中文完整字幕轨，下载并缓存两份 SRT，再由 BetterDualSub 的同一视频时钟独立查找两轨内容、上下显示。需要排除仅翻译外语对白的 forced 轨，并允许选择简体、繁体及 CC 等实际存在的变体；不假定每部影片都有中文。

当前 BetterDualSub 的 `ContentView.swift` 仅加载一份 SRT；双轨选择、文本换行、共享视频时钟和独立延迟仍需实施，见[此前评估](bilingual-subtitle-assessment.md)。iSubRip 没有提供双语合并显示和 TV.app 播放同步。

首版不宜承诺自动识别正在播放影片：本机 TV.app 脚本字典有 `current track`、`database ID`、`persistent ID` 和 `current stream URL`，但没有验证这些值可稳定映射到 UTS API 的 `umc.cmc` ID。标题匹配也不足以区分重名影片、剪辑版本和地区。先使用准确的影片页面链接更便于验证端到端下载和同步。

以上为接入建议，未修改 BetterDualSub 应用代码、安装 iSubRip 到全局环境或实现网络下载功能。
