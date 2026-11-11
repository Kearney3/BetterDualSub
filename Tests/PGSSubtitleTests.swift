import XCTest
import CoreGraphics
import CoreText
import os
@testable import BetterDualSubCore

/// Builds PGS display sets the way a Blu-ray authoring tool does, so the decoder is checked against an encoder written
/// from the format description rather than against itself.
enum PGSFixture {
    static func segment(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [type, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    /// Run-length encodes palette indices row by row.
    static func rle(_ indices: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<height {
            var column = 0
            while column < width {
                let color = indices[row * width + column]
                var run = 1
                while column + run < width, indices[row * width + column + run] == color, run < 16383 { run += 1 }
                if color == 0 {
                    out += run < 64 ? [0, UInt8(run)] : [0, 0x40 | UInt8(run >> 8), UInt8(run & 0xFF)]
                } else if run == 1 {
                    out += [color]
                } else {
                    out += run < 64 ? [0, 0x80 | UInt8(run), color] : [0, 0xC0 | UInt8(run >> 8), UInt8(run & 0xFF), color]
                }
                column += run
            }
            out += [0, 0]
        }
        return out
    }

    /// 16 levels of white: index 0 is clear, index i has alpha i * 17.
    static func whitePalette(id: UInt8 = 0) -> [UInt8] {
        segment(0x14, [id, 0] + (0..<16).flatMap { [UInt8($0), 235, 128, 128, UInt8($0 * 17)] })
    }

    static func composition(state: UInt8, objects: [(id: Int, x: Int, y: Int, crop: (Int, Int, Int, Int)?)], videoHeight: Int = 1080) -> [UInt8] {
        var body: [UInt8] = be16(1920) + be16(videoHeight) + [0x10] + be16(1) + [state, 0, 0, UInt8(objects.count)]
        for object in objects {
            body += be16(object.id) + [0, object.crop == nil ? 0 : 0x40] + be16(object.x) + be16(object.y)
            if let crop = object.crop { body += be16(crop.0) + be16(crop.1) + be16(crop.2) + be16(crop.3) }
        }
        return segment(0x16, body)
    }

    /// The object's data in one segment, or in two when `split` is set.
    static func object(id: Int, indices: [UInt8], width: Int, height: Int, split: Bool = false) -> [UInt8] {
        let data = rle(indices, width: width, height: height)
        let header = [UInt8((data.count + 4) >> 16 & 0xFF), UInt8((data.count + 4) >> 8 & 0xFF), UInt8((data.count + 4) & 0xFF)] + be16(width) + be16(height)
        guard split, data.count > 2 else { return segment(0x15, be16(id) + [0, 0xC0] + header + data) }
        let half = data.count / 2
        return segment(0x15, be16(id) + [0, 0x80] + header + data[..<half]) + segment(0x15, be16(id) + [0, 0x40] + data[half...])
    }

    /// A display set showing one object.
    static func show(indices: [UInt8], width: Int, height: Int, x: Int = 100, y: Int = 900, videoHeight: Int = 1080,
                     split: Bool = false, crop: (Int, Int, Int, Int)? = nil) -> Data {
        Data(composition(state: 0x80, objects: [(0, x, y, crop)], videoHeight: videoHeight)
            + segment(0x17, [1, 0] + be16(x) + be16(y) + be16(width) + be16(height))
            + whitePalette() + object(id: 0, indices: indices, width: width, height: height, split: split) + segment(0x80, []))
    }

    /// A display set with nothing in it, which clears the screen.
    static func clear() -> Data { Data(composition(state: 0x00, objects: []) + segment(0x80, [])) }

    /// White text on a transparent picture, quantized to the 16 levels of `whitePalette`.
    static func text(_ string: String, fontSize: CGFloat = 56) -> (indices: [UInt8], width: Int, height: Int) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, nil)
        let width = Int(ceil(bounds.width)) + 12, height = Int(ceil(bounds.height)) + 12
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            context.textPosition = CGPoint(x: 6 - bounds.minX, y: 6 - bounds.minY)
            CTLineDraw(line, context)
        }
        // A CGContext's rows run bottom to top in memory only when flipped by the caller; this one is top row first.
        return (pixels.map { UInt8($0 / 17) }, width, height)
    }
}

