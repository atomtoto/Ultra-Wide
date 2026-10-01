import Foundation
import XCTest
@testable import UltraWide

final class SweepExposurePolicyTests: XCTestCase {
    func testWholeLightCyclesRemovePhaseVariationAtFiftyAndSixtyHertz() throws {
        for frequency in [50.0, 60.0] {
            let setting = try XCTUnwrap(makeSetting(frequency: frequency))
            XCTAssertTrue(setting.integratesFlickerCycle)
            let phases = stride(from: 0.0, to: 2 * Double.pi, by: 0.13)
            let amplitudes = phases.map { averageLampOutput(duration: setting.duration,
                modulationFrequency: 2 * frequency, phase: $0) }
            XCTAssertLessThan(try XCTUnwrap(amplitudes.max()) - XCTUnwrap(amplitudes.min()), 1e-10)
            let short = phases.map { averageLampOutput(duration: 1.0 / 240,
                modulationFrequency: 2 * frequency, phase: $0) }
            XCTAssertGreaterThan(try XCTUnwrap(short.max()) - XCTUnwrap(short.min()), 0.5,
                "The former short shutter sampled very different phases of an electric lamp.")
        }
    }

    func testIndoorSettingsPreserveMeteredBrightnessAndReduceISO() throws {
        let setting = try XCTUnwrap(makeSetting(duration: 1.0 / 240, iso: 640))
        XCTAssertEqual(setting.duration, 1.0 / 100, accuracy: 1e-12)
        XCTAssertEqual(setting.iso * setting.duration, 640.0 / 240, accuracy: 1e-9)
        XCTAssertLessThan(setting.iso, 640)
    }

    func testDimSceneUsesMoreCyclesBeforeExceedingMaximumISO() throws {
        let setting = try XCTUnwrap(makeSetting(duration: 1.0 / 30, iso: 900))
        XCTAssertEqual(setting.duration, 0.03, accuracy: 1e-12)
        XCTAssertEqual(setting.iso, 1000, accuracy: 1e-8)
        XCTAssertTrue(setting.integratesFlickerCycle)
        XCTAssertEqual(setting.iso * setting.duration, 900.0 / 30, accuracy: 1e-9)
    }

    func testBrightSceneKeepsFastExposureRatherThanClippingAtMinimumISO() throws {
        let setting = try XCTUnwrap(makeSetting(duration: 1.0 / 2000, iso: 50))
        XCTAssertFalse(setting.integratesFlickerCycle)
        XCTAssertEqual(setting.duration, 1.0 / 2000, accuracy: 1e-12)
        XCTAssertEqual(setting.iso, 50)
    }

    func testUnsupportedWholeCycleKeepsValidExposureWithinFormatAndFrameBounds() throws {
        let setting = try XCTUnwrap(makeSetting(duration: 1.0 / 500, iso: 400, frameDuration: 1.0 / 240))
        XCTAssertFalse(setting.integratesFlickerCycle)
        XCTAssertLessThanOrEqual(setting.duration, 1.0 / 240)
        XCTAssertEqual(setting.iso * setting.duration, 400.0 / 500, accuracy: 1e-9)
        XCTAssertNil(makeSetting(duration: .nan))
        XCTAssertNil(makeSetting(frequency: 0))
    }

    func testRegionalDefaultFollowsLocationAndManualChoiceOverridesIt() throws {
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(CaptureLighting.automatic.frequency(timeZone: paris, region: "US"), 50)
        XCTAssertEqual(CaptureLighting.automatic.frequency(timeZone: newYork, region: "FR"), 60)
        XCTAssertEqual(CaptureLighting.hz60.frequency(timeZone: paris, region: "FR"), 60)
        XCTAssertEqual(CaptureLighting.hz50.frequency(timeZone: newYork, region: "US"), 50)
    }

    func testExposureGateRejectsOldBuffersAndStaleCallbacksAfterReconfiguration() {
        var gate = ExposureFrameGate()
        let first = gate.begin()
        XCTAssertFalse(gate.accepts(99))
        XCTAssertFalse(gate.accepts(101))
        gate.applied(at: 100, revision: first)
        XCTAssertFalse(gate.accepts(99.999))
        XCTAssertTrue(gate.accepts(100))
        XCTAssertTrue(gate.accepts(101))
        gate.reset()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first), "A stale operation must not restore metering over the new capture.")
        XCTAssertTrue(gate.isCurrent(second))
        gate.applied(at: 100, revision: first)
        XCTAssertFalse(gate.accepts(201), "An old camera completion cannot open a new capture gate.")
        gate.applied(at: 200, revision: second)
        XCTAssertFalse(gate.accepts(199))
        XCTAssertTrue(gate.accepts(200))
    }

    private func makeSetting(duration: Double = 1.0 / 240, iso: Double = 640,
                             frequency: Double = 50, frameDuration: Double = 1.0 / 25) -> SweepExposurePolicy.Setting? {
        SweepExposurePolicy.setting(meteredDuration: duration, meteredISO: iso,
            minimumDuration: 1.0 / 10_000, maximumDuration: 1, minimumISO: 50, maximumISO: 1000,
            frameDuration: frameDuration, mainsFrequency: frequency)
    }

    /// Integrate a sinusoid over the exposure instead of sampling a single
    /// point. This models the phase-sensitive brightness before any stitching.
    private func averageLampOutput(duration: Double, modulationFrequency: Double, phase: Double) -> Double {
        let omega = 2 * Double.pi * modulationFrequency
        return 1 + 0.8 * (sin(omega * duration + phase) - sin(phase)) / (omega * duration)
    }
}
