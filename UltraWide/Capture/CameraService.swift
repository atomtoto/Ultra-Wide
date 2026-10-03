import AVFoundation
import CoreImage
import Foundation
import ImageIO
import QuartzCore

/// Keeps the physical wide or tele camera running and exposes selected frames
/// from its video stream. Encoding happens off the capture callback queue.
final class CameraService: CameraCapturing, @unchecked Sendable {
    // Mutated on sessionQueue; the main actor only attaches its preview.
    nonisolated(unsafe) let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.ultrawide.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.ultrawide.camera.video", qos: .userInitiated)
    private let selectionQueue = DispatchQueue(label: "com.ultrawide.camera.selection", qos: .userInitiated)
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
    private var lighting: CaptureLighting = .automatic
    private var sweepSettingsLocked = false

    static func device(for lens: CaptureLens) -> AVCaptureDevice? {
        let type: AVCaptureDevice.DeviceType = lens == .wide
            ? .builtInWideAngleCamera : .builtInTelephotoCamera
        return AVCaptureDevice.default(type, for: .video, position: .back)
    }

    static var availableLenses: [CaptureLens] {
        CaptureLens.allCases.filter { device(for: $0) != nil }
    }

    var supportedLenses: [CaptureLens] { Self.availableLenses }
    func fieldOfView(for lens: CaptureLens) -> Double? { Self.horizontalFieldOfView(for: lens) }

