import XCTest
import AVFoundation
import os
@testable import BetterDualSubCore

final class TranscriptCueBuilderTests: XCTestCase {
    private func piece(_ text: String, _ start: Double, _ end: Double) -> TimedSpeech { TimedSpeech(text: text, start: start, end: end) }

    func testSentencesEndCues() {
        let cues = TranscriptCueBuilder.cues(from: [
            piece("Hello", 0.0, 0.4), piece(" world.", 0.4, 0.9), piece("How", 1.1, 1.3), piece(" are", 1.3, 1.5), piece(" you?", 1.5, 2.0)
        ])
        XCTAssertEqual(cues, [SubtitleItem(startMs: 0, endMs: 900, text: "Hello world."), SubtitleItem(startMs: 1100, endMs: 2000, text: "How are you?")])
    }

    func testPiecesWithoutTheirOwnSpacesAreJoinedWithOne_ButNotInChinese() {
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("Hello", 0, 0.4), piece("world.", 0.4, 0.9)]).map(\.text), ["Hello world."])
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("你好", 0, 0.4), piece("世界。", 0.4, 0.9)]).map(\.text), ["你好世界。"])
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("こんにちは", 0, 0.5), piece("世界。", 0.5, 1.0)]).map(\.text), ["こんにちは世界。"])
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("你好", 0, 0.4), piece("world.", 0.4, 0.9)]).map(\.text), ["你好world."])
    }

    func testAPauseOrALongStretchStartsANewCue() {
        let pause = TranscriptCueBuilder.cues(from: [piece("one", 0, 0.5), piece("two", 2.0, 2.5)])
        XCTAssertEqual(pause.map(\.text), ["one", "two"])
        // No punctuation for a long time: cut by length of time.
        let words = (0..<30).map { piece("word\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        let long = TranscriptCueBuilder.cues(from: words)
        XCTAssertGreaterThan(long.count, 1)
        for cue in long { XCTAssertLessThanOrEqual(cue.endMs - cue.startMs, Int((TranscriptCueBuilder.maximumSeconds + 1) * 1000)) }
        XCTAssertEqual(long.map(\.text).joined(separator: " "), words.map(\.text).joined(separator: " "))
    }

    func testLongTextBreaksAtACommaButShortTextDoesNot() {
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("Well,", 0, 0.3), piece("yes.", 0.3, 0.6)]).map(\.text), ["Well, yes."])
        let longClause = String(repeating: "word ", count: 9) + "end,"
        let cues = TranscriptCueBuilder.cues(from: [piece(longClause, 0, 3), piece("then more.", 3, 4)])
        XCTAssertEqual(cues.map(\.text), [longClause, "then more."])
    }

    func testShortCuesStayLongEnoughToReadWithoutOverlappingTheNextOne() {
        let cues = TranscriptCueBuilder.cues(from: [piece("Hi.", 0, 0.2), piece("There.", 0.5, 0.7)])
        XCTAssertEqual(cues.map(\.startMs), [0, 500])
        XCTAssertEqual(cues[0].endMs, 500, "cut at the next cue's start rather than the 800 ms minimum")
        XCTAssertEqual(cues[1].endMs, 1300)
        XCTAssertEqual(TranscriptCueBuilder.cues(from: [piece("  ", 0, 1)]), [])
        XCTAssertEqual(TranscriptCueBuilder.cues(from: []), [])
    }

    func testPreferredLanguageComesFromTheAudioThenTheUser() {
        let languages = [
            SpeechTranscription.Language(locale: Locale(identifier: "en_GB"), installed: false),
            SpeechTranscription.Language(locale: Locale(identifier: "en_US"), installed: true),
            SpeechTranscription.Language(locale: Locale(identifier: "zh_CN"), installed: true),
            SpeechTranscription.Language(locale: Locale(identifier: "ja_JP"), installed: false)
        ]
        XCTAssertEqual(SpeechTranscription.preferred(among: languages, audioTags: ["ja"], preferred: ["en-US"])?.id, "ja_JP")
        XCTAssertEqual(SpeechTranscription.preferred(among: languages, audioTags: ["en"], preferred: [])?.id, "en_US", "an installed one first")
        XCTAssertEqual(SpeechTranscription.preferred(among: languages, audioTags: ["en-GB"], preferred: [])?.id, "en_GB", "an exact region wins")
        XCTAssertEqual(SpeechTranscription.preferred(among: languages, audioTags: [], preferred: ["zh-Hans-CN", "en"])?.id, "zh_CN")
        XCTAssertNil(SpeechTranscription.preferred(among: languages, audioTags: ["xx"], preferred: ["yy"]))
    }
}

