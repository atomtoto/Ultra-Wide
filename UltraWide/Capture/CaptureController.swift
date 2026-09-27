import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Main-actor façade for the SwiftUI capture flow. Its snapshot and photo URLs
/// are ready for the stitching pipeline once `finishPass()` succeeds.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var plan: CapturePlan?
    @Published private(set) var slots: [CaptureSlot] = []
    @Published private(set) var guidance: CaptureGuidance?
    @Published private(set) var orientationNeedsCorrection = false
    @Published private(set) var isCenterAnchoring = false
    @Published private(set) var currentPass = 1

    let maximumRetakes = 6
    private let camera = CameraService()
    private let motion = MotionGuide()
    private let store = CaptureSessionStore()
    private var snapshot: CaptureSessionSnapshot?
    private var selectedSlotID: String?
    private var latestReading: MotionReading?
    private var stableSince: TimeInterval?
    private var previousGuidedSlotID: String?
    private var captureRequested = false
    private var firstCenterArmed = false
    private var lifecycleGeneration = 0
    private var observers: [NSObjectProtocol] = []

    var previewSession: AVCaptureSession { camera.session }
    var availableLenses: [CaptureLens] { CameraService.availableLenses }
    var currentSnapshot: CaptureSessionSnapshot? { snapshot }
    var hasRecoverableSession: Bool {
        snapshot != nil && (status == .paused || status.isFailure)
    }
    var calibrationFrameURL: URL? {
        guard status == .recalibrating, let snapshot else { return nil }
        let centerID = "r\(snapshot.plan.rows / 2)c\(snapshot.plan.columns / 2)"
        return snapshot.slots.first { $0.id == centerID }?.frame?.fileURL
    }
    var remainingRetakes: Int { maximumRetakes - (snapshot?.retakeCount ?? 0) }
    var completedCount: Int { slots.filter { $0.frame != nil }.count }
    var currentSlot: CaptureSlot? {
        if let selectedSlotID { return slots.first { $0.id == selectedSlotID } }
        guard currentPass == 1 else { return nil }
        return slots.first { $0.frame == nil }
    }

    init() {
        motion.onReading = { [weak self] reading in self?.updateGuidance(reading) }
        if let saved = try? store.load() {
            snapshot = saved
            publish(saved)
            status = .paused
        }
        let interruption = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: camera.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
        }
        let runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: camera.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
                self?.status = .failed(CaptureError.cameraUnavailable.localizedDescription)
            }
        }
        observers = [interruption, runtimeError]
    }

    func availableTargets(
        for lens: CaptureLens,
        orientation: CaptureOrientation = .portrait
    ) -> [CaptureTarget] {
        guard let wideFOV = CameraService.horizontalFieldOfView(for: .wide),
              let lensFOV = CameraService.horizontalFieldOfView(for: lens) else { return [] }
        let candidates: [CaptureTarget] = lens == .wide
            ? [.half] : CaptureTarget.allCases
        return candidates.filter {
            CapturePlan.make(
                lens: lens,
                target: $0,
                orientation: orientation,
                wideHorizontalFOV: wideFOV,
                lensHorizontalFOV: lensFOV
            ) != nil
        }
    }

    func start(
        lens: CaptureLens,
        target: CaptureTarget,
        orientation: CaptureOrientation = .portrait
    ) async throws {
        guard snapshot == nil, !captureRequested, !isCenterAnchoring,
              status == .idle || status.isFailure else { throw CaptureError.notReady }
        guard availableLenses.contains(lens) else { throw CaptureError.lensUnavailable }
        guard availableTargets(for: lens, orientation: orientation).contains(target),
              let wideFOV = CameraService.horizontalFieldOfView(for: .wide),
              let lensFOV = CameraService.horizontalFieldOfView(for: lens),
              let newPlan = CapturePlan.make(
                lens: lens,
                target: target,
                orientation: orientation,
                wideHorizontalFOV: wideFOV,
                lensHorizontalFOV: lensFOV
              ) else { throw CaptureError.targetUnavailable }

        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        clearMotionReading()
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            try await camera.configure(lens: lens, orientation: orientation)
            guard generation == lifecycleGeneration else { return }
            try motion.start(orientation: orientation)
            let now = Date()
            let fresh = CaptureSessionSnapshot(
                sessionID: UUID(),
                plan: newPlan,
                slots: newPlan.makeSlots(),
                currentPass: 1,
                isPassOpen: true,
                retakeCount: 0,
                createdAt: now,
                updatedAt: now
            )
            try store.create(fresh)
            snapshot = fresh
            selectedSlotID = nil
            resetGuidance()
            publish(fresh)
            status = .ready
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Takes one full-quality still after the phone has settled on the target.
    /// Failed captures leave the slot untouched and may be retried.
    @discardableResult
    func captureCurrentView() async throws -> CapturedFrame {
        guard status == .ready, !captureRequested, var sessionSnapshot = snapshot else {
            throw CaptureError.notReady
        }
        guard completedCount > 0 || firstCenterArmed else { throw CaptureError.notReady }
        guard let slot = currentSlot,
              let index = sessionSnapshot.slots.firstIndex(where: { $0.id == slot.id }) else {
            throw CaptureError.noCurrentSlot
        }
        guard let guidance, guidance.slotID == slot.id else {
            throw CaptureError.notAligned
        }
        guard guidance.isOrientationValid else { throw CaptureError.orientationChanged }
        guard guidance.canCapture else {
            throw CaptureError.notAligned
        }
        let previous = sessionSnapshot.slots[index].frame
        if previous != nil && sessionSnapshot.retakeCount >= maximumRetakes {
            throw CaptureError.retakeLimitReached
        }

        captureRequested = true
        defer { captureRequested = false }
        try await camera.prepareForCapture()
        guard status == .ready,
              let latestGuidance = self.guidance,
              latestGuidance.slotID == slot.id,
              let reading = latestReading else {
            throw CaptureError.notAligned
        }
        guard latestGuidance.isOrientationValid else { throw CaptureError.orientationChanged }
        guard latestGuidance.canCapture, readingIsFresh(reading) else { throw CaptureError.notAligned }
        status = .capturing
        var newPhotoURL: URL?
        do {
            let data = try await camera.capturePhoto()
            guard status == .capturing, let after = latestReading,
                  readingIsFresh(after) else {
                throw CaptureError.notReady
            }
            guard after.orientationMatchesConfiguration,
                  abs(after.rollDegrees) < 8 else {
                throw CaptureError.orientationChanged
            }
            guard abs(after.yawDegrees - reading.yawDegrees) < 3,
                  abs(after.pitchDegrees - reading.pitchDegrees) < 3,
                  after.angularSpeed < 0.20 else {
                throw CaptureError.notAligned
            }
            let id = UUID()
            let url = try store.writePhoto(data, id: id)
            newPhotoURL = url
            let quality = PhotoQualityAnalyzer.analyze(data)
            let frame = CapturedFrame(
                id: id,
                slotID: slot.id,
                fileURL: url,
                pass: sessionSnapshot.currentPass,
                capturedAt: Date(),
                yawDegrees: reading.yawDegrees,
                pitchDegrees: reading.pitchDegrees,
                rollDegrees: reading.rollDegrees,
                sharpnessScore: quality.sharpness,
                meanBrightness: quality.brightness,
                quality: quality.quality
            )
            sessionSnapshot.slots[index].frame = frame
            if previous != nil { sessionSnapshot.retakeCount += 1 }
            sessionSnapshot.updatedAt = Date()
            try store.save(sessionSnapshot)
            snapshot = sessionSnapshot
            publish(sessionSnapshot)
            if let previous { store.removePhoto(at: previous.fileURL) }
            selectedSlotID = nil
            resetGuidance()
            if status == .capturing { status = .ready }
            return frame
        } catch {
            if let newPhotoURL { store.removePhoto(at: newPhotoURL) }
            if status == .capturing { status = .ready }
            throw error
        }
    }

    /// The first photo is deliberately manual. The user's tap fixes the center
    /// of the sweep from the composed live preview, then waits for a steady
    /// phone before taking that photo. Later views may be captured automatically.
    @discardableResult
    func anchorCenterAndCapture() async throws -> CapturedFrame {
        guard status == .ready, currentPass == 1, completedCount == 0,
              !isCenterAnchoring, !captureRequested,
              let plan, let currentSlot,
              currentSlot.id == "r\(plan.rows / 2)c\(plan.columns / 2)" else {
            throw CaptureError.notReady
        }
        guard let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        guard reading.orientationMatchesConfiguration else {
            throw CaptureError.orientationChanged
        }
        isCenterAnchoring = true
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration { isCenterAnchoring = false }
        }
        try motion.recenter()
        resetGuidance()

        let deadline = CACurrentMediaTime() + 4
        while CACurrentMediaTime() < deadline {
            guard generation == lifecycleGeneration else { throw CancellationError() }
            guard status == .ready else { throw CaptureError.notReady }
            if guidance?.canCapture == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard guidance?.canCapture == true else { throw CaptureError.notAligned }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        firstCenterArmed = true
        defer { firstCenterArmed = false }
        return try await captureCurrentView()
    }

    /// Completes a pass only when every planned view has a durable photo.
    @discardableResult
    func finishPass() throws -> CaptureSessionSnapshot {
        guard var saved = snapshot else { throw CaptureError.notReady }
        guard saved.isComplete else { throw CaptureError.incompletePass }
        guard status == .ready || status == .reviewing else { throw CaptureError.notReady }
        saved.isPassOpen = false
        saved.updatedAt = Date()
        try store.save(saved)
        snapshot = saved
        motion.suspendSampling()
        camera.pause()
        guidance = nil
        status = .reviewing
        return saved
    }

    /// The second pass lets the user replace weak images or manually selected
    /// views. The six-replacement cap includes retakes from both passes.
    func beginRefinementPass() async throws {
        guard var saved = snapshot, saved.isComplete, status == .reviewing else {
            throw CaptureError.notReady
        }
        guard saved.retakeCount < maximumRetakes else {
            throw CaptureError.retakeLimitReached
        }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        clearMotionReading()
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation)
            guard generation == lifecycleGeneration else { return }
            let needsCalibration = !motion.isActive || !motion.hasReference
            try motion.start(orientation: saved.plan.orientation, resetReference: false)
            saved.currentPass = 2
            saved.isPassOpen = true
            saved.updatedAt = Date()
            try store.save(saved)
            snapshot = saved
            publish(saved)
            selectedSlotID = nil
            resetGuidance()
            status = needsCalibration && !saved.frames.isEmpty ? .recalibrating : .ready
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Selects a missing or previously captured view. Replacement is charged
    /// against the retake allowance only after its new photo is saved.
    func retake(slotID: String) throws {
        guard status == .ready, let slot = slots.first(where: { $0.id == slotID }) else {
            throw CaptureError.invalidSlot
        }
        if slot.frame != nil && remainingRetakes <= 0 {
            throw CaptureError.retakeLimitReached
        }
        if completedCount == 0, let plan,
           slotID != "r\(plan.rows / 2)c\(plan.columns / 2)" {
            throw CaptureError.notReady
        }
        selectedSlotID = slotID
        resetGuidance()
    }

    func pause() {
        lifecycleGeneration += 1
        motion.stop()
        camera.pause()
        clearMotionReading()
        isCenterAnchoring = false
        firstCenterArmed = false
        status = snapshot == nil ? .idle : .paused
    }

    func resume() async throws {
        guard let saved = snapshot else { throw CaptureError.noSavedSession }
        guard status == .paused || status.isFailure else { throw CaptureError.notReady }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        clearMotionReading()
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            if !saved.isPassOpen {
                status = .reviewing
            } else {
                try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation)
                guard generation == lifecycleGeneration else { return }
                try motion.start(orientation: saved.plan.orientation)
                resetGuidance()
                status = saved.frames.isEmpty ? .ready : .recalibrating
            }
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// After a cold resume, the user aligns the live preview with the central
    /// reference photo before fixing the new motion origin.
    func confirmReferenceAlignment() throws {
        guard status == .recalibrating, calibrationFrameURL != nil else {
            throw CaptureError.notReady
        }
        guard let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        guard reading.orientationMatchesConfiguration else {
            throw CaptureError.orientationChanged
        }
        guard reading.angularSpeed < 0.20 else { throw CaptureError.notAligned }
        try motion.recenter()
        resetGuidance()
        status = .ready
    }

    /// Call after successful export or when the user abandons the session.
    func discard() {
        lifecycleGeneration += 1
        motion.stop()
        camera.pause()
        store.discard()
        snapshot = nil
        selectedSlotID = nil
        latestReading = nil
        firstCenterArmed = false
        isCenterAnchoring = false
        plan = nil
        slots = []
        guidance = nil
        currentPass = 1
        orientationNeedsCorrection = false
        status = .idle
    }

    private func publish(_ saved: CaptureSessionSnapshot) {
        plan = saved.plan
        slots = saved.slots
        currentPass = saved.currentPass
    }

    private func resetGuidance() {
        guidance = nil
        stableSince = nil
        previousGuidedSlotID = nil
    }

    private func clearMotionReading() {
        latestReading = nil
        orientationNeedsCorrection = false
        resetGuidance()
    }

    private func updateGuidance(_ reading: MotionReading) {
        latestReading = reading
        let fresh = readingIsFresh(reading)
        let needsOrientationCorrection = !reading.orientationMatchesConfiguration
            || abs(reading.rollDegrees) >= 8
        if orientationNeedsCorrection != needsOrientationCorrection {
            orientationNeedsCorrection = needsOrientationCorrection
        }
        guard status == .ready, let slot = currentSlot, let plan else {
            if guidance != nil { guidance = nil }
            return
        }
        if previousGuidedSlotID != slot.id {
            previousGuidedSlotID = slot.id
            stableSince = nil
        }
        let horizontalError = slot.yawDegrees - reading.yawDegrees
        let verticalError = slot.pitchDegrees - reading.pitchDegrees
        let tolerance = min(4.0, max(2.5, min(plan.horizontalStep, plan.verticalStep) * 0.35))
        let aligned = abs(horizontalError) <= tolerance
            && abs(verticalError) <= tolerance
            && !orientationNeedsCorrection && fresh
        let settled = aligned && reading.angularSpeed < 0.12
        let now = CACurrentMediaTime()
        if settled {
            if stableSince == nil { stableSince = now }
        } else {
            stableSince = nil
        }
        guidance = CaptureGuidance(
            slotID: slot.id,
            horizontalErrorDegrees: horizontalError,
            verticalErrorDegrees: verticalError,
            rollDegrees: reading.rollDegrees,
            isOrientationValid: !orientationNeedsCorrection,
            isAligned: aligned,
            isStable: settled && now - (stableSince ?? now) >= 0.4,
            actualYawDegrees: reading.yawDegrees,
            actualPitchDegrees: reading.pitchDegrees
        )
    }

    private func readingIsFresh(_ reading: MotionReading) -> Bool {
        let age = CACurrentMediaTime() - reading.sampleTimestamp
        return age > -0.1 && age < 0.3
    }

    private func ensureCameraPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CaptureError.cameraPermissionDenied
            }
        default:
            throw CaptureError.cameraPermissionDenied
        }
    }
}