    func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CaptureError.cameraPermissionDenied
            }
        default: throw CaptureError.cameraPermissionDenied
        }
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
        sweepSettingsLocked = false
        lighting = CaptureLighting.saved()
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
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        device.setExposureTargetBias(0, completionHandler: nil)
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            device.activeMaxExposureDuration = .invalid
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        // An 8-bit panorama must keep one SDR transfer curve. Automatic EDR
        // changes can otherwise alter highlights independently between views.
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
        let spaces = device.activeFormat.supportedColorSpaces
        if spaces.contains(.P3_D65) {
            device.activeColorSpace = .P3_D65
        } else if spaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        // Whole light cycles between preview frames reduce beat-frequency
        // pulsing while automatic metering is still active before the tap.
        let previewRate = lighting.mainsFrequency == 50 ? 25.0 : 30.0
        if device.activeFormat.isAutoVideoFrameRateSupported {
            device.isAutoVideoFrameRateEnabled = false
        }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= previewRate && $0.maxFrameRate >= previewRate
        }) {
            let period = CMTime(value: 1, timescale: Int32(previewRate))
            device.activeVideoMinFrameDuration = period
            device.activeVideoMaxFrameDuration = period
        }
        let boundedZoom = min(max(CGFloat(zoomFactor), device.minAvailableVideoZoomFactor),
                              device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = boundedZoom
        activeZoomFactor = Double(device.videoZoomFactor)
        device.unlockForConfiguration()

        session.startRunning()
        guard session.isRunning else { throw CaptureError.cameraUnavailable }
        frameCache.setClock(session.synchronizationClock)
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

    func setMeteringPoint(_ point: CGPoint) async throws {
        guard point.x.isFinite, point.y.isFinite else { throw CaptureError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, !pauseRequested, !sweepSettingsLocked, let device = activeDevice else {
                    continuation.resume(throwing: CaptureError.notReady)
                    return
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = clamped
                        if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                    }
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = clamped
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func setExposureBias(_ value: Float) async throws -> Float {
        guard value.isFinite else { throw CaptureError.notReady }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Float, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, !pauseRequested, !sweepSettingsLocked, let device = activeDevice else {
                    continuation.resume(throwing: CaptureError.notReady)
                    return
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    let bias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, value))
                    device.setExposureTargetBias(bias) { _ in continuation.resume(returning: bias) }
                } catch { continuation.resume(throwing: error) }
            }
        }
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

    /// Freeze the measured exposure before retaining the first source image.
    /// Await hardware application, never a stationary pose or JPEG encoding.
    func prepareForSweep() async throws {
        let revision = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, !pauseRequested, let device = activeDevice else {
                    continuation.resume(throwing: CaptureError.cameraUnavailable)
                    return
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    sweepSettingsLocked = true
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    let format = device.activeFormat
                    let setting = SweepExposurePolicy.setting(
                        meteredDuration: device.exposureDuration.seconds,
                        meteredISO: Double(device.iso),
                        minimumDuration: format.minExposureDuration.seconds,
                        maximumDuration: format.maxExposureDuration.seconds,
                        minimumISO: Double(format.minISO), maximumISO: Double(format.maxISO),
                        frameDuration: device.activeVideoMaxFrameDuration.seconds,
                        mainsFrequency: lighting.mainsFrequency
                    )
                    let revision = frameCache.beginExposureChange()
                    if device.isExposureModeSupported(.custom) {
                        let deviceClock = session.inputs.flatMap(\.ports).first { $0.mediaType == .video }?.clock
                        let cache = frameCache
                        let duration = setting.map {
                            CMTimeMaximum(format.minExposureDuration, CMTimeMinimum(format.maxExposureDuration,
                                CMTime(seconds: $0.duration, preferredTimescale: 1_000_000_000)))
                        } ?? AVCaptureDevice.currentExposureDuration
                        let iso = setting.map { min(format.maxISO, max(format.minISO, Float($0.iso))) }
                            ?? AVCaptureDevice.currentISO
                        device.setExposureModeCustom(duration: duration, iso: iso) { syncTime in
                            let now = CACurrentMediaTime()
                            let hostTime = deviceClock.map {
                                CMSyncConvertTime(syncTime, from: $0, to: CMClockGetHostTimeClock()).seconds
                            } ?? now
                            // With no usable device clock, require the next
                            // delivered frame instead of accepting an old one.
                            let applied = hostTime.isFinite && abs(hostTime - now) < 0.5 ? hostTime : now
                            cache.exposureDidApply(at: applied, revision: revision)
                        }
                    } else if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                        let frameDelay = device.activeVideoMaxFrameDuration.seconds
                        frameCache.exposureDidApply(at: CACurrentMediaTime()
                            + (frameDelay.isFinite && frameDelay > 0 ? frameDelay : 1.0 / 25), revision: revision)
                    } else {
                        throw CaptureError.cameraConfigurationFailed
                    }
                    continuation.resume(returning: revision)
                } catch {
                    restorePreviewMeteringOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
        do {
            let deadline = CACurrentMediaTime() + 0.6
            while CACurrentMediaTime() < deadline {
                try Task.checkCancellation()
                if frameCache.latest(near: CACurrentMediaTime(), maxAge: 0.20) != nil { return }
                try await Task.sleep(for: .milliseconds(8))
            }
            throw CaptureError.photoDataUnavailable
        } catch {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionQueue.async { [self] in
                    if frameCache.exposureRevisionIsCurrent(revision) { restorePreviewMeteringOnQueue() }
                    continuation.resume()
                }
            }
            throw error
        }
    }

    private func restorePreviewMeteringOnQueue() {
        guard !pauseRequested, let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            sweepSettingsLocked = false
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                device.activeMaxExposureDuration = .invalid
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            frameCache.cancelExposureChange()
        } catch { /* A later configure retries hardware setup. */ }
    }

    /// Select the video buffer before enqueuing JPEG encoding. Its arrival
    /// must be close to the motion reading that will describe its geometry.
    func captureVideoFrame(near motionTimestamp: TimeInterval) async throws -> Data {
        let sample = try await captureVideoSample(near: motionTimestamp, allowLowQuality: true)
        guard let data = sample.data else { throw CaptureError.photoDataUnavailable }
        return data
    }

    /// Select and assess a retained buffer independently of the JPEG writer.
    func selectVideoFrame(near motionTimestamp: TimeInterval) async throws -> SelectedVideoFrame {
        guard let frame = frameCache.latest(near: motionTimestamp, maxAge: 0.20) else {
            throw CaptureError.photoDataUnavailable
        }
        return await assess(frame)
    }

    private func assess(_ frame: VideoFrame) async -> SelectedVideoFrame {
        await withCheckedContinuation { continuation in
            selectionQueue.async {
                let quality = PhotoQualityAnalyzer.analyze(frame.pixelBuffer)
                continuation.resume(returning: SelectedVideoFrame(
                    pixelBuffer: frame.pixelBuffer, quality: quality, timestamp: frame.timestamp
                ))
            }
        }
    }

    /// Compatibility helper for callers that need the encoded image itself.
    func captureVideoSample(
        near motionTimestamp: TimeInterval,
        allowLowQuality: Bool = false
    ) async throws -> VideoCaptureSample {
        let selected = try await selectVideoFrame(near: motionTimestamp)
        return try await encodeIfUseful(selected, allowLowQuality: allowLowQuality)
    }

    func encodeVideoSample(
        _ pixelBuffer: CVPixelBuffer,
        allowLowQuality: Bool = false
    ) async throws -> VideoCaptureSample {
        let selected = await assess(VideoFrame(pixelBuffer: pixelBuffer, timestamp: 0))
        return try await encodeIfUseful(selected, allowLowQuality: allowLowQuality)
    }

    private func encodeIfUseful(
        _ selected: SelectedVideoFrame,
        allowLowQuality: Bool
    ) async throws -> VideoCaptureSample {
        guard allowLowQuality || SweepCapturePolicy.shouldEncode(selected.quality)
        else { return VideoCaptureSample(data: nil, quality: selected.quality) }
        let data = try await encodeSelectedFrame(selected)
        return VideoCaptureSample(data: data, quality: selected.quality)
    }

    func encodeSelectedFrame(_ selected: SelectedVideoFrame) async throws -> Data {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            encodingQueue.async { [self] in
                let image = CIImage(cvPixelBuffer: selected.pixelBuffer)
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
        cropFactor: Double,
        maximumMegapixels: Int = 16
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
                        cropFactor: cropFactor / capture.2, maximumMegapixels: maximumMegapixels
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
        cropFactor: Double,
        maximumMegapixels: Int = 16
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
        let maxPixels = Double(max(1, min(maximumMegapixels, 48))) * 1_000_000
        if cropFactor <= 1.01, Double(uprightWidth) * Double(uprightHeight) <= maxPixels {
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
        let effectiveCropFactor = cropFactor > 1.01 ? cropFactor : 1
        let cropWidth = max(1, Int((Double(width) / effectiveCropFactor).rounded(.down)))
        let cropHeight = max(1, Int((Double(height) / effectiveCropFactor).rounded(.down)))
        let cropRect = CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
                              width: cropWidth, height: cropHeight)
        guard let crop = upright.cropping(to: cropRect) else { throw CaptureError.photoDataUnavailable }
        let scale = min(1, sqrt(maxPixels / (Double(cropWidth) * Double(cropHeight))))
        let outputWidth = max(1, Int((Double(cropWidth) * scale).rounded(.down)))
        let outputHeight = max(1, Int((Double(cropHeight) * scale).rounded(.down)))
        let output: CGImage
        if outputWidth == cropWidth, outputHeight == cropHeight {
            output = crop
        } else {
            guard let context = CGContext(
                data: nil, width: outputWidth, height: outputHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: crop.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw CaptureError.photoDataUnavailable }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
            guard let resized = context.makeImage() else { throw CaptureError.photoDataUnavailable }
            output = resized
        }
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, fileExtension == "heic" ? "public.heic" as CFString
                    : "public.jpeg" as CFString, 1, nil
              ) else { throw CaptureError.photoDataUnavailable }
        CGImageDestinationAddImage(destination, output, [
            kCGImageDestinationLossyCompressionQuality: 0.93
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.diskWriteFailed
        }
        return SinglePhotoResult(url: url, pixelWidth: outputWidth, pixelHeight: outputHeight)
    }
}

