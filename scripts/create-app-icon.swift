import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: create-app-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for (filename, pixels) in outputs {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
              bytesPerRow: pixels * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fputs("Unable to create the app icon drawing context.\n", stderr)
        exit(1)
    }
    let unit = CGFloat(pixels)
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.055, green: 0.105, blue: 0.275, alpha: 1),
            CGColor(srgbRed: 0.12, green: 0.36, blue: 0.82, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(background, start: .zero, end: CGPoint(x: unit, y: unit), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    let driveRect = CGRect(x: unit * 0.18, y: unit * 0.25, width: unit * 0.64, height: unit * 0.49)
    context.setShadow(offset: CGSize(width: 0, height: -unit * 0.018), blur: unit * 0.045,
                      color: CGColor(srgbRed: 0.015, green: 0.025, blue: 0.08, alpha: 0.28))
    fillRoundedRect(driveRect, radius: unit * 0.105,
                    color: CGColor(srgbRed: 0.96, green: 0.98, blue: 1, alpha: 1))
    context.setShadow(offset: .zero, blur: 0, color: nil)

    fillRoundedRect(CGRect(x: unit * 0.27, y: unit * 0.57, width: unit * 0.46, height: unit * 0.052),
                    radius: unit * 0.026,
                    color: CGColor(srgbRed: 0.085, green: 0.19, blue: 0.43, alpha: 1))

    context.setFillColor(CGColor(srgbRed: 0.12, green: 0.48, blue: 0.92, alpha: 1))
    context.fillEllipse(in: CGRect(x: unit * 0.28, y: unit * 0.36, width: unit * 0.14, height: unit * 0.14))
    context.setFillColor(CGColor(srgbRed: 0.45, green: 0.86, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: unit * 0.325, y: unit * 0.405, width: unit * 0.05, height: unit * 0.05))

    for (index, color) in [
        CGColor(srgbRed: 0.10, green: 0.54, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.17, green: 0.70, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.27, green: 0.84, blue: 0.91, alpha: 1),
    ].enumerated() {
        context.setFillColor(color)
        let x = unit * (0.53 + CGFloat(index) * 0.075)
        context.fillEllipse(in: CGRect(x: x, y: unit * 0.37, width: unit * 0.038, height: unit * 0.038))
    }

    guard let cgImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputDirectory.appendingPathComponent(filename) as CFURL,
              UTType.png.identifier as CFString, 1, nil
          ) else {
        fputs("Unable to encode app icon PNG.\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("Unable to finalize app icon PNG.\n", stderr)
        exit(1)
    }
}
