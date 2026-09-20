import CoreMotion
import simd

struct MotionReading {
    var angle = 0.0
    var pitch = 0.0
    var roll = 0.0
    var speed = 0.0
}

@MainActor
final class MotionTracker {
    private let manager = CMMotionManager()
    private var origin: simd_quatd?
    private var latest: simd_quatd?
    var onUpdate: ((MotionReading) -> Void)?
    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var hasReading: Bool { latest != nil }

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let q = motion.attitude.quaternion
                let current = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
                self.latest = current
                guard let origin = self.origin else { return }
                let relative = origin.inverse * current
                let forward = relative.act(SIMD3<Double>(0, 0, -1))
                let up = relative.act(SIMD3<Double>(0, 1, 0))
                let degrees = 180.0 / Double.pi
                self.onUpdate?(MotionReading(
                    angle: atan2(-forward.x, -forward.z) * degrees,
                    pitch: atan2(forward.y, hypot(forward.x, forward.z)) * degrees,
                    roll: atan2(-up.x, up.y) * degrees,
                    speed: sqrt(pow(motion.rotationRate.x, 2) + pow(motion.rotationRate.y, 2) + pow(motion.rotationRate.z, 2)) * degrees
                ))
            }
        }
    }

    func reset() { origin = latest }
    func stop() { manager.stopDeviceMotionUpdates(); origin = nil; latest = nil }
}
