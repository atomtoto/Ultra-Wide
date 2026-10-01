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
    @Published private(set) var assemblyPreview: CGImage?
    @Published private(set) var visualCoverage: VisualSweepCoverage?
    @Published private(set) var isVerifyingAlignment = false
    @Published private(set) var orientationNeedsCorrection = false
    @Published private(set) var orientationCorrection: CaptureError?
    @Published private(set) var isCenterAnchoring = false
    @Published private(set) var isFinishingSweep = false
    @Published private(set) var currentPass = 1

    let maximumFrames = 60
    let maximumRetakes = 60
    private let camera: any CameraCapturing
    private let motion: any CaptureMotionProviding
    private let store: CaptureSessionStore
    private let visualAssembler: any SweepAssembling
    private var progressiveUpdate: ProgressiveSweepUpdate?
    private var alignmentTask: Task<Void, Never>?
    private var pendingAlignmentSnapshot: CaptureSessionSnapshot?
    private var snapshot: CaptureSessionSnapshot?
    private var tracker: CoverageTracker?
    private var latestReading: MotionReading?
    private var captureRequested = false
    private var lifecycleGeneration = 0
    private var lastAttemptAt: TimeInterval = 0
    private var lastVisualSelectionAt: TimeInterval = 0
    private var consecutiveMissingFrames = 0
    private let frameQueue = SweepFrameQueue()
    private var automaticFinishRequested = false
    private var finishInProgress = false
    private var repairMode = false
    private var repairFrameCount = 0
    private var repairEdgeFrameCount = 0
    private var referenceYawOffset = 0.0
    private var referencePitchOffset = 0.0
    private var observers: [NSObjectProtocol] = []

    var previewSession: AVCaptureSession { camera.session }
    var availableLenses: [CaptureLens] { camera.supportedLenses }
    var currentSnapshot: CaptureSessionSnapshot? { snapshot }
    var preparedFocalRatio: Double? {
        guard let plan, preparedStitchInputs != nil else { return nil }
        return 1 / (2 * tan(plan.targetVerticalFOV * .pi / 360))
    }
    var preparedStitchInputs: [StitchInput]? {
        guard let saved = snapshot, let update = progressiveUpdate,
              update.sessionID == saved.sessionID else { return nil }
        let inputs = saved.frames.compactMap { frame -> StitchInput? in
            guard let alignment = update.alignments[frame.id] else { return nil }
            return StitchInput(url: frame.fileURL, yawRadians: frame.yawDegrees * .pi / 180,
                pitchRadians: frame.pitchDegrees * .pi / 180, rollRadians: frame.rollDegrees * .pi / 180,
                alignment: alignment)
        }
        return inputs.count >= 2 ? inputs : nil
    }
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
    var completedCount: Int { (snapshot?.frames.count ?? 0) + frameQueue.count }
    var currentSlot: CaptureSlot? { nil }

    private func orientationCorrection(for reading: MotionReading) -> CaptureError? {
        if !reading.orientationMatchesConfiguration { return .orientationChanged }
        // Preview has no fixed center: the shutter tap will define its roll.
        if snapshot != nil && abs(reading.rollDegrees) >= SweepCapturePolicy.maximumRollDegrees {
            return .excessiveRoll
        }
        return nil
    }

    init(camera: (any CameraCapturing)? = nil,
         motion: (any CaptureMotionProviding)? = nil,
         store: CaptureSessionStore? = nil,
         visualAssembler: (any SweepAssembling)? = nil) {
        self.camera = camera ?? CameraService()
        self.motion = motion ?? MotionGuide()
        self.store = store ?? CaptureSessionStore()
        self.visualAssembler = visualAssembler ?? ProgressiveSweepAssembler()
        self.motion.onReading = { [weak self] reading in self?.updateReading(reading) }
        frameQueue.onCompletion = { [weak self] in self?.selectedFrameFinished() }
        if let saved = try? self.store.load() {
            snapshot = saved
            tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            repairMode = saved.currentPass > 1
            publish(saved)
            coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
            status = .paused
        }
        let interruption = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: self.camera.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
        }
        let runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: self.camera.session,
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
        guard let wideFOV = camera.fieldOfView(for: .wide),
              let lensFOV = camera.fieldOfView(for: lens) else { return [] }
        return CaptureTarget.allCases.filter {
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

    /// A 4:3 still from this physical lens already spans the requested field.
    /// The video sweep is only needed when the target is wider than the lens.
    var singlePhotoCropFactor: Double? {
        guard let plan,
              let wideFOV = camera.fieldOfView(for: .wide) else { return nil }
        let lensFOV = plan.orientation.isPortrait
            ? plan.sourceVerticalFOV : plan.sourceHorizontalFOV
        let factor = plan.target.zoomFactor(wideHorizontalFOV: wideFOV,
                                            lensHorizontalFOV: lensFOV)
        return factor >= 0.995 ? max(1, factor) : nil
    }

    func captureSinglePhoto(to baseURL: URL) async throws -> SinglePhotoResult {
        guard status == .ready, snapshot == nil, !captureRequested,
              let factor = singlePhotoCropFactor else { throw CaptureError.notReady }
        captureRequested = true
        defer { captureRequested = false }
        let result = try await camera.captureSinglePhoto(
            to: baseURL, cropFactor: factor
        )
        camera.pause()
        motion.stop()
        status = .idle
        return result
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
        cancelAlignment()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        latestReading = nil
        orientationNeedsCorrection = false
        orientationCorrection = nil
        referenceYawOffset = 0
        referencePitchOffset = 0
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            let wideFOV = camera.fieldOfView(for: .wide)
            let lensFOV = camera.fieldOfView(for: lens)
            let desiredZoom: Double
            if let wideFOV, let lensFOV {
                desiredZoom = max(1, target.zoomFactor(wideHorizontalFOV: wideFOV,
                                                       lensHorizontalFOV: lensFOV))
            } else {
                desiredZoom = 1
            }
            try await camera.configure(lens: lens, orientation: orientation,
                                       zoomFactor: desiredZoom)
            guard generation == lifecycleGeneration else { return }
            let aspect = try await camera.videoLandscapeAspectRatio()
            guard generation == lifecycleGeneration else { return }
            guard let wideFOV = camera.fieldOfView(for: .wide),
                  let lensFOV = camera.fieldOfView(for: lens),
                  let newPlan = CapturePlan.make(
                    lens: lens,
                    target: target,
                    orientation: orientation,
                    wideHorizontalFOV: wideFOV,
                    lensHorizontalFOV: lensFOV,
                    sourceLandscapeAspectRatio: aspect
                  ) else { throw CaptureError.targetUnavailable }
            if target.zoomFactor(wideHorizontalFOV: wideFOV,
                                 lensHorizontalFOV: lensFOV) < 0.995 {
                try motion.start(orientation: orientation, resetReference: true)
            } else {
                motion.stop()
            }
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
        isCenterAnchoring = true
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration { isCenterAnchoring = false }
        }
        // A rotation just before the tap may have restarted motion sampling.
        // Give the first reading time to arrive before defining the center.
        if snapshot == nil && latestReading == nil {
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(33))
                guard generation == lifecycleGeneration, status == .ready else {
                    throw CancellationError()
                }
                if latestReading != nil { break }
            }
        }
        guard let reading = latestReading, readingIsFresh(reading) else {
            throw CaptureError.notReady
        }
        if let correction = orientationCorrection(for: reading) { throw correction }
        // Apply stable exposure before the central source. The camera waits
        // only for a buffer using the new settings; acquisition then runs freely.
        do { try await camera.prepareForSweep() }
        catch {
            guard generation == lifecycleGeneration, status == .ready else { return }
            throw error
        }
        guard generation == lifecycleGeneration, status == .ready else { return }
        // The tap defines the center, including the pose of its first image.
        // Recenter publishes an explicit zero pose from this same motion sample.
        let tappedCenter = (snapshot?.frames.isEmpty ?? true) ? try motion.recenter() : nil
        guard generation == lifecycleGeneration, status == .ready,
              let centerReading = tappedCenter ?? latestReading,
              readingIsFresh(centerReading) else {
            throw CaptureError.notReady
        }
        if let correction = orientationCorrection(for: centerReading) { throw correction }

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
        automaticFinishRequested = false
        isFinishingSweep = false
        coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
        status = .capturing
        if let saved = snapshot, !saved.frames.isEmpty { scheduleAlignment(saved) }
        // Select the video buffer while the phone still points at the center.
        // Encoding and saving may finish after the user begins moving.
        captureRequested = true
        lastAttemptAt = CACurrentMediaTime()
        _ = await captureCandidate(centerReading, allowLowQuality: completedCount == 0)
        guard generation == lifecycleGeneration, status == .capturing else { return }
    }

    /// Ends the sweep manually. The full target might still be incomplete;
    /// the user can continue from the review without losing selected frames.
    @discardableResult
    func stopSweep() async throws -> CaptureSessionSnapshot {
        guard snapshot != nil, completedCount >= 2, !finishInProgress,
              status == .capturing || status == .ready else {
            throw CaptureError.incompletePass
        }
        finishInProgress = true
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration {
                finishInProgress = false
                isFinishingSweep = false
            }
        }
        isFinishingSweep = true
        camera.pause()
        motion.suspendSampling()
        // Flush selected buffers before exposing their durable files to export.
        await frameQueue.drain()
        // Registration has already advanced during capture. Flush only its
        // remaining coalesced update before handing prepared geometry to export.
        await drainAlignment()
        guard generation == lifecycleGeneration,
              status == .capturing || status == .ready,
              var saved = snapshot, saved.frames.count >= 2 else {
            throw CaptureError.notReady
        }
        saved.isPassOpen = false
        saved.coverageFraction = visualCoverage?.fraction ?? 0
        saved.updatedAt = Date()
        try await store.saveAsync(saved)
        guard generation == lifecycleGeneration else { throw CaptureError.notReady }
        snapshot = saved
        lifecycleGeneration += 1
        captureRequested = false
        finishInProgress = false
        isFinishingSweep = false
        isCenterAnchoring = false
        automaticFinishRequested = false
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
        cancelAlignment()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .preparing
        latestReading = nil
        do {
            try await ensureCameraPermission()
            guard generation == lifecycleGeneration else { return }
            try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation, zoomFactor: 1)
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
            let polygons = progressiveUpdate.flatMap {
                $0.sessionID == saved.sessionID ? $0.polygonsByFrame : nil
            }
            let repairSnapshot = saved
            let targetCount = maximumFrames - 4
            let reclaimed = try await Task.detached(priority: .userInitiated) {
                try Self.reclaimRepairCapacity(in: repairSnapshot, targetCount: targetCount,
                                              polygonsByFrame: polygons)
            }.value
            guard generation == lifecycleGeneration else { return }
            saved = reclaimed.snapshot
            let retiredURLs = reclaimed.retiredURLs
            saved.currentPass = 2
            saved.isPassOpen = true
            saved.updatedAt = Date()
            try store.save(saved)
            retiredURLs.forEach { store.removePhoto(at: $0) }
            snapshot = saved
            publish(saved)
            visualCoverage = confirmedCoverage(in: saved)
            if !retiredURLs.isEmpty { assemblyPreview = nil }
            tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            coverage = tracker?.coverage(viewYaw: 0, viewPitch: 0)
            repairMode = true
            repairFrameCount = 0
            repairEdgeFrameCount = 0
            consecutiveMissingFrames = 0
            status = needsCalibration ? .recalibrating : .ready
            scheduleAlignment(saved)
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
    func finishPass() async throws -> CaptureSessionSnapshot { try await stopSweep() }

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
        guard status == .capturing, !captureRequested, !isFinishingSweep, !frameQueue.isFull,
              completedCount < maximumFrames,
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
        saved.coverageFraction = confirmedCoverage(in: saved)?.fraction ?? 0
        try store.save(saved)
        store.removePhoto(at: old.fileURL)
        snapshot = saved
        tracker = newTracker
        visualCoverage = confirmedCoverage(in: saved)
        assemblyPreview = nil
        publish(saved)
        scheduleAlignment(saved)
        coverage = tracker?.coverage(viewYaw: latestReading?.yawDegrees ?? 0,
                                     viewPitch: latestReading?.pitchDegrees ?? 0)
    }

    func pause() {
        lifecycleGeneration += 1
        cancelAlignment()
        cancelPendingCaptures()
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
        cancelAlignment()
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
                    scheduleAlignment(saved)
                    return
                }
                try await camera.configure(lens: saved.plan.lens, orientation: saved.plan.orientation, zoomFactor: 1)
                guard generation == lifecycleGeneration else { return }
                referenceYawOffset = 0
                referencePitchOffset = 0
                try motion.start(orientation: saved.plan.orientation, resetReference: true)
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
            if !saved.frames.isEmpty { scheduleAlignment(saved) }
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
        do { _ = try motion.recenter() }
        catch {
            referenceYawOffset = previousYawOffset
            referencePitchOffset = previousPitchOffset
            throw error
        }
        status = .ready
    }

    func discard() {
        lifecycleGeneration += 1
        cancelAlignment()
        progressiveUpdate = nil
        visualCoverage = nil
        assemblyPreview = nil
        frameQueue.cancel()
        automaticFinishRequested = false
        finishInProgress = false
        isFinishingSweep = false
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
        orientationCorrection = nil
        status = .idle
    }

    private func publish(_ saved: CaptureSessionSnapshot) {
        plan = saved.plan
        slots = saved.slots
        currentPass = saved.currentPass
    }

    /// Every accepted image overlaps the existing graph. Removing a vertex
    /// that leaves the graph connected makes space without stranding a seam.
    private nonisolated static func reclaimRepairCapacity(
        in original: CaptureSessionSnapshot, targetCount: Int,
        polygonsByFrame: [UUID: [CGPoint]]?
    ) throws -> (snapshot: CaptureSessionSnapshot, retiredURLs: [URL]) {
        var saved = original
        var retiredURLs: [URL] = []
        while saved.frames.count > targetCount {
            try Task.checkCancellation()
            let indexedFrames = saved.slots.enumerated().compactMap { index, slot in
                slot.frame.map { (index, $0) }
            }
            guard let anchor = indexedFrames.min(by: {
                hypot($0.1.yawDegrees, $0.1.pitchDegrees)
                    < hypot($1.1.yawDegrees, $1.1.pitchDegrees)
            })?.1.id else { throw CaptureError.retakeLimitReached }
            let previousFraction = polygonsByFrame.map { polygons in
                VisualSweepCoverage(polygons: saved.frames.compactMap { polygons[$0.id] }).fraction
            }
                ?? CoverageTracker(plan: saved.plan, frames: indexedFrames.map(\.1)).fraction
            var preferred: (slotIndex: Int, fractionLoss: Double, qualityRank: Int)?
            for (slotIndex, frame) in indexedFrames where frame.id != anchor {
                let remaining = indexedFrames.filter { $0.0 != slotIndex }.map(\.1)
                let candidateTracker = CoverageTracker(plan: saved.plan, frames: remaining)
                let projected = polygonsByFrame.map { polygons in
                    remaining.compactMap { polygons[$0.id] }
                }
                let fraction = projected.map { VisualSweepCoverage(polygons: $0).fraction }
                    ?? candidateTracker.fraction
                let option = (
                    slotIndex: slotIndex,
                    fractionLoss: max(0, previousFraction - fraction),
                    qualityRank: frame.quality == .good ? 1 : 0
                )
                if projected.map(projectedFramesRemainConnected) ?? framesRemainConnected(candidateTracker.imageRects),
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
        saved.coverageFraction = polygonsByFrame.map { polygons in
            VisualSweepCoverage(polygons: saved.frames.compactMap { polygons[$0.id] }).fraction
        } ?? 0
        return (saved, retiredURLs)
    }

    private nonisolated static func projectedFramesRemainConnected(_ polygons: [[CGPoint]]) -> Bool {
        guard !polygons.isEmpty else { return true }
        var visited: Set<Int> = [0], frontier = [0]
        while let index = frontier.popLast() {
            for other in polygons.indices where !visited.contains(other) {
                if VisualSweepCoverage.overlap(polygons[index], polygons[other]) >= 0.15 {
                    visited.insert(other); frontier.append(other)
                }
            }
        }
        return visited.count == polygons.count
    }

    private nonisolated static func framesRemainConnected(_ rects: [CGRect]) -> Bool {
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

    private func adjusted(_ raw: MotionReading) -> MotionReading {
        MotionReading(
            yawDegrees: raw.yawDegrees + referenceYawOffset,
            pitchDegrees: raw.pitchDegrees + referencePitchOffset,
            rollDegrees: raw.rollDegrees,
            angularSpeed: raw.angularSpeed,
            orientationMatchesConfiguration: raw.orientationMatchesConfiguration,
            sampleTimestamp: raw.sampleTimestamp
        )
    }

    private func updateReading(_ raw: MotionReading) {
        let reading = adjusted(raw)
        latestReading = reading
        let correction = orientationCorrection(for: reading)
        let wrongOrientation = correction != nil
        if orientationCorrection != correction { orientationCorrection = correction }
        if orientationNeedsCorrection != wrongOrientation {
            orientationNeedsCorrection = wrongOrientation
        }
        guard let tracker, readingIsFresh(reading) else { return }
        let displayed = status == .capturing || snapshot != nil
            ? tracker.coverage(viewYaw: reading.yawDegrees, viewPitch: reading.pitchDegrees)
            : tracker.coverage(viewYaw: 0, viewPitch: 0)
        if coverage != displayed { coverage = displayed }
        guard status == .capturing, !captureRequested, !isFinishingSweep,
              !frameQueue.isFull, !wrongOrientation,
              SweepCapturePolicy.allows(reading),
              completedCount < maximumFrames,
              CACurrentMediaTime() - lastAttemptAt >= SweepCapturePolicy.minimumFrameInterval,
              shouldSelect(reading) else { return }
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
        guard let task = await reserveCandidate(reading, allowLowQuality: allowLowQuality) else { return nil }
        return await task.value
    }

    /// Only the small luma analysis holds the selection latch. JPEG encoding
    /// and disk writes cannot delay the next motion sample.
    private func reserveCandidate(
        _ reading: MotionReading,
        allowLowQuality: Bool
    ) async -> Task<CapturedFrame?, Never>? {
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration { captureRequested = false }
        }
        guard status == .capturing, !isFinishingSweep, !frameQueue.isFull, let saved = snapshot,
              tracker != nil, readingIsFresh(reading),
              reading.orientationMatchesConfiguration,
              abs(reading.rollDegrees) < SweepCapturePolicy.maximumRollDegrees,
              completedCount < maximumFrames else { return nil }
        do {
            let selected = try await camera.selectVideoFrame(near: reading.sampleTimestamp)
            guard generation == lifecycleGeneration, status == .capturing, !isFinishingSweep,
                  snapshot?.sessionID == saved.sessionID,
                  !frameQueue.isFull, completedCount < maximumFrames else { return nil }
            consecutiveMissingFrames = 0
            // The tap fixes the first frame at the center. Subsequent frames
            // use the pose at exposure, including during continuous movement.
            let pose: MotionReading
            if allowLowQuality && saved.frames.isEmpty && frameQueue.count == 0 {
                pose = reading
            } else if let sampled = motion.reading(near: selected.timestamp) {
                pose = adjusted(sampled)
            } else { return nil }
            guard pose.orientationMatchesConfiguration,
                  abs(pose.rollDegrees) < SweepCapturePolicy.maximumRollDegrees,
                  allowLowQuality || SweepCapturePolicy.allows(pose) else { return nil }
            let quality = selected.quality
            guard allowLowQuality || SweepCapturePolicy.shouldEncode(quality) else { return nil }
            // The live tracker includes buffers still waiting for the writer.
            guard let tracker = self.tracker, shouldSelect(pose, rateLimited: false) else { return nil }
            let id = UUID()
            let frame = CapturedFrame(
                id: id,
                slotID: id.uuidString,
                fileURL: store.photoURL(id: id),
                pass: saved.currentPass,
                capturedAt: Date(),
                yawDegrees: pose.yawDegrees,
                pitchDegrees: pose.pitchDegrees,
                rollDegrees: pose.rollDegrees,
                sharpnessScore: quality.sharpness,
                meanBrightness: quality.brightness,
                quality: quality.quality
            )
            guard let task = frameQueue.enqueue(frame, write: { [weak self] in
                await self?.persistCandidate(frame, selected: selected,
                                             sessionID: saved.sessionID, generation: generation)
            }) else { return nil }
            var newTracker = tracker
            newTracker.include(yaw: frame.yawDegrees, pitch: frame.pitchDegrees)
            self.tracker = newTracker
            coverage = newTracker.coverage(viewYaw: latestReading?.yawDegrees ?? pose.yawDegrees,
                                           viewPitch: latestReading?.pitchDegrees ?? pose.pitchDegrees)
            if repairMode {
                repairFrameCount += 1
                let position = tracker.footprint(yaw: frame.yawDegrees, pitch: frame.pitchDegrees)
                if position.midX < 0.35 || position.midX > 0.65
                    || position.midY < 0.35 || position.midY > 0.65 {
                    repairEdgeFrameCount += 1
                }
            }
            if completedCount >= maximumFrames {
                automaticFinishRequested = true
                isFinishingSweep = true
                camera.pause()
                motion.suspendSampling()
            }
            return task
        } catch {
            guard generation == lifecycleGeneration else { return nil }
            // A single missing video sample is normal while moving. Persistent
            // storage/configuration errors remain visible and recoverable.
            if case CaptureError.photoDataUnavailable = error {
                consecutiveMissingFrames += 1
                if consecutiveMissingFrames < 10 { return nil }
                pause()
                status = .failed(CaptureError.cameraUnavailable.localizedDescription)
                return nil
            }
            pause()
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    private func persistCandidate(
        _ frame: CapturedFrame,
        selected: SelectedVideoFrame,
        sessionID: UUID,
        generation: Int
    ) async -> CapturedFrame? {
        func isCurrent() -> Bool {
            generation == lifecycleGeneration && snapshot?.sessionID == sessionID
                && status == .capturing && !Task.isCancelled
        }
        guard isCurrent() else { return nil }
        do {
            let data = try await camera.encodeSelectedFrame(selected)
            guard isCurrent() else { return nil }
            let url = try await store.writePhoto(data, id: frame.id, sessionID: sessionID)
            guard isCurrent(), var saved = snapshot else {
                store.removePhoto(at: url)
                return nil
            }
            let position = CoverageTracker(plan: saved.plan).footprint(
                yaw: frame.yawDegrees, pitch: frame.pitchDegrees
            )
            let column = max(0, min(saved.plan.columns - 1,
                Int(position.midX * Double(saved.plan.columns))))
            let row = max(0, min(saved.plan.rows - 1,
                Int(position.midY * Double(saved.plan.rows))))
            saved.slots.append(CaptureSlot(
                id: frame.slotID, row: row, column: column,
                yawDegrees: frame.yawDegrees, pitchDegrees: frame.pitchDegrees, frame: frame
            ))
            var retiredURLs: [URL] = []
            if let update = progressiveUpdate, update.sessionID == sessionID {
                // Only the image-confirmed reducer can retire views. Unverified
                // new files remain until the worker has actually inspected them.
                let retiredIDs = update.frameIDs.subtracting(update.retainedFrameIDs)
                retiredURLs = saved.frames.filter { retiredIDs.contains($0.id) && $0.id != frame.id }.map(\.fileURL)
                saved.slots.removeAll { $0.frame.map { retiredIDs.contains($0.id) && $0.id != frame.id } ?? false }
            }
            // Only durable files enter the manifest and the stitch snapshot.
            saved.coverageFraction = confirmedCoverage(in: saved)?.fraction ?? 0
            saved.updatedAt = Date()
            do { try await store.saveAsync(saved) }
            catch {
                store.removePhoto(at: url)
                throw error
            }
            guard isCurrent() else {
                store.removePhoto(at: url)
                return nil
            }
            snapshot = saved
            visualCoverage = confirmedCoverage(in: saved)
            retiredURLs.forEach { store.removePhoto(at: $0) }
            publish(saved)
            scheduleAlignment(saved)
            return frame
        } catch {
            guard generation == lifecycleGeneration else { return nil }
            pause()
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    private func selectedFrameFinished() {
        guard status == .capturing, let saved = snapshot else { return }
        let rejected = progressiveUpdate?.rejectedFrameIDs ?? []
        let liveTracker = CoverageTracker(plan: saved.plan,
            frames: saved.frames.filter { !rejected.contains($0.id) } + frameQueue.frames)
        tracker = liveTracker
        coverage = liveTracker.coverage(viewYaw: latestReading?.yawDegrees ?? 0,
                                        viewPitch: latestReading?.pitchDegrees ?? 0)
        if automaticFinishRequested, frameQueue.count == 0, !finishInProgress {
            Task { [weak self] in
                guard let self, self.status == .capturing, !self.finishInProgress else { return }
                do { _ = try await self.stopSweep() }
                catch {
                    guard self.status == .capturing else { return }
                    self.pause()
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func cancelPendingCaptures() {
        let hadPending = frameQueue.count > 0 || finishInProgress
        frameQueue.cancel()
        automaticFinishRequested = false
        finishInProgress = false
        isFinishingSweep = false
        if var saved = snapshot {
            // Serialize this behind any file write already in progress, so a
            // paused session only references the confirmed images on screen.
            let verifiedFraction = confirmedCoverage(in: saved)?.fraction ?? 0
            if hadPending || saved.coverageFraction != verifiedFraction {
                saved.coverageFraction = verifiedFraction
                try? store.save(saved)
                snapshot = saved
            }
            tracker = CoverageTracker(plan: saved.plan, frames: saved.frames)
            coverage = tracker?.coverage(viewYaw: latestReading?.yawDegrees ?? 0,
                                         viewPitch: latestReading?.pitchDegrees ?? 0)
        }
    }

    private func confirmedCoverage(in saved: CaptureSessionSnapshot) -> VisualSweepCoverage? {
        guard let update = progressiveUpdate, update.sessionID == saved.sessionID else { return nil }
        let current = Set(saved.frames.map(\.id))
        if update.polygonsByFrame.keys.allSatisfy({ current.contains($0) }) { return update.coverage }
        return VisualSweepCoverage(polygons: saved.frames.compactMap { update.polygonsByFrame[$0.id] })
    }

    private func shouldSelect(_ reading: MotionReading, rateLimited: Bool = true) -> Bool {
        guard let tracker, let plan else { return false }
        if let rejected = progressiveUpdate?.rejectedFrameIDs,
           snapshot?.frames.contains(where: { frame in
               rejected.contains(frame.id) && Date().timeIntervalSince(frame.capturedAt) < 0.6
                   && hypot((frame.yawDegrees - reading.yawDegrees) / plan.sourceHorizontalFOV,
                            (frame.pitchDegrees - reading.pitchDegrees) / plan.sourceVerticalFOV) < 0.035
                   && abs(frame.rollDegrees - reading.rollDegrees) < 2
           }) == true { return false }
        if tracker.shouldKeep(yaw: reading.yawDegrees, pitch: reading.pitchDegrees, repairMode: repairMode) { return true }
        guard !repairMode, let confirmed = visualCoverage, !confirmed.isComplete,
              let update = progressiveUpdate, let saved = snapshot,
              abs(reading.yawDegrees) + plan.sourceHorizontalFOV / 2 < 86,
              abs(reading.pitchDegrees) + plan.sourceVerticalFOV / 2 < 86 else { return false }
        if rateLimited {
            guard CACurrentMediaTime() - lastVisualSelectionAt >= 0.1 else { return false }
            lastVisualSelectionAt = CACurrentMediaTime()
        }
        // The motion estimate may already be full while the actual projected
        // images leave an edge gap. Continue accepting useful small corrections.
        let acquired = saved.frames.filter { !update.rejectedFrameIDs.contains($0.id) } + frameQueue.frames
        guard acquired.allSatisfy({ frame in
            hypot((frame.yawDegrees - reading.yawDegrees) / plan.sourceHorizontalFOV,
                  (frame.pitchDegrees - reading.pitchDegrees) / plan.sourceVerticalFOV) >= 0.025
                || abs(frame.rollDegrees - reading.rollDegrees) >= 2
        }), let reference = saved.frames.filter({ update.alignments[$0.id] != nil }).min(by: {
            hypot($0.yawDegrees - reading.yawDegrees, $0.pitchDegrees - reading.pitchDegrees)
                < hypot($1.yawDegrees - reading.yawDegrees, $1.pitchDegrees - reading.pitchDegrees)
        }), let alignment = update.alignments[reference.id],
            let polygon = VisualSweepCoverage.footprint(ProgressiveSweepAssembler.predictedTransform(
                reading, relativeTo: reference, alignment: alignment, plan: plan)),
            confirmed.polygons.contains(where: { VisualSweepCoverage.overlap($0, polygon) >= 0.2 }) else { return false }
        return VisualSweepCoverage(polygons: confirmed.polygons + [polygon]).fraction - confirmed.fraction >= 0.0001
    }

    private func scheduleAlignment(_ saved: CaptureSessionSnapshot) {
        pendingAlignmentSnapshot = saved
        isVerifyingAlignment = true
        guard alignmentTask == nil else { return }
        let generation = lifecycleGeneration
        let assembler = visualAssembler
        alignmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.lifecycleGeneration {
                    self.alignmentTask = nil
                    self.isVerifyingAlignment = false
                    if self.automaticFinishRequested { self.selectedFrameFinished() }
                }
            }
            while let next = self.pendingAlignmentSnapshot {
                self.pendingAlignmentSnapshot = nil
                do {
                    let update = try await assembler.update(sessionID: next.sessionID, plan: next.plan, frames: next.frames)
                    guard !Task.isCancelled, generation == self.lifecycleGeneration,
                          self.snapshot?.sessionID == next.sessionID else { return }
                    self.progressiveUpdate = update
                    self.assemblyPreview = update.preview
                    if let current = self.snapshot {
                        self.visualCoverage = self.confirmedCoverage(in: current)
                        let rejected = update.rejectedFrameIDs
                        self.tracker = CoverageTracker(plan: current.plan,
                            frames: current.frames.filter { !rejected.contains($0.id) } + self.frameQueue.frames)
                    }
                    if self.visualCoverage?.isComplete == true, self.status == .capturing,
                       !self.isFinishingSweep,
                       !self.repairMode || (self.repairFrameCount >= 4 && self.repairEdgeFrameCount >= 3) {
                        self.automaticFinishRequested = true
                        self.isFinishingSweep = true
                        self.camera.pause()
                        self.motion.suspendSampling()
                    }
                } catch is CancellationError { return }
                catch {
                    // A transient registration failure does not stop acquisition
                    // or paint motion-estimated regions as verified coverage.
                    guard generation == self.lifecycleGeneration else { return }
                }
            }
        }
    }

    private func drainAlignment() async {
        while let task = alignmentTask { await task.value }
    }

    private func cancelAlignment() {
        alignmentTask?.cancel()
        alignmentTask = nil
        pendingAlignmentSnapshot = nil
        isVerifyingAlignment = false
    }

    private func readingIsFresh(_ reading: MotionReading) -> Bool {
        let age = CACurrentMediaTime() - reading.sampleTimestamp
        return age > -0.1 && age < 0.3
    }

    private func ensureCameraPermission() async throws {
        try await camera.ensurePermission()
    }
}
