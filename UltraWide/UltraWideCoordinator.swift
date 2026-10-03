import AVFoundation
import Combine
import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit

/// Connects the free video sweep, on-device assembler, and SwiftUI camera.
@MainActor
final class UltraWideCoordinator {
    let ui = CaptureUIModel()

    private let capture = CaptureController()
    private let stitcher = StitchingEngine()
    private var cancellables = Set<AnyCancellable>()
    private var isAssembling = false
    private var automaticAssemblyKey: String?
    private var orientationBannerActive = false
    private var lastOutputURL: URL?
    private var lastAssemblyPreview: CGImage?
    private var pendingExposureBias: Double?
    private var pendingMeteringPoint: CGPoint?
    private var cameraAdjustmentTask: Task<Void, Never>?
    private var lastHapticFraction = 0.0
    private var lastHapticAt = Date.distantPast
    private let acquisitionFeedback = UISelectionFeedbackGenerator()

    init() {
        ui.onAction = { [weak self] action in
            Task { @MainActor [weak self] in await self?.handle(action) }
        }
        capture.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.synchronize()
            }
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
                    detail: message("Un iPhone doté d’un appareil photo arrière est nécessaire.",
                                    "An iPhone with a rear camera is required."),
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
        case .start, .startSweep:
            await beginOrResumeSweep()
        case .resume:
            await resumeSavedSweep()
        case .stopSweep, .finishPass:
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
        case .beginRefinementPass:
            await beginOrResumeSweep()
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
        case .capture:
            // Kept for existing accessibility shortcuts; the sweep captures frames itself.
            if capture.currentSnapshot == nil { await beginOrResumeSweep() }
        case .retake(let slotID):
            do {
                try capture.retake(slotID: slotID)
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: false)
            }
        case .pause:
            cameraAdjustmentTask?.cancel()
            pendingExposureBias = nil
            pendingMeteringPoint = nil
            capture.pause()
            synchronize()
        case .discard, .newCapture:
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
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await UIApplication.shared.open(url)
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
        let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
        let target = CaptureTarget(rawValue: ui.selectedTarget.rawValue) ?? .half
        ui.isStarting = true
        do {
            try await capture.preparePreview(lens: lens, target: target,
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
                let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
                let target = CaptureTarget(rawValue: ui.selectedTarget.rawValue) ?? .half
                try await capture.preparePreview(lens: lens, target: target,
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
            let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
                .appendingPathComponent("UltraWideResults", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let baseURL = folder.appendingPathComponent(UUID().uuidString)
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
            if AppPreferences.hapticsEnabled() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
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
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UltraWideResults", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            outputURL = folder.appendingPathComponent("\(snapshot.sessionID.uuidString)-\(UUID().uuidString).heic")
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
            if AppPreferences.hapticsEnabled() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
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

    private func saveToPhotos() async {
        guard let url = ui.resultURL, ui.saveState == .idle else { return }
        ui.saveState = .saving
        ui.issue = nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ui.saveState = .idle
            ui.issue = CaptureUIIssue(kind: .photoLibraryPermission,
                                      detail: message("Autorisez Photos dans Réglages, ou utilisez Partager.",
                                                      "Allow Photos in Settings, or use Share."),
                                      canRetry: false)
            return
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: nil)
                } completionHandler: { success, error in
                    if success { continuation.resume() }
                    else { continuation.resume(throwing: error ?? PhotoSaveError.failed) }
                }
            }
            ui.saveState = .saved
            ui.issue = nil
            if AppPreferences.hapticsEnabled() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            capture.discard()
            synchronize()
        } catch {
            ui.saveState = .idle
            ui.issue = CaptureUIIssue(kind: .saveFailure,
                                      detail: message("Enregistrement impossible. Réessayez ou partagez l’image.",
                                                      "Couldn’t save. Try again or share the image."),
                                      canRetry: true)
        }
    }

    private func synchronize() {
        ui.availableLenses = capture.availableLenses.compactMap { CaptureUILens(rawValue: $0.rawValue) }
        ui.hasActiveSession = capture.currentSnapshot != nil
        ui.hasRecoverableSession = capture.hasRecoverableSession
        ui.canAdjustCamera = capture.canAdjustCamera
        if cameraAdjustmentTask == nil { ui.exposureBias = Double(capture.exposureBias) }
        if let plan = capture.plan {
            if capture.currentSnapshot != nil {
                ui.selectedLens = CaptureUILens(rawValue: plan.lens.rawValue) ?? .wide
                ui.selectedTarget = CaptureUITarget(rawValue: plan.target.rawValue) ?? .half
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
        if let coverage = capture.coverage {
            ui.sweep.viewRect = coverage.viewRect
        } else {
            ui.sweep.viewRect = CaptureUISweep().viewRect
        }
        if let visual = capture.visualCoverage {
            // Motion positions guide the live camera frame; only image alignment
            // contributes to the completed field shown to the photographer.
            ui.sweep.coveredRects = []
            if ui.sweep.coveredPolygons != visual.polygons {
                ui.sweep.coveredPolygons = visual.polygons
            }
            ui.sweep.coverageFraction = visual.fraction
            ui.sweep.isComplete = visual.isComplete
        } else {
            ui.sweep.coveredRects = []
            ui.sweep.coveredPolygons = []
            ui.sweep.coverageFraction = 0
            ui.sweep.isComplete = false
        }
        if capture.assemblyPreview !== lastAssemblyPreview {
            lastAssemblyPreview = capture.assemblyPreview
            ui.sweep.previewImage = capture.assemblyPreview.map { UIImage(cgImage: $0) }
        }
        ui.sweep.isVerifyingAlignment = capture.isVerifyingAlignment
        ui.sweep.isRecording = capture.status == .capturing
        ui.sweep.isFinishing = capture.isFinishingSweep || isAssembling || ui.phase == .processing
        ui.sweep.blockReason = capture.captureBlockReason
        if let analysis = capture.sweepAnalysis {
            let center = CGPoint(x: ui.sweep.viewRect.midX, y: ui.sweep.viewRect.midY)
            ui.sweep.missingTarget = analysis.target(from: center, retaining: ui.sweep.missingTarget)
            ui.sweep.guidanceDirection = ui.sweep.missingTarget.map { CGVector(dx: $0.x - center.x, dy: $0.y - center.y) }
            ui.sweep.capturedField = analysis.capturedField?.rect
        } else {
            ui.sweep.missingTarget = nil
            ui.sweep.guidanceDirection = nil
            ui.sweep.capturedField = nil
        }
        if AppPreferences.hapticsEnabled(), capture.status == .capturing, ui.sweep.coverageFraction - lastHapticFraction >= 0.02,
           Date().timeIntervalSince(lastHapticAt) >= 0.4 {
            acquisitionFeedback.selectionChanged()
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
                ui.reanchorImage = capture.calibrationFrameURL.flatMap {
                    makeThumbnail(url: $0, maxPixelSize: 900)
                }
            case .capturing:
                ui.phase = .capturing
            case .reviewing:
                ui.phase = .passReview
            case .failed:
                if ui.issue == nil {
                    ui.issue = CaptureUIIssue(
                        kind: .captureFailure,
                        detail: message("La prise de vue a été interrompue. Réessayez.",
                                        "Capture was interrupted. Try again."),
                        canRetry: true
                    )
                }
                ui.phase = ui.issue?.kind == .cameraPermission ? .permission : .unavailable
            }
        }
        if capture.status != .preparing && !capture.isCenterAnchoring { ui.isStarting = false }
        scheduleAutomaticAssembly()
    }

    private func updateAvailableTargets() {
        let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
        let orientation = capture.currentSnapshot?.plan.orientation ?? currentOrientation()
        ui.availableTargets = capture.availableTargets(for: lens, orientation: orientation)
            .compactMap { CaptureUITarget(rawValue: $0.rawValue) }
        if !ui.availableTargets.contains(ui.selectedTarget) {
            ui.selectedTarget = ui.availableTargets.first ?? .half
        }
        ui.isSinglePhoto = capture.currentSnapshot == nil
            && capture.plan?.lens == lens
            && capture.plan?.target.rawValue == ui.selectedTarget.rawValue
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
        let detail: CaptureUIMessage
        switch error {
        case StitchingFailure.incompleteCoverage:
            detail = message("Complétez les bords du cadre.", "Fill the frame edges.")
        case StitchingFailure.insufficientOverlap:
            detail = message("Balayez plus lentement les zones manquantes.",
                             "Sweep the missing areas more slowly.")
        case StitchingFailure.invalidGeometry:
            detail = message("Bougez moins l’iPhone pendant le balayage.",
                             "Move the iPhone more steadily during the sweep.")
        default:
            detail = message("Assemblage impossible. Continuez le balayage.",
                             "Couldn’t stitch. Continue the sweep.")
        }
        ui.issue = CaptureUIIssue(kind: .stitchingFailure, detail: detail, canRetry: false)
    }

    private func resetCapture() {
        capture.discard()
        if let output = lastOutputURL { try? FileManager.default.removeItem(at: output) }
        lastOutputURL = nil
        automaticAssemblyKey = nil
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

    private func captureErrorMessage(_ error: Error) -> CaptureUIMessage {
        guard let error = error as? CaptureError else {
            return message("La prise de vue a échoué. Réessayez.", "Capture failed. Try again.")
        }
        if case .orientationChanged = error {
            let orientation = capture.plan?.orientation ?? currentOrientation()
            return orientation.isPortrait
                ? message("Tenez l’iPhone verticalement (mode portrait).", "Hold the iPhone vertically (portrait).")
                : message("Tenez l’iPhone horizontalement (mode paysage).", "Hold the iPhone horizontally (landscape).")
        }
        let english: String
        switch error {
        case .cameraPermissionDenied: english = "Allow camera access in Settings."
        case .cameraUnavailable: english = "The camera is temporarily unavailable."
        case .lensUnavailable: english = "This lens is unavailable on this iPhone."
        case .targetUnavailable: english = "This field is unavailable with this lens."
        case .cameraConfigurationFailed: english = "The camera could not be prepared."
        case .motionUnavailable: english = "Motion sensors are unavailable."
        case .notReady: english = "Wait for the camera to be ready."
        case .notAligned: english = "Hold the iPhone still."
        case .orientationChanged: english = "Hold the iPhone in the orientation of the displayed frame."
        case .excessiveRoll: english = "Straighten the iPhone to keep the frame level."
        case .noCurrentSlot: english = "No view is selected."
        case .incompletePass: english = "Sweep a little further before stopping."
        case .retakeLimitReached: english = "The sweep reached its frame limit."
        case .invalidSlot: english = "This frame is unavailable."
        case .noSavedSession: english = "There is no session to resume."
        case .corruptSavedSession: english = "The saved session is incomplete."
        case .photoDataUnavailable: english = "A video frame could not be read."
        case .diskWriteFailed: english = "The frame could not be saved on this iPhone."
        }
        return message(error.localizedDescription, english)
    }

    private func message(_ french: String, _ english: String) -> CaptureUIMessage {
        CaptureUIMessage(french: french, english: english)
    }
}

private enum PhotoSaveError: Error { case failed }