struct VideoCaptureSample: Sendable {
    let data: Data?
    let quality: PhotoQualityResult
}

/// AVFoundation buffers are retained and read only by the selection and
/// encoding queues. At most three selected buffers wait for the writer.
struct SelectedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let quality: PhotoQualityResult
    let timestamp: TimeInterval
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
    let timestamp: TimeInterval
}

private final class VideoFrameCache: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var receivedAt: TimeInterval = 0
    private var presentationTimestamp: TimeInterval = 0
    private var clock: CMClock?
    private var exposureGate = ExposureFrameGate()

    func beginExposureChange() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return exposureGate.begin()
    }

    func exposureDidApply(at timestamp: TimeInterval, revision: Int) {
        lock.lock()
        exposureGate.applied(at: timestamp, revision: revision)
        lock.unlock()
    }

    func exposureRevisionIsCurrent(_ revision: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return exposureGate.isCurrent(revision)
    }

    func cancelExposureChange() {
        lock.lock()
        exposureGate.reset()
        lock.unlock()
    }

    func setClock(_ clock: CMClock?) {
        lock.lock()
        self.clock = clock
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let arrival = CACurrentMediaTime()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = clock.map {
            CMSyncConvertTime(presentationTime, from: $0, to: CMClockGetHostTimeClock()).seconds
        } ?? arrival
        // A delayed or incoherent PTS cannot be relabeled as a fresh exposure
        // merely because delivery happened after the configuration callback.
        guard hostTime.isFinite, abs(hostTime - arrival) < 0.5 else {
            buffer = nil
            lock.unlock()
            return
        }
        buffer = pixelBuffer
        receivedAt = arrival
        presentationTimestamp = hostTime
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
              exposureGate.accepts(presentationTimestamp),
              abs(presentationTimestamp - timestamp) <= maxAge else { return nil }
        return buffer.map { VideoFrame(pixelBuffer: $0, timestamp: presentationTimestamp) }
    }

    func clear() {
        lock.lock()
        buffer = nil
        receivedAt = 0
        presentationTimestamp = 0
        clock = nil
        exposureGate.reset()
        lock.unlock()
    }
}
