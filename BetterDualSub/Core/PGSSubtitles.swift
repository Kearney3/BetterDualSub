import Foundation

/// A subtitle picture: the pixels of every object shown together, in straight (not premultiplied) RGBA.
nonisolated struct PGSBitmap: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    /// Height of the video the subtitle was made for, which tells how large the text is.
    let videoHeight: Int
}

/// A picture shown from `startMs` until `endMs` (nil when the track never clears it).
nonisolated struct PGSCue: Sendable {
    let startMs: Int
    var endMs: Int?
    let bitmap: PGSBitmap
}

/// Decodes a PGS (Blu-ray "HDMV presentation graphics") subtitle track as stored in Matroska: every block holds the
/// segments of one display set, each as a type byte, a 16-bit length and its payload, and the block's timestamp is
/// when the display set takes effect. An empty composition clears the screen and ends the cue before it. Damaged
/// or truncated data gives fewer cues, never a failure.
nonisolated struct PGSDecoder {
    private struct Entry { var y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8 }
    private struct Object {
        var width = 0, height = 0
        var data: [UInt8] = []
    }
    private struct Placement {
        var objectID: Int
        var x: Int, y: Int
        var crop: (x: Int, y: Int, width: Int, height: Int)?
    }
    private struct Composition {
        var videoHeight = 0
        var placements: [Placement] = []
        var paletteID = 0
    }

    private enum Segment {
        static let palette: UInt8 = 0x14, object: UInt8 = 0x15, composition: UInt8 = 0x16
        static let window: UInt8 = 0x17, end: UInt8 = 0x80
    }

    private var palettes: [Int: [UInt8: Entry]] = [:]
    private var objects: [Int: Object] = [:]
    private var composition = Composition()
    private var cues: [PGSCue] = []
    /// Pixels no larger than this many in either direction are taken as a damaged object.
    private static let maximumSide = 4096

    /// Feeds one block (the display set shown at `timeMs`).
    mutating func feed(timeMs: Int, payload: Data) {
        let bytes = [UInt8](payload)
        var offset = 0
        while offset + 3 <= bytes.count {
            let type = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            guard offset + length <= bytes.count else { return }
            let body = Array(bytes[offset..<offset + length])
            offset += length
            switch type {
            case Segment.composition: readComposition(body)
            case Segment.palette: readPalette(body)
            case Segment.object: readObject(body)
            case Segment.end: finishDisplaySet(at: timeMs)
            default: break   // window definitions say where to draw; the composition's own positions are enough
            }
        }
    }

    /// The cues so far; the picture still showing at the end has no end time.
    func result() -> [PGSCue] { cues }

    // MARK: Segments

    private mutating func readComposition(_ body: [UInt8]) {
        guard body.count >= 11 else { composition = Composition(); return }
        let state = body[7]
        // An epoch start discards everything defined before it.
        if state & 0x80 != 0 { palettes = [:]; objects = [:] }
        var next = Composition(videoHeight: Int(body[2]) << 8 | Int(body[3]), paletteID: Int(body[9]))
        let count = Int(body[10])
        var offset = 11
        for _ in 0..<count {
            guard offset + 8 <= body.count else { break }
            var placement = Placement(objectID: Int(body[offset]) << 8 | Int(body[offset + 1]),
                                      x: Int(body[offset + 4]) << 8 | Int(body[offset + 5]),
                                      y: Int(body[offset + 6]) << 8 | Int(body[offset + 7]))
            let cropped = body[offset + 3] & 0x40 != 0   // the flag that says the 8 bytes of a crop rectangle follow
            offset += 8
            if cropped, offset + 8 <= body.count {
                placement.crop = (Int(body[offset]) << 8 | Int(body[offset + 1]), Int(body[offset + 2]) << 8 | Int(body[offset + 3]),
                                  Int(body[offset + 4]) << 8 | Int(body[offset + 5]), Int(body[offset + 6]) << 8 | Int(body[offset + 7]))
                offset += 8
            }
            next.placements.append(placement)
        }
        composition = next
    }

    private mutating func readPalette(_ body: [UInt8]) {
        guard body.count >= 2 else { return }
        let id = Int(body[0])
        var palette = palettes[id] ?? [:]
        var offset = 2
        while offset + 5 <= body.count {
            palette[body[offset]] = Entry(y: body[offset + 1], cr: body[offset + 2], cb: body[offset + 3], alpha: body[offset + 4])
            offset += 5
        }
        palettes[id] = palette
    }

    private mutating func readObject(_ body: [UInt8]) {
        guard body.count >= 4 else { return }
        let id = Int(body[0]) << 8 | Int(body[1])
        let flags = body[3]
        var payload = body[4...]
        if flags & 0x80 != 0 {
            // First fragment: the length of all the data (3 bytes, not needed), then the picture size.
            guard payload.count >= 7 else { return }
            let base = payload.startIndex
            let width = Int(payload[base + 3]) << 8 | Int(payload[base + 4]), height = Int(payload[base + 5]) << 8 | Int(payload[base + 6])
            guard (1...Self.maximumSide).contains(width), (1...Self.maximumSide).contains(height) else { objects[id] = nil; return }
            objects[id] = Object(width: width, height: height, data: [])
            payload = payload.dropFirst(7)
        }
        guard var object = objects[id] else { return }
        object.data += payload
        objects[id] = object
    }

    // MARK: Display sets

    private mutating func finishDisplaySet(at timeMs: Int) {
        // Whatever was showing ends when anything new is shown or the screen is cleared.
        if !cues.isEmpty, cues[cues.count - 1].endMs == nil { cues[cues.count - 1].endMs = timeMs }
        guard let bitmap = render() else { return }
        cues.append(PGSCue(startMs: timeMs, endMs: nil, bitmap: bitmap))
    }

    /// The composition's objects drawn in their positions, cropped to the box that holds them.
    private func render() -> PGSBitmap? {
        struct Drawn { var placement: Placement; var object: Object; var rect: (x: Int, y: Int, width: Int, height: Int) }
        let palette = palettes[composition.paletteID] ?? palettes.values.first ?? [:]
        let drawn: [Drawn] = composition.placements.compactMap { placement in
            guard let object = objects[placement.objectID] else { return nil }
            var rect = (x: placement.x, y: placement.y, width: object.width, height: object.height)
            if let crop = placement.crop {
                rect.width = min(crop.width, object.width - crop.x)
                rect.height = min(crop.height, object.height - crop.y)
            }
            return rect.width > 0 && rect.height > 0 ? Drawn(placement: placement, object: object, rect: rect) : nil
        }
        guard !drawn.isEmpty, !palette.isEmpty else { return nil }
        let minX = drawn.map(\.rect.x).min()!, minY = drawn.map(\.rect.y).min()!
        let maxX = drawn.map { $0.rect.x + $0.rect.width }.max()!, maxY = drawn.map { $0.rect.y + $0.rect.height }.max()!
        let width = maxX - minX, height = maxY - minY
        guard width > 0, height > 0, width <= Self.maximumSide, height <= Self.maximumSide else { return nil }
        let hd = composition.videoHeight > 576
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for item in drawn {
            let indices = Self.decode(item.object)
            let crop = item.placement.crop ?? (0, 0, item.object.width, item.object.height)
            for row in 0..<item.rect.height {
                for column in 0..<item.rect.width {
                    let source = (crop.y + row) * item.object.width + crop.x + column
                    guard source >= 0, source < indices.count, let entry = palette[indices[source]], entry.alpha > 0 else { continue }
                    let (red, green, blue) = Self.rgb(entry, hd: hd)
                    let target = ((item.rect.y - minY + row) * width + item.rect.x - minX + column) * 4
                    rgba[target] = red
                    rgba[target + 1] = green
                    rgba[target + 2] = blue
                    rgba[target + 3] = entry.alpha
                }
            }
        }
        return PGSBitmap(width: width, height: height, rgba: rgba, videoHeight: composition.videoHeight)
    }

    /// The palette index of every pixel of an object, from its run-length encoded data.
    private static func decode(_ object: Object) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: object.width * object.height)
        let data = object.data
        var position = 0, x = 0, y = 0
        func put(_ color: UInt8, _ count: Int) {
            var remaining = count
            while remaining > 0, y < object.height {
                let run = min(remaining, object.width - x)
                if color != 0 { for index in 0..<run { pixels[y * object.width + x + index] = color } }
                x += run
                remaining -= run
                if x >= object.width { x = 0; y += 1 }
            }
        }
        while position < data.count, y < object.height {
            let byte = data[position]
            position += 1
            if byte != 0 { put(byte, 1); continue }
            guard position < data.count else { break }
            let flags = data[position]
            position += 1
            if flags == 0 {
                // End of line: pad what is left of the row with colour 0 (already so) and start the next.
                if x > 0 { x = 0; y += 1 }
                continue
            }
            var length = Int(flags & 0x3F)
            if flags & 0x40 != 0 {
                guard position < data.count else { break }
                length = length << 8 | Int(data[position])
                position += 1
            }
            var color: UInt8 = 0
            if flags & 0x80 != 0 {
                guard position < data.count else { break }
                color = data[position]
                position += 1
            }
            put(color, length)
        }
        return pixels
    }

    /// PGS stores Y, Cr, Cb: BT.709 for HD video, BT.601 below.
    private static func rgb(_ entry: Entry, hd: Bool) -> (UInt8, UInt8, UInt8) {
        let y = 1.164 * (Double(entry.y) - 16), cr = Double(entry.cr) - 128, cb = Double(entry.cb) - 128
        let red = hd ? y + 1.793 * cr : y + 1.596 * cr
        let green = hd ? y - 0.213 * cb - 0.533 * cr : y - 0.392 * cb - 0.813 * cr
        let blue = hd ? y + 2.112 * cb : y + 2.017 * cb
        func clamp(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        return (clamp(red), clamp(green), clamp(blue))
    }
}
