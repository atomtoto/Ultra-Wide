import AVFoundation
import Foundation

protocol CameraCapturing: AnyObject {
    @MainActor var session: AVCaptureSession { get }
    @MainActor var supportedLenses: [CaptureLens] { get }
    @MainActor func fieldOfView(for lens: CaptureLens) -> Double?
    func ensurePermission() async throws
    func configure(lens: CaptureLens, orientation: CaptureOrientation, zoomFactor: Double) async throws
    func videoLandscapeAspectRatio() async throws -> Double
    func setMeteringPoint(_ point: CGPoint) async throws
    func setExposureBias(_ value: Float) async throws -> Float
    func prepareForSweep() async throws
    func selectVideoFrame(near motionTimestamp: TimeInterval) async throws -> SelectedVideoFrame
    func encodeSelectedFrame(_ selected: SelectedVideoFrame) async throws -> Data
    func captureSinglePhoto(to baseURL: URL, cropFactor: Double, maximumMegapixels: Int) async throws -> SinglePhotoResult
    @MainActor func pause()
}

@MainActor
protocol CaptureMotionProviding: AnyObject {
    var onReading: ((MotionReading) -> Void)? { get set }
    var isActive: Bool { get }
    var hasReference: Bool { get }
    func start(orientation: CaptureOrientation, resetReference: Bool) throws
    func recenter() throws -> MotionReading
    func reading(near timestamp: TimeInterval) -> MotionReading?
    func stop()
    func suspendSampling()
}
