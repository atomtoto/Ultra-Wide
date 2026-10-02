import AVFoundation
import SwiftUI

/// Keeps the preview layer in UIKit so SwiftUI updates do not recreate the
/// camera session or interrupt an in-progress capture.
struct CameraPreviewView: UIViewRepresentable {
    var session: AVCaptureSession
    var rotationAngle: CGFloat
    var allowsMetering = false
    var onMeteringPoint: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.allowsMetering = allowsMetering
        view.onMeteringPoint = onMeteringPoint
        applyRotation(to: view)
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.allowsMetering = allowsMetering
        view.onMeteringPoint = onMeteringPoint
        applyRotation(to: view)
    }

    private func applyRotation(to view: PreviewHostView) {
        guard let connection = view.previewLayer.connection,
              connection.isVideoRotationAngleSupported(rotationAngle) else { return }
        connection.videoRotationAngle = rotationAngle
    }
}

final class PreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
    var allowsMetering = false
    var onMeteringPoint: ((CGPoint) -> Void)?
    private let focusRing = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.strokeColor = UIColor(red: 1, green: 0.73, blue: 0.16, alpha: 1).cgColor
        focusRing.lineWidth = 1.5
        focusRing.opacity = 0
        layer.addSublayer(focusRing)
        isAccessibilityElement = true
        accessibilityLabel = Locale.current.captureLanguageIsFrench ? "Aperçu caméra" : "Camera preview"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Locale.current.captureLanguageIsFrench ? "Mise au point au centre" : "Focus at center",
            target: self, selector: #selector(focusAtCenter))]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func focus(_ recognizer: UITapGestureRecognizer) {
        guard allowsMetering else { return }
        meter(at: recognizer.location(in: self))
    }

    @objc private func focusAtCenter() -> Bool {
        guard allowsMetering else { return false }
        meter(at: CGPoint(x: bounds.midX, y: bounds.midY))
        return true
    }

    private func meter(at point: CGPoint) {
        // AVFoundation accounts for rotation, aspect-fill cropping and zoom.
        onMeteringPoint?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        focusRing.removeAllAnimations()
        focusRing.path = UIBezierPath(roundedRect: CGRect(x: point.x - 34, y: point.y - 34,
            width: 68, height: 68), cornerRadius: 8).cgPath
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 1.5
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        focusRing.add(fade, forKey: "focus")
    }
}