final class PGSSubtitleTests: XCTestCase {
    /// A small picture with runs of every length class: a bar, single pixels and a long clear stretch.
    private func pattern(width: Int = 300, height: Int = 12) -> [UInt8] {
        (0..<width * height).map { index in
            let column = index % width, row = index / width
            if row == 0 { return 0 }
            if column < 80 { return 15 }
            if column < 120 { return UInt8(column % 14 + 1) }
            if column == 250 { return 8 }
            return 0
        }
    }

    private func decoded(_ blocks: [(Int, Data)]) -> [PGSCue] {
        var decoder = PGSDecoder()
        for (time, payload) in blocks { decoder.feed(timeMs: time, payload: payload) }
        return decoder.result()
    }

    func testDecodesTheEncodedPictureAndItsTiming() throws {
        let indices = pattern()
        let cues = decoded([(1000, PGSFixture.show(indices: indices, width: 300, height: 12)), (3500, PGSFixture.clear())])
        XCTAssertEqual(cues.count, 1)
        let cue = try XCTUnwrap(cues.first)
        XCTAssertEqual(cue.startMs, 1000)
        XCTAssertEqual(cue.endMs, 3500)
        XCTAssertEqual(cue.bitmap.width, 300)
        XCTAssertEqual(cue.bitmap.height, 12)
        XCTAssertEqual(cue.bitmap.videoHeight, 1080)
        for (index, level) in indices.enumerated() {
            XCTAssertEqual(cue.bitmap.rgba[index * 4 + 3], level * 17, "alpha of pixel \(index)")
            if level > 0 { XCTAssertEqual(Int(cue.bitmap.rgba[index * 4]), 255, accuracy: 2, "Y 235 is white") }
        }
    }

    func testAPictureLeftOnScreenHasNoEnd_AndANewOneEndsTheOldOne() {
        let first = PGSFixture.show(indices: pattern(), width: 300, height: 12)
        XCTAssertNil(decoded([(0, first)]).first?.endMs)
        let cues = decoded([(0, first), (2000, first), (4000, PGSFixture.clear())])
        XCTAssertEqual(cues.map(\.startMs), [0, 2000])
        XCTAssertEqual(cues.map(\.endMs), [2000, 4000])
    }

    func testAnObjectSplitOverTwoSegmentsIsJoined() {
        let indices = pattern()
        let whole = decoded([(0, PGSFixture.show(indices: indices, width: 300, height: 12))])
        let split = decoded([(0, PGSFixture.show(indices: indices, width: 300, height: 12, split: true))])
        XCTAssertEqual(split.first?.bitmap, whole.first?.bitmap)
        XCTAssertNotNil(whole.first)
    }

    func testCroppingShowsOnlyTheCroppedPart() throws {
        let indices = pattern()
        let cropped = try XCTUnwrap(decoded([(0, PGSFixture.show(indices: indices, width: 300, height: 12, crop: (80, 0, 100, 12)))]).first)
        XCTAssertEqual(cropped.bitmap.width, 100)
        XCTAssertEqual(cropped.bitmap.height, 12)
        // The crop starts at column 80, where the bar ends and the single levels begin.
        XCTAssertEqual(cropped.bitmap.rgba[(1 * 100 + 0) * 4 + 3], UInt8(indices[1 * 300 + 80]) * 17)
    }

    func testDamagedOrTruncatedDataGivesFewerCuesNeverACrash() {
        let good = PGSFixture.show(indices: pattern(), width: 300, height: 12)
        XCTAssertTrue(decoded([(0, Data(good.prefix(good.count / 2)))]).isEmpty)
        XCTAssertTrue(decoded([(0, Data([0x15, 0xFF, 0xFF, 1, 2, 3]))]).isEmpty)
        XCTAssertTrue(decoded([(0, Data())]).isEmpty)
        // An object claiming an absurd size is ignored, and the good set after it still decodes.
        let absurd = Data(PGSFixture.segment(0x15, PGSFixture.be16(0) + [0, 0xC0, 0, 0, 9] + PGSFixture.be16(60_000) + PGSFixture.be16(60_000) + [1, 2]))
        XCTAssertEqual(decoded([(0, absurd), (10, good)]).count, 1)
        // Run-length data that stops early leaves the rest clear.
        let truncatedRLE = PGSFixture.show(indices: [UInt8](repeating: 15, count: 200 * 10), width: 200, height: 10)
        XCTAssertEqual(decoded([(0, Data(truncatedRLE))]).count, 1)
    }

