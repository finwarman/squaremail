import AppKit

struct IconShape: Decodable {
    let fill: String
    let rect: [CGFloat]?
    let points: [[CGFloat]]?
}

struct IconSource: Decodable {
    let size: Int
    let shapes: [IconShape]
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
enum Product: String { case mail, notes }
let product = CommandLine.arguments.dropFirst().first.flatMap(Product.init(rawValue:)) ?? .mail
let source = try JSONDecoder().decode(IconSource.self, from: Data(contentsOf: root.appendingPathComponent(product == .mail ? "assets/icon.json" : "assets/notes-icon.json")))
let output = root.appendingPathComponent(product == .mail ? ".build/AppIcon.iconset" : ".build/NotesIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ value: String) -> NSColor {
    let hex = UInt32(value.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255,
                   green: CGFloat(hex >> 8 & 255) / 255,
                   blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(_ size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    graphics.cgContext.setShouldAntialias(false)
    graphics.cgContext.translateBy(x: 0, y: CGFloat(size))
    graphics.cgContext.scaleBy(x: CGFloat(size) / CGFloat(source.size), y: -CGFloat(size) / CGFloat(source.size))
    for shape in source.shapes {
        color(shape.fill).setFill()
        if let rect = shape.rect {
            NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]).fill()
            continue
        }
        guard let points = shape.points, let first = points.first else { continue }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: first[0], y: first[1]))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point[0], y: point[1])) }
        path.close()
        path.fill()
    }
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(512).write(to: root.appendingPathComponent(product == .mail ? "assets/squaremail.png" : "assets/squarenotes.png"))
var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(source.size) \(source.size)\" shape-rendering=\"crispEdges\">\n"
for shape in source.shapes {
    if let r = shape.rect {
        svg += "<rect x=\"\(r[0])\" y=\"\(r[1])\" width=\"\(r[2])\" height=\"\(r[3])\" fill=\"\(shape.fill)\"/>\n"
    } else if let points = shape.points {
        svg += "<polygon points=\"\(points.map { "\($0[0]),\($0[1])" }.joined(separator: " "))\" fill=\"\(shape.fill)\"/>\n"
    }
}
svg += "</svg>\n"
try Data(svg.utf8).write(to: root.appendingPathComponent(product == .mail ? "assets/squaremail.svg" : "assets/squarenotes.svg"))
print(output.path)
