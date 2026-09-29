import AVFoundation
import CoreImage
import Foundation
import ImageIO
import QuartzCore

/// Keeps the physical wide or tele camera running and exposes selected frames
/// from its video stream. Encoding happens off the capture callback queue.
final class CameraService: @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.ultrawide.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.ultrawide.camera.video", qos: .userInitiated)
    private let encodingQueue = DispatchQueue(label: "com.ultrawide.camera.encoding", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let frameCache = VideoFrameCache()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var activeDevice: AVCaptureDevice?
    private var activePhotoDelegate: StillPhotoDelegate?
    private var photoDimensions = CMVideoDimensions(width: 0, height: 0)
    private var activeZoomFactor = 1.0
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

    func configure(lens: CaptureLens, orientation: CaptureOrientation,
                   zoomFactor: Double = 1) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configureOnQueue(lens: lens, orientation: orientation,
                                         zoomFactor: zoomFactor)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue(lens: CaptureLens, orientation: CaptureOrientation,
                                  zoomFactor: Double) throws {
        guard let device = Self.device(for: lens) else { throw CaptureError.lensUnavailable }
        pauseRequested = false
        activeDevice = nil
        activeZoomFactor = 1
        if session.isRunning { session.stopRunning() }
        // Drain callbacks from the previous configuration before accepting
        // dimensions or images from the new lens.
        videoQueue.sync {}
        frameCache.clear()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(frameCache, queue: videoQueue)
        guard session.canAddInput(input), session.canAddOutput(output),
              session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CaptureError.cameraConfigurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.addOutput(photoOutput)
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
            .sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        guard let chosen = dimensions.last(where: {
            Int64($0.width) * Int64($0.height) <= 16_000_000
        }) ?? dimensions.first else {
            session.commitConfiguration()
            throw CaptureError.cameraConfigurationFailed
        }
        photoOutput.maxPhotoDimensions = chosen
        photoOutput.maxPhotoQualityPrioritization = .speed
        photoDimensions = chosen
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(orientation.rotationAngle) {
                connection.videoRotationAngle = orientation.rotationAngle
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
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
        let boundedZoom = min(max(CGFloat(zoomFactor), device.minAvailableVideoZoomFactor),
                              device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = boundedZoom
        activeZoomFactor = Double(device.videoZoomFactor)
        device.unlockForConfiguration()

        session.startRunning()
        guard session.isRunning else { throw CaptureError.cameraUnavailable }
        activeDevice = device
    }

    /// Dimensions come from delivered samples, rather than an assumed 4:3
    /// photo format. A video output can instead be 16:9.
    func videoLandscapeAspectRatio() async throws -> Double {
        let deadline = CACurrentMediaTime() + 3
        while CACurrentMediaTime() < deadline {
            if let dimensions = frameCache.latestDimensions() {
                let width = Double(max(dimensions.width, dimensions.height))
                let height = Double(min(dimensions.width, dimensions.height))
                if height > 0 { return width / height }
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw CaptureError.cameraUnavailable
    }

    func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard !session.inputs.isEmpty else {
                    continuation.resume(throwing: CaptureError.cameraConfigurationFailed)
                    return
                }
                pauseRequested = false
                if !session.isRunning { session.startRunning() }
                session.isRunning ? continuation.resume()
                    : continuation.resume(throwing: CaptureError.cameraUnavailable)
            }
        }
    }

    func pause() {
        sessionQueue.async { [self] in
            pauseOnQueue()
        }
    }

    /// Wait for the physical camera to be released before another capture
    /// session tries to acquire it.
    func pauseAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                pauseOnQueue()
                continuation.resume()
            }
        }
    }

    private func pauseOnQueue() {
        pauseRequested = true
        if session.isRunning { session.stopRunning() }
        videoQueue.sync {}
        frameCache.clear()
    }

    /// Lock focus and white balance after the center frame is selected. This
    /// must not hold up the user's tap or a camera interruption.
    func prepareForSweep() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, !pauseRequested, let device = activeDevice else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                    return
                }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                    device.unlockForConfiguration()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Select the video buffer before enqueuing JPEG encoding. Its arrival
    /// must be close to the motion reading that will describe its geometry.
    func captureVideoFrame(near motionTimestamp: TimeInterval) async throws -> Data {
        guard let frame = frameCache.latest(near: motionTimestamp, maxAge: 0.20) else {
            throw CaptureError.photoDataUnavailable
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            encodingQueue.async { [self] in
                let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
                guard let cgImage = imageContext.createCGImage(image, from: image.extent),
                      let destinationData = CFDataCreateMutable(nil, 0),
                      let destination = CGImageDestinationCreateWithData(
                        destinationData, "public.jpeg" as CFString, 1, nil
                      ) else {
                    continuation.resume(throwing: CaptureError.photoDataUnavailable)
                    return
                }
                CGImageDestinationAddImage(destination, cgImage, [
                    kCGImageDestinationLossyCompressionQuality: 0.91
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    continuation.resume(throwing: CaptureError.photoDataUnavailable)
                    return
                }
                continuation.resume(returning: destinationData as Data)
            }
        }
    }

    /// Capture a processed 4:3 still through AVFoundation. A narrower target
    /// needs only a centered crop, avoiding the sweep and feature registration.
    func captureSinglePhoto(
        to baseURL: URL,
        cropFactor: Double
    ) async throws -> SinglePhotoResult {
        let capture = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, String, Double), Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, !pauseRequested, activePhotoDelegate == nil else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                    return
                }
                let useHEIF = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                let codec: AVVideoCodecType = useHEIF ? .hevc : .jpeg
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.maxPhotoDimensions = photoDimensions
                settings.photoQualityPrioritization = .speed
                settings.flashMode = .off
                let delegate = StillPhotoDelegate { [weak self] result in
                    guard let self else {
                        continuation.resume(throwing: CaptureError.cameraUnavailable)
                        return
                    }
                    self.sessionQueue.async {
                        self.activePhotoDelegate = nil
                        switch result {
                        case .success(let data):
                            continuation.resume(returning: (
                                data, useHEIF ? "heic" : "jpg", self.activeZoomFactor
                            ))
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
                activePhotoDelegate = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SinglePhotoResult, Error>) in
            encodingQueue.async {
                do {
                    let result = try Self.writeSinglePhoto(
                        capture.0, fileExtension: capture.1, to: baseURL,
                        cropFactor: cropFactor / capture.2
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func writeSinglePhoto(
        _ data: Data,
        fileExtension: String,
        to baseURL: URL,
        cropFactor: Double
    ) throws -> SinglePhotoResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw CaptureError.photoDataUnavailable
        }
        let exifOrientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let swapsAxes = (5...8).contains(exifOrientation)
        let uprightWidth = swapsAxes ? rawHeight : rawWidth
        let uprightHeight = swapsAxes ? rawWidth : rawHeight
        let url = baseURL.appendingPathExtension(fileExtension)
        if cropFactor <= 1.01 {
            do { try data.write(to: url, options: .atomic) }
            catch { throw CaptureError.diskWriteFailed }
            return SinglePhotoResult(url: url, pixelWidth: uprightWidth,
                                     pixelHeight: uprightHeight)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight)
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CaptureError.photoDataUnavailable }
        let width = upright.width
        let height = upright.height
        let cropWidth = max(1, Int((Double(width) / cropFactor).rounded(.down)))
        let cropHeight = max(1, Int((Double(height) / cropFactor).rounded(.down)))
        let cropRect = CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
                              width: cropWidth, height: cropHeight)
        guard let crop = upright.cropping(to: cropRect),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, fileExtension == "heic" ? "public.heic" as CFString
                    : "public.jpeg" as CFString, 1, nil
              ) else { throw CaptureError.photoDataUnavailable }
        CGImageDestinationAddImage(destination, crop, [
            kCGImageDestinationLossyCompressionQuality: 0.93
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.diskWriteFailed
        }
        return SinglePhotoResult(url: url, pixelWidth: cropWidth, pixelHeight: cropHeight)
    }
}

struct SinglePhotoResult: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

private final class StillPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var photoData: Data?
    private var captureError: Error?

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        captureError = error
        photoData = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error = error ?? captureError { completion(.failure(error)) }
        else if let photoData { completion(.success(photoData)) }
        else { completion(.failure(CaptureError.photoDataUnavailable)) }
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

private struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

private final class VideoFrameCache: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var receivedAt: TimeInterval = 0

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = pixelBuffer
        receivedAt = CACurrentMediaTime()
        lock.unlock()
    }

    func latestDimensions() -> (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else { return nil }
        return (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    func latest(near timestamp: TimeInterval, maxAge: TimeInterval) -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        let age = CACurrentMediaTime() - receivedAt
        guard age >= 0, age <= maxAge,
              abs(receivedAt - timestamp) <= maxAge else { return nil }
        return buffer.map { VideoFrame(pixelBuffer: $0) }
    }

    func clear() {
        lock.lock()
        buffer = nil
        receivedAt = 0
        lock.unlock()
    }
}
