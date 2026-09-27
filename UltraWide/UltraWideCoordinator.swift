import AVFoundation
import Combine
import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit

/// Joins the durable capture session, native assembler, and SwiftUI presentation.
/// Camera and Photos permissions are requested only when their actions need them.
@MainActor
final class UltraWideCoordinator {
    let ui = CaptureUIModel()

    private let capture = CaptureController()
    private let stitcher = StitchingEngine()
    private var cancellables = Set<AnyCancellable>()
    private var isTakingPhoto = false
    private var autoCaptureTask: Task<Void, Never>?
    private var autoAttemptedSlotID: String?
    private var orientationBannerActive = false
    private var rejectedSlotIDs = Set<String>()
    private var lastOutputURL: URL?

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
    }

    private func handle(_ action: CaptureUIAction) async {
        switch action {
        case .prepare:
            synchronize()
            if capture.availableLenses.isEmpty {
                ui.phase = .unavailable
                ui.issue = CaptureUIIssue(
                    kind: .cameraUnavailable,
                    detail: message("Ultra Wide nécessite un iPhone doté d’un appareil photo arrière.",
                                    "Ultra Wide needs an iPhone with a rear camera."),
                    canRetry: false
                )
            }
        case .selectLens:
            updateAvailableTargets()
        case .selectTarget:
            updateEstimate()
        case .start:
            await startCapture()
        case .resume:
            await resumeCapture()
        case .confirmReanchor:
            do {
                try capture.confirmReferenceAlignment()
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: false)
                synchronize()
            }
        case .capture:
            autoCaptureTask?.cancel()
            await takePhoto()
        case .finishPass:
            do {
                _ = try capture.finishPass()
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: false)
                synchronize()
            }
        case .beginRefinementPass:
            do {
                try await capture.beginRefinementPass()
                ui.issue = nil
                ui.phase = .passReview
                synchronize()
            } catch {
                showCaptureError(error, fatal: capture.status.isFailure)
                synchronize()
            }
        case .assemble:
            await assemble()
        case .retake(let slotID):
            do {
                try capture.retake(slotID: slotID)
                rejectedSlotIDs.remove(slotID)
                ui.issue = nil
                synchronize()
            } catch {
                showCaptureError(error, fatal: false)
                synchronize()
            }
        case .pause:
            autoCaptureTask?.cancel()
            capture.pause()
            synchronize()
        case .discard:
            resetCapture()
        case .newCapture:
            resetCapture()
        case .saveToPhotos:
            await saveToPhotos()
        case .retry:
            if ui.phase == .review, ui.issue?.kind == .saveFailure {
                await saveToPhotos()
            } else if ui.phase == .permission || ui.phase == .unavailable {
                if capture.availableLenses.isEmpty { await handle(.prepare) }
                else if capture.currentSnapshot != nil { await resumeCapture() }
                else { await startCapture() }
            }
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await UIApplication.shared.open(url)
        }
    }

    private func startCapture() async {
        // A saved session must be resumed or explicitly discarded first.
        guard capture.currentSnapshot == nil else {
            ui.isStarting = false
            synchronize()
            return
        }
        let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
        let target = CaptureTarget(rawValue: ui.selectedTarget.rawValue) ?? .half
        do {
            try await capture.start(lens: lens, target: target, orientation: currentOrientation())
            ui.issue = nil
            ui.banner = nil
            synchronize()
        } catch {
            ui.isStarting = false
            showCaptureError(error)
        }
    }

    private func resumeCapture() async {
        do {
            try await capture.resume()
            ui.issue = nil
            synchronize()
        } catch {
            ui.isStarting = false
            showCaptureError(error)
        }
    }

    private func takePhoto() async {
        guard !isTakingPhoto else { return }
        isTakingPhoto = true
        defer {
            isTakingPhoto = false
            synchronize()
        }
        do {
            let frame: CapturedFrame
            if capture.completedCount == 0 {
                frame = try await capture.anchorCenterAndCapture()
            } else {
                frame = try await capture.captureCurrentView()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if frame.quality == .soft {
                ui.banner = message("Vue légèrement floue : vous pourrez la refaire au second passage.",
                                    "This view is a little soft. You can retake it in the second pass.")
            } else if frame.quality == .dark {
                ui.banner = message("Vue sombre : envisagez une reprise si le résultat manque de détail.",
                                    "This view is dark. Consider a retake if it lacks detail.")
            } else {
                ui.banner = nil
            }
            ui.issue = nil
            autoAttemptedSlotID = nil
        } catch {
            if !(error is CancellationError), capture.status != .idle, capture.status != .paused {
                showCaptureError(error, fatal: false)
            }
        }
    }

    private func assemble() async {
        guard let snapshot = capture.currentSnapshot, snapshot.isComplete else {
            ui.phase = .passReview
            showCaptureError(CaptureError.incompletePass, fatal: false)
            return
        }
        ui.phase = .processing
        ui.issue = nil
        ui.processingProgress = 0
        autoCaptureTask?.cancel()

        let ordered = snapshot.slots.compactMap { slot -> (CaptureSlot, CapturedFrame)? in
            guard let frame = slot.frame else { return nil }
            return (slot, frame)
        }
        let inputs = ordered.map { _, frame in
            StitchInput(
                url: frame.fileURL,
                yawRadians: frame.yawDegrees * .pi / 180,
                pitchRadians: frame.pitchDegrees * .pi / 180,
                rollRadians: frame.rollDegrees * .pi / 180
            )
        }
        let outputURL: URL
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UltraWideResults", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            outputURL = folder.appendingPathComponent("\(snapshot.sessionID.uuidString)-\(UUID().uuidString).heic")
        } catch {
            showStitchError(error)
            return
        }

        do {
            let result = try await stitcher.stitch(
                inputs: inputs,
                outputURL: outputURL,
                maximumMegapixels: 48,
                targetAspectRatio: snapshot.plan.orientation.isPortrait ? 3.0 / 4.0 : 4.0 / 3.0,
                minimumHorizontalFOVDegrees: snapshot.plan.targetHorizontalFOV,
                minimumVerticalFOVDegrees: snapshot.plan.targetVerticalFOV
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
            ui.saveState = .idle
            ui.processingProgress = nil
            ui.phase = .review
            let omitted = result.rejectedFrameIndices.compactMap { index in
                ordered.indices.contains(index) ? ordered[index].0.id : nil
            }
            rejectedSlotIDs = Set(omitted)
            if !omitted.isEmpty {
                ui.banner = message("Certaines vues ont été écartées de l’assemblage.",
                                    "Some views were omitted from the stitch.")
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            ui.processingProgress = nil
            if case StitchingFailure.insufficientOverlap(let indices) = error {
                rejectedSlotIDs = Set(indices.compactMap { index in
                    ordered.indices.contains(index) ? ordered[index].0.id : nil
                })
            } else if case StitchingFailure.incompleteCoverage(let indices) = error {
                rejectedSlotIDs = Set(indices.compactMap { index in
                    ordered.indices.contains(index) ? ordered[index].0.id : nil
                })
            }
            showStitchError(error)
        }
    }

    private func saveToPhotos() async {
        guard let url = ui.resultURL, ui.saveState == .idle else { return }
        ui.saveState = .saving
        ui.issue = nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ui.saveState = .idle
            ui.issue = CaptureUIIssue(kind: .photoLibraryPermission,
                                      detail: message("Autorisez l’ajout à Photos dans Réglages, ou utilisez Partager.",
                                                      "Allow adding to Photos in Settings, or use Share."),
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            capture.discard()
            synchronize()
        } catch {
            ui.saveState = .idle
            ui.issue = CaptureUIIssue(kind: .saveFailure,
                                      detail: message("Impossible d’enregistrer dans Photos. Réessayez ou utilisez Partager.",
                                                      "Couldn’t save to Photos. Try again or use Share."),
                                      canRetry: true)
        }
    }

    private func synchronize() {
        ui.availableLenses = capture.availableLenses.compactMap { CaptureUILens(rawValue: $0.rawValue) }
        ui.hasRecoverableSession = capture.hasRecoverableSession
        if let plan = capture.plan {
            ui.selectedLens = CaptureUILens(rawValue: plan.lens.rawValue) ?? .wide
            ui.selectedTarget = CaptureUITarget(rawValue: plan.target.rawValue) ?? .half
            ui.previewRotationAngle = plan.orientation.rotationAngle
            ui.previewSession = capture.previewSession
        } else {
            ui.previewSession = nil
            updateAvailableTargets()
        }
        ui.currentPass = capture.currentPass
        ui.plannedPhotos = capture.plan?.expectedFrameCount ?? 0
        ui.capturedPhotos = capture.completedCount
        ui.refinementPhotos = capture.currentSnapshot?.retakeCount ?? 0
        ui.remainingRetakes = capture.remainingRetakes
        ui.canRefine = capture.status == .reviewing
            && capture.currentPass == 1 && capture.remainingRetakes > 0
        ui.canFinishPass = capture.status == .ready
            && (capture.currentSnapshot?.isComplete ?? false)
        ui.canCapture = capture.status == .ready && !capture.orientationNeedsCorrection
            && !capture.isCenterAnchoring
            && (capture.completedCount == 0 || (capture.guidance?.canCapture ?? false))

        let currentID = capture.currentSlot?.id
        ui.coverage = capture.slots.map { slot in
            let state: CaptureUICoverageCell.State
            if slot.id == currentID && capture.status == .ready {
                state = .current
            } else if let frame = slot.frame {
                state = rejectedSlotIDs.contains(slot.id) || frame.quality == .soft || frame.quality == .dark
                    ? .needsRetake : .captured
            } else {
                state = .pending
            }
            return CaptureUICoverageCell(id: slot.id, row: slot.row, column: slot.column, state: state)
        }

        if capture.completedCount == 0 && capture.status == .ready {
            ui.guidance = CaptureUIGuidance(hasTarget: false, isAligned: true,
                                            isStable: false, isAutoCaptureEnabled: false)
        } else if let guidance = capture.guidance, let plan = capture.plan {
            ui.guidance = CaptureUIGuidance(
                hasTarget: true,
                horizontalOffset: clip(guidance.horizontalErrorDegrees / max(plan.horizontalStep, 4)),
                verticalOffset: clip(-guidance.verticalErrorDegrees / max(plan.verticalStep, 4)),
                isAligned: guidance.isAligned,
                isStable: guidance.isStable,
                isCapturing: capture.status == .capturing,
                isAutoCaptureEnabled: true
            )
        } else {
            ui.guidance = CaptureUIGuidance(hasTarget: currentID != nil,
                                            isCapturing: capture.status == .capturing)
        }
        if capture.orientationNeedsCorrection {
            ui.banner = message("Remettez l’iPhone dans l’orientation du début de session.",
                                "Return the iPhone to the orientation used at the start.")
            orientationBannerActive = true
        } else if orientationBannerActive {
            ui.banner = nil
            orientationBannerActive = false
        }

        if ui.phase != .processing && ui.phase != .review {
            switch capture.status {
            case .idle, .paused:
                ui.phase = .setup
            case .preparing:
                if ui.phase != .passReview { ui.phase = .setup }
            case .recalibrating:
                ui.phase = .reanchor
                ui.reanchorImage = capture.calibrationFrameURL.flatMap {
                    makeThumbnail(url: $0, maxPixelSize: 900)
                }
            case .ready, .capturing:
                ui.phase = .capturing
            case .reviewing:
                ui.phase = .passReview
            case .failed:
                ui.phase = ui.issue?.kind == .cameraPermission ? .permission : .unavailable
            }
        }
        if capture.status != .preparing { ui.isStarting = false }
        scheduleAutomaticCapture()
    }

    private func updateAvailableTargets() {
        let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
        let orientation = capture.plan?.orientation ?? currentOrientation()
        ui.availableTargets = capture.availableTargets(for: lens, orientation: orientation)
            .compactMap { CaptureUITarget(rawValue: $0.rawValue) }
        if !ui.availableTargets.contains(ui.selectedTarget) {
            ui.selectedTarget = ui.availableTargets.first ?? .half
        }
        updateEstimate()
    }

    private func updateEstimate() {
        let lens = CaptureLens(rawValue: ui.selectedLens.rawValue) ?? .wide
        let target = CaptureTarget(rawValue: ui.selectedTarget.rawValue) ?? .half
        let orientation = capture.plan?.orientation ?? currentOrientation()
        if let wideFOV = CameraService.horizontalFieldOfView(for: .wide),
           let lensFOV = CameraService.horizontalFieldOfView(for: lens),
           let plan = CapturePlan.make(lens: lens, target: target,
                                       orientation: orientation, wideHorizontalFOV: wideFOV,
                                       lensHorizontalFOV: lensFOV) {
            ui.estimatedPhotos = plan.expectedFrameCount
        } else {
            ui.estimatedPhotos = 0
        }
    }

    private func scheduleAutomaticCapture() {
        guard ui.phase == .capturing, capture.status == .ready,
              capture.completedCount > 0,
              let guidance = capture.guidance, guidance.canCapture,
              let slotID = capture.currentSlot?.id,
              !isTakingPhoto else {
            if capture.guidance?.canCapture != true { autoAttemptedSlotID = nil }
            return
        }
        guard autoAttemptedSlotID != slotID else { return }
        autoAttemptedSlotID = slotID
        autoCaptureTask?.cancel()
        autoCaptureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self,
                  self.capture.status == .ready,
                  self.capture.currentSlot?.id == slotID,
                  self.capture.guidance?.canCapture == true else { return }
            await self.takePhoto()
        }
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
        case StitchingFailure.insufficientOverlap:
            detail = rejectedSlotIDs.isEmpty
                ? message("Certaines vues ne se recouvrent pas assez. Reprenez-les en tournant plus lentement.",
                          "Some views do not overlap enough. Retake them while rotating more slowly.")
                : message("Certaines vues ne se recouvrent pas assez. Reprenez les vues signalées.",
                          "Some views do not overlap enough. Retake the marked views.")
        case StitchingFailure.incompleteCoverage:
            detail = rejectedSlotIDs.isEmpty
                ? message("Le balayage ne couvre pas le cadrage demandé. Reprenez les vues des bords.",
                          "The sweep does not cover the requested field. Retake the edge views.")
                : message("Le balayage ne couvre pas le cadrage demandé. Reprenez les vues des bords signalées.",
                          "The sweep does not cover the requested field. Retake the marked edge views.")
        case StitchingFailure.invalidGeometry:
            detail = message("Les vues n’ont pas pu être alignées. Reprenez-les en tournant lentement autour de l’iPhone.",
                             "The views could not be aligned. Retake them while rotating slowly around the iPhone.")
        default:
            detail = message("L’assemblage a échoué. Reprenez les vues signalées ou recommencez.",
                             "Stitching failed. Retake the marked views or start again.")
        }
        ui.issue = CaptureUIIssue(kind: .stitchingFailure,
                                  detail: detail,
                                  canRetry: false)
        synchronize()
    }

    private func captureErrorMessage(_ error: Error) -> CaptureUIMessage {
        guard let error = error as? CaptureError else {
            return message("La prise de vue a échoué. Réessayez.",
                           "Capture failed. Please try again.")
        }
        let english: String
        switch error {
        case .cameraPermissionDenied: english = "Allow camera access in Settings."
        case .cameraUnavailable: english = "The camera is temporarily unavailable."
        case .lensUnavailable: english = "This lens is unavailable on this iPhone."
        case .targetUnavailable: english = "This field would need too many photos with this lens."
        case .cameraConfigurationFailed: english = "The camera could not be prepared."
        case .motionUnavailable: english = "Motion sensors are unavailable."
        case .notReady: english = "Capture is not ready yet."
        case .notAligned: english = "Align the guide and hold your iPhone still."
        case .orientationChanged: english = "Return the iPhone to the starting orientation."
        case .noCurrentSlot: english = "All planned views have been captured."
        case .incompletePass: english = "Some views still need to be captured."
        case .retakeLimitReached: english = "The six-retake limit has been reached."
        case .invalidSlot: english = "This view is not part of the session."
        case .noSavedSession: english = "There is no session to resume."
        case .corruptSavedSession: english = "The saved session is incomplete."
        case .photoDataUnavailable: english = "The photo could not be read."
        case .diskWriteFailed: english = "The photo could not be saved on this iPhone."
        }
        return message(error.localizedDescription, english)
    }

    private func resetCapture() {
        autoCaptureTask?.cancel()
        capture.discard()
        if let output = lastOutputURL { try? FileManager.default.removeItem(at: output) }
        lastOutputURL = nil
        rejectedSlotIDs.removeAll()
        ui.resultURL = nil
        ui.resultPreview = nil
        ui.resultPixelSize = nil
        ui.saveState = .idle
        ui.processingProgress = nil
        ui.issue = nil
        ui.banner = nil
        ui.phase = .setup
        synchronize()
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

    private func message(_ french: String, _ english: String) -> CaptureUIMessage {
        CaptureUIMessage(french: french, english: english)
    }

    private func clip(_ value: Double) -> Double { min(1, max(-1, value)) }
}

private enum PhotoSaveError: Error { case failed }
