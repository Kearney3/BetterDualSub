// Draws the app icon and writes every size the asset catalog and the README use.
// Run from anywhere: swift script/generate_icon.swift [preview.png]
// With an argument, only the 1024-pixel master is written there, to look at a change before replacing the icon.
import AppKit

let canvas: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func bitmap(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// A play triangle pointing right, with its flat side on x = 0 and its tip on the x axis.
func playPath(width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPath {
    let top = CGPoint(x: 0, y: height / 2), bottom = CGPoint(x: 0, y: -height / 2), tip = CGPoint(x: width, y: 0)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addArc(tangent1End: top, tangent2End: tip, radius: radius)
    path.addArc(tangent1End: tip, tangent2End: bottom, radius: radius)
    path.addArc(tangent1End: bottom, tangent2End: top, radius: radius)
    path.closeSubpath()
    return path
}

/// Where the shape's weight sits. A triangle looks centred when this point is, not when its bounding box is.
func centroid(of path: CGPath) -> CGPoint {
    let box = path.boundingBox.integral, width = Int(box.width), height = Int(box.height)
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.translateBy(x: -box.minX, y: -box.minY)
    context.addPath(path)
    context.setFillColor(gray: 1, alpha: 1)
    context.fillPath()
    var sumX = 0.0, sumY = 0.0, total = 0.0
    for y in 0..<height {
        for x in 0..<width {
            let weight = Double(pixels[y * width + x])
            sumX += weight * (Double(x) + 0.5); sumY += weight * (Double(y) + 0.5); total += weight
        }
    }
    // Bitmap rows run top to bottom, the path's y axis bottom to top.
    return CGPoint(x: box.minX + sumX / total, y: box.maxY - sumY / total)
}

/// The 1024-pixel master. Core Graphics has y pointing up; the layout below is written with y pointing down.
func master() -> CGImage {
    let context = bitmap(Int(canvas))
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // The plate, on the macOS icon grid: 824 points square in a 1024 canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let playCenter = CGPoint(x: canvas / 2, y: 428)

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    context.drawLinearGradient(gradient([(0, color(0x3A376C)), (0.55, color(0x1A1A40)), (1, color(0x0B0D1F))]),
                               start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: plate.maxY), options: [])
    // A glow behind the play symbol, so the eye lands on it.
    context.drawRadialGradient(gradient([(0, color(0x4A45A0, 0.85)), (0.45, color(0x3A3684, 0.4)), (1, color(0x3A3684, 0))]),
                               startCenter: playCenter, startRadius: 0, endCenter: playCenter, endRadius: 430, options: [])
    context.restoreGState()

    // A hairline of light along the plate's edge.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    context.addPath(platePath)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.22)), (0.5, color(0xFFFFFF, 0.05)), (1, color(0xFFFFFF, 0.1))]),
                               start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: plate.maxY), options: [])
    context.restoreGState()

    func fill(_ path: CGPath, top: UInt32, bottom: UInt32, shadow: CGColor) {
        let box = path.boundingBox
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: shadow)
        context.addPath(path)
        context.setFillColor(color(bottom))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient([(0, color(top)), (1, color(bottom))]),
                                   start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        context.restoreGState()
    }

    // The play symbol, placed by its centroid.
    let play = playPath(width: 262, height: 292, radius: 24)
    let weight = centroid(of: play)
    var move = CGAffineTransform(translationX: playCenter.x - weight.x, y: playCenter.y - weight.y)
    fill(play.copy(using: &move)!, top: 0xFFFFFF, bottom: 0xE6E3FF, shadow: color(0x05061A, 0.45))

    // The two subtitle lines.
    func line(width: CGFloat, y: CGFloat, top: UInt32, bottom: UInt32) {
        let rect = CGRect(x: (canvas - width) / 2, y: y, width: width, height: 54)
        fill(CGPath(roundedRect: rect, cornerWidth: 27, cornerHeight: 27, transform: nil), top: top, bottom: bottom,
             shadow: color(0x05061A, 0.4))
    }
    line(width: 536, y: 652, top: 0xFFFFFF, bottom: 0xE4E1FB)
    line(width: 388, y: 742, top: 0xFFB05C, bottom: 0xFF8046)

    return context.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) throws {
    var output = image
    if size != image.width {
        let context = bitmap(size)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        output = context.makeImage()!
    }
    guard let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let image = master()
if CommandLine.arguments.count > 1 {
    try write(image, size: Int(canvas), to: URL(fileURLWithPath: CommandLine.arguments[1]))
} else {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let icons = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    let files = ["16-mac.png": 16, "32-mac.png": 32, "32-mac 1.png": 32, "64-mac.png": 64, "128-mac.png": 128, "256-mac.png": 256,
                 "256-mac 1.png": 256, "512-mac.png": 512, "512-mac 1.png": 512, "1024-mac.png": 1024]
    for (name, size) in files { try write(image, size: size, to: icons.appendingPathComponent(name)) }
    try write(image, size: 256, to: root.appendingPathComponent("docs/images/icon.png"))
    print("Wrote \(files.count + 1) icon files.")
}
