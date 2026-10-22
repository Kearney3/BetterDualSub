import XCTest
@testable import BetterDualSubCore

final class SubtitleDownloadTests: XCTestCase {
    func testBackgroundWorkLeavesMainActorAndCancelsAnInFlightWorker() async throws {
        let mainActorTask = await MainActor.run {
            Task { try await SubtitleBackgroundWork.run { Thread.isMainThread } }
        }
        let ranOnMainThread = try await mainActorTask.value
        XCTAssertFalse(ranOnMainThread)
        let started = expectation(description: "Worker started")
        let stopped = expectation(description: "Worker received cancellation")
        let task = Task {
            try await SubtitleBackgroundWork.run {
                started.fulfill()
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    if Task.isCancelled { stopped.fulfill(); throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return false
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testMovpkgRejectsUnrepresentableOrUnboundedTimelines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).movpkg")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = root.appendingPathComponent("2-test")
        let data = root.appendingPathComponent("Data")
        for folder in [stream, data] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "<HLSMoviePackage/>".write(to: root.appendingPathComponent("boot.xml"), atomically: true, encoding: .utf8)
        try "x".write(to: stream.appendingPathComponent("segment.frag"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n".write(to: stream.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,STABLE-RENDITION-ID=test,LANGUAGE=en,NAME=English\n"
            .write(to: data.appendingPathComponent("test-master.m3u8"), atomically: true, encoding: .utf8)
        for (start, duration) in [("1e20", "1"), ("0", "1e20"), ("1e308", "1e308"),
                                  ("nan", "10"), ("0", "inf"), ("35999999", "2")] {
            let xml = "<StreamInfoBoot><Complete>YES</Complete><Type>Supplemental</Type><MediaType type=\"sbtl\"/>" +
                "<UniqueIdentifier>test</UniqueIdentifier><PathToLocalCopy>playlist.m3u8</PathToLocalCopy>" +
                "<SEG PATH=\"segment.frag\" Off=\"0\" Len=\"1\" SeqNum=\"0\" Tim=\"\(start)\" Dur=\"\(duration)\"/></StreamInfoBoot>"
            try xml.write(to: stream.appendingPathComponent("StreamInfoBoot.xml"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try MovpkgSubtitleExtractor.inspect(root), "\(start), \(duration)")
        }
    }

    func testLocalReaderRejectsOversizedFilesAndCancelledWork() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: SubtitleFileReader.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try SubtitleFileReader.document(at: url))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubtitleBackgroundWork.run { try SubtitleFileReader.document(at: url) }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testMovpkgSkipsDamagedTracksAndExtractsRemainingTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).movpkg")
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("2-good")
        let damaged = root.appendingPathComponent("2-damaged")
        let outOfRange = root.appendingPathComponent("2-out-of-range")
        let data = root.appendingPathComponent("Data")
        for folder in [good, damaged, outOfRange, data] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "<HLSMoviePackage/>".write(to: root.appendingPathComponent("boot.xml"), atomically: true, encoding: .utf8)
        let vtt = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
        try vtt.write(to: good.appendingPathComponent("segment.frag"), atomically: true, encoding: .utf8)
        let xml = { (id: String, length: Int) in
            "<StreamInfoBoot><Complete>YES</Complete><Type>Supplemental</Type><MediaType type=\"sbtl\"/>" +
            "<UniqueIdentifier>\(id)</UniqueIdentifier><PathToLocalCopy>playlist.m3u8</PathToLocalCopy>" +
            "<SEG PATH=\"segment.frag\" Off=\"0\" Len=\"\(length)\" SeqNum=\"0\" Tim=\"0\" Dur=\"10\"/></StreamInfoBoot>"
        }
        try xml("good", vtt.utf8.count).write(to: good.appendingPathComponent("StreamInfoBoot.xml"), atomically: true, encoding: .utf8)
        try xml("bad", 9999).write(to: outOfRange.appendingPathComponent("StreamInfoBoot.xml"), atomically: true, encoding: .utf8)
        try vtt.write(to: outOfRange.appendingPathComponent("segment.frag"), atomically: true, encoding: .utf8)
        try "<broken".write(to: damaged.appendingPathComponent("StreamInfoBoot.xml"), atomically: true, encoding: .utf8)
        for folder in [good, outOfRange] {
            try "#EXTM3U\n".write(to: folder.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        }
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,STABLE-RENDITION-ID=good,LANGUAGE=en,NAME=English\n" +
            "#EXT-X-MEDIA:TYPE=SUBTITLES,STABLE-RENDITION-ID=bad,LANGUAGE=zh,NAME=Chinese\n"
        try master.write(to: data.appendingPathComponent("one-master.m3u8"), atomically: true, encoding: .utf8)

        let tracks = try MovpkgSubtitleExtractor.inspect(root)
        XCTAssertEqual(tracks.map(\.id), ["good"])
        let document = try MovpkgSubtitleExtractor.document(for: XCTUnwrap(tracks.first), packageTimeline: false)
        XCTAssertEqual(document.items, [SubtitleItem(startMs: 1000, endMs: 2000, text: "Hello")])
    }

    func testMoviePageValidation() throws {
        let page = try MoviePage("https://tv.apple.com/hk/movie/title/umc.cmc.1vrwat5k1ucm5k42q97ioqyq3?x=1")
        XCTAssertEqual(page.country, "HK")
        XCTAssertEqual(try MoviePage("https://tv.apple.com/movie/umc.cmc.1vrwat5k1ucm5k42q97ioqyq3").country, "US")
        for invalid in ["http://tv.apple.com/movie/x", "https://tv.apple.com.evil.com/movie/x", "https://tv.apple.com/show/umc.cmc.1vrwat5k1ucm5k42q97ioqyq3", "https://user@tv.apple.com/movie/x"] {
            XCTAssertThrowsError(try MoviePage(invalid))
        }
    }

    func testSRTAndVTTParsingBoundaryOverlapAndEmptySegments() throws {
        let text = "\u{feff}1\r\n00:00:01,000 --> 00:00:03,000\r\n你好\r\nHello\r\n \r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nOverlapping"
        let document = try SubtitleDocument(text: text)
        XCTAssertEqual(document.text(at: 1000), "你好\nHello")
        XCTAssertEqual(document.text(at: 2000), "你好\nHello\nOverlapping")
        XCTAssertEqual(document.text(at: 3000), "Overlapping")
        XCTAssertEqual(document.text(at: 4000), "")
        XCTAssertEqual(try SubtitleDocument(text: document.srt).items, document.items)
        let vtt = "WEBVTT\n\nNOTE ignore --> this\ntext\n\ncue-1\n00:01.500 --> 00:03.000 align:center\nHello"
        XCTAssertEqual(try SubtitleDocument(text: vtt).items.first?.startMs, 1500)
        XCTAssertTrue(try SubtitleDocument.parse("WEBVTT\n", allowEmpty: true).document.items.isEmpty)
        XCTAssertThrowsError(try SubtitleDocument(text: "not subtitles"))
        XCTAssertThrowsError(try SubtitleDocument(text: "1\n00:00:03,000 --> 00:00:01,000\nInvalid"))
        XCTAssertNil(SubtitleDocument.time("nan:00:00"))
        XCTAssertNil(SubtitleDocument.time("00:00:inf"))
        XCTAssertNil(SubtitleDocument.time("00:60:00"))
    }

    func testBilingualMergeAlignsDifferentSegmentationAndCleansMarkup() throws {
        let en = try SubtitleDocument(text: "1\n00:00:01,000 --> 00:00:03,000\n<v Bob>Hello &amp; hi</v>\n\n2\n00:00:05,000 --> 00:00:06,000\nBye")
        let zh = try SubtitleDocument(text: "1\n00:00:01,050 --> 00:00:02,000\n你好\n\n2\n00:00:02,000 --> 00:00:03,100\n你好吗\n\n3\n00:00:07,000 --> 00:00:08,000\n仅中文")
        let merged = try SubtitleDocument.bilingual(primary: en, secondary: zh)
        XCTAssertEqual(merged.items, [
            SubtitleItem(startMs: 1000, endMs: 2000, text: "Hello & hi\n你好"),
            SubtitleItem(startMs: 2000, endMs: 3000, text: "Hello & hi\n你好吗"),
            SubtitleItem(startMs: 5000, endMs: 6000, text: "Bye"),
            SubtitleItem(startMs: 7000, endMs: 8000, text: "仅中文")
        ])
    }

    func testHTMLPreservesBilingualLinesWithoutExternalResources() throws {
        XCTAssertEqual(SubtitleDocument.displayHTML("<b>你好</b>\n<v Speaker>Hello</v><img src='https://example.com/x'>"), "<b>你好</b><br>Hello")
    }

    func testClockHandlesSpeedPauseSeekAndLongTimerDelay() {
        var clock = SubtitleClock(positionMs: 1000, uptime: 10, rate: 2, valid: true)
        XCTAssertEqual(clock.position(at: 20), 21_000)
        clock = SubtitleClock(positionMs: 5000, uptime: 20, rate: 0, valid: true)
        XCTAssertEqual(clock.position(at: 100), 5000)
        clock = SubtitleClock(positionMs: 2000, uptime: 100, rate: 1, valid: true)
        XCTAssertEqual(clock.position(at: 100.5), 2500)
    }

    func testLookupWithLongOverlapAndDuration() throws {
        let document = try SubtitleDocument(items: [
            SubtitleItem(startMs: 0, endMs: 10_000, text: "long"),
            SubtitleItem(startMs: 1000, endMs: 2000, text: "a"),
            SubtitleItem(startMs: 3000, endMs: 4000, text: "b")])
        XCTAssertEqual(document.text(at: 500), "long")
        XCTAssertEqual(document.text(at: 1500), "long\na")
        XCTAssertEqual(document.text(at: 2500), "long")
        XCTAssertEqual(document.text(at: 3000), "long\nb")
        XCTAssertEqual(document.text(at: 10_000), "")
        XCTAssertEqual(document.duration, 10_000)
    }

    func testLineModes() {
        XCTAssertEqual(SubtitleLineMode.original.apply(to: "a\nb"), "a\nb")
        XCTAssertEqual(SubtitleLineMode.single.apply(to: "Hello\nworld"), "Hello world")
        XCTAssertEqual(SubtitleLineMode.single.apply(to: "你好\n世界"), "你好世界")
        XCTAssertEqual(SubtitleLineMode.double.apply(to: "short"), "short")
        XCTAssertEqual(SubtitleLineMode.double.apply(to: "a\nb"), "a\nb")
        let three = SubtitleLineMode.double.apply(to: "one two\nthree four\nfive six")
        XCTAssertEqual(three.split(separator: "\n").count, 2)
        let long = SubtitleLineMode.double.apply(to: "This is a rather long single line subtitle that should split in two")
        XCTAssertEqual(long.split(separator: "\n").count, 2)
        XCTAssertEqual(long.replacingOccurrences(of: "\n", with: " "), "This is a rather long single line subtitle that should split in two")
    }

    func testClockRebaseKeepsPositionAcrossRateChange() {
        var clock = SubtitleClock(positionMs: 1000, uptime: 10, rate: 1, valid: true)
        clock.rebase(at: 12)
        clock.rate = 2
        XCTAssertEqual(clock.position(at: 12), 3000)
        XCTAssertEqual(clock.position(at: 13), 5000)
    }

    func testRenditionsRelativeURLsMirrorGroupingAndVariants() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles_ap",NAME="English, US",LANGUAGE="en-US",URI="en/list.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles_ak",NAME="English, US",LANGUAGE="en-US",URI="https://vod-ak-amt.tv.apple.com/en/list.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,NAME="English, US",LANGUAGE="en-US",FORCED=YES,URI="forced.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,NAME="简体中文",LANGUAGE="zh-Hans",CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound",URI="zh.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,LANGUAGE="en",URI="audio.m3u8"
        """
        let tracks = try SubtitlePlaylist.tracks(master, baseURL: URL(string: "https://vod-ap-amt.tv.apple.com/movie/master.m3u8")!)
        XCTAssertEqual(tracks.count, 3)
        let english = try XCTUnwrap(tracks.first { $0.language == "en-US" && !$0.forced })
        XCTAssertEqual(english.mirrors.count, 2)
        XCTAssertEqual(english.mirrors[0].absoluteString, "https://vod-ap-amt.tv.apple.com/movie/en/list.m3u8")
        XCTAssertTrue(tracks.first { $0.language == "zh-Hans" }!.accessibility)
        XCTAssertTrue(tracks.last!.forced)
    }

    func testSegmentPlaylistRejectsUnsupportedOrIncompleteFormats() throws {
        let base = URL(string: "https://vod-ap-amt.tv.apple.com/s/list.m3u8")!
        let playlist = "#EXTM3U\n#EXTINF:10,\na.vtt\n#EXTINF:5,\nb.vtt\n#EXT-X-ENDLIST"
        XCTAssertEqual(try SubtitlePlaylist.segments(playlist, baseURL: base).map(\.startMs), [0, 10_000])
        for bad in [playlist.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""),
                    "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128\n#EXTINF:5,\na.vtt\n#EXT-X-ENDLIST",
                    "#EXTM3U\n#EXT-X-BYTERANGE:20@0\n#EXTINF:5,\na.vtt\n#EXT-X-ENDLIST",
                    "#EXTM3U\n#EXTINF:nan,\na.vtt\n#EXT-X-ENDLIST",
                    playlist.replacingOccurrences(of: "a.vtt", with: "https://example.com/a.vtt")] {
            XCTAssertThrowsError(try SubtitlePlaylist.segments(bad, baseURL: base))
        }
    }

    func testTimestampMapsEmptySegmentsDedupAndMPEGWrap() throws {
        let base = URL(string: "https://vod-ap-amt.tv.apple.com/a.vtt")!
        let segments = [SubtitleSegment(url: base, startMs: 0), SubtitleSegment(url: base, startMs: 10_000)]
        let first = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n\n00:01.000 --> 00:02.000\nFirst\n\n00:14.000 --> 00:15.000\nShared"
        let second = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:1800000,LOCAL:00:00:00.000\n\n00:01.000 --> 00:02.000\nSecond\n\n00:04.000 --> 00:05.000\nShared"
        let result = try SubtitlePlaylist.merge([first, second], segments: segments)
        XCTAssertEqual(result.items.map(\.startMs), [1000, 11_000, 14_000])
        let empty = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n"
        XCTAssertEqual(try SubtitlePlaylist.merge([empty, second], segments: segments).items.first?.startMs, 11_000)
        let wrapFirst = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:8589034592\n\n00:01.000 --> 00:02.000\nA"
        let wrapSecond = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n00:01.000 --> 00:02.000\nB"
        XCTAssertEqual(try SubtitlePlaylist.merge([wrapFirst, wrapSecond], segments: segments).items.map(\.startMs), [1000, 11_000])
    }

    func testResourceAndAccountIdentifierRestrictions() {
        for bad in ["http://vod-ak-amt.tv.apple.com/x", "https://apple.com.evil.com/x", "https://user@tv.apple.com/x", "https://tv.apple.com:8443/x", "https://vod-ak-amt.tv.apple.com/x?dsid=123"] {
            XCTAssertThrowsError(try MovieSubtitleDownloader.validateResource(URL(string: bad)!))
        }
        XCTAssertNoThrow(try MovieSubtitleDownloader.validateResource(URL(string: "https://play.itunes.apple.com/WebObjects/MZPlay.woa/hls/playlist.m3u8?dsid=123")!))
    }

    func testAppleTVPlusHasAnActionableError() async throws {
        let session = mockSession { request in
            switch request.url!.path {
            case "/api/uts/v3/storefronts": return json(["data": ["US": ["storefrontId": 143441]]])
            case "/api/uts/v3/configurations": return json(["data": ["applicationProps": [
                "requiredParamsMap": ["Default": ["caller": "web"]],
                "storefront": ["defaultLocale": "en_US", "localesSupported": ["en_US"]]
            ]]])
            default: return json(["data": ["playables": ["1": ["channelId": "tvs.sbd.4000"]]]])
            }
        }
        do {
            _ = try await MovieSubtitleDownloader(session: session).versions(for: MoviePage("https://tv.apple.com/us/movie/umc.cmc.1vrwat5k1ucm5k42q97ioqyq3"))
            XCTFail("Apple TV+ must not silently produce an empty catalog")
        } catch {
            // The package test target has no string catalog, so the message may be the raw key.
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Apple TV+") || message.contains("appleTVPlusOnly"), message)
        }
    }

    func testCancellationStopsAnInFlightDownload() async throws {
        let requests = RecordedRequests()
        let started = expectation(description: "Request started")
        let session = mockSession { request in
            requests.append(request.url!)
            started.fulfill()
            return text("#EXTM3U\n#EXTINF:10,\n0.vtt\n#EXT-X-ENDLIST")
        }
        MockURLProtocol.delay = 1
        defer { MockURLProtocol.delay = 0 }
        let downloader = MovieSubtitleDownloader(session: session)
        let track = MovieSubtitleTrack(id: "en", language: "en", name: "English", forced: false, accessibility: false,
                                       mirrors: [URL(string: "https://vod-ak-amt.tv.apple.com/en.m3u8")!])
        let task = Task {
            try await downloader.download(track) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(requests.urls.count, 1)
    }

    func testMovieLookupRenditionsDownloadAndMirrorFallback() async throws {
        let requests = RecordedRequests()
        let session = mockSession { request in
            requests.append(request.url!)
            let url = request.url!
            switch url.path {
            case "/api/uts/v3/storefronts": return json(["data": ["US": ["storefrontId": 143441]]])
            case "/api/uts/v3/configurations": return json(["data": ["applicationProps": [
                "routes": ["movie": ["path": "/uts/v3/movies/{movieId}", "requiredParamsType": "Movie"]],
                "requiredParamsMap": ["Movie": ["caller": "web", "special": "required"]],
                "storefront": ["defaultLocale": "en_US", "localesSupported": ["en_US"]]
            ]]])
            case let path where path.hasPrefix("/api/uts/v3/movies/"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains { $0.name == "special" && $0.value == "required" })
                XCTAssertTrue(query.contains { $0.name == "sf" && $0.value == "143441" })
                return json(["data": ["playables": ["1": ["channelId": "tvs.sbd.9001", "canonicalMetadata": ["movieTitle": "Sample"],
                    "itunesMediaApiData": ["id": "123", "offers": [["durationInMilliseconds": 60_000,
                        "hlsUrl": "https://play.itunes.apple.com/WebObjects/MZPlay.woa/hls/playlist.m3u8?dsid=999"]]]]]]])
            case "/WebObjects/MZPlay.woa/hls/playlist.m3u8":
                XCTAssertFalse(url.query?.contains("dsid") == true)
                return text("#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,LANGUAGE=\"en\",NAME=\"English\",URI=\"https://vod-ap-amt.tv.apple.com/bad.m3u8\"\n#EXT-X-MEDIA:TYPE=SUBTITLES,LANGUAGE=\"en\",NAME=\"English\",URI=\"https://vod-ak-amt.tv.apple.com/en/list.m3u8\"")
            case "/bad.m3u8": return (Data(), 503)
            case "/en/list.m3u8": return text("#EXTM3U\n#EXTINF:10,\n0.vtt\n#EXTINF:10,\n1.vtt\n#EXT-X-ENDLIST")
            case "/en/0.vtt": return text("WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n\n00:01.000 --> 00:02.000\nHello")
            case "/en/1.vtt": return text("WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:1800000\n\n00:01.000 --> 00:02.000\n世界")
            default: XCTFail("Unexpected path \(url.path)"); return (Data(), 404)
            }
        }
        let downloader = MovieSubtitleDownloader(session: session)
        let versions = try await downloader.versions(for: MoviePage("https://tv.apple.com/us/movie/umc.cmc.1vrwat5k1ucm5k42q97ioqyq3"))
        XCTAssertEqual(versions.first?.title, "Sample")
        let tracks = try await downloader.tracks(for: versions[0], dsid: "123")
        let result = try await downloader.download(tracks[0]) { _, _ in }
        XCTAssertEqual(result.items.map(\.startMs), [1000, 11_000])
        XCTAssertTrue(requests.urls.contains { $0.path == "/bad.m3u8" })
        XCTAssertFalse(requests.urls.contains { $0.query?.contains("dsid") == true })
    }

    func testDSIDOnlyRetriedAfterEligibleFailure() async throws {
        let requests = RecordedRequests()
        let session = mockSession { request in
            requests.append(request.url!)
            if request.url!.query?.contains("dsid=123") == true {
                return text("#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,LANGUAGE=\"en\",NAME=\"English\",URI=\"https://vod-ak-amt.tv.apple.com/en.m3u8\"")
            }
            return (Data(), 403)
        }
        let downloader = MovieSubtitleDownloader(session: session)
        let movie = MovieVersion(id: "1", title: "Sample", durationMs: nil,
                                 manifests: [URL(string: "https://play.itunes.apple.com/WebObjects/MZPlay.woa/hls/playlist.m3u8")!])
        let available = try await downloader.tracks(for: movie, dsid: "123")
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(requests.urls.count, 2)
        XCTAssertNil(requests.urls[0].query)
        XCTAssertEqual(requests.urls[1].query, "dsid=123")
        requests.clear()
        let other = MovieVersion(id: "2", title: "Other", durationMs: nil, manifests: [URL(string: "https://vod-ak-amt.tv.apple.com/master.m3u8")!])
        do { _ = try await downloader.tracks(for: other, dsid: "123"); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(requests.urls.count, 1)
        XCTAssertNil(requests.urls[0].query)
    }

    func testLiveAppleMovieLinkWhenRequested() async throws {
        guard let link = ProcessInfo.processInfo.environment["BETTERDUALSUB_LIVE_MOVIE_URL"] else {
            throw XCTSkip("Set BETTERDUALSUB_LIVE_MOVIE_URL to verify public Apple subtitle downloads.")
        }
        let downloader = MovieSubtitleDownloader()
        let versions = try await downloader.versions(for: MoviePage(link))
        var selected: (MovieVersion, MovieSubtitleTrack, MovieSubtitleTrack)?
        for movie in versions {
            let tracks = try await downloader.tracks(for: movie)
            let full = tracks.filter { !$0.forced }
            print("Live rendition languages: \(movie.id), \(full.map(\.language).joined(separator: ", "))")
            if let english = full.first(where: { $0.language.hasPrefix("en") }),
               let chinese = full.first(where: { $0.language.hasPrefix("zh") || $0.language.hasPrefix("cmn") }) {
                selected = (movie, english, chinese)
                break
            }
        }
        let (movie, english, chinese) = try XCTUnwrap(selected, "The selected storefront has no version with both English and Chinese subtitles.")
        for track in [english, chinese] {
            let document = try await downloader.download(track) { _, _ in }
            XCTAssertFalse(document.items.isEmpty)
            XCTAssertEqual(try SubtitleDocument(text: document.srt).items, document.items)
            print("Live subtitle verification: \(movie.title), \(track.language), \(document.items.count) cues, final end \(document.items.last!.endMs)ms")
        }
    }
}

private func json(_ value: [String: Any]) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: value), 200) }
private func text(_ value: String) -> (Data, Int) { (Data(value.utf8), 200) }

private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; storage.append(url) }
    func clear() { lock.lock(); defer { lock.unlock() }; storage = [] }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (@Sendable (URLRequest) -> (Data, Int))!
    nonisolated(unsafe) static var delay: TimeInterval = 0
    private var scheduled: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.respond(request)
        let deliver = DispatchWorkItem { [self] in
            guard scheduled?.isCancelled != true else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        scheduled = deliver
        if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: deliver) }
        else { deliver.perform() }
    }
    override func stopLoading() { scheduled?.cancel() }
}

private func mockSession(_ respond: @escaping @Sendable (URLRequest) -> (Data, Int)) -> URLSession {
    MockURLProtocol.respond = respond
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}
