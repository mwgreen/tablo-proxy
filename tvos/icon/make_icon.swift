// Draws the tvOS app icon (layered), App Store icon and Top Shelf images into
// Sources/Assets.xcassets. Run from tvos/:  swift icon/make_icon.swift
// Tweak the colours / proportions below and re-run; the PNGs are regenerated.
//
// The picture: a TV with rabbit-ear antennas (Tablo is over-the-air), a
// broadcast glyph on a glowing blue screen, and a red record dot for the DVR.
// Layers split so the tvOS focus parallax reads as depth: background glow at
// the back, the TV in the middle, antennas + screen gloss + record dot in front.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bgTop = rgb(0x17223a), bgBottom = rgb(0x070a12)
let glow = rgb(0x3aa8ff, 0.28)
let bodyLight = rgb(0x3a4254), bodyDark = rgb(0x161a23), bodyEdge = rgb(0x596377)
let screenTop = rgb(0x2a86f0), screenBottom = rgb(0x0a2a6e), screenGlow = rgb(0x7fdcff, 0.85)
let antenna = rgb(0xd3dae5), antennaDark = rgb(0x8d97a8)
let recRed = rgb(0xff3b30)

// MARK: helpers

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func save(_ ctx: CGContext, _ path: String, opaque: Bool) {
    var image = ctx.makeImage()!
    if opaque {  // the back layer / top shelf must not carry alpha
        let flat = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        flat.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = flat.makeImage()!
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func background(_ ctx: CGContext, _ size: CGSize, glowAt center: CGPoint, glowRadius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
    let r = CGGradient(colorsSpace: space, colors: [glow, rgb(0x3aa8ff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r, startCenter: center, startRadius: 0, endCenter: center, endRadius: glowRadius, options: [])
}

/// Geometry of the TV, all derived from its centre `c` and unit `u` (≈ its height).
struct TV {
    let c: CGPoint
    let u: CGFloat
    var body: CGRect { CGRect(x: c.x - u * 0.78, y: c.y - u * 0.46, width: u * 1.56, height: u * 0.92) }
    var screen: CGRect { body.insetBy(dx: u * 0.075, dy: u * 0.075).offsetBy(dx: 0, dy: u * 0.012) }
    var topCentre: CGPoint { CGPoint(x: c.x, y: body.maxY) }
    var corner: CGFloat { u * 0.14 }
}

/// The TV itself: stand, body with bevel, glowing screen and broadcast glyph.
func tvBody(_ ctx: CGContext, _ tv: TV) {
    let u = tv.u
    // stand: two short splayed feet
    ctx.saveGState()
    ctx.setStrokeColor(bodyDark)
    ctx.setLineWidth(u * 0.07)
    ctx.setLineCap(.round)
    for dx in [-0.42, 0.42] as [CGFloat] {
        ctx.move(to: CGPoint(x: tv.c.x + u * dx, y: tv.body.minY + u * 0.02))
        ctx.addLine(to: CGPoint(x: tv.c.x + u * dx * 1.22, y: tv.body.minY - u * 0.13))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // body with drop shadow
    let bodyPath = CGPath(roundedRect: tv.body, cornerWidth: tv.corner, cornerHeight: tv.corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.06), blur: u * 0.22, color: rgb(0x000000, 0.6))
    ctx.addPath(bodyPath)
    ctx.setFillColor(bodyDark)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [bodyLight, bodyDark] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tv.body.maxY), end: CGPoint(x: 0, y: tv.body.minY), options: [])
    ctx.restoreGState()
    // thin light edge along the top of the bezel
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(bodyEdge)
    ctx.setLineWidth(u * 0.012)
    ctx.strokePath()
    ctx.restoreGState()

    // screen
    let sc = u * 0.07
    let screenPath = CGPath(roundedRect: tv.screen, cornerWidth: sc, cornerHeight: sc, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let sg = CGGradient(colorsSpace: space, colors: [screenTop, screenBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sg, start: CGPoint(x: 0, y: tv.screen.maxY), end: CGPoint(x: 0, y: tv.screen.minY), options: [])
    let mid = CGPoint(x: tv.screen.midX, y: tv.screen.midY)
    let rg = CGGradient(colorsSpace: space, colors: [screenGlow, rgb(0x7fdcff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(rg, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: tv.screen.width * 0.55, options: [])

    // broadcast glyph: a dot with two arcs either side
    ctx.setFillColor(rgb(0xffffff, 0.95))
    let d = u * 0.075
    ctx.fillEllipse(in: CGRect(x: mid.x - d / 2, y: mid.y - d / 2, width: d, height: d))
    ctx.setStrokeColor(rgb(0xffffff, 0.92))
    ctx.setLineWidth(u * 0.034)
    ctx.setLineCap(.round)
    for (i, radius) in [u * 0.12, u * 0.20].enumerated() {
        let spread: CGFloat = i == 0 ? 0.62 : 0.55   // radians either side of horizontal
        for side in [0, CGFloat.pi] {
            ctx.addArc(center: mid, radius: radius, startAngle: side - spread, endAngle: side + spread, clockwise: false)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
}

/// Front layer: rabbit-ear antennas, glass glare on the screen, record dot.
func tvFront(_ ctx: CGContext, _ tv: TV) {
    let u = tv.u
    let base = tv.topCentre
    // antennas
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.02), blur: u * 0.05, color: rgb(0x000000, 0.5))
    ctx.setStrokeColor(antenna)
    ctx.setLineWidth(u * 0.03)
    ctx.setLineCap(.round)
    let tips = [CGPoint(x: base.x - u * 0.40, y: base.y + u * 0.40),
                CGPoint(x: base.x + u * 0.30, y: base.y + u * 0.44)]
    for tip in tips {
        ctx.move(to: CGPoint(x: base.x, y: base.y + u * 0.04))
        ctx.addLine(to: tip)
    }
    ctx.strokePath()
    ctx.setFillColor(antenna)
    for tip in tips {
        let b = u * 0.075
        ctx.fillEllipse(in: CGRect(x: tip.x - b / 2, y: tip.y - b / 2, width: b, height: b))
    }
    // antenna base dome
    ctx.setFillColor(antennaDark)
    let dome = CGRect(x: base.x - u * 0.13, y: base.y - u * 0.03, width: u * 0.26, height: u * 0.13)
    ctx.addPath(CGPath(roundedRect: dome, cornerWidth: u * 0.065, cornerHeight: u * 0.065, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // diagonal glass glare across the upper-left of the screen
    let sc = u * 0.07
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tv.screen, cornerWidth: sc, cornerHeight: sc, transform: nil))
    ctx.clip()
    let glare = CGMutablePath()
    let s = tv.screen
    glare.move(to: CGPoint(x: s.minX, y: s.maxY))
    glare.addLine(to: CGPoint(x: s.minX + s.width * 0.55, y: s.maxY))
    glare.addLine(to: CGPoint(x: s.minX + s.width * 0.20, y: s.minY + s.height * 0.35))
    glare.addLine(to: CGPoint(x: s.minX, y: s.minY + s.height * 0.35))
    glare.closeSubpath()
    ctx.addPath(glare)
    ctx.clip()
    let gg = CGGradient(colorsSpace: space, colors: [rgb(0xffffff, 0.22), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gg, start: CGPoint(x: s.minX, y: s.maxY), end: CGPoint(x: s.minX + s.width * 0.4, y: s.minY + s.height * 0.4), options: [])
    ctx.restoreGState()

    // record dot on the bezel, bottom-right
    // (sized to sit inside the bottom bezel, clear of the screen edge)
    let r = u * 0.058
    let dot = CGRect(x: tv.body.maxX - u * 0.19, y: tv.body.minY + u * 0.013, width: r, height: r)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: u * 0.05, color: rgb(0xff3b30, 0.8))
    ctx.setFillColor(recRed)
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()
}

// MARK: outputs

let root = "Sources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"

/// Home-screen / App Store icon: three layers of the same size.
func iconLayers(w: Int, h: Int, stack: String, suffix: String) {
    let size = CGSize(width: w, height: h)
    // Keep the TV inside the middle ~70%: focus zooms the icon and the
    // parallax shifts layers, so edges get cropped.
    let tv = TV(c: CGPoint(x: size.width / 2, y: size.height * 0.43), u: CGFloat(h) * 0.47)
    let back = makeContext(w, h)
    background(back, size, glowAt: tv.c, glowRadius: CGFloat(h) * 0.62)
    save(back, "\(root)/\(stack).imagestack/Back.imagestacklayer/Content.imageset/back\(suffix).png", opaque: true)
    let middle = makeContext(w, h)
    tvBody(middle, tv)
    save(middle, "\(root)/\(stack).imagestack/Middle.imagestacklayer/Content.imageset/middle\(suffix).png", opaque: false)
    let front = makeContext(w, h)
    tvFront(front, tv)
    save(front, "\(root)/\(stack).imagestack/Front.imagestacklayer/Content.imageset/front\(suffix).png", opaque: false)
}

/// Top Shelf banner: the TV on the left, name and tagline beside it.
func topShelf(w: Int, h: Int, set: String, file: String) {
    let size = CGSize(width: w, height: h)
    let ctx = makeContext(w, h)
    let tv = TV(c: CGPoint(x: size.width * 0.28, y: size.height * 0.44), u: CGFloat(h) * 0.40)
    background(ctx, size, glowAt: tv.c, glowRadius: CGFloat(h) * 0.8)
    tvBody(ctx, tv)
    tvFront(ctx, tv)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let title = NSAttributedString(string: "Tablo", attributes: [
        .font: NSFont.systemFont(ofSize: CGFloat(h) * 0.16, weight: .bold), .foregroundColor: NSColor.white])
    let sub = NSAttributedString(string: "Live TV, guide and recordings from your Tablo", attributes: [
        .font: NSFont.systemFont(ofSize: CGFloat(h) * 0.052, weight: .medium),
        .foregroundColor: NSColor(white: 0.72, alpha: 1)])
    let x = tv.body.maxX + CGFloat(h) * 0.12
    title.draw(at: CGPoint(x: x, y: size.height * 0.48))
    sub.draw(at: CGPoint(x: x + CGFloat(h) * 0.006, y: size.height * 0.37))
    NSGraphicsContext.restoreGraphicsState()
    save(ctx, "\(root)/\(set).imageset/\(file)", opaque: true)
}

iconLayers(w: 400, h: 240, stack: "App Icon", suffix: "")
iconLayers(w: 800, h: 480, stack: "App Icon", suffix: "@2x")
iconLayers(w: 1280, h: 768, stack: "App Icon - App Store", suffix: "")
topShelf(w: 1920, h: 720, set: "Top Shelf Image", file: "topshelf.png")
topShelf(w: 3840, h: 1440, set: "Top Shelf Image", file: "topshelf@2x.png")
topShelf(w: 2320, h: 720, set: "Top Shelf Image Wide", file: "topshelf-wide.png")
topShelf(w: 4640, h: 1440, set: "Top Shelf Image Wide", file: "topshelf-wide@2x.png")
print("wrote \(root)")