final class SpeechTranscriptionTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }

    /// Speech made by the system voice, as an AAC file; the test is skipped where `say` or the voice is missing.
    private func speech(_ text: String, voice: String? = nil) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-speech-\(UUID().uuidString)")
        let aiff = base.appendingPathExtension("aiff"), m4a = base.appendingPathExtension("m4a")
        files += [aiff, m4a]
        func run(_ tool: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) is not available here") }
        }
        try run("/usr/bin/say", (voice.map { ["-v", $0] } ?? []) + ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, m4a.path])
        return m4a
    }

    private func installed(_ identifier: String) async throws -> Locale {
        let languages = await SpeechTranscription.languages()
        guard let language = languages.first(where: { $0.id == identifier && $0.installed }) else {
            throw XCTSkip("The \(identifier) speech model is not installed on this Mac")
        }
        return language.locale
    }

    func testTranscribesEnglishSpeechIntoTimedCues() async throws {
        let locale = try await installed("en_US")
        let url = try speech("Hello world. This is a test of the speech recognizer.", voice: "Samantha")
        let phases = OSAllocatedUnfairLock(initialState: [SpeechTranscription.Phase]())
        let document = try await SpeechTranscription.document(from: url, locale: locale) { phase in phases.withLock { $0.append(phase) } }
        // Compared without punctuation: the recognizer adds its own.
        let text = document.items.map(\.text).joined(separator: " ").lowercased().filter { $0.isLetter || $0 == " " }
        XCTAssertTrue(text.contains("hello world"), text)
        XCTAssertTrue(text.contains("speech recognizer") || text.contains("speech recognise"), text)
        XCTAssertEqual(document.items.first?.startMs ?? 9999, 0, accuracy: 1500)
        XCTAssertTrue(document.items.allSatisfy { $0.endMs > $0.startMs })
        XCTAssertEqual(phases.withLock { $0.last }, .transcribing(1))
        XCTAssertGreaterThanOrEqual(document.items.count, 2, "two sentences make two cues: \(document.items)")
    }

    func testTranscribesChineseSpeech() async throws {
        let locale = try await installed("zh_CN")
        let url = try speech("你好，欢迎收看今天的节目。", voice: "Tingting")
        let document = try await SpeechTranscription.document(from: url, locale: locale)
        let text = document.items.map(\.text).joined().filter { !"，。, ".contains($0) }
        XCTAssertTrue(text.contains("你好") && text.contains("欢迎"), text)
    }

    func testSilenceIsReportedAndUnreadableOrUnsupportedInputIsRefused() async throws {
        let locale = try await installed("en_US")
        let silence = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-silence-\(UUID().uuidString).m4a")
        files.append(silence)
        // The writer is released at the end of this block, which finishes the file.
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let writer = try AVAudioFile(forWriting: silence, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000
            try writer.write(from: buffer)
        }
        do { _ = try await SpeechTranscription.document(from: silence, locale: locale); XCTFail("Expected no speech") }
        catch { XCTAssertEqual(error.localizedDescription, "error.transcribe.noSpeech") }

        let notAudio = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).mkv")
        files.append(notAudio)
        try Data("not media".utf8).write(to: notAudio)
        XCTAssertFalse(SpeechTranscription.canTranscribe(notAudio))
        do { _ = try await SpeechTranscription.document(from: notAudio, locale: locale); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "error.transcribe.unreadable") }
    }

    func testAudioLanguageTagsOfAFileWithoutOne() async throws {
        let url = try speech("Hello there.", voice: "Samantha")
        XCTAssertTrue(SpeechTranscription.canTranscribe(url))
        let tags = await SpeechTranscription.audioLanguageTags(of: url)
        XCTAssertTrue(tags.count <= 1)
    }

    /// An MP4 file with speech and no subtitle track, as a video without subtitles is for the importer's purposes.
    private func speechVideoFile() throws -> URL {
        let m4a = try speech("Hello there.", voice: "Samantha")
        let mp4 = m4a.deletingPathExtension().appendingPathExtension("mp4")
        files.append(mp4)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "mp4f", "-d", "aac", m4a.path, mp4.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("afconvert cannot make an MP4 here") }
        return mp4
    }

    func testAVideoWithoutSubtitleTracksIsStillImportableForTranscription() async throws {
        let url = try speechVideoFile()
        let inspection = try await VideoSubtitleExtractor.inspectForImport(url)
        XCTAssertTrue(inspection.tracks.isEmpty)
        XCTAssertTrue(inspection.canTranscribe)
    }

    func testImportInspectionKeepsErrorsForFilesWithNothingToOffer() async throws {
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).mkv")
        files.append(broken)
        try Data("not a video".utf8).write(to: broken)
        do { _ = try await VideoSubtitleExtractor.inspectForImport(broken); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "error.video.invalid") }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-missing-\(UUID().uuidString).mp4")
        do { _ = try await VideoSubtitleExtractor.inspectForImport(missing); XCTFail("Expected an error") }
        catch {}
    }

    // MARK: Matroska audio

    private func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        let idBytes = withUnsafeBytes(of: id.bigEndian, Array.init).drop { $0 == 0 }
        return Array(idBytes) + [0x01] + withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init).dropFirst() + payload
    }

    private func element(_ id: UInt32, _ children: [[UInt8]]) -> [UInt8] { element(id, children.flatMap { $0 }) }

    private func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] { element(id, Array(withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 })) }

    /// The AudioSpecificConfig inside an `esds`-style cookie: the body of its decoder-specific descriptor (tag 5).
    private func audioSpecificConfig(in cookie: Data) throws -> Data {
        let bytes = [UInt8](cookie)
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            while index < bytes.count, bytes[index] == 0x80 { index += 1 }
            guard index < bytes.count else { break }
            let length = Int(bytes[index])
            index += 1
            if tag == 0x05 { return Data(bytes[index..<min(bytes.count, index + length)]) }
            // The ES and decoder-config descriptors hold the next ones; skip only their own fixed fields.
            if tag == 0x03 { index += 3 } else if tag == 0x04 { index += 13 } else { index += length }
        }
        throw XCTSkip("No AudioSpecificConfig in the cookie")
    }

    /// A Matroska file holding the AAC packets of `m4a` as audio track 2 (video track 1 is only there to be skipped).
    private func matroska(aacFrom m4a: URL, codec: String = "A_AAC", codecPrivate: Data? = nil) async throws -> URL {
        let asset = AVURLAsset(url: m4a)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        var cookieSize = 0
        let cookieBytes = try XCTUnwrap(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize))
        let config = try codecPrivate ?? audioSpecificConfig(in: Data(bytes: cookieBytes, count: cookieSize))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var packets: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            var descriptions: UnsafePointer<AudioStreamPacketDescription>?
            var count = 0
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample, packetDescriptionsPointerOut: &descriptions, sizeOut: nil)
            count = CMSampleBufferGetNumSamples(sample)
            guard let pointer, let descriptions else { continue }
            for index in 0..<count {
                let packet = descriptions[index]
                packets.append(Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
                    .advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))))
            }
        }
        let sampleRate = format.mSampleRate
        func block(_ time: Int, _ payload: [UInt8]) -> [UInt8] {
            element(0xA3, [0x82] + withUnsafeBytes(of: Int16(time).bigEndian, Array.init) + [0x80] + payload) as [UInt8]
        }
        // A Cluster for every ten seconds of packets, as a muxer would write them.
        var clusters: [UInt8] = []
        var group: [[UInt8]] = []
        var groupStart = 0
        func flush() {
            guard !group.isEmpty else { return }
            clusters += element(0x1F43_B675, [uint(0xE7, UInt64(groupStart))] + group)
            group = []
        }
        for (index, packet) in packets.enumerated() {
            let time = Int((Double(index) * 1024 / sampleRate * 1000).rounded())
            if group.isEmpty { groupStart = time }
            if time - groupStart > 10_000 { flush(); groupStart = time }
            group.append(block(time - groupStart, packet))
            if index % 7 == 0 { group.append(element(0xA3, [0x81, 0, 0, 0x80] + [UInt8](repeating: 9, count: 300))) }   // video, skipped
        }
        flush()
        let audio = element(0xAE, [uint(0xD7, 2), uint(0x83, 2), element(0x86, Array(codec.utf8)), element(0x63A2, [UInt8](config)),
                                   element(0x22_B59C, Array("eng".utf8)),
                                   element(0xE1, element(0xB5, Array(withUnsafeBytes(of: sampleRate.bitPattern.bigEndian, Array.init)))
                                           + uint(0x9F, UInt64(format.mChannelsPerFrame)))])
        let video = element(0xAE, [uint(0xD7, 1), uint(0x83, 1), element(0x86, Array("V_MPEG4/ISO/AVC".utf8))])
        let bytes = element(0x1A45_DFA3, element(0x4282, Array("matroska".utf8)))
            + [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + element(0x1549_A966, uint(0x2A_D7B1, 1_000_000)) + element(0x1654_AE6B, video + audio) + clusters
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-aac-\(UUID().uuidString).mkv")
        files.append(url)
        try Data(bytes).write(to: url)
        return url
    }

    func testMatroskaAacAudioIsRewrittenIntoAFileTheSystemDecodes() async throws {
        let m4a = try speech("Hello world. This is a test of the speech recognizer.", voice: "Samantha")
        let source = try AVAudioFile(forReading: m4a)
        let mkv = try await matroska(aacFrom: m4a)
        let track = try XCTUnwrap(MatroskaAudio.firstSupportedTrack(in: mkv))
        XCTAssertEqual(track.number, 2)
        XCTAssertEqual(track.sampleRate, source.processingFormat.sampleRate)
        XCTAssertEqual(track.channels, Int(source.processingFormat.channelCount))
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-\(UUID().uuidString).caf")
        files.append(caf)
        try MatroskaAudio.writeCAF(of: track, from: mkv, to: caf)
        let decoded = try AVAudioFile(forReading: caf)
        XCTAssertEqual(decoded.processingFormat.sampleRate, source.processingFormat.sampleRate)
        // The same number of frames, give or take the encoder's priming at the ends.
        XCTAssertEqual(Double(decoded.length), Double(source.length), accuracy: 3000)
        XCTAssertTrue(SpeechTranscription.canTranscribe(mkv))
    }

    func testTranscribesTheAacAudioOfAMatroskaFile() async throws {
        let locale = try await installed("en_US")
        let mkv = try await matroska(aacFrom: try speech("Hello world. This is a test of the speech recognizer.", voice: "Samantha"))
        func temporaryAudioFiles() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
                .filter { $0.hasPrefix("BetterDualSub-audio-") })
        }
        let before = temporaryAudioFiles()
        let phases = OSAllocatedUnfairLock(initialState: [SpeechTranscription.Phase]())
        let document = try await SpeechTranscription.document(from: mkv, locale: locale) { phase in phases.withLock { $0.append(phase) } }
        let text = document.items.map(\.text).joined(separator: " ").lowercased().filter { $0.isLetter || $0 == " " }
        XCTAssertTrue(text.contains("hello world"), text)
        XCTAssertTrue(phases.withLock { $0.contains(.reading) })
        // The temporary audio file made for this run is gone (files of other runs are not this test's concern).
        XCTAssertEqual(temporaryAudioFiles().subtracting(before), [])
    }

    func testMatroskaAudioInAnUnsupportedCodecIsRefusedWithAReason() async throws {
        let m4a = try speech("Hello there.", voice: "Samantha")
        let ac3 = try await matroska(aacFrom: m4a, codec: "A_AC3", codecPrivate: Data())
        XCTAssertFalse(SpeechTranscription.canTranscribe(ac3))
        XCTAssertNil(MatroskaAudio.firstSupportedTrack(in: ac3))
        let locale = Locale(identifier: "en_US")
        do { _ = try await SpeechTranscription.document(from: ac3, locale: locale); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "error.transcribe.unsupportedAudio") }
    }

    func testAudioSpecificConfigAndCookie() throws {
        // AAC-LC, 44.1 kHz, stereo: 0x12 0x10.
        let parsed = try XCTUnwrap(MatroskaAudio.parse(Data([0x12, 0x10])))
        XCTAssertEqual(parsed.objectType, 2)
        XCTAssertEqual(parsed.sampleRate, 44_100)
        XCTAssertEqual(parsed.channels, 2)
        XCTAssertEqual(MatroskaAudio.parse(Data([0x11, 0x88]))?.sampleRate, 48_000)
        XCTAssertEqual(MatroskaAudio.parse(Data([0x11, 0x88]))?.channels, 1)
        XCTAssertNil(MatroskaAudio.parse(Data([0x12])))
        XCTAssertNil(MatroskaAudio.parse(Data([0xF8, 0x00])), "an escape object type is not read")
        XCTAssertTrue(MatroskaAudio.isSupported(codec: "A_AAC"))
        XCTAssertTrue(MatroskaAudio.isSupported(codec: "A_AAC/MPEG4/LC"))
        XCTAssertFalse(MatroskaAudio.isSupported(codec: "A_AC3"))
        XCTAssertFalse(MatroskaAudio.isSupported(codec: "A_OPUS"))
        let cookie = MatroskaAudio.cookie(audioSpecificConfig: Data([0x12, 0x10]))
        XCTAssertEqual(cookie.count, 39, "the size of the cookie the system makes for a two-byte config")
        XCTAssertEqual(try audioSpecificConfig(in: cookie), Data([0x12, 0x10]))
    }

    func testTheLanguageListHasInstalledLanguagesFirst() async {
        let languages = await SpeechTranscription.languages()
        XCTAssertFalse(languages.isEmpty)
        if let firstMissing = languages.firstIndex(where: { !$0.installed }) {
            XCTAssertTrue(languages[firstMissing...].allSatisfy { !$0.installed }, "installed languages come first")
        }
    }
}
