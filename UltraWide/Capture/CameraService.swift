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
    private let frameCache = VideoFrameCache()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var activeDevice: AVCaptureDevice?
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
            sessionQueue.async { [self] in
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
        guard let device = Self.device(for: lens) else { throw CaptureError.lensUnavailable }
        pauseRequested = false
        activeDevice = nil
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
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.cameraConfigurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(orientation.rotationAngle) {
                connection.videoRotationAngle = orientation.rotationAngle
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
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
            pauseRequested = true
            if session.isRunning { session.stopRunning() }
            videoQueue.sync {}
            frameCache.clear()
        }
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
