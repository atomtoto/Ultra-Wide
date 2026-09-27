import CoreMotion
import Foundation

struct MotionReading: Sendable {
    let yawDegrees: Double
    let pitchDegrees: Double
    let rollDegrees: Double
    let angularSpeed: Double
    let orientationMatchesConfiguration: Bool
    let sampleTimestamp: TimeInterval
}

/// Motion is sampled on the main actor so UI guidance never races with slot
/// changes. The first sample defines the center of the sweep.
@MainActor
final class MotionGuide {
    private let manager = CMMotionManager()
    private var reference: CMRotationMatrix?
    private var matrixMapsDeviceToReference: Bool?
    private var orientation: CaptureOrientation = .portrait
    private var samplingTask: Task<Void, Never>?
    private var referenceExpiryTask: Task<Void, Never>?
    var onReading: ((MotionReading) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }
    var hasReference: Bool { reference != nil }

    func start(orientation: CaptureOrientation, resetReference: Bool = true) throws {
        guard manager.isDeviceMotionAvailable else { throw CaptureError.motionUnavailable }
        let reuseActiveReference = manager.isDeviceMotionActive
            && self.orientation == orientation && !resetReference
        cancelSampling()
        referenceExpiryTask?.cancel()
        referenceExpiryTask = nil
        if !reuseActiveReference {
            manager.stopDeviceMotionUpdates()
            reference = nil
            matrixMapsDeviceToReference = nil
        }
        self.orientation = orientation
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        if !reuseActiveReference {
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self { self.sample() } else { return }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        cancelSampling()
        referenceExpiryTask?.cancel()
        referenceExpiryTask = nil
        manager.stopDeviceMotionUpdates()
        reference = nil
        matrixMapsDeviceToReference = nil
    }

    func suspendSampling() {
        cancelSampling()
        referenceExpiryTask?.cancel()
        guard manager.isDeviceMotionActive else { return }
        // The user usually chooses the second pass immediately. Keep its
        // original motion frame briefly, then release the sensor if the
        // review stays open. A later pass will request visual recalibration.
        referenceExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func cancelSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    func recenter() throws {
        guard matrixMapsDeviceToReference != nil,
              let motion = manager.deviceMotion else { throw CaptureError.motionUnavailable }
        reference = motion.attitude.rotationMatrix
    }

    private func sample() {
        guard let motion = manager.deviceMotion else { return }
        let current = motion.attitude.rotationMatrix
        let gravity = motion.gravity
        if matrixMapsDeviceToReference == nil {
            let worldDown = Vector3(x: 0, y: 0, z: -1)
            let measured = Vector3(x: gravity.x, y: gravity.y, z: gravity.z)
            let deviceToReferenceError =
                (current.transposeTransform(worldDown) - measured).lengthSquared
            let referenceToDeviceError =
                (current.transform(worldDown) - measured).lengthSquared
            // Compare Core Motion's independently reported gravity vector to
            // determine which matrix direction this device uses. Wait for a
            // non-ambiguous pose rather than guide with inverted movement.
            guard abs(deviceToReferenceError - referenceToDeviceError) > 0.05 else { return }
            matrixMapsDeviceToReference = deviceToReferenceError < referenceToDeviceError
        }
        guard let matrixMapsDeviceToReference else { return }
        func worldVector(_ vector: Vector3, using matrix: CMRotationMatrix) -> Vector3 {
            matrixMapsDeviceToReference
                ? matrix.transform(vector) : matrix.transposeTransform(vector)
        }
        if reference == nil { reference = motion.attitude.rotationMatrix }
        guard let reference else { return }
        let opticalAxis = Vector3(x: 0, y: 0, z: -1)
        let imageRight: Vector3
        let imageUp: Vector3
        switch orientation {
        case .portrait:
            imageRight = Vector3(x: 1, y: 0, z: 0)
            imageUp = Vector3(x: 0, y: 1, z: 0)
        case .landscapeLeft:
            imageRight = Vector3(x: 0, y: -1, z: 0)
            imageUp = Vector3(x: 1, y: 0, z: 0)
        case .landscapeRight:
            imageRight = Vector3(x: 0, y: 1, z: 0)
            imageUp = Vector3(x: -1, y: 0, z: 0)
        }
        let initialForward = worldVector(opticalAxis, using: reference)
        let initialRight = worldVector(imageRight, using: reference)
        let initialUp = worldVector(imageUp, using: reference)
        let forward = worldVector(opticalAxis, using: current)
        let up = worldVector(imageUp, using: current)
        let forwardDepth = forward.dot(initialForward)
        let yaw = atan2(forward.dot(initialRight), forwardDepth)
        let pitch = atan2(forward.dot(initialUp), forwardDepth)
        let expectedUp = (initialUp - forward * initialUp.dot(forward)).normalized
        let roll = atan2(expectedUp.cross(up).dot(forward), expectedUp.dot(up))
        let rate = motion.rotationRate
        let gravityInScreenPlane = hypot(gravity.x, gravity.y)
        let expectedDownComponent: Double = switch orientation {
        case .portrait: -gravity.y
        case .landscapeLeft: -gravity.x
        case .landscapeRight: gravity.x
        }
        let orientationMatches = gravityInScreenPlane < 0.45
            || expectedDownComponent / gravityInScreenPlane > 0.70
        onReading?(
            MotionReading(
                yawDegrees: yaw * 180 / .pi,
                pitchDegrees: pitch * 180 / .pi,
                rollDegrees: roll * 180 / .pi,
                angularSpeed: sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z),
                orientationMatchesConfiguration: orientationMatches,
                sampleTimestamp: motion.timestamp
            )
        )
    }
}

private struct Vector3 {
    let x: Double
    let y: Double
    let z: Double

    static func -(lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func *(lhs: Self, rhs: Double) -> Self {
        Self(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    func dot(_ other: Self) -> Double { x * other.x + y * other.y + z * other.z }

    func cross(_ other: Self) -> Self {
        Self(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    var lengthSquared: Double { dot(self) }

    var normalized: Self {
        let length = sqrt(dot(self))
        return length > 0 ? self * (1 / length) : self
    }
}

private extension CMRotationMatrix {
    func transform(_ vector: Vector3) -> Vector3 {
        Vector3(
            x: m11 * vector.x + m12 * vector.y + m13 * vector.z,
            y: m21 * vector.x + m22 * vector.y + m23 * vector.z,
            z: m31 * vector.x + m32 * vector.y + m33 * vector.z
        )
    }

    func transposeTransform(_ vector: Vector3) -> Vector3 {
        Vector3(
            x: m11 * vector.x + m21 * vector.y + m31 * vector.z,
            y: m12 * vector.x + m22 * vector.y + m32 * vector.z,
            z: m13 * vector.x + m23 * vector.y + m33 * vector.z
        )
    }
}
