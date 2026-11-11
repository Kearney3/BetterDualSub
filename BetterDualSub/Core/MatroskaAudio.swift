import Foundation
import AudioToolbox

/// Audio of a Matroska file, which the system cannot open itself, made readable by rewriting the compressed packets of
/// one track into a temporary CAF file that it can decode. Only AAC is supported: the audio of most web releases.
nonisolated enum MatroskaAudio {
    /// An AAC track: its packets are raw frames and its codec data is the MPEG-4 AudioSpecificConfig.
    struct Track: Sendable {
        let number: Int
        let audioSpecificConfig: Data
        let encodings: [MatroskaContentEncoding]
        let sampleRate: Double
        let channels: Int
    }

    /// Sampling rates an AudioSpecificConfig names by index.
    private static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func isSupported(codec: String) -> Bool { codec == "A_AAC" || codec.hasPrefix("A_AAC/") }

    /// The first AAC track of the file, or nil when it has none, its codec data is unusable, or it is not a Matroska file.
    static func firstSupportedTrack(in url: URL) -> Track? {
        guard let file = try? MatroskaFile(url: url) else { return nil }
        for track in file.audioTracks where isSupported(codec: track.codec) {
            guard let config = track.codecPrivate, let fields = parse(config), let encodings = track.frameEncodings else { continue }
            return Track(number: track.number, audioSpecificConfig: config, encodings: encodings,
                         sampleRate: fields.sampleRate ?? track.samplingFrequency, channels: fields.channels ?? track.channels)
        }
        return nil
    }

    /// The object type, sampling rate and channel count an AudioSpecificConfig states; nil when it is too short or
    /// uses a form this does not read (an explicit rate, or an escape object type).
    static func parse(_ config: Data) -> (objectType: Int, sampleRate: Double?, channels: Int?)? {
        let bytes = [UInt8](config)
        guard bytes.count >= 2 else { return nil }
        let objectType = Int(bytes[0] >> 3)
        guard objectType != 31 else { return nil }
        let rateIndex = Int(bytes[0] & 0x07) << 1 | Int(bytes[1] >> 7)
        let channelConfiguration = Int(bytes[1] >> 3) & 0x0F
        let channels: Int? = switch channelConfiguration {
        case 1...6: channelConfiguration
        case 7: 8
        default: nil
        }
        return (objectType, rateIndex < sampleRates.count ? sampleRates[rateIndex] : nil, channels)
    }

    /// The MPEG-4 elementary stream descriptor Core Audio wants as the magic cookie of AAC: the AudioSpecificConfig
    /// wrapped in decoder-specific, decoder-config, SL-config and ES descriptors.
    static func cookie(audioSpecificConfig config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, 0x80, 0x80, 0x80, UInt8(body.count)] + body }
        let specific = descriptor(0x05, [UInt8](config))
        // Object type 0x40 (MPEG-4 audio), stream type 0x15 (audio), then buffer size and the two bit rates, unknown.
        let decoderConfig = descriptor(0x04, [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific)
        let slConfig = descriptor(0x06, [0x02])
        return Data(descriptor(0x03, [0, 0, 0] + decoderConfig + slConfig))
    }

    /// Writes the track's packets to a CAF file at `destination`, reading the Matroska file once. Throws when the file
    /// holds no packets of the track or the system refuses the data.
    static func writeCAF(of track: Track, from url: URL, to destination: URL) throws {
        let objectType = parse(track.audioSpecificConfig)?.objectType ?? 2
        var format = AudioStreamBasicDescription(mSampleRate: track.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                 mFormatFlags: UInt32(objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                 mBytesPerFrame: 0, mChannelsPerFrame: UInt32(track.channels), mBitsPerChannel: 0, mReserved: 0)
        var file: AudioFileID?
        try? FileManager.default.removeItem(at: destination)
        guard AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format, .eraseFile, &file) == noErr, let file else {
            throw SubtitleError.message("error.transcribe.audioExtraction")
        }
        defer { AudioFileClose(file) }
        let cookie = cookie(audioSpecificConfig: track.audioSpecificConfig)
        guard cookie.withUnsafeBytes({ AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(cookie.count), $0.baseAddress!) }) == noErr else {
            throw SubtitleError.message("error.transcribe.audioExtraction")
        }
        var packets: Int64 = 0
        let source = MatroskaBlockSource(trackNumber: track.number, encodings: track.encodings, maximumLength: 1_000_000)
        try MatroskaFile(url: url).forEachBlock(of: [source]) { _, _, _, payload in
            guard !payload.isEmpty else { return }
            var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
            var count: UInt32 = 1
            let status = payload.withUnsafeBytes { AudioFileWritePackets(file, false, UInt32(payload.count), &description, packets, &count, $0.baseAddress!) }
            guard status == noErr else { throw SubtitleError.message("error.transcribe.audioExtraction") }
            packets += Int64(count)
        }
        guard packets > 0 else { throw SubtitleError.message("error.transcribe.audioExtraction") }
    }
}
