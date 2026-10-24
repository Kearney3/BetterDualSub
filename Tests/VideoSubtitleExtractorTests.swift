import XCTest
import AVFoundation
@testable import BetterDualSubCore

final class VideoSubtitleExtractorTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }

    private func temporaryFile(_ ext: String, _ bytes: [UInt8]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).\(ext)")
        files.append(url)
        if let bytes { try Data(bytes).write(to: url) }
        return url
    }

    // MARK: Matroska

    private func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        let idBytes = withUnsafeBytes(of: id.bigEndian, Array.init).drop { $0 == 0 }
        let size = withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init).dropFirst()
        return Array(idBytes) + [0x01] + size + payload
    }

    private func element(_ id: UInt32, _ children: [[UInt8]]) -> [UInt8] { element(id, children.flatMap { $0 }) }
    private func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        element(id, Array(withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 }))
    }
    private func string(_ id: UInt32, _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }

    private func block(track: UInt8, at time: Int16, _ payload: [UInt8], simple: Bool) -> [UInt8] {
        element(simple ? 0xA3 : 0xA1, [0x80 | track] + withUnsafeBytes(of: time.bigEndian, Array.init) + [simple ? 0x80 : 0] + payload)
    }

    private func zlib(_ text: String) throws -> [UInt8] {
        let deflated = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
        return [0x78, 0x9C] + deflated + [0, 0, 0, 0]
    }

    private func trackEntry(_ number: UInt64, type: UInt64, codec: String, extra: [[UInt8]] = []) -> [UInt8] {
        element(0xAE, [uint(0xD7, number), uint(0x83, type), string(0x86, codec)] + extra)
    }

    /// Video (1), SRT (2, Chinese, forced), zlib-compressed ASS (3) and PGS (4); the second Cluster has an unknown size.
    private func matroska() throws -> [UInt8] {
        let header = element(0x1A45_DFA3, [string(0x4282, "matroska")])
        let info = element(0x1549_A966, [uint(0x2A_D7B1, 1_000_000)])
        let compression = element(0x6D80, [element(0x6240, [element(0x5034, [uint(0x4254, 0)])])])
        let tracks = element(0x1654_AE6B, [
            trackEntry(1, type: 1, codec: "V_MPEG4/ISO/AVC"),
            trackEntry(2, type: 0x11, codec: "S_TEXT/UTF8", extra: [string(0x22_B59C, "chi"), uint(0x55AA, 1)]),
            trackEntry(3, type: 0x11, codec: "S_TEXT/ASS", extra: [string(0x536E, "Signs & Songs"), compression]),
            trackEntry(4, type: 0x11, codec: "S_HDMV/PGS")
        ])
        let first = element(0x1F43_B675, [
            uint(0xE7, 1000),
            block(track: 1, at: 0, [UInt8](repeating: 7, count: 200_000), simple: true),
            element(0xA0, [block(track: 2, at: 500, Array("你好\r\n<i>Hello</i>".utf8), simple: false), uint(0x9B, 1500)]),
            element(0xA0, [block(track: 3, at: 600, try zlib("0,0,Default,,0,0,0,,{\\i1}Sign, with comma\\Nline"), simple: false),
                           uint(0x9B, 900)]),
            block(track: 4, at: 700, [1, 2, 3], simple: true)
        ])
        let second = [0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + uint(0xE7, 10_000)
            + block(track: 1, at: 0, [UInt8](repeating: 9, count: 1000), simple: true)
            + block(track: 2, at: 0, Array("Open ended".utf8), simple: true)
            + block(track: 2, at: 2000, Array("Last".utf8), simple: true)
        let cues = element(0x1C53_BB6B, [[0xAA]])
        return header + [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + info + tracks + first + second + cues
    }

    func testMatroskaListsTextTracksAndReadsThemInOnePass() async throws {
        let url = try temporaryFile("mkv", matroska())
        let tracks = try await VideoSubtitleExtractor.inspect(url)
        XCTAssertEqual(tracks.map(\.id), ["mkv:3", "mkv:2"])
        XCTAssertEqual(tracks[1].language, "zh")
        XCTAssertTrue(tracks[1].forced)
        XCTAssertEqual(tracks[0].name, "Signs & Songs")

        let documents = try await VideoSubtitleExtractor.documents(for: tracks)
        XCTAssertEqual(documents["mkv:2"]?.items, [
            SubtitleItem(startMs: 1500, endMs: 3000, text: "你好\n<i>Hello</i>"),
            SubtitleItem(startMs: 10_000, endMs: 12_000, text: "Open ended"),
            SubtitleItem(startMs: 12_000, endMs: 15_000, text: "Last")
        ])
        XCTAssertEqual(documents["mkv:3"]?.items, [SubtitleItem(startMs: 1600, endMs: 2500, text: "Sign, with comma\nline")])
    }

    func testMatroskaCutShortKeepsTheCuesBeforeTheCut() async throws {
        let full = try matroska()
        let url = try temporaryFile("mkv", Array(full.prefix(full.count - 40)))
        let tracks = try await VideoSubtitleExtractor.inspect(url)
        let documents = try await VideoSubtitleExtractor.documents(for: tracks)
        XCTAssertEqual(documents["mkv:2"]?.items.first?.text, "你好\n<i>Hello</i>")
        XCTAssertNotNil(documents["mkv:3"])
    }

    func testMatroskaWithOnlyImageSubtitlesOrNoMatroskaHeaderIsRejected() async throws {
        let header = element(0x1A45_DFA3, [string(0x4282, "webm")])
        let segment = element(0x1853_8067, [element(0x1654_AE6B, [trackEntry(1, type: 0x11, codec: "S_VOBSUB")])])
        let imageOnly = try temporaryFile("webm", header + segment)
        do { _ = try await VideoSubtitleExtractor.inspect(imageOnly); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "error.video.noTextTracks") }
        let notMatroska = try temporaryFile("mkv", Array("not a video".utf8))
        do { _ = try await VideoSubtitleExtractor.inspect(notMatroska); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "error.video.invalid") }
    }

    func testLanguageCodesBecomeTheShortestTag() {
        XCTAssertEqual(VideoSubtitleExtractor.language("eng"), "en")
        XCTAssertEqual(VideoSubtitleExtractor.language("ger"), "de")
        XCTAssertEqual(VideoSubtitleExtractor.language("zh-Hant"), "zh-Hant")
        XCTAssertEqual(VideoSubtitleExtractor.language(nil), "und")
    }

    // MARK: MPEG-4

    /// A tx3g sample description: display flags, justification, colors, text box, default style and font table.
    private func tx3gFormat() throws -> CMFormatDescription {
        var entry: [UInt8] = []
        func u32(_ value: UInt32) { entry += withUnsafeBytes(of: value.bigEndian, Array.init) }
        func u16(_ value: UInt16) { entry += withUnsafeBytes(of: value.bigEndian, Array.init) }
        u32(0); entry += Array("tx3g".utf8) + [0, 0, 0, 0, 0, 0]; u16(1)
        u32(0); entry += [1, 0xFF, 0, 0, 0, 0]
        u16(0); u16(0); u16(100); u16(640)
        u16(0); u16(0); u16(1); entry += [0, 18, 255, 255, 255, 255]
        u32(18); entry += Array("ftab".utf8); u16(1); u16(1); entry += [5] + Array("Serif".utf8)
        withUnsafeBytes(of: UInt32(entry.count).bigEndian) { entry.replaceSubrange(0..<4, with: $0) }
        var format: CMFormatDescription?
        let status = entry.withUnsafeBufferPointer {
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: $0.baseAddress!, size: $0.count, flavor: nil,
                mediaType: kCMMediaType_Subtitle, formatDescriptionOut: &format)
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }

    func testMPEG4TimedTextTrack() async throws {
        let url = try temporaryFile("mp4")
        let format = try tx3gFormat()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        input.languageCode = "chi"
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (start, duration, text) in [(1.0, 1.5, "你好, world"), (2.5, 1.0, ""), (3.5, 2.0, "Line one\nline two")] {
            let bytes = [UInt8(text.utf8.count >> 8), UInt8(text.utf8.count & 0xFF)] + Array(text.utf8)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            let buffer = try XCTUnwrap(block)
            bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer,
                                                                      offsetIntoDestination: 0, dataLength: bytes.count) }
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 600),
                                            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
                                            decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: buffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                 formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(input.append(try XCTUnwrap(sample)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let tracks = try await VideoSubtitleExtractor.inspect(url)
        XCTAssertEqual(tracks.map(\.language), ["zh"])
        let documents = try await VideoSubtitleExtractor.documents(for: tracks)
        XCTAssertEqual(documents[tracks[0].id]?.items, [
            SubtitleItem(startMs: 1000, endMs: 2500, text: "你好, world"),
            SubtitleItem(startMs: 3500, endMs: 5500, text: "Line one\nline two")
        ])
    }

    func testWebVTTSampleBoxes() {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            withUnsafeBytes(of: UInt32(payload.count + 8).bigEndian, Array.init) + Array(type.utf8) + payload
        }
        let sample = box("vttc", box("sttg", Array("align:start".utf8)) + box("payl", Array("<i>Hi</i>\n".utf8)))
            + box("vttc", box("payl", Array("there".utf8)))
        XCTAssertEqual(VideoSubtitleExtractor.text(Data(Array("x".utf8)), format: .plain), "x")
        XCTAssertEqual(VideoSubtitleExtractor.mpeg4SampleText(Data(sample), format: .webVTTSamples), "<i>Hi</i>\nthere")
    }
}
