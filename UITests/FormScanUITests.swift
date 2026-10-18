import XCTest

final class FormScanUITests: XCTestCase {
    private func screenshot(_ name: String) {
        // Allow native glass/sheet presentation animations to finish before capturing evidence.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testHomeUsesFullScreenAndSupportsDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.navigationBars.firstMatch.frame.minY, 120)
        XCTAssertGreaterThan(app.buttons["scanDocument"].frame.maxY, app.frame.height * 0.8)
        screenshot("01-home-light")
        app.terminate()
        app.launchArguments += ["-ui-testing-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        screenshot("02-home-dark")
    }
    func testFillPreviewShareAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example"]
        app.launch()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        screenshot("03-document-empty")
        picker.buttons["Formulario"].tap()
        let name = app.textFields["field-Nombre completo"]
        // A vertical TextField is exposed as a text view on some iOS SDKs.
        let text = name.exists ? name : app.textViews["field-Nombre completo"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Ana Garcia")
        picker.buttons["Documento"].tap()
        screenshot("04-document-filled")
        app.buttons["exportPDF"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 8) || app.buttons["Copy"].exists || app.buttons["Copiar"].exists)
        let copy = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Copy", "Copiar"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        screenshot("05-share-pdf")
        app.swipeDown()
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        if app.buttons["Cerrar"].exists { app.buttons["Cerrar"].tap() }
        // Relaunch preserving the same test library to verify the saved file, not view state.
        app.terminate()
        app.launchArguments = ["-ui-testing-reopen"]
        app.launch()
        let saved = app.staticTexts["Formulario de ejemplo"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.buttons["Formulario"].tap()
        let restored = app.textViews["field-Nombre completo"].exists ? app.textViews["field-Nombre completo"] : app.textFields["field-Nombre completo"]
        XCTAssertEqual(restored.value as? String, "Ana Garcia")
        screenshot("08-form-restored")
    }
    func testFormAndLandscapeLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example", "-ui-testing-dark"]
        app.launch()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["Formulario"].tap(); screenshot("06-form-dark")
        picker.buttons["Documento"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["exportPDF"].waitForExistence(timeout: 5))
        screenshot("07-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    func testImportPickerAndUnavailableCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.buttons["scanDocument"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        screenshot("09-camera-unavailable")
        app.alerts.buttons["Aceptar"].tap()
        app.buttons["importDocument"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 8) || app.buttons["Cancelar"].exists)
        screenshot("10-import-picker")
    }
    func testAccessibilityTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["scanDocument"].isHittable)
        XCTAssertTrue(app.buttons["importDocument"].isHittable)
        screenshot("11-large-text")
    }
    func testManualFieldPlacement() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example"]
        app.launch()
        XCTAssertTrue(app.buttons["addField"].waitForExistence(timeout: 15))
        app.buttons["addField"].tap(); app.buttons["Campo de texto"].tap()
        let content = app.textViews["Contenido"].exists ? app.textViews["Contenido"] : app.textFields["Contenido"]
        XCTAssertTrue(content.waitForExistence(timeout: 5)); content.tap(); content.typeText("Texto manual")
        app.buttons["Colocar en el documento"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let picker = app.segmentedControls["editorMode"]
        picker.buttons["Formulario"].tap()
        let value = app.textViews["field-Texto"].exists ? app.textViews["field-Texto"] : app.textFields["field-Texto"]
        if !value.exists { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.value as? String, "Texto manual")
        screenshot("12-manual-field")
    }
    func testOnboardingExampleAndDocumentLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-onboarding"]
        app.launch()
        let next = app.buttons["continueTutorial"]
        XCTAssertTrue(next.waitForExistence(timeout: 12)); screenshot("13-tutorial-welcome")
        next.tap(); screenshot("14-tutorial-form")
        next.tap(); screenshot("15-tutorial-local-ai")
        next.tap()
        XCTAssertTrue(app.segmentedControls["editorMode"].waitForExistence(timeout: 12))
        screenshot("16-tutorial-example")
        app.navigationBars.buttons.firstMatch.tap()
        let library = app.buttons["allDocuments"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        if !library.isHittable { app.swipeUp() }
        library.tap()
        XCTAssertTrue(app.navigationBars["Documentos"].waitForExistence(timeout: 8))
        screenshot("18-document-library")
        app.staticTexts["Formulario de ejemplo"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["editorMode"].waitForExistence(timeout: 8))
    }
    func testModelMenuDownloadsAndSelectsCompactModel() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let models = app.buttons["openModels"]
        XCTAssertTrue(models.waitForExistence(timeout: 8))
        for _ in 0..<4 { if models.isHittable { break }; app.swipeUp() }
        models.tap()
        XCTAssertTrue(app.navigationBars["Modelos de IA"].waitForExistence(timeout: 8))
        // Previous test runs may already have downloaded the compact model.
        let install = app.buttons["install-compact"]
        let use = app.buttons["use-compact"]
        for _ in 0..<6 {
            if install.isHittable || use.isHittable { break }
            app.swipeUp()
        }
        if install.exists { install.tap() }
        else { use.tap() }
        let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == 'En uso'"), object: use)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 90), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        screenshot("17-models-installed")
    }
}
