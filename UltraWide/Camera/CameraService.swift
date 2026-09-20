@preconcurrency import AVFoundation
import Foundation

/// All session mutations and photo continuations belong to `queue`.
final class CameraService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.ultrawide.camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var delegates: [Int64: PhotoDelegate] = [:]

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func configure(lensID: String? = nil) async throws -> [CameraLens] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let devices = AVCaptureDevice.DiscoverySession(
                        deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera],
                        mediaType: .video, position: .back
                    ).devices.sorted { $0.deviceType == .builtInWideAngleCamera && $1.deviceType != .builtInWideAngleCamera }
                    guard let selected = devices.first(where: { $0.uniqueID == lensID }) ?? devices.first else {
                        throw CaptureFailure.cameraUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: selected)
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    let oldInputs = self.session.inputs
                    oldInputs.forEach { self.session.removeInput($0) }
                    guard self.session.canAddInput(input) else {
                        oldInputs.forEach { if self.session.canAddInput($0) { self.session.addInput($0) } }
                        self.session.commitConfiguration()
                        throw CaptureFailure.cameraUnavailable
                    }
                    self.session.addInput(input)
                    if !self.session.outputs.contains(self.output) {
                        guard self.session.canAddOutput(self.output) else {
                            self.session.commitConfiguration()
                            throw CaptureFailure.cameraUnavailable
                        }
                        self.session.addOutput(self.output)
                    }
                    self.output.maxPhotoQualityPrioritization = .balanced
                    // Bound input size to 12 MP to keep an entire sweep within a phone's memory budget.
                    let dimensions = selected.activeFormat.supportedMaxPhotoDimensions
                    if let size = dimensions.filter({ Int64($0.width) * Int64($0.height) <= 12_500_000 })
                        .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) ?? dimensions.first {
                        self.output.maxPhotoDimensions = size
                    }
                    if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                    self.device = selected
                    self.session.commitConfiguration()
                    if !self.session.isRunning { self.session.startRunning() }
                    let lenses = devices.map { camera in
                        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
                        // Sensor FOV is landscape. The UI and encoded captures are locked to portrait.
                        let ratio = Double(min(dimensions.width, dimensions.height)) / Double(max(dimensions.width, dimensions.height))
                        let fov = 2 * atan(tan(Double(camera.activeFormat.videoFieldOfView) * .pi / 360) * ratio) * 180 / .pi
                        return CameraLens(id: camera.uniqueID,
                                          name: camera.deviceType == .builtInTelephotoCamera ? "Téléobjectif" : "Principal",
                                          isTelephoto: camera.deviceType == .builtInTelephotoCamera,
                                          horizontalFieldOfView: fov)
                    }
                    continuation.resume(returning: lenses)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func setLocked(_ locked: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = self.device else { throw CaptureFailure.cameraUnavailable }
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    let focus: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
                    let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                    let whiteBalance: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
                    if device.isFocusModeSupported(focus) { device.focusMode = focus }
                    if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
                    if device.isWhiteBalanceModeSupported(whiteBalance) { device.whiteBalanceMode = whiteBalance }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning, self.delegates.isEmpty else {
                    continuation.resume(throwing: CaptureFailure.capture); return
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .speed
                settings.maxPhotoDimensions = self.output.maxPhotoDimensions
                settings.flashMode = .off
                let id = settings.uniqueID
                let delegate = PhotoDelegate { result in
                    self.queue.async {
                        guard self.delegates.removeValue(forKey: id) != nil else { return }
                        continuation.resume(with: result)
                    }
                }
                self.delegates[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
                self.queue.asyncAfter(deadline: .now() + 12) {
                    guard self.delegates.removeValue(forKey: id) != nil else { return }
                    continuation.resume(throwing: CaptureFailure.capture)
                }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var result: Result<Data, Error> = .failure(CaptureFailure.capture)
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}