    func testStandardDefinitionVideoUsesTheOtherColourMatrix() throws {
        func red(videoHeight: Int) throws -> UInt8 {
            let data = Data(PGSFixture.composition(state: 0x80, objects: [(0, 0, 0, nil)], videoHeight: videoHeight)
                + PGSFixture.segment(0x14, [0, 0, 1, 81, 90, 240, 255])   // a strongly red colour: Y 81, Cr 240, Cb 90
                + PGSFixture.object(id: 0, indices: [1], width: 1, height: 1) + PGSFixture.segment(0x80, []))
            return try XCTUnwrap(decoded([(0, data)]).first).bitmap.rgba[0]
        }
        XCTAssertNotEqual(try red(videoHeight: 480), try red(videoHeight: 1080))
    }

    // MARK: Recognition

    private func recognized(_ text: String, language: String, fontSize: CGFloat = 56) async throws -> String {
        let picture = PGSFixture.text(text, fontSize: fontSize)
        let cues = decoded([(0, PGSFixture.show(indices: picture.indices, width: picture.width, height: picture.height)), (2000, PGSFixture.clear())])
        let items = try await SubtitleOCR.cues(from: cues, language: language)
        return items.first?.text ?? ""
    }

    func testRecognizesEnglishText() async throws {
        let text = try await recognized("Hello, world", language: "en")
        XCTAssertEqual(text.lowercased(), "hello, world")
    }

    func testRecognizesChineseAndJapaneseText() async throws {
        let chinese = try await recognized("你好，世界", language: "zh")
        XCTAssertEqual(chinese.filter { !"，, 。".contains($0) }, "你好世界")
        let japanese = try await recognized("おはようございます", language: "ja")
        XCTAssertEqual(japanese, "おはようございます")
    }

    func testRecognizesAnotherColourOfTextAndSmallSizes() async throws {
        let text = try await recognized("Small text here", language: "en", fontSize: 30)
        XCTAssertEqual(text.lowercased(), "small text here")
    }

    func testIdenticalPicturesAreReadOnceAndConsecutiveRepeatsMerge() async throws {
        let picture = PGSFixture.text("Same line")
        let show = PGSFixture.show(indices: picture.indices, width: picture.width, height: picture.height)
        // A fade changes only the palette: the same picture is shown again straight away, then later once more.
        let cues = decoded([(0, show), (1000, show), (2000, PGSFixture.clear()), (8000, show), (9000, PGSFixture.clear())])
        XCTAssertEqual(cues.count, 3)
        let reported = OSAllocatedUnfairLock(initialState: [Int]())
        let items = try await SubtitleOCR.cues(from: cues, language: "en") { done, _ in reported.withLock { $0.append(done) } }
        XCTAssertEqual(items.map(\.text), ["Same line", "Same line"])
        XCTAssertEqual(items.map(\.startMs), [0, 8000])
        XCTAssertEqual(items.map(\.endMs), [2000, 9000])
        XCTAssertEqual(reported.withLock { $0.last }, 1, "one distinct picture")
    }

    func testPicturesWithoutTextAreDropped() async throws {
        let blank = [UInt8](repeating: 0, count: 60 * 20)
        let cues = decoded([(0, PGSFixture.show(indices: blank, width: 60, height: 20)), (1000, PGSFixture.clear())])
        let items = try await SubtitleOCR.cues(from: cues, language: "en")
        XCTAssertTrue(items.isEmpty)
    }

    func testLanguagesForRecognition() {
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "en"), ["en-US"])
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "zh").first, "zh-Hans")
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "zh-TW").first, "zh-Hant")
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "zh_Hant").first, "zh-Hant")
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "ja"), ["ja-JP", "en-US"])
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "pt-BR").first, "pt-BR")
        XCTAssertEqual(SubtitleOCR.recognitionLanguages(for: "xx").first, "xx")
    }

    func testPiecesBecomeRowsTopToBottomAndLeftToRight() {
        let pieces = [("world", CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.1)), ("Second line", CGRect(x: 0.1, y: 0.05, width: 0.5, height: 0.1)),
                      ("Hello", CGRect(x: 0.1, y: 0.21, width: 0.2, height: 0.1))]
        XCTAssertEqual(SubtitleOCR.lines(from: pieces.map { (text: $0.0, box: $0.1) }), "Hello world\nSecond line")
    }
}
