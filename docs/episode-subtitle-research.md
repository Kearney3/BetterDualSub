# Apple TV 剧集字幕下载可行性研究

核对日期：2026-10-11。GitHub `main` 当前 HEAD 与已有研究快照相同，均为 [`b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1`](https://github.com/MichaelYochpaz/iSubRip/commit/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1)。因此本报告的固定行号链接既代表当前上游，也代表该快照。

## 结论

BetterDualSub 可以扩展到 iTunes **单集页面的资源发现**，但本次实测尚未成功下载剧集的独立文字字幕。限制不只是当前电影 URL 校验：样本的英文 CC 位于视频流内，现有 HLS → WebVTT 下载器不能提取；Apple TV+ 样本也没有返回电影路径使用的 iTunes `hlsUrl`。因此应把“支持单集链接”“提取视频内嵌 CC”“支持 Apple TV+ 授权资源”分为不同能力。只有单集实际提供可访问的外挂文字字幕时，现有字幕下载与双轨显示流程才可直接复用。

iSubRip 当前不能通过它自己的 Apple TV 页面 scraper 下载剧集字幕。源码能识别 show、season、episode 页面 URL，但这只是 URL 分流；实际 `get_episode_data`、`get_season_data`、`get_show_data` 都直接抛出“Series scraping is not currently supported.”。唯一声明并调用的 UTS 媒体 API 路由是 `/uts/v3/movies/{movieId}`。这证明功能尚未实现，不能据此断言 Apple 技术上没有剧集字幕或没有可用的接口。[URL 类型与 movie route 常量](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L26-L38) [三个系列方法均为 stub](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L441-L448) [URL 解析最终调用这些方法](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L450-L484)

## 源码具体做了什么

- Apple TV scraper 的 URL 正则包含 `movie|episode|season|show`，但在数据获取阶段，movie 会进入 `get_movie_data()`；episode、season、show 分别进入上述未实现方法。season URL 还要求 query 中出现 `showId`。源码只定义 `APPLE_MOVIE_ROUTE_PATH`，电影方法请求 `/movies/{movie_id}`；没有 episode、season、show 的 API route 常量或相应 metadata extractor。[正则和唯一 route 常量](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L26-L38) [movie API 调用](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L337-L384) [episode/season/show 路由](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L469-L482)
- 类上 `is_series_scraper = True`，以及 `data_structures.py` 中有 Episode、Season、Series 数据类，不代表下载能力已完成：这些类型的 playlist 信息字段存在，但 scraper 未填充它们。[类标记](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L29-L39) [数据模型](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/data_structures.py#L143-L220)
- iTunes scraper 的正则看起来接受 `tv-show`、`tv-season` URL，但其 `get_data()` 注释、返回类型和实际行为都是电影路径：把 ID 拼成 `/country/movie/{media_id}`，再转交 Apple TV scraper。仅凭正则接受 TV 字符串，不能认为 iTunes Store 剧集链接可用。[iTunes URL 正则](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L55-L63) [固定 movie redirect 路径](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/itunes_scraper.py#L111-L180)
- 两种 iTunes/TV+ 内容也不能混称。代码把 `tvs.sbd.9001` 定义为 ITUNES，把 `tvs.sbd.4000` 定义为 APPLE_TV_PLUS；电影方法只从 iTunes channel 取 playable，若只有 Apple TV+ playable 则明确报不支持。[channel ID](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L118-L129) [只选择 iTunes movie playable](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L337-L384) [Apple TV+ movie 的明确失败分支和对应 mock test](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/isubrip/scrapers/appletv_scraper.py#L344-L352) [test](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/tests/test_appletv_scraper.py#L110-L128)
- README 将工具范围描述为 Apple TV 与 iTunes 的 **movie** URL；现有 README 没有宣布剧集支持。[项目范围](https://github.com/MichaelYochpaz/iSubRip/blob/b482a61894d1bdbe78d28640e8d2cc6a2f0cdad1/README.md#L1-L4)

## Apple 官方资料与可行性边界

Apple 官方资料区分 Apple TV 订阅（包含 Apple Originals 系列、电影等按需内容）与 Apple TV app Store 中购买或租赁的内容；官方也说明可购买 TV 节目的单集、整季、整部系列或 Season Pass，且功能受地区影响。[Apple TV 订阅与 Store 购买/租赁说明](https://support.apple.com/guide/tv/subscribe-to-and-buy-content-atvb721df44e/27/tvos) [购买 TV 节目单集或整季](https://support.apple.com/en-ca/guide/tv/-atvb0d26676e/tvos) [Apple Originals 订阅说明](https://support.apple.com/guide/tvapp/watch-apple-originals-atvb60881377/web)

这些官方用户指南证明苹果产品里存在这两种剧集分发形态，但不公开 UTS episode/season/show API schema，也不承诺第三方字幕下载接口。iSubRip 对电影所用的 Apple web API、iTunes HLS manifest 做法可以作为探索剧集的起点，但目前没有剧集 API 请求字段、剧集 playable 解析、系列层级遍历或针对剧集的 mock 测试证据；尚需单独验证每种分发形态是否返回可用字幕 rendition 及访问条件。不能把现有电影成功推演成 TV+ 或 Store 剧集已可下载，也不能把当前未实现等同技术不可行。

## 对 BetterDualSub 的建议

若要支持剧集，建议将任务表述为实现一个新的 Apple episode metadata adapter，而非仅把现有电影链接校验扩展到 `/episode/`：需要先确认用户可提供的 episode URL/ID、对应 storefront、苹果实际 metadata endpoint 和 response shape，再判断返回内容属于 Apple TV 订阅还是 iTunes Store 购买项。若能取得字幕 playlist URL，后续 HLS rendition → VTT segments → SRT 转换逻辑可沿用电影链路；但 episode 选择、剧集/季关系、字幕语言轨选择和 entitlement 错误需要分别处理。当前 upstream 源码只能支持“值得实测”，不能支持“已经可下载”的结论。

## 验证范围

源码结论来自当前上游 HEAD（通过 `git ls-remote` 核对与给定快照同 SHA）及固定提交上的官方项目代码/README。源码研究与以下真实 API 验证分开记录。所有请求匿名；未登录账号、未使用 DSID、未下载视频。没有成功导出剧集字幕，也没有验收整季遍历或付费播放授权。

## Apple API 真实验证

2026-10-11，使用与当前电影下载器相同的 storefront/configuration 参数发现流程。苹果运行时配置的 `applicationProps.routes` 包含下列路由，`requiredParamsType` 均为 `Default`；以下接口通过 Apple TV 网站 `/api` 代理访问。[配置接口](https://tv.apple.com/api/uts/v3/configurations?utscf=OjAAAAAAAAA~&caller=web&v=96&pfm=web&sf=143441)

| 入口 | 实测结果 | 接入含义 |
| --- | --- | --- |
| `/uts/v3/episodes/{episodeId}` | 返回 `content`、`playables`；部分 iTunes playable 含 `itunesMediaApiData.offers[].hlsUrl` | 可直接复用电影的资源选择及 HLS 解析层 |
| `/uts/v3/shows/{showId}` | 返回 `seasons`、`smartEpisode` 和购买项 | 整部剧链接应先让用户选季、选集，不能直接把季购买项当视频资源 |
| `/uts/v3/shows/{showId}/episodes` | Breaking Bad 默认返回 6 集，`totalEpisodeCount=62` | 不可把第一次响应当作全部剧集 |
| `/uts/v3/shows/{showId}/{seasonId}` | 季详情返回 `content`，未直接给出剧集列表 | 季详情和剧集列表是独立流程 |

本次少量分页探测中 `startIndex=6&count=10` 没有改变返回的前 6 集；`nextToken=6&count=10` 返回 HTTP 400。这些是试探参数，不是已确认的 API 合同。完整分页字段和按季筛选仍需追踪网站实际请求；首版先支持单集链接可避免这一依赖。上述 API 为苹果网站内部接口，没有找到第三方稳定性承诺。

### 单集样本

| 官方单集页面 | 实际资源 | 字幕结果 |
| --- | --- | --- |
| [Breaking Bad S1E1：Pilot（US）](https://tv.apple.com/us/episode/pilot/umc.cmc.6trodclp7sphpy2gelbgwb4fk) | iTunes 596636935 的 master 可访问；942690845 的候选请求返回 404 | 只有英文 `TYPE=CLOSED-CAPTIONS`、`INSTREAM-ID=CC1`，没有 `TYPE=SUBTITLES` |
| [Game of Thrones S1E1：Winter Is Coming（US）](https://tv.apple.com/us/episode/winter-is-coming/umc.cmc.11q7jp45c84lp6d16zdhum6ul) | iTunes 494877461 的 master 可访问；1460846388 的候选返回 404 | 只有英文内嵌 CC1，无外挂字幕 URI |
| [Planet Earth S1E1：From Pole to Pole（US）](https://tv.apple.com/us/episode/from-pole-to-pole/umc.cmc.40ua0gxewmvd8sy0fnyp0uo8p) | iTunes 285897274 的 master 可访问；1776920988 的候选返回 404 | 只有英文内嵌 CC1，无外挂字幕 URI |
| [Severance S1E1：Good News About Hell（US）](https://tv.apple.com/us/episode/good-news-about-hell/umc.cmc.s80mx1ic96pu6ewupz8pfasf) | `tvs.sbd.4000` Apple TV+ playable，无 `itunesMediaApiData` | 页面列出英中字幕，匿名元数据未给出当前下载链路需要的 master URL；不能据此判定字幕不存在 |

对 Breaking Bad 同一集补测 GB 与 DE：GB iTunes 661527190 的 master 仍仅英文 CC1；DE 746348896、303160406、648120836 以及一个 GB/DE 291565398 候选返回的 master 未列出上述两种字幕标签；另一个 GB 候选返回 404。这些结果只代表选定地区、版本和匿名访问，不代表所有剧集，也不能把 404 直接解释为需要登录。

另外，用当前 `MovieSubtitleDownloader.swift` 和 `SubtitleDocument.swift` 编译临时 Swift 探针，对上述 Breaking Bad 两个 US 版本调用 `tracks(for:)`：分别得到“没有可下载的文字字幕”和 HTTP 404。探针没有修改应用，证明失败发生在真实资源/字幕格式层，而不是只被当前 `MoviePage` URL 校验阻止。

HLS 中 `CLOSED-CAPTIONS` 表示字幕位于视频流，URI 属性禁止出现，`INSTREAM-ID=CC1` 是字幕通道标识而不是下载地址；`SUBTITLES` 则必须提供 URI。这一差别由 [RFC 8216 §4.3.4.1](https://www.rfc-editor.org/rfc/rfc8216#section-4.3.4.1) 明确定义。因此把 CC1 拼成下载 URL 或把电影 VTT 分段解析器套到 CC1 上都不可行。内嵌 CC 的后续路线需要另外验证可访问的视频分段、字幕提取及时间戳；本次没有下载或解密视频。

### 建议实施顺序

1. **先支持单集链接**：将页面模型增加 `episode` 类型，按配置选择 `/episodes/{episodeId}`；提取剧名、季号、集号、单集标题和 iTunes offer。复用现有语言选择、缓存、双轨时钟；无外挂字幕时明确告知“仅内嵌 CC”或“无可用字幕”，避免模糊失败。
2. **为真实目标剧集确认字幕路径**：选有需要的地区/版本，验证是否存在英中两条可访问的外挂轨。若只有 CC1，另立内嵌 CC 提取能力；不承诺现有下载器可完成。
3. **Apple TV+ 单独研究**：追踪合法已授权播放时获得 manifest 的方式，再验证字幕 rendition 和分段访问条件。DSID fallback 当前仅覆盖指定 iTunes master 端点，不能替代 TV+ 播放授权。
4. **整季/整剧选择随后接入**：确认分页与 season 过滤合同，再考虑批量下载。不能用默认 6 集响应充当全剧。

实测 JSON、master 快照、探针与输出临时保存在 `/tmp/betterdualsub-episode-research/`，包括 `config.json`、`breakingbad.json`、`severance.json`、`show.json`、`episodes.json`、`breakingbad-master.m3u8`、`download.log`、`markets.log`。本报告只保留必要字段和结果，不提交可能失效的完整资源 URL。
