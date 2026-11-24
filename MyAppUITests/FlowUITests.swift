import XCTest

/// Taps through the app like a person, including the iOS permission and delete dialogs.
/// CI puts one test video into the simulator's library first (`simctl addmedia`).
final class FlowUITests: XCTestCase {

    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    func testFullFlow() throws {
        let app = XCUIApplication()
        // list small test videos too (normal minimum is 100 MB)
        app.launchArguments += ["-minSizeMB", "1"]
        app.launch()
        shot(app, "1-launch")

        // 0. Onboarding (3 pages) → skip after checking it shows
        let skip = app.buttons["onboardingSkip"]
        if skip.waitForExistence(timeout: 10) {
            shot(app, "0-onboarding")
            skip.tap()
        }

        // 1. Access screen → system dialog → allow full access
        let allow = app.buttons["allowAccess"]
        // The system dialog sometimes takes a while in a cold simulator: try up to 3 times.
        for _ in 0..<3 where allow.waitForExistence(timeout: 10) {
            allow.tap()
            answerSystemDialog(prefixes: ["Allow Full Access", "Allow Access to All", "Allow"], timeout: 30)
            // iOS may ask a second time to confirm full access
            answerSystemDialog(prefixes: ["Allow Full Access", "Allow Access to All"], timeout: 4)
            if !allow.waitForExistence(timeout: 3) { break }
        }

        // 2. The test video is listed and NOT pre-selected
        let row = app.buttons["videoRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no video listed after granting access")
        shot(app, "2-list")
        XCTAssertFalse(row.isSelected, "video was pre-selected")
        let compress = app.buttons["compressButton"]
        XCTAssertFalse(compress.isEnabled, "Compress enabled with nothing selected")

        // 3. Select, pick Best quality, compress
        row.tap()
        XCTAssertTrue(compress.isEnabled, "Compress not enabled after selecting a video")
        app.buttons["Best quality"].tap()
        compress.tap()

        // 4. Working screen appears, then finishes
        XCTAssertTrue(app.staticTexts["workingTitle"].waitForExistence(timeout: 20), "working screen did not appear")
        shot(app, "3-working")
        let delete = app.buttons["deleteOriginals"]
        XCTAssertTrue(delete.waitForExistence(timeout: 240), "batch did not finish with a copy saved")
        shot(app, "4-done")

        // 4b. Compare: watch the copy, switch to the original, close
        let compareButton = app.buttons["compareButton"].firstMatch
        XCTAssertTrue(compareButton.waitForExistence(timeout: 10), "no compare button on the result screen")
        compareButton.tap()
        let compareSwitch = app.segmentedControls["compareSwitch"]
        XCTAssertTrue(compareSwitch.waitForExistence(timeout: 20), "compare screen did not open")
        compareSwitch.buttons["Original"].tap()
        shot(app, "4b-compare")
        app.buttons["Done"].firstMatch.tap()

        // 5. Delete originals → iOS confirmation → card disappears
        delete.tap()
        answerSystemDialog(prefixes: ["Delete"], timeout: 15)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: delete)
        waitForExpectations(timeout: 20)
        shot(app, "5-after-delete")
    }

    /// Screenshots in German and Turkish, to check the translations on screen.
    func testTranslatedScreens() throws {
        for (lang, locale) in [("de", "de_DE"), ("tr", "tr_TR")] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(\(lang))", "-AppleLocale", locale, "-minSizeMB", "1",
                                    "-onboarded", "NO"]
            app.launch()
            if app.buttons["onboardingNext"].waitForExistence(timeout: 10) {
                shot(app, "\(lang)-onboarding-1")
                app.buttons["onboardingNext"].tap()
                shot(app, "\(lang)-onboarding-2")
                app.buttons["onboardingSkip"].tap()
            }
            _ = app.buttons["compressButton"].waitForExistence(timeout: 15)
            shot(app, "\(lang)-main")
            if app.buttons["selectMenu"].exists {
                app.buttons["selectMenu"].tap()
                shot(app, "\(lang)-select-menu")
                app.tap()
            }
            app.terminate()
        }
    }

    // MARK: helpers

    /// Taps the first button in a system alert whose label starts with one of the prefixes.
    /// Never taps "Don't Allow". Returns quietly if no dialog shows up.
    func answerSystemDialog(prefixes: [String], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for p in prefixes {
                let pred = NSPredicate(format: "label BEGINSWITH[c] %@ AND NOT (label BEGINSWITH[c] %@)", p, "Don")
                let b = springboard.alerts.buttons.matching(pred).firstMatch
                if b.exists {
                    shot(springboard, "dialog-\(p)")
                    b.tap()
                    return
                }
                let inApp = XCUIApplication().alerts.buttons.matching(pred).firstMatch
                if inApp.exists {
                    inApp.tap()
                    return
                }
                // newer iOS versions may present the photo prompt outside a classic alert
                let anyButton = springboard.buttons.matching(pred).firstMatch
                if p != "Allow", p != "Delete", anyButton.exists, anyButton.isHittable {
                    shot(springboard, "dialog-\(p)")
                    anyButton.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
