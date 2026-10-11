import AVFoundation
import Combine
import Foundation
import ImageIO
import Photos
import UIKit

/// Connects the free video sweep, on-device assembler, and SwiftUI camera.
@MainActor
final class UltraWideCoordinator {
    let ui = CaptureUIModel()

    private let capture = CaptureController()
    private let stitcher = StitchingEngine()
    private var cancellables = Set<AnyCancellable>()
    private var isAssembling = false
    private var synchronizeScheduled = false
    private var automaticAssemblyKey: String?
    private var orientationBannerActive = false
    private var lastOutputURL: URL?
    private var lastAssemblyPreview: CGImage?
    private var reanchorImageURL: URL?
    private var targetsCacheKey: TargetsCacheKey?
    private var pendingExposureBias: Double?
    private var pendingMeteringPoint: CGPoint?
    private var cameraAdjustmentTask: Task<Void, Never>?
    private var lastHapticFraction = 0.0
    private var lastHapticAt = Date.distantPast

    /// Finished images are only kept while they are reviewed. They live outside
    /// iCloud backups and are never restored after a relaunch.
    private static let resultsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UltraWideResults", isDirectory: true)

    /// Photos saved from the app are added to this album in Photos.
    private static let ultraWideAlbumTitle = "Ultra Wide"

    init() {
        Self.removeAbandonedFiles()
        ui.onAction = { [weak self] action in
            Task { @MainActor [weak self] in await self?.handle(action) }
        }
        capture.objectWillChange.sink { [weak self] in
            // Published changes arrive on the main actor, often several per
            // motion sample. Read them once, after they have all been applied.
            MainActor.assumeIsolated { self?.scheduleSynchronize() }
        }.store(in: &cancellables)
        synchronize()
        if CaptureDiagnostics.enabled {
            Task { @MainActor [weak self] in
                var previous = CACurrentMediaTime()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    CaptureDiagnostics.log("heartbeat",
                        String(format: "main_lag_ms=%.1f memory_mb=%.1f thermal=%ld frames=%ld queued=%ld coverage=%.4f verifying=%@ status=%@",
                            max(0, now - previous - 1) * 1000, CaptureDiagnostics.footprintMegabytes(),
                            ProcessInfo.processInfo.thermalState.rawValue, self.capture.currentSnapshot?.frames.count ?? 0,
                            self.capture.completedCount - (self.capture.currentSnapshot?.frames.count ?? 0),
                            self.capture.visualCoverage?.fraction ?? 0, String(self.capture.isVerifyingAlignment),
                            String(describing: self.capture.status)))
                    previous = now
                }
            }
        }
    }

    private func handle(_ action: CaptureUIAction) async {
        switch action {
        case .prepare:
            synchronize()
            if capture.availableLenses.isEmpty {
                ui.phase = .unavailable
                ui.issue = CaptureUIIssue(
                    kind: .cameraUnavailable,
                    detail: String(localized: "An iPhone with a rear camera is required."),
                    canRetry: false
                )
            } else if capture.currentSnapshot == nil,
                      (capture.status == .idle || capture.status.isFailure
                       || (capture.status == .ready && capture.plan?.orientation != currentOrientation())) {
                await preparePreview()
            }
        case .selectLens:
            updateAvailableTargets()
            if capture.currentSnapshot == nil { await preparePreview() }
        case .selectTarget:
            if capture.currentSnapshot == nil { await preparePreview() }
        case .selectLighting(let lighting):
            guard capture.currentSnapshot == nil, capture.status != .capturing,
                  !ui.isStarting, ui.phase == .setup else {
                ui.selectedLighting = .saved()
                return
            }
            UserDefaults.standard.set(lighting.rawValue, forKey: CaptureLighting.preferenceKey)
            await preparePreview()
        case .setMeteringPoint(let point):
            pendingMeteringPoint = point
            applyCameraAdjustments()
        case .setExposureBias:
            pendingExposureBias = ui.exposureBias
            applyCameraAdjustments()
        case .startSweep:
            await beginOrResumeSweep()
        case .resume:
            await resumeSavedSweep()
        case .stopSweep:
            do {
                _ = try await capture.stopSweep()
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: false)
                synchronize()
            }
        case .confirmReanchor:
            do {
                try capture.confirmReferenceAlignment()
                try await capture.beginSweep()
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: capture.status.isFailure)
                synchronize()
            }
        case .assemble:
            await assemble()
        case .useCapturedField:
            guard capture.status == .reviewing, let crop = capture.sweepAnalysis?.capturedField else {
                ui.phase = .passReview
                return
            }
            await assemble(crop: crop)
        case .continueAfterCrop:
            ui.phase = .passReview
            await beginOrResumeSweep()
        case .pause:
            cameraAdjustmentTask?.cancel()
            pendingExposureBias = nil
            pendingMeteringPoint = nil
            capture.pause()
            synchronize()
        case .discard:
            resetCapture()
        case .saveToPhotos:
            await saveToPhotos()
        case .retry:
            if ui.phase == .review, ui.issue?.kind == .saveFailure {
                await saveToPhotos()
            } else if capture.currentSnapshot != nil {
                await resumeSavedSweep()
            } else {
                await preparePreview()
            }
        }
    }

    private func applyCameraAdjustments() {
        guard cameraAdjustmentTask == nil else { return }
        cameraAdjustmentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.cameraAdjustmentTask = nil }
            while self.pendingMeteringPoint != nil || self.pendingExposureBias != nil {
                let point = self.pendingMeteringPoint
                let bias = self.pendingExposureBias
                self.pendingMeteringPoint = nil
                self.pendingExposureBias = nil
                guard !Task.isCancelled, self.capture.canAdjustCamera else { return }
                do {
                    if let point { try await self.capture.setMeteringPoint(point) }
                    if let bias { try await self.capture.setExposureBias(Float(bias)) }
                    guard !Task.isCancelled else { return }
                    if self.pendingExposureBias == nil { self.ui.exposureBias = Double(self.capture.exposureBias) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showCaptureError(error, fatal: false)
                }
            }
        }
    }

    private func preparePreview() async {
        guard capture.currentSnapshot == nil else { return }
        ui.isStarting = true
        do {
            try await capture.preparePreview(lens: ui.selectedLens, target: ui.selectedTarget,
                                             orientation: currentOrientation())
            ui.issue = nil
            ui.banner = nil
            synchronize()
        } catch {
            ui.isStarting = false
            showCaptureError(error)
        }
    }

    private func beginOrResumeSweep() async {
        ui.isStarting = true
        do {
            // Flush the last slider/focus change before fixing sweep settings.
            await cameraAdjustmentTask?.value
            ui.isStarting = true
            if capture.currentSnapshot == nil
                && (capture.status != .ready || capture.plan?.orientation != currentOrientation()) {
                try await capture.preparePreview(lens: ui.selectedLens, target: ui.selectedTarget,
                                                 orientation: currentOrientation())
            }
            if capture.status == .reviewing {
                try await capture.resumeSweep()
            } else if capture.status == .paused || capture.status.isFailure {
                try await capture.resume()
            }
            if capture.status == .ready {
                if capture.singlePhotoCropFactor != nil {
                    await captureSinglePhoto()
                    return
                }
                try await capture.beginSweep()
            }
            ui.issue = nil
            ui.banner = nil
            automaticAssemblyKey = nil
            synchronize()
        } catch {
            ui.isStarting = false
            if !(error is CancellationError) { showCaptureError(error, fatal: capture.status.isFailure) }
            synchronize()
        }
    }

    private func captureSinglePhoto() async {
        ui.phase = .processing
        ui.issue = nil
        ui.processingProgress = nil
        do {
            let baseURL = try Self.makeResultsDirectory().appendingPathComponent(UUID().uuidString)
            let result = try await capture.captureSinglePhoto(
                to: baseURL, maximumMegapixels: AppPreferences.outputResolution().rawValue
            )
            guard let preview = makeThumbnail(url: result.url, maxPixelSize: 1800) else {
                throw CaptureError.photoDataUnavailable
            }
            if let previous = lastOutputURL { try? FileManager.default.removeItem(at: previous) }
            lastOutputURL = result.url
            ui.resultURL = result.url
            ui.resultPreview = preview
            ui.resultPixelSize = CGSize(width: result.pixelWidth, height: result.pixelHeight)
            ui.saveState = .idle
            ui.phase = .review
            ui.isStarting = false
        } catch {
            ui.phase = .setup
            ui.isStarting = false
            showCaptureError(error, fatal: false)
            synchronize()
        }
    }

    private func resumeSavedSweep() async {
        ui.isStarting = true
        do {
            try await capture.resume()
            if capture.status == .ready, capture.currentSnapshot?.isPassOpen == true {
                try await capture.beginSweep()
            }
            ui.issue = nil
            automaticAssemblyKey = nil
            synchronize()
        } catch {
            ui.isStarting = false
            if !(error is CancellationError) { showCaptureError(error, fatal: capture.status.isFailure) }
            synchronize()
        }
    }

    private func assemble(crop: CapturedFieldCrop? = nil) async {
        guard !isAssembling else { return }
        guard let snapshot = capture.currentSnapshot, snapshot.frames.count >= 2 else {
            ui.phase = .passReview
            showCaptureError(CaptureError.incompletePass, fatal: false)
            return
        }
        isAssembling = true
        defer { isAssembling = false }
        ui.phase = .processing
        ui.issue = nil
        ui.processingProgress = 0

        let outputURL: URL
        do {
            outputURL = try Self.makeResultsDirectory()
                .appendingPathComponent("\(snapshot.sessionID.uuidString)-\(UUID().uuidString).heic")
        } catch {
            ui.processingProgress = nil
            showStitchError(error)
            return
        }

        let capturedInputs = snapshot.frames.map { frame in
            StitchInput(
                url: frame.fileURL,
                yawRadians: frame.yawDegrees * .pi / 180,
                pitchRadians: frame.pitchDegrees * .pi / 180,
                rollRadians: frame.rollDegrees * .pi / 180
            )
        }
        let preparedInputs = capture.preparedStitchInputs
        let usesPreparedAlignment = (preparedInputs?.count ?? 0) >= 2
        do {
            let inputs: [StitchInput]
            if let crop {
                guard let preparedInputs else { throw StitchingFailure.invalidGeometry }
                inputs = try crop.inputs(from: preparedInputs)
            } else {
                inputs = usesPreparedAlignment ? (preparedInputs ?? capturedInputs) : capturedInputs
            }
            let result = try await stitcher.stitch(
                inputs: inputs,
                outputURL: outputURL,
                maximumMegapixels: AppPreferences.outputResolution().rawValue,
                targetAspectRatio: snapshot.plan.orientation.isPortrait ? 3.0 / 4.0 : 4.0 / 3.0,
                minimumHorizontalFOVDegrees: crop == nil ? snapshot.plan.targetHorizontalFOV : nil,
                minimumVerticalFOVDegrees: crop == nil ? snapshot.plan.targetVerticalFOV : nil,
                preparedFocalRatio: usesPreparedAlignment
                    ? capture.preparedFocalRatio.map { $0 / (crop?.rect.height ?? 1) } : nil
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.ui.processingProgress = fraction }
            }
            guard let preview = makeThumbnail(url: result.imageURL, maxPixelSize: 1800) else {
                throw StitchingFailure.unreadableImage
            }
            if let previous = lastOutputURL, previous != result.imageURL {
                try? FileManager.default.removeItem(at: previous)
            }
            lastOutputURL = result.imageURL
            ui.resultURL = result.imageURL
            ui.resultPreview = preview
            ui.resultPixelSize = CGSize(width: result.pixelWidth, height: result.pixelHeight)
            ui.resultWasCropped = crop != nil
            ui.resultMagnification = snapshot.plan.target.magnification / (crop?.rect.width ?? 1)
            ui.saveState = .idle
            ui.processingProgress = nil
            ui.phase = .review
            ui.banner = nil
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            ui.processingProgress = nil
            showStitchError(error)
        }
    }

    private func scheduleAutomaticAssembly() {
        guard capture.status == .reviewing, let snapshot = capture.currentSnapshot,
              snapshot.frames.count >= 2, !isAssembling,
              ui.phase != .review, ui.phase != .processing else { return }
        // Stopping an incomplete sweep opens its choices immediately. A
        // narrower field always requires the photographer's explicit action.
        guard capture.visualCoverage?.isComplete == true else { return }
        let key = "\(snapshot.sessionID.uuidString):\(snapshot.frames.count)"
        guard automaticAssemblyKey != key else { return }
        automaticAssemblyKey = key
        ui.phase = .processing
        Task { [weak self] in await self?.assemble() }
    }

    private static func ultraWideAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", ultraWideAlbumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    private func saveToPhotos() async {
        guard let url = ui.resultURL, ui.saveState == .idle else { return }
        ui.saveState = .saving
        ui.issue = nil
        // Finding the album needs read-write access. Without it, the photo is still
        // saved with add-only access, but outside the album.
        let readWrite = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canUseAlbum = readWrite == .authorized || readWrite == .limited
        if !canUseAlbum {
            let addOnly = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard addOnly == .authorized || addOnly == .limited else {
                ui.saveState = .idle
                ui.issue = CaptureUIIssue(kind: .photoLibraryPermission,
                                          detail: String(localized: "Allow Photos access in Settings, or use Share."),
                                          canRetry: false)
                return
            }
        }
        let album = canUseAlbum ? Self.ultraWideAlbum() : nil
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: .photo, fileURL: url, options: nil)
                guard canUseAlbum, let placeholder = creation.placeholderForCreatedAsset else { return }
                if let album {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                } else {
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.ultraWideAlbumTitle)
                        .addAssets([placeholder] as NSArray)
                }
            }
            ui.saveState = .saved
            ui.issue = nil
            capture.discard()
            synchronize()
        } catch {
            ui.saveState = .idle
            ui.issue = CaptureUIIssue(kind: .saveFailure,
                                      detail: String(localized: "Couldn’t save. Try again or share the image."),
                                      canRetry: true)
        }
    }

    private func scheduleSynchronize() {
        guard !synchronizeScheduled else { return }
        synchronizeScheduled = true
        Task { @MainActor [weak self] in
            // objectWillChange fires before the new value is stored.
            await Task.yield()
            guard let self else { return }
            self.synchronizeScheduled = false
            self.synchronize()
        }
    }

    private func synchronize() {
        ui.availableLenses = capture.availableLenses
        ui.hasActiveSession = capture.currentSnapshot != nil
        ui.hasRecoverableSession = capture.hasRecoverableSession
        ui.canAdjustCamera = capture.canAdjustCamera
        if cameraAdjustmentTask == nil { ui.exposureBias = Double(capture.exposureBias) }
        if let plan = capture.plan {
            if capture.currentSnapshot != nil {
                ui.selectedLens = plan.lens
                ui.selectedTarget = plan.target
            }
            ui.previewRotationAngle = plan.orientation.rotationAngle
        }
        switch capture.status {
        case .ready, .capturing, .recalibrating:
            ui.previewSession = capture.previewSession
        default:
            ui.previewSession = nil
        }
        updateAvailableTargets()
        synchronizeSweep()
        if capture.status == .capturing, ui.sweep.coverageFraction - lastHapticFraction >= 0.02,
           Date().timeIntervalSince(lastHapticAt) >= 0.4 {
            ui.coverageFeedbackCount += 1
            lastHapticFraction = ui.sweep.coverageFraction
            lastHapticAt = Date()
        }

        if capture.orientationNeedsCorrection, let correction = capture.orientationCorrection {
            ui.banner = captureErrorMessage(correction)
            orientationBannerActive = true
        } else if orientationBannerActive {
            ui.banner = nil
            orientationBannerActive = false
        }

        if ui.phase != .processing && ui.phase != .review {
            switch capture.status {
            case .idle, .paused, .ready:
                ui.phase = .setup
            case .preparing:
                if ui.phase != .passReview { ui.phase = .setup }
            case .recalibrating:
                ui.phase = .reanchor
                // Decode the reference once, not on every motion sample.
                let url = capture.calibrationFrameURL
                if url != reanchorImageURL {
                    reanchorImageURL = url
                    ui.reanchorImage = url.flatMap { makeThumbnail(url: $0, maxPixelSize: 900) }
                }
            case .capturing:
                ui.phase = .capturing
            case .reviewing:
                ui.phase = .passReview
            case .failed:
                if ui.issue == nil {
                    ui.issue = CaptureUIIssue(
                        kind: .captureFailure,
                        detail: String(localized: "Capture was interrupted. Try again."),
                        canRetry: true
                    )
                }
                ui.phase = ui.issue?.kind == .cameraPermission ? .permission : .unavailable
            }
        }
        if capture.status != .preparing && !capture.isCenterAnchoring { ui.isStarting = false }
        scheduleAutomaticAssembly()
    }

    /// Builds the sweep state as one value: the camera overlay is invalidated
    /// only when something it displays actually changed.
    private func synchronizeSweep() {
        var sweep = ui.sweep
        sweep.viewRect = capture.coverage?.viewRect ?? CaptureUISweep().viewRect
        if let visual = capture.visualCoverage {
            // Motion positions guide the live camera frame; only image alignment
            // contributes to the completed field shown to the photographer.
            sweep.coveredPolygons = visual.polygons
            sweep.coverageFraction = visual.fraction
            sweep.isComplete = visual.isComplete
        } else {
            sweep.coveredPolygons = []
            sweep.coverageFraction = 0
            sweep.isComplete = false
        }
        if capture.assemblyPreview !== lastAssemblyPreview {
            lastAssemblyPreview = capture.assemblyPreview
            sweep.previewImage = capture.assemblyPreview.map { UIImage(cgImage: $0) }
        }
        sweep.isVerifyingAlignment = capture.isVerifyingAlignment
        sweep.isRecording = capture.status == .capturing
        sweep.isFinishing = capture.isFinishingSweep || isAssembling || ui.phase == .processing
        sweep.blockReason = capture.captureBlockReason
        if let analysis = capture.sweepAnalysis {
            let center = CGPoint(x: sweep.viewRect.midX, y: sweep.viewRect.midY)
            sweep.missingTarget = analysis.target(from: center, retaining: sweep.missingTarget)
            sweep.guidanceDirection = sweep.missingTarget.map { CGVector(dx: $0.x - center.x, dy: $0.y - center.y) }
            sweep.capturedField = analysis.capturedField?.rect
        } else {
            sweep.missingTarget = nil
            sweep.guidanceDirection = nil
            sweep.capturedField = nil
        }
        if sweep != ui.sweep { ui.sweep = sweep }
    }

    private struct TargetsCacheKey: Equatable {
        let lens: CaptureLens
        let orientation: CaptureOrientation
        let plan: CapturePlan?
    }

    private func updateAvailableTargets() {
        let lens = ui.selectedLens
        let orientation = capture.currentSnapshot?.plan.orientation ?? currentOrientation()
        // Fields of view only change with the lens, orientation or a new
        // camera configuration, never with motion samples.
        let key = TargetsCacheKey(lens: lens, orientation: orientation, plan: capture.plan)
        if key != targetsCacheKey || ui.availableTargets.isEmpty {
            targetsCacheKey = key
            ui.availableTargets = capture.availableTargets(for: lens, orientation: orientation)
        }
        if !ui.availableTargets.contains(ui.selectedTarget) {
            ui.selectedTarget = ui.availableTargets.first ?? .half
        }
        ui.isSinglePhoto = capture.currentSnapshot == nil
            && capture.plan?.lens == lens
            && capture.plan?.target == ui.selectedTarget
            && capture.singlePhotoCropFactor != nil
    }

    private func showCaptureError(_ error: Error, fatal: Bool = true) {
        ui.isStarting = false
        let kind: CaptureUIIssue.Kind
        switch error {
        case CaptureError.cameraPermissionDenied: kind = .cameraPermission
        case CaptureError.motionUnavailable: kind = .motionPermission
        case CaptureError.cameraUnavailable, CaptureError.lensUnavailable: kind = .cameraUnavailable
        default: kind = .captureFailure
        }
        ui.issue = CaptureUIIssue(kind: kind,
                                  detail: captureErrorMessage(error),
                                  canRetry: fatal)
        if fatal { ui.phase = kind == .cameraPermission ? .permission : .unavailable }
    }

    private func showStitchError(_ error: Error) {
        ui.phase = .passReview
        let detail: String
        switch error {
        case StitchingFailure.incompleteCoverage:
            detail = String(localized: "Fill the frame edges.")
        case StitchingFailure.insufficientOverlap:
            detail = String(localized: "Sweep the missing areas more slowly.")
        case StitchingFailure.invalidGeometry:
            detail = String(localized: "Move the iPhone more steadily during the sweep.")
        default:
            detail = String(localized: "Couldn’t stitch. Continue the sweep.")
        }
        ui.issue = CaptureUIIssue(kind: .stitchingFailure, detail: detail, canRetry: false)
    }

    private func resetCapture() {
        capture.discard()
        if let output = lastOutputURL { try? FileManager.default.removeItem(at: output) }
        lastOutputURL = nil
        automaticAssemblyKey = nil
        reanchorImageURL = nil
        ui.reanchorImage = nil
        ui.resultURL = nil
        ui.resultPreview = nil
        ui.resultPixelSize = nil
        ui.resultWasCropped = false
        ui.resultMagnification = nil
        lastHapticFraction = 0
        cameraAdjustmentTask?.cancel()
        pendingExposureBias = nil
        pendingMeteringPoint = nil
        ui.saveState = .idle
        ui.processingProgress = nil
        ui.issue = nil
        ui.banner = nil
        ui.phase = .setup
        synchronize()
        Task { [weak self] in await self?.preparePreview() }
    }

    private func currentOrientation() -> CaptureOrientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let orientation: UIInterfaceOrientation? = scene?.effectiveGeometry.interfaceOrientation
        switch orientation ?? .portrait {
        case UIInterfaceOrientation.landscapeLeft: return .landscapeLeft
        case UIInterfaceOrientation.landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    private func makeThumbnail(url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func captureErrorMessage(_ error: Error) -> String {
        guard let error = error as? CaptureError else {
            return String(localized: "Capture failed. Try again.")
        }
        if case .orientationChanged = error {
            let orientation = capture.plan?.orientation ?? currentOrientation()
            return orientation.isPortrait
                ? String(localized: "Hold the iPhone vertically (portrait).")
                : String(localized: "Hold the iPhone horizontally (landscape).")
        }
        return error.localizedDescription
    }

    private static func makeResultsDirectory() throws -> URL {
        var directory = resultsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    /// A result that was never saved, or an export interrupted by the system,
    /// cannot be reopened after a relaunch. Reclaim its storage before any new
    /// capture: a full-resolution assembly buffer can occupy hundreds of MB.
    private static func removeAbandonedFiles() {
        let manager = FileManager.default
        try? manager.removeItem(at: resultsDirectory)
        let temporary = manager.temporaryDirectory
        let names = (try? manager.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("ultrawide-") {
            try? manager.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
}
