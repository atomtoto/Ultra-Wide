import UIKit
import XCTest
@testable import UltraWide

@MainActor
final class AppSettingsTests: XCTestCase {
    func testEveryOfferedIconIsBundledWithAPreview() throws {
        let bundle = Bundle(for: UltraWideCoordinator.self)
        let icons = try XCTUnwrap(bundle.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for icon in AppIcon.allCases {
            XCTAssertNotNil(UIImage(named: icon.previewName, in: bundle, compatibleWith: nil))
            if let name = icon.alternateName {
                XCTAssertNotNil(alternates[name], "Missing alternate icon: \(name)")
            }
        }
    }

    func testChangingAndRestoringIconUsesSystemSelection() async {
        var systemName: String?
        var requests: [String?] = []
        let store = AppIconStore(currentName: { systemName }, supportsIcons: { true }, applyIcon: {
            requests.append($0)
            systemName = $0
        })
        await store.select(.amber)
        XCTAssertEqual(store.selectedName, AppIcon.amber.rawValue)
        await store.select(.amber)
        XCTAssertEqual(requests.count, 1, "Selecting the current icon should not ask iOS again.")
        await store.select(.original)
        XCTAssertNil(store.selectedName)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.last!)
        systemName = AppIcon.aurora.rawValue
        store.refresh()
        XCTAssertEqual(store.selectedName, systemName)
    }

    func testFailedChangeKeepsActualIconAndAllowsRetry() async {
        var systemName: String? = AppIcon.graphite.rawValue
        var shouldFail = true
        let store = AppIconStore(currentName: { systemName }, supportsIcons: { true }, applyIcon: {
            if shouldFail { throw NSError(domain: "IconTest", code: 1) }
            systemName = $0
        })
        await store.select(.amber)
        XCTAssertEqual(store.selectedName, AppIcon.graphite.rawValue)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.pendingIcon)
        shouldFail = false
        await store.select(.amber)
        XCTAssertEqual(store.selectedName, AppIcon.amber.rawValue)
        XCTAssertNil(store.errorMessage)
    }

    func testUnsupportedDevicesDoNotRequestIconChanges() async {
        var requested = false
        let store = AppIconStore(currentName: { nil }, supportsIcons: { false }, applyIcon: { _ in requested = true })
        await store.select(.amber)
        XCTAssertFalse(requested)
        XCTAssertNil(store.selectedName)
    }

    func testConcurrentChangeIsIgnoredUntilFirstRequestCompletes() async {
        var systemName: String?
        var continuation: CheckedContinuation<Void, Never>?
        var requests = 0
        let store = AppIconStore(currentName: { systemName }, supportsIcons: { true }, applyIcon: { name in
            requests += 1
            await withCheckedContinuation { continuation = $0 }
            systemName = name
        })
        let first = Task { await store.select(.amber) }
        // Yield until the first request is suspended in the fake system API.
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(store.pendingIcon, .amber)
        await store.select(.aurora)
        XCTAssertEqual(requests, 1)
        continuation?.resume()
        await first.value
        XCTAssertEqual(store.selectedName, AppIcon.amber.rawValue)
        XCTAssertNil(store.pendingIcon)
    }

    func testHapticsDefaultOnAndRespectPersistedChoice() throws {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppPreferences.hapticsEnabled(defaults: defaults))
        defaults.set(false, forKey: AppPreferences.hapticsKey)
        XCTAssertFalse(AppPreferences.hapticsEnabled(defaults: defaults))
        defaults.set(true, forKey: AppPreferences.hapticsKey)
        XCTAssertTrue(AppPreferences.hapticsEnabled(defaults: defaults))
    }

    func testOutputResolutionDefaultsTo16MPAndRestoresSavedChoice() throws {
        let suite = "OutputResolutionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppPreferences.outputResolution(defaults: defaults), .mp16)
        defaults.set(4, forKey: AppPreferences.outputResolutionKey)
        XCTAssertEqual(AppPreferences.outputResolution(defaults: defaults), .mp4)
        defaults.set(48, forKey: AppPreferences.outputResolutionKey)
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppPreferences.outputResolution(defaults: restoredDefaults), .mp48)
        defaults.set(999, forKey: AppPreferences.outputResolutionKey)
        XCTAssertEqual(AppPreferences.outputResolution(defaults: defaults), .mp16)
    }
}
