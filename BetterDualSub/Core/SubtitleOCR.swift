import Foundation
import CoreGraphics
import Vision

/// Reads the text of subtitle pictures with Vision's on-device text recognition.
nonisolated enum SubtitleOCR {
    /// Vision language codes to try for a subtitle language (`SubtitleLanguagePreference`-style, such as "zh" or "en-US").
    static func recognitionLanguages(for language: String) -> [String] {
        let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = code.split(separator: "-").first.map(String.init) ?? code
        switch base {
        case "zh", "cmn", "chi", "zho":
            // Traditional for Taiwan, Hong Kong and Macau and for an explicit script; Simplified otherwise.
            let traditional = code.contains("hant") || code.hasSuffix("-tw") || code.hasSuffix("-hk") || code.hasSuffix("-mo")
            return traditional ? ["zh-Hant", "zh-Hans", "en-US"] : ["zh-Hans", "zh-Hant", "en-US"]
        case "yue": return ["yue-Hant", "zh-Hant", "en-US"]
        case "ja", "jpn": return ["ja-JP", "en-US"]
        case "ko", "kor": return ["ko-KR", "en-US"]
        case "en", "eng", "und", "": return ["en-US"]
        case "fr", "fra", "fre": return ["fr-FR", "en-US"]
        case "de", "deu", "ger": return ["de-DE", "en-US"]
        case "es", "spa": return ["es-ES", "en-US"]
        case "it", "ita": return ["it-IT", "en-US"]
        case "pt", "por": return ["pt-BR", "en-US"]
        case "ru", "rus": return ["ru-RU", "en-US"]
        case "uk", "ukr": return ["uk-UA", "en-US"]
        case "th", "tha": return ["th-TH", "en-US"]
        case "vi", "vie": return ["vi-VT", "en-US"]
        default: return [code, "en-US"]
        }
    }

    /// The picture as an opaque image for recognition: light text on black, or dark text on white when the picture has
    /// no light colours, enlarged for the small pictures of DVD-sized video, with a margin the recognizer likes.
    static func image(for bitmap: PGSBitmap) -> CGImage? {
        let scale = bitmap.videoHeight > 0 && bitmap.videoHeight <= 576 ? 2 : 1
        let margin = 16 * scale
        let width = bitmap.width * scale + 2 * margin, height = bitmap.height * scale + 2 * margin
        // Any clearly visible light pixel means light text; otherwise draw on white.
        var brightest = 0.0
        for index in stride(from: 0, to: bitmap.rgba.count, by: 4) where bitmap.rgba[index + 3] > 128 {
            let luma = 0.299 * Double(bitmap.rgba[index]) + 0.587 * Double(bitmap.rgba[index + 1]) + 0.114 * Double(bitmap.rgba[index + 2])
            brightest = max(brightest, luma)
        }
        let background: CGFloat = brightest >= 150 ? 0 : 1
        var premultiplied = bitmap.rgba
        for index in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = Int(premultiplied[index + 3])
            for channel in 0..<3 { premultiplied[index + channel] = UInt8(Int(premultiplied[index + channel]) * alpha / 255) }
        }
        guard let source = premultiplied.withUnsafeMutableBytes({ buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: margin, y: margin, width: bitmap.width * scale, height: bitmap.height * scale))
        return context.makeImage()
    }

    /// The text of the picture, lines top to bottom, or an empty string when nothing was recognized.
    @concurrent static func text(in bitmap: PGSBitmap, languages: [String]) async throws -> String {
        guard let image = image(for: bitmap) else { return "" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        let observations = try await request.perform(on: image)
        return lines(from: observations.compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox.cgRect) }
        })
    }

    /// Recognized pieces joined into lines: pieces on the same row left to right, rows top to bottom.
    static func lines(from pieces: [(text: String, box: CGRect)]) -> String {
        var rows: [[(text: String, box: CGRect)]] = []
        // Vision's origin is the bottom left, so the highest boxes come first.
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.indices.last, let reference = rows[last].first,
               abs(reference.box.midY - piece.box.midY) < min(reference.box.height, piece.box.height) * 0.5 {
                rows[last].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Reads the pictures of `pictures` and returns the cues that have text. Identical pictures are read once, up to
    /// `concurrency` at a time, and a cue that repeats the text of the one just before it (a fade changes only the
    /// palette) is merged into it. `progress` gets the number of distinct pictures read so far and their total.
    static func cues(from pictures: [PGSCue], language: String, concurrency: Int = 4,
                     progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [SubtitleItem] {
        let languages = recognitionLanguages(for: language)
        var firstOf: [[UInt8]: Int] = [:]
        var distinct: [Int] = []
        for (index, picture) in pictures.enumerated() where firstOf[picture.bitmap.rgba] == nil {
            firstOf[picture.bitmap.rgba] = index
            distinct.append(index)
        }
        var texts: [Int: String] = [:]
        progress(0, distinct.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func launchNext() {
                guard next < distinct.count else { return }
                let picture = distinct[next]
                let bitmap = pictures[picture].bitmap
                next += 1
                group.addTask { (picture, try await Self.text(in: bitmap, languages: languages)) }
            }
            for _ in 0..<max(1, min(concurrency, distinct.count)) { launchNext() }
            while let (picture, text) = try await group.next() {
                try Task.checkCancellation()
                texts[picture] = text
                progress(texts.count, distinct.count)
                launchNext()
            }
        }
        var items: [SubtitleItem] = []
        for picture in pictures {
            guard let first = firstOf[picture.bitmap.rgba], let text = texts[first], !text.isEmpty else { continue }
            let end = max(picture.endMs ?? picture.startMs + 3000, picture.startMs + 1)
            if let last = items.last, last.text == text, picture.startMs - last.endMs <= 100 {
                items[items.count - 1] = SubtitleItem(startMs: last.startMs, endMs: max(last.endMs, end), text: text)
            } else {
                items.append(SubtitleItem(startMs: picture.startMs, endMs: end, text: text))
            }
        }
        return items
    }
}
