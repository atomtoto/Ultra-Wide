import XCTest

final class CaptureFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    @MainActor func testDemoCaptureAndGalleryPersistence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--uitesting"]
        app.launch()
        let capture = app.buttons["captureButton"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "01-Camera"; home.lifetime = .keepAlways; add(home)
        capture.tap()
        XCTAssertTrue(app.staticTexts["savedConfirmation"].waitForExistence(timeout: 60))
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "02-Panorama"; result.lifetime = .keepAlways; add(result)
        app.buttons["resultDone"].tap()
        app.buttons["galleryButton"].tap()
        XCTAssertTrue(app.staticTexts["La vue d’ensemble."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Exploration · Démo"].firstMatch.exists)
        app.terminate()
        app.launch()
        app.buttons["galleryButton"].tap()
        XCTAssertTrue(app.staticTexts["Exploration · Démo"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testCancelSweepReturnsToCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--uitesting"]
        app.launch()
        app.buttons["captureButton"].tap()
        app.buttons["galleryButton"].tap()
        XCTAssertTrue(app.buttons["Commencer la capture"].waitForExistence(timeout: 5))
    }
}
