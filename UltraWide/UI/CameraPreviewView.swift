import AVFoundation
import SwiftUI

/// Keeps the preview layer in UIKit so SwiftUI updates do not recreate the
/// camera session or interrupt an in-progress capture.
struct CameraPreviewView: UIViewRepresentable {
    var session: AVCaptureSession
    var rotationAngle: CGFloat

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        applyRotation(to: view)
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
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
}
