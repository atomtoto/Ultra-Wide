import UIKit

/// Deterministic illustrated landscape, only used by the explicitly labeled demo.
enum DemoScene {
    @MainActor static let image: UIImage = {
        let size = CGSize(width: 2400, height: 1600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let c = renderer.cgContext
            let colors = [UIColor(red: 0.21, green: 0.38, blue: 0.44, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.78, blue: 0.67, alpha: 1).cgColor] as CFArray
            c.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!,
                                 start: .zero, end: CGPoint(x: 0, y: 1400), options: [])
            c.setFillColor(UIColor(red: 0.96, green: 0.85, blue: 0.61, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 1630, y: 260, width: 155, height: 155))
            var seed: UInt64 = 42
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1
                return CGFloat((seed >> 33) % 10000) / 10000
            }
            for layer in 0..<5 {
                let base = CGFloat(650 + layer * 160)
                let path = CGMutablePath(); path.move(to: CGPoint(x: 0, y: 1600))
                for x in stride(from: 0, through: 2460, by: 60) {
                    let ridge = sin(CGFloat(x) / 240 + CGFloat(layer) * 1.8) * 140 + random() * 130
                    path.addLine(to: CGPoint(x: CGFloat(x), y: base + ridge))
                }
                path.addLine(to: CGPoint(x: 2400, y: 1600)); path.closeSubpath()
                c.setFillColor(UIColor(red: 0.23 - CGFloat(layer) * 0.035,
                                      green: 0.43 - CGFloat(layer) * 0.047,
                                      blue: 0.43 - CGFloat(layer) * 0.046, alpha: 1).cgColor)
                c.addPath(path); c.fillPath()
            }
            // Small irregular features provide real registration signal across the crops.
            for _ in 0..<1800 {
                let x = random() * 2400, y = 800 + random() * 800
                let r = 1 + random() * 4
                c.setFillColor(UIColor(white: 0.75, alpha: 0.05 + random() * 0.14).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: y, width: r * 3, height: r))
            }
            for index in 0..<110 {
                let x = CGFloat(index) * 24 + random() * 18
                let y = 1410 + sin(x / 250) * 80
                let h = 25 + random() * 110
                let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y - h))
                p.addLine(to: CGPoint(x: x - h * 0.25, y: y)); p.addLine(to: CGPoint(x: x + h * 0.25, y: y)); p.closeSubpath()
                c.setFillColor(UIColor(red: 0.045, green: 0.14, blue: 0.14, alpha: 1).cgColor)
                c.addPath(p); c.fillPath()
            }
        }
    }()

    @MainActor static func frames() throws -> [CapturedFrame] {
        guard let source = image.cgImage else { throw CaptureFailure.capture }
        return try (0..<5).map { index in
            guard let crop = source.cropping(to: CGRect(x: index * 280, y: 100, width: 1000, height: 1333)),
                  let data = UIImage(cgImage: crop).jpegData(compressionQuality: 0.97) else { throw CaptureFailure.capture }
            return CapturedFrame(data: data, angle: Double(index) * 10)
        }
    }
}
