import SwiftUI
import AVFoundation
import Combine

struct CaptureResult: Identifiable {
    let id = UUID()
    let image: StitchResult
    let lensName: String
    let isDemo: Bool
}

@MainActor
final class CaptureModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, capturing, assembling, denied, unavailable }
    let camera = CameraService()
    private let motion = MotionTracker()
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLens: CameraLens?
    @Published var sweepSize: SweepSize = .wide
    @Published private(set) var reading = MotionReading()
    @Published private(set) var progress = 0.0
    @Published private(set) var frameCount = 0
    @Published private(set) var guidance = "Pivotez doucement, le regard vers l’horizon."
    @Published private(set) var isDemo = false
    @Published var errorMessage: String?
    @Published var result: CaptureResult?
    private var tracker = SweepTracker(target: 40, step: 10)
    private var frames: [CapturedFrame] = []
    private var captureInFlight = false
    private var runID = UUID()
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var notifications = Set<AnyCancellable>()
    private var isActive = true
    private var configuring = false

    var targetDegrees: Double { sweepSize.degrees(telephoto: selectedLens?.isTelephoto ?? false) }
    var isBusy: Bool { phase == .capturing || phase == .assembling || phase == .loading }
    var canFinish: Bool { frameCount >= 3 && !captureInFlight }

    init() {
        #if targetEnvironment(simulator)
        isDemo = true
        #endif
        if ProcessInfo.processInfo.arguments.contains("--demo") { isDemo = true }
        motion.onUpdate = { [weak self] reading in self?.receive(reading) }
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            NotificationCenter.default.publisher(for: name, object: camera.session)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    guard let self else { return }
                    if self.phase == .capturing { self.cancel(); self.errorMessage = CaptureFailure.interrupted.localizedDescription }
                    if self.phase == .ready { self.phase = .unavailable }
                }.store(in: &notifications)
        }
        NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: camera.session)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.isActive, self.phase == .unavailable else { return }
                Task { await self.prepare() }
            }.store(in: &notifications)
    }

    func prepare() async {
        isActive = true
        guard !configuring, phase != .capturing, phase != .assembling else { return }
        configuring = true
        defer { configuring = false }
        if isDemo {
            lenses = [CameraLens(id: "demo", name: "Principal", isTelephoto: false, horizontalFieldOfView: 52)]
            selectedLens = lenses.first
            phase = .ready
            return
        }
        phase = .loading
        guard await CameraService.requestAccess() else { phase = .denied; return }
        guard isActive else { return }
        do {
            lenses = try await camera.configure(lensID: selectedLens?.id)
            guard isActive else { camera.stop(); return }
            selectedLens = lenses.first(where: { $0.id == selectedLens?.id }) ?? lenses.first
            guard motion.isAvailable else { throw CaptureFailure.motionUnavailable }
            motion.start()
            phase = .ready
        } catch { phase = .unavailable; errorMessage = error.localizedDescription }
    }

    func chooseLens(_ lens: CameraLens) async {
        guard phase == .ready, selectedLens != lens else { return }
        let old = selectedLens
        selectedLens = lens
        await prepare()
        if phase != .ready { selectedLens = old }
    }

    func start() {
        guard phase == .ready else { return }
        if !isDemo, !motion.hasReading { errorMessage = "Le capteur de mouvement se prépare. Réessayez dans un instant."; return }
        runID = UUID()
        let id = runID
        frames = []; frameCount = 0; progress = 0; reading = MotionReading()
        tracker = SweepTracker(target: targetDegrees, step: min(11, max(3, (selectedLens?.horizontalFieldOfView ?? 50) * 0.24)))
        phase = .capturing
        guidance = "Stabilisez l’iPhone pour la première photo."
        UIApplication.shared.isIdleTimerDisabled = true
        if isDemo {
            worker = Task {
                do {
                    let demoFrames = try DemoScene.frames()
                    for frame in demoFrames {
                        try await Task.sleep(for: .milliseconds(420))
                        guard runID == id else { return }
                        frames.append(frame); frameCount = frames.count
                        progress = Double(frameCount) / Double(demoFrames.count)
                        guidance = "Démonstration · capture des images"
                    }
                    finish()
                } catch { if runID == id { cancel() } }
            }
            return
        }
        captureInFlight = true
        Task {
            do {
                try await camera.setLocked(true)
                guard runID == id, phase == .capturing else { try? await camera.setLocked(false); return }
                motion.reset()
                let data = try await camera.capture()
                guard runID == id, phase == .capturing else { return }
                frames.append(CapturedFrame(data: data, angle: 0)); frameCount = 1
                captureInFlight = false
                guidance = "Pivotez lentement vers la gauche ou la droite."
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch { fail(error, id: id) }
        }
        timeout = Task {
            try? await Task.sleep(for: .seconds(65))
            guard !Task.isCancelled, runID == id, phase == .capturing else { return }
            if canFinish { finish() }
            else { fail(CaptureFailure.insufficientFrames, id: id) }
        }
    }

    private func receive(_ value: MotionReading) {
        reading = value
        guard phase == .capturing, !isDemo, frameCount > 0 else { return }
        tracker.update(angle: value.angle)
        progress = tracker.progress
        let maxGap = (selectedLens?.horizontalFieldOfView ?? 50) * 0.52
        if tracker.gap(angle: value.angle) > maxGap {
            fail(CaptureFailure.excessiveMotion, id: runID); return
        }
        guard abs(value.pitch) < 7, abs(value.roll) < 7 else { guidance = "Gardez la même hauteur et redressez l’iPhone."; return }
        guard value.speed < (selectedLens?.isTelephoto == true ? 9 : 15) else { guidance = "Ralentissez pour une image bien nette."; return }
        guard !tracker.isReversing(angle: value.angle) else { guidance = "Continuez dans le même sens."; return }
        guidance = tracker.direction == 0 ? "Pivotez lentement vers la gauche ou la droite." : "Très bien. Continuez à pivoter doucement."
        guard !captureInFlight, tracker.shouldCapture(angle: value.angle) else { return }
        let id = runID, angle = value.angle
        captureInFlight = true
        Task {
            do {
                let data = try await camera.capture()
                guard runID == id, phase == .capturing else { return }
                frames.append(CapturedFrame(data: data, angle: angle)); frameCount = frames.count
                tracker.didCapture(angle: angle)
                captureInFlight = false
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                if tracker.lastCapture >= targetDegrees || frames.count >= 18 { finish() }
            } catch { fail(error, id: id) }
        }
    }

    func finish() {
        guard phase == .capturing, canFinish else { return }
        timeout?.cancel()
        phase = .assembling; progress = 0
        UIApplication.shared.isIdleTimerDisabled = false
        let id = runID, captured = frames
        let name = selectedLens?.name ?? "Principal", demo = isDemo
        frames = []
        Task { try? await camera.setLocked(false) }
        worker = Task {
            let processing = Task.detached(priority: .userInitiated) {
                try PanoramaStitcher.stitch(captured) { value in
                    Task { @MainActor in if self.runID == id { self.progress = value } }
                }
            }
            do {
                let image = try await withTaskCancellationHandler { try await processing.value } onCancel: { processing.cancel() }
                guard runID == id, !Task.isCancelled else { return }
                result = CaptureResult(image: image, lensName: name, isDemo: demo)
                phase = .ready
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { if !Task.isCancelled { fail(error, id: id) } }
        }
    }

    func cancel() {
        runID = UUID(); worker?.cancel(); timeout?.cancel()
        frames = []; frameCount = 0; progress = 0; captureInFlight = false
        phase = .ready
        guidance = "Pivotez doucement, le regard vers l’horizon."
        UIApplication.shared.isIdleTimerDisabled = false
        Task { if !isDemo { try? await camera.setLocked(false) } }
    }

    func suspend() {
        isActive = false
        if phase == .capturing { cancel(); errorMessage = CaptureFailure.interrupted.localizedDescription }
        motion.stop(); camera.stop()
    }

    private func fail(_ error: Error, id: UUID) {
        guard runID == id else { return }
        cancel(); errorMessage = error.localizedDescription
    }
}
