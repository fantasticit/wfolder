import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func shape(_ draw: (CGMutablePath) -> Void) -> CGPath {
    let path = CGMutablePath()
    draw(path)
    path.closeSubpath()
    return path
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func fill(_ path: CGPath, with color: CGColor) {
    canvas.addPath(path)
    canvas.setFillColor(color)
    canvas.fillPath()
}

func gradient(_ path: CGPath, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    canvas.saveGState()
    canvas.addPath(path)
    canvas.clip()
    let ramp = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    canvas.drawLinearGradient(ramp, start: start, end: end,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    canvas.restoreGState()
}

func rim(_ outline: CGPath, width: CGFloat, top: CGColor, bottom: CGColor) {
    let band = outline.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let bounds = outline.boundingBoxOfPath
    gradient(band, [top, bottom], from: point(bounds.midX, bounds.minY), to: point(bounds.midX, bounds.maxY))
}

func shadow(_ path: CGPath, color: CGColor, blur: CGFloat, down: CGFloat) {
    canvas.saveGState()
    canvas.setShadow(offset: CGSize(width: 0, height: -down), blur: blur, color: color)
    fill(path, with: color)
    canvas.restoreGState()
}

func glow(in path: CGPath, at center: CGPoint, reach: CGFloat, tint: CGColor) {
    canvas.saveGState()
    canvas.addPath(path)
    canvas.clip()
    let ramp = CGGradient(colorsSpace: colorSpace, colors: [tint, tint.copy(alpha: 0)!] as CFArray,
                          locations: nil)!
    canvas.drawRadialGradient(ramp, startCenter: center, startRadius: 0,
                              endCenter: center, endRadius: reach, options: [])
    canvas.restoreGState()
}

// Use top-left coordinates for the artwork. The PNG retains transparent corners.
canvas.translateBy(x: 0, y: CGFloat(size))
canvas.scaleBy(x: 1, y: -1)

let tile = shape { path in
    let steps = 256
    let radius: CGFloat = 425
    let curvature: CGFloat = 0.43
    for step in 0..<steps {
        let angle = CGFloat(step) * 2 * .pi / CGFloat(steps)
        let x = cos(angle)
        let y = sin(angle)
        let position = point(
            512 + radius * (x < 0 ? -1 : 1) * pow(abs(x), curvature),
            507 + radius * (y < 0 ? -1 : 1) * pow(abs(y), curvature)
        )
        if step == 0 { path.move(to: position) }
        else { path.addLine(to: position) }
    }
}

shadow(tile, color: rgb(0x04091E, alpha: 0.48), blur: 28, down: 17)
gradient(tile, [rgb(0x277CD8), rgb(0x213C90), rgb(0x171C59), rgb(0x111637)],
         from: point(171, 95), to: point(885, 922))
glow(in: tile, at: point(310, 105), reach: 660, tint: rgb(0x4CB7F4, alpha: 0.50))
glow(in: tile, at: point(970, 761), reach: 500, tint: rgb(0x744DDB, alpha: 0.44))
rim(tile, width: 3, top: rgb(0xBCE4FF, alpha: 0.58), bottom: rgb(0x4B55B0, alpha: 0.42))

let folderBack = shape { path in
    path.move(to: point(214, 433))
    path.addQuadCurve(to: point(269, 373), control: point(214, 373))
    path.addLine(to: point(371, 373))
    path.addQuadCurve(to: point(420, 394), control: point(400, 373))
    path.addLine(to: point(448, 421))
    path.addQuadCurve(to: point(474, 431), control: point(459, 431))
    path.addLine(to: point(738, 431))
    path.addQuadCurve(to: point(797, 487), control: point(797, 431))
    path.addLine(to: point(786, 697))
    path.addQuadCurve(to: point(737, 747), control: point(782, 747))
    path.addLine(to: point(267, 747))
    path.addQuadCurve(to: point(214, 692), control: point(214, 747))
}

shadow(folderBack, color: rgb(0x060F3B, alpha: 0.54), blur: 54, down: 33)
gradient(folderBack, [rgb(0x9AE3FF), rgb(0x4388D6), rgb(0x2849AF)],
         from: point(292, 368), to: point(684, 736))
rim(folderBack, width: 4, top: rgb(0xEDFAFF, alpha: 0.77), bottom: rgb(0x719AFF, alpha: 0.25))

canvas.saveGState()
canvas.translateBy(x: 570, y: 451)
canvas.rotate(by: -.pi / 24)
canvas.translateBy(x: -570, y: -451)

let paper = shape { path in
    path.move(to: point(450, 281))
    path.addQuadCurve(to: point(465, 274), control: point(456, 274))
    path.addLine(to: point(633, 274))
    path.addQuadCurve(to: point(659, 286), control: point(647, 274))
    path.addLine(to: point(713, 342))
    path.addQuadCurve(to: point(725, 371), control: point(725, 354))
    path.addLine(to: point(725, 635))
    path.addQuadCurve(to: point(687, 673), control: point(725, 673))
    path.addLine(to: point(452, 673))
    path.addQuadCurve(to: point(414, 635), control: point(414, 673))
    path.addLine(to: point(414, 322))
    path.addQuadCurve(to: point(429, 292), control: point(414, 302))
}

shadow(paper, color: rgb(0x0B2965, alpha: 0.47), blur: 27, down: 12)
gradient(paper, [rgb(0xF5FFFF), rgb(0xBEEAFF), rgb(0x81A9F0)],
         from: point(447, 282), to: point(686, 638))
rim(paper, width: 3, top: rgb(0xFFFFFF, alpha: 0.94), bottom: rgb(0xDAEBFF, alpha: 0.40))

let fold = shape { path in
    path.move(to: point(641, 278))
    path.addLine(to: point(641, 336))
    path.addQuadCurve(to: point(664, 359), control: point(641, 359))
    path.addLine(to: point(720, 359))
    path.addQuadCurve(to: point(713, 342), control: point(718, 351))
    path.addLine(to: point(659, 286))
    path.addQuadCurve(to: point(641, 278), control: point(650, 278))
}
gradient(fold, [rgb(0xFCFFFF), rgb(0x8CBDED)],
         from: point(644, 286), to: point(677, 361))
fill(rounded(471, 364, 122, 22, 11), with: rgb(0x3372B3, alpha: 0.73))
fill(rounded(471, 413, 159, 19, 9.5), with: rgb(0x3372B3, alpha: 0.48))
canvas.restoreGState()

let folderFront = shape { path in
    path.move(to: point(261, 493))
    path.addLine(to: point(754, 493))
    path.addQuadCurve(to: point(809, 557), control: point(825, 493))
    path.addLine(to: point(773, 703))
    path.addQuadCurve(to: point(716, 754), control: point(761, 754))
    path.addLine(to: point(308, 754))
    path.addQuadCurve(to: point(252, 713), control: point(264, 754))
    path.addLine(to: point(208, 565))
    path.addQuadCurve(to: point(261, 493), control: point(186, 493))
}

shadow(folderFront, color: rgb(0x132957, alpha: 0.38), blur: 24, down: -3)
gradient(folderFront,
         [rgb(0xC5F4FF, alpha: 0.99), rgb(0x68C4FF, alpha: 0.91),
          rgb(0x528DED, alpha: 0.94), rgb(0x574BD0)],
         from: point(287, 493), to: point(697, 767))
glow(in: folderFront, at: point(335, 490), reach: 280, tint: rgb(0xD6FEFF, alpha: 0.58))
rim(folderFront, width: 4, top: rgb(0xF2FFFF, alpha: 0.94), bottom: rgb(0x9FADFF, alpha: 0.56))

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
