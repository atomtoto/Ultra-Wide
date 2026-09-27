import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Main-actor owner of the preview, free sweep, and durable selected frames.
/// The camera streams throughout the sweep; only useful overlapping samples
/// become images for the assembler.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var plan: CapturePlan?
    @Published private(set) var slots: [CaptureSlot] = []
    @Published private(set) var guidance: CaptureGuidance?
    @Published private(set) var coverage: CaptureCoverage?
    @Published private(set) var orientationNeedsCorrection = false
    @Published private(set) var isCenterAnchoring = false
    @Published private(set) var currentPass = 1

    let maximumFrames = 60
    let maximumRetakes = 60
    private let camera = CameraService()
    private let motion = MotionGuide()
    private let store = CaptureSessionStore()
    private var snapshot: CaptureSessionSnapshot?
    private var tracker: CoverageTracker?
    private var latestReading: MotionReading?
    private var captureRequested = false
    private var lifecycleGeneration = 0
    private var lastAttemptAt: TimeInterval = 0
    private var consecutiveMissingFrames = 0
    private var repairMode = false
    private var repairFrameCount = 0
    private var repairEdgeFrameCount = 0
    private var referenceYawOffset = 0.0
    private var referencePitchOffset = 0.0
    private var observers: [NSObjectProtocol] = []

    var previewSession: AVCaptureSession { camera.session }
    var availableLenses: [CaptureLens] { CameraService.availableLenses }
    var currentSnapshot: CaptureSessionSnapshot? { snapshot }
    var hasRecoverableSession: Bool {
        snapshot != nil && (status == .paused || status.isFailure)
    }
    var calibrationFrameURL: URL? {
        guard status == .recalibrating else { return nil }
        return nearestCenterFrame?.fileURL
    }
    private var nearestCenterFrame: CapturedFrame? {
        snapshot?.frames.min {
            hypot($0.yawDegrees, $0.pitchDegrees) < hypot($1.yawDegrees, $1.pitchDegrees)
        }
    }
    var remainingRetakes: Int { max(0, maximumFrames - completedCount) }
    var completedCount: Int { snapshot?.frames.count ?? 0 }
    var currentSlot: CaptureSlot? { nil }

    init() {
        motion.onReading = { [weak self] reading in self?.updateReading(reading) }
        if let saved = try? store.load() {
            snapshot = saved
            tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            repairMode = saved.currentPass > 1
            publish(saved)
            coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
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
        let candidates: [CaptureTarget] = lens == .wide ? [.half] : CaptureTarget.allCases
        return candidates.filter {
            CapturePlan.make(
                lens: lens,
                target: $0,
                orientation: orientation,
                wideHorizontalFOV: wideFOV,
                lensHorizontalFOV: lensFOV,
                sourceLandscapeAspectRatio: 16.0 / 9.0
            ) != nil
        }
    }

    /// Starts live preview before the user's center tap. The plan uses the
    /// measured video buffer ratio, which is often different from a still.
    func preparePreview(
        lens: CaptureLens,
        target: CaptureTarget,
        orientation: CaptureOrientation = .portrait
    ) async throws {
        guard snapshot == nil, !captureRequested, !isCenterAnchoring,
              status == .idle || status == .ready || status.isFailure else {
            throw CaptureError.notReady
        }
        guard availableLenses.contains(lens) else { throw CaptureError.lensUnavailable }
        guard availableTargets(for: lens, orientation: orientation).contains(target) else {
            throw CaptureError.targetUnavailable
        }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        latestReading = nil
        referenceYawOffset = 0
        referencePitchOffset = 0
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            try await camera.configure(lens: lens, orientation: orientation)
            guard generation == lifecycleGeneration else { return }
            let aspect = try await camera.videoLandscapeAspectRatio()
            guard generation == lifecycleGeneration else { return }
            guard let wideFOV = CameraService.horizontalFieldOfView(for: .wide),
                  let lensFOV = CameraService.horizontalFieldOfView(for: lens),
                  let newPlan = CapturePlan.make(
                    lens: lens,
                    target: target,
                    orientation: orientation,
                    wideHorizontalFOV: wideFOV,
                    lensHorizontalFOV: lensFOV,
                    sourceLandscapeAspectRatio: aspect
                  ) else { throw CaptureError.targetUnavailable }
            try motion.start(orientation: orientation)
            plan = newPlan
            tracker = CoverageTracker(plan: newPlan)
            coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
            status = .ready
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Compatibility alias for callers that prepared the previous still mode.
    func start(
        lens: CaptureLens,
        target: CaptureTarget,
        orientation: CaptureOrientation = .portrait
    ) async throws {
        try await preparePreview(lens: lens, target: target, orientation: orientation)
    }

    /// Fixes the motion origin at the composed center and begins a free sweep.
    /// On a resumed session the calibrated origin is retained.
    func beginSweep() async throws {
        guard status == .ready, let plan, !isCenterAnchoring, !captureRequested else {
            throw CaptureError.notReady
        }
        guard completedCount < maximumFrames else { throw CaptureError.retakeLimitReached }
        guard let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        guard reading.orientationMatchesConfiguration, abs(reading.rollDegrees) < 8 else {
            throw CaptureError.orientationChanged
        }
        isCenterAnchoring = true
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration { isCenterAnchoring = false }
        }
        // The tap defines the center, including the pose of its first image.
        // Recenter publishes an explicit zero pose from this same motion sample.
        let tappedCenter = (snapshot?.frames.isEmpty ?? true) ? try motion.recenter() : nil
        guard generation == lifecycleGeneration, status == .ready,
              let centerReading = tappedCenter ?? latestReading,
              readingIsFresh(centerReading) else {
            throw CaptureError.notReady
        }
        guard centerReading.orientationMatchesConfiguration,
              abs(centerReading.rollDegrees) < 8 else {
            throw CaptureError.orientationChanged
        }

        if snapshot == nil {
            let now = Date()
            let fresh = CaptureSessionSnapshot(
                sessionID: UUID(),
                plan: plan,
                slots: [],
                currentPass: 1,
                isPassOpen: true,
                retakeCount: 0,
                coverageFraction: 0,
                createdAt: now,
                updatedAt: now
            )
            try store.create(fresh)
            snapshot = fresh
            tracker = CoverageTracker(plan: plan)
            repairMode = false
            repairFrameCount = 0
            repairEdgeFrameCount = 0
        } else if var saved = snapshot {
            saved.isPassOpen = true
            saved.updatedAt = Date()
            try store.save(saved)
            snapshot = saved
        }
        lastAttemptAt = 0
        consecutiveMissingFrames = 0
        coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
        status = .capturing
        // Select the video buffer while the phone still points at the center.
        // Encoding and saving may finish after the user begins moving.
        captureRequested = true
        lastAttemptAt = CACurrentMediaTime()
        _ = await captureCandidate(centerReading, allowLowQuality: completedCount == 0)
        guard generation == lifecycleGeneration, status == .capturing else { return }
        // This is a quick device lock and is intentionally outside the path
        // that determines the center image.
        Task { [weak self] in
            guard let self, self.lifecycleGeneration == generation,
                  self.status == .capturing else { return }
            try? await self.camera.prepareForSweep()
        }
    }

    /// Ends the sweep manually. The full target might still be incomplete;
    /// the user can continue from the review without losing selected frames.
    @discardableResult
    func stopSweep() throws -> CaptureSessionSnapshot {
        guard var saved = snapshot, saved.frames.count >= 2,
              status == .capturing || status == .ready else {
            throw CaptureError.incompletePass
        }
        saved.isPassOpen = false
        saved.coverageFraction = tracker?.fraction ?? saved.coverageFraction
        saved.updatedAt = Date()
        try store.save(saved)
        snapshot = saved
        lifecycleGeneration += 1
        captureRequested = false
        camera.pause()
        motion.suspendSampling()
        status = .reviewing
        return saved
    }

    /// Opens the same sweep after review or a failed stitch. Existing frames
    /// remain in the connected coverage graph; the next pass must add edge
    /// images before automatic completion can fire again.
    func resumeSweep() async throws {
        guard var saved = snapshot, status == .reviewing else {
            throw CaptureError.notReady
        }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        latestReading = nil
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation)
            guard generation == lifecycleGeneration else { return }
            let needsCalibration = !motion.isActive || !motion.hasReference
            if needsCalibration {
                referenceYawOffset = 0
                referencePitchOffset = 0
            }
            try motion.start(orientation: saved.plan.orientation, resetReference: false)
            // Keep room for the four edge views required by a repair pass.
            // Remove redundant persisted views only after the camera is ready;
            // update the manifest before deleting their JPEGs.
            let retiredURLs = try reclaimRepairCapacity(in: &saved)
            saved.currentPass = 2
            saved.isPassOpen = true
            saved.updatedAt = Date()
            try store.save(saved)
            retiredURLs.forEach { store.removePhoto(at: $0) }
            snapshot = saved
            publish(saved)
            tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
            repairMode = true
            repairFrameCount = 0
            repairEdgeFrameCount = 0
            consecutiveMissingFrames = 0
            status = needsCalibration ? .recalibrating : .ready
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    // Compatibility entry points during migration of the coordinator.
    @discardableResult
    func finishPass() throws -> CaptureSessionSnapshot { try stopSweep() }

    func beginRefinementPass() async throws { try await resumeSweep() }

    @discardableResult
    func anchorCenterAndCapture() async throws -> CapturedFrame {
        try await beginSweep()
        let deadline = CACurrentMediaTime() + 4
        while CACurrentMediaTime() < deadline {
            if let frame = snapshot?.frames.first { return frame }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw CaptureError.notAligned
    }

    @discardableResult
    func captureCurrentView() async throws -> CapturedFrame {
        guard status == .capturing, !captureRequested, completedCount < maximumFrames,
              let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        captureRequested = true
        guard let frame = await captureCandidate(reading) else { throw CaptureError.notAligned }
        return frame
    }

    func retake(slotID: String) throws {
        guard var saved = snapshot,
              let index = saved.slots.firstIndex(where: { $0.id == slotID }),
              let old = saved.slots[index].frame else { throw CaptureError.invalidSlot }
        saved.slots.remove(at: index)
        saved.coverageFraction = nil
        saved.updatedAt = Date()
        let newTracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
        saved.coverageFraction = newTracker.fraction
        try store.save(saved)
        store.removePhoto(at: old.fileURL)
        snapshot = saved
        tracker = newTracker
        publish(saved)
        coverage = tracker?.coverage(viewYaw: latestReading?.yawDegrees ?? 0,
                                     viewPitch: latestReading?.pitchDegrees ?? 0)
    }

    func pause() {
        lifecycleGeneration += 1
        motion.stop()
        camera.pause()
        latestReading = nil
        isCenterAnchoring = false
        captureRequested = false
        consecutiveMissingFrames = 0
        status = snapshot == nil ? .idle : .paused
    }

    func resume() async throws {
        guard var saved = snapshot else { throw CaptureError.noSavedSession }
        guard status == .paused || status.isFailure else { throw CaptureError.notReady }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        latestReading = nil
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            if saved.isPassOpen {
                // A process can exit after persisting the 60th image but
                // before the automatic stop has closed the sweep.
                if saved.frames.count >= maximumFrames {
                    saved.isPassOpen = false
                    saved.updatedAt = Date()
                    try store.save(saved)
                    snapshot = saved
                    status = .reviewing
                    return
                }
                try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation)
                guard generation == lifecycleGeneration else { return }
                referenceYawOffset = 0
                referencePitchOffset = 0
                try motion.start(orientation: saved.plan.orientation)
                tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
                repairMode = saved.currentPass > 1
                repairFrameCount = 0
                repairEdgeFrameCount = 0
                consecutiveMissingFrames = 0
                coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
                status = saved.frames.isEmpty ? .ready : .recalibrating
            } else {
                status = .reviewing
            }
        } catch {
            guard generation == lifecycleGeneration else { return }
            motion.stop()
            camera.pause()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// On a cold resume the closest-to-center saved image is a visual guide.
    func confirmReferenceAlignment() throws {
        guard status == .recalibrating, let referenceFrame = nearestCenterFrame else {
            throw CaptureError.notReady
        }
        guard let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        guard reading.orientationMatchesConfiguration else {
            throw CaptureError.orientationChanged
        }
        guard reading.angularSpeed < 0.25 else { throw CaptureError.notAligned }
        let previousYawOffset = referenceYawOffset
        let previousPitchOffset = referencePitchOffset
        referenceYawOffset = referenceFrame.yawDegrees
        referencePitchOffset = referenceFrame.pitchDegrees
        do { try motion.recenter() }
        catch {
            referenceYawOffset = previousYawOffset
            referencePitchOffset = previousPitchOffset
            throw error
        }
        status = .ready
    }

    func discard() {
        lifecycleGeneration += 1
        motion.stop()
        camera.pause()
        store.discard()
        snapshot = nil
        tracker = nil
        latestReading = nil
        captureRequested = false
        consecutiveMissingFrames = 0
        isCenterAnchoring = false
        repairMode = false
        referenceYawOffset = 0
        referencePitchOffset = 0
        plan = nil
        slots = []
        guidance = nil
        coverage = nil
        currentPass = 1
        orientationNeedsCorrection = false
        status = .idle
    }

    private func publish(_ saved: CaptureSessionSnapshot) {
        plan = saved.plan
        slots = saved.slots
        currentPass = saved.currentPass
    }

    /// Every accepted image overlaps the existing graph. Removing a vertex
    /// that leaves the graph connected makes space without stranding a seam.
    private func reclaimRepairCapacity(in saved: inout CaptureSessionSnapshot) throws -> [URL] {
        var retiredURLs: [URL] = []
        let targetCount = maximumFrames - 4
        while saved.frames.count > targetCount {
            let indexedFrames = saved.slots.enumerated().compactMap { index, slot in
                slot.frame.map { (index, $0) }
            }
            guard let anchor = indexedFrames.min(by: {
                hypot($0.1.yawDegrees, $0.1.pitchDegrees)
                    < hypot($1.1.yawDegrees, $1.1.pitchDegrees)
            })?.1.id else { throw CaptureError.retakeLimitReached }
            let previousFraction = CoverageTracker(plan: saved.plan,
                                                   frames: indexedFrames.map(\.1)).fraction
            var preferred: (slotIndex: Int, fractionLoss: Double, qualityRank: Int)?
            for (slotIndex, frame) in indexedFrames where frame.id != anchor {
                let remaining = indexedFrames.filter { $0.0 != slotIndex }.map(\.1)
                let candidateTracker = CoverageTracker(plan: saved.plan, frames: remaining)
                let option = (
                    slotIndex: slotIndex,
                    fractionLoss: max(0, previousFraction - candidateTracker.fraction),
                    qualityRank: frame.quality == .good ? 1 : 0
                )
                if framesRemainConnected(candidateTracker.imageRects),
                   preferred == nil || option.fractionLoss < preferred!.fractionLoss
                        || (option.fractionLoss == preferred!.fractionLoss
                            && option.qualityRank < preferred!.qualityRank) {
                    preferred = option
                }
            }
            guard let chosen = preferred,
                  let oldFrame = saved.slots[chosen.slotIndex].frame else {
                throw CaptureError.retakeLimitReached
            }
            retiredURLs.append(oldFrame.fileURL)
            saved.slots.remove(at: chosen.slotIndex)
        }
        saved.coverageFraction = CoverageTracker(plan: saved.plan, frames: saved.frames).fraction
        return retiredURLs
    }

    private func framesRemainConnected(_ rects: [CGRect]) -> Bool {
        guard !rects.isEmpty else { return true }
        var visited: Set<Int> = [0]
        var frontier = [0]
        while let index = frontier.popLast() {
            for other in rects.indices where !visited.contains(other) {
                let intersection = rects[index].intersection(rects[other])
                guard !intersection.isNull else { continue }
                let smallerArea = min(rects[index].width * rects[index].height,
                                      rects[other].width * rects[other].height)
                guard smallerArea > 0,
                      intersection.width * intersection.height / smallerArea >= 0.30 else {
                    continue
                }
                visited.insert(other)
                frontier.append(other)
            }
        }
        return visited.count == rects.count
    }

    private func updateReading(_ raw: MotionReading) {
        let reading = MotionReading(
            yawDegrees: raw.yawDegrees + referenceYawOffset,
            pitchDegrees: raw.pitchDegrees + referencePitchOffset,
            rollDegrees: raw.rollDegrees,
            angularSpeed: raw.angularSpeed,
            orientationMatchesConfiguration: raw.orientationMatchesConfiguration,
            sampleTimestamp: raw.sampleTimestamp
        )
        latestReading = reading
        let wrongOrientation = !reading.orientationMatchesConfiguration
            || abs(reading.rollDegrees) >= 8
        if orientationNeedsCorrection != wrongOrientation {
            orientationNeedsCorrection = wrongOrientation
        }
        guard let tracker, readingIsFresh(reading) else { return }
        let displayed = status == .capturing || snapshot != nil
            ? tracker.coverage(viewYaw: reading.yawDegrees, viewPitch: reading.pitchDegrees)
            : tracker.coverage(viewYaw: 0, viewPitch: 0)
        if coverage != displayed { coverage = displayed }
        guard status == .capturing, !captureRequested, !wrongOrientation,
              abs(reading.rollDegrees) < 6,
              reading.angularSpeed < 0.45,
              completedCount < maximumFrames,
              CACurrentMediaTime() - lastAttemptAt >= 0.22,
              tracker.shouldKeep(yaw: reading.yawDegrees,
                                 pitch: reading.pitchDegrees,
                                 repairMode: repairMode) else { return }
        lastAttemptAt = CACurrentMediaTime()
        captureRequested = true
        Task { [weak self] in
            _ = await self?.captureCandidate(reading)
        }
    }

    private func captureCandidate(
        _ reading: MotionReading,
        allowLowQuality: Bool = false
    ) async -> CapturedFrame? {
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration { captureRequested = false }
        }
        guard status == .capturing, var saved = snapshot,
              let tracker, readingIsFresh(reading),
              reading.orientationMatchesConfiguration,
              abs(reading.rollDegrees) < 8,
              saved.frames.count < maximumFrames else { return nil }
        do {
            let data = try await camera.captureVideoFrame(near: reading.sampleTimestamp)
            guard generation == lifecycleGeneration, status == .capturing,
                  snapshot?.sessionID == saved.sessionID,
                  snapshot?.slots.count == saved.slots.count,
                  saved.frames.count < maximumFrames else { return nil }
            consecutiveMissingFrames = 0
            let quality = PhotoQualityAnalyzer.analyze(data)
            guard allowLowQuality || (quality.quality != .soft && quality.quality != .dark) else {
                return nil
            }
            guard tracker.shouldKeep(yaw: reading.yawDegrees,
                                     pitch: reading.pitchDegrees,
                                     repairMode: repairMode) else { return nil }
            let id = UUID()
            let url = try store.writePhoto(data, id: id)
            let frame = CapturedFrame(
                id: id,
                slotID: id.uuidString,
                fileURL: url,
                pass: saved.currentPass,
                capturedAt: Date(),
                yawDegrees: reading.yawDegrees,
                pitchDegrees: reading.pitchDegrees,
                rollDegrees: reading.rollDegrees,
                sharpnessScore: quality.sharpness,
                meanBrightness: quality.brightness,
                quality: quality.quality
            )
            let position = tracker.footprint(yaw: reading.yawDegrees,
                                             pitch: reading.pitchDegrees)
            let column = max(0, min(saved.plan.columns - 1,
                Int(position.midX * Double(saved.plan.columns))))
            let row = max(0, min(saved.plan.rows - 1,
                Int(position.midY * Double(saved.plan.rows))))
            saved.slots.append(CaptureSlot(
                id: frame.slotID, row: row, column: column,
                yawDegrees: frame.yawDegrees, pitchDegrees: frame.pitchDegrees,
                frame: frame
            ))
            let newTracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            saved.coverageFraction = newTracker.fraction
            saved.updatedAt = Date()
            do { try store.save(saved) }
            catch {
                store.removePhoto(at: url)
                throw error
            }
            snapshot = saved
            self.tracker = newTracker
            publish(saved)
            coverage = newTracker.coverage(viewYaw: latestReading?.yawDegrees ?? reading.yawDegrees,
                                           viewPitch: latestReading?.pitchDegrees ?? reading.pitchDegrees)
            if repairMode {
                repairFrameCount += 1
                if position.midX < 0.35 || position.midX > 0.65
                    || position.midY < 0.35 || position.midY > 0.65 {
                    repairEdgeFrameCount += 1
                }
            }
            if saved.frames.count >= maximumFrames || (newTracker.isComplete
                && (!repairMode || (repairFrameCount >= 4 && repairEdgeFrameCount >= 3))) {
                _ = try stopSweep()
            }
            return frame
        } catch {
            guard generation == lifecycleGeneration else { return nil }
            // A single missing video sample is normal while moving. Persistent
            // storage/configuration errors remain visible and recoverable.
            if case CaptureError.photoDataUnavailable = error {
                consecutiveMissingFrames += 1
                if consecutiveMissingFrames < 10 { return nil }
                status = .failed(CaptureError.cameraUnavailable.localizedDescription)
                motion.stop()
                camera.pause()
                return nil
            }
            status = .failed(error.localizedDescription)
            motion.stop()
            camera.pause()
            return nil
        }
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
