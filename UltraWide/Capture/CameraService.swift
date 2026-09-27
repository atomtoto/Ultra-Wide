import AVFoundation
import Foundation

/// All session mutations and still captures run on one serial queue. The
/// session itself can be attached to an AVCaptureVideoPreviewLayer on main.
final class CameraService: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.ultrawide.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var retainedDelegates: [Int64: PhotoDelegate] = [:]
    private var activeDevice: AVCaptureDevice?
    private var imagingLocked = false
    private var inFlightPhotos = 0
    private var pauseRequested = false

    static func device(for lens: CaptureLens) -> AVCaptureDevice? {
        let type: AVCaptureDevice.DeviceType = lens == .wide
            ? .builtInWideAngleCamera : .builtInTelephotoCamera
        return AVCaptureDevice.default(type, for: .video, position: .back)
    }

    static var availableLenses: [CaptureLens] {
        CaptureLens.allCases.filter { device(for: $0) != nil }
    }

    static func horizontalFieldOfView(for lens: CaptureLens) -> Double? {
        guard let device = device(for: lens) else { return nil }
        return Double(device.activeFormat.videoFieldOfView)
    }

    func configure(lens: CaptureLens, orientation: CaptureOrientation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureOnQueue(lens: lens, orientation: orientation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue(lens: CaptureLens, orientation: CaptureOrientation) throws {
        guard let device = Self.device(for: lens) else {
            throw CaptureError.lensUnavailable
        }
        guard inFlightPhotos == 0 else { throw CaptureError.notReady }
        pauseRequested = false
        imagingLocked = false
        activeDevice = nil
        if session.isRunning { session.stopRunning() }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .photo
        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CaptureError.cameraConfigurationFailed
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = largest
        }
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(orientation.rotationAngle) {
            connection.videoRotationAngle = orientation.rotationAngle
        }
        session.commitConfiguration()

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()

        session.startRunning()
        guard session.isRunning else { throw CaptureError.cameraUnavailable }
        activeDevice = device
    }

    func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !session.inputs.isEmpty else {
                    continuation.resume(throwing: CaptureError.cameraConfigurationFailed)
                    return
                }
                if !session.isRunning { session.startRunning() }
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                }
            }
        }
    }

    func pause() {
        queue.async { [self] in
            pauseRequested = true
            if inFlightPhotos == 0 && session.isRunning { session.stopRunning() }
        }
    }

    /// Called just before the first still of each pass. It waits briefly for
    /// automatic focus, exposure, and color to settle, then fixes their values
    /// for the sweep. The UI rechecks motion alignment after this await.
    func prepareForCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard session.isRunning, !pauseRequested, let device = activeDevice else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                    return
                }
                if !imagingLocked {
                    let deadline = Date().addingTimeInterval(1.2)
                    while (device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance)
                            && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.04)
                    }
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                        device.unlockForConfiguration()
                        imagingLocked = true
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }
                continuation.resume()
            }
        }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning, !pauseRequested else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                    return
                }
                let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                    ? .hevc : .jpeg
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.photoQualityPrioritization = .quality
                let dimensions = photoOutput.maxPhotoDimensions
                if dimensions.width > 0 && dimensions.height > 0 {
                    settings.maxPhotoDimensions = dimensions
                }
                let id = settings.uniqueID
                // Resume only after the delegate has been removed on our queue.
                // Otherwise a quick Finish -> Refine can try to reconfigure
                // while this photo still appears to be in flight.
                let delegate = PhotoDelegate { [self] result in
                    self.queue.async { [self] in
                        self.retainedDelegates.removeValue(forKey: id)
                        self.inFlightPhotos -= 1
                        if self.pauseRequested && self.inFlightPhotos == 0 && self.session.isRunning {
                            self.session.stopRunning()
                        }
                        continuation.resume(with: result)
                    }
                }
                retainedDelegates[id] = delegate
                inFlightPhotos += 1
                photoOutput.capturePhoto(with: settings, delegate: delegate)
                queue.asyncAfter(deadline: .now() + 15) { [weak delegate] in
                    delegate?.failIfStillPending()
                }
            }
        }
    }
}

extension CaptureOrientation {
    var rotationAngle: CGFloat {
        switch self {
        case .portrait: 90
        case .landscapeLeft: 180
        case .landscapeRight: 0
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var processingResult: Result<Data, Error>?
    private var didComplete = false
    private let onComplete: @Sendable (Result<Data, Error>) -> Void

    init(onComplete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.onComplete = onComplete
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<Data, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(CaptureError.photoDataUnavailable)
        }
        lock.lock()
        if !didComplete { processingResult = result }
        lock.unlock()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let result = error.map { Result<Data, Error>.failure($0) }
            ?? processingResult ?? .failure(CaptureError.photoDataUnavailable)
        processingResult = nil
        lock.unlock()
        onComplete(result)
    }

    func failIfStillPending() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        processingResult = nil
        lock.unlock()
        onComplete(.failure(CaptureError.cameraUnavailable))
    }
}
