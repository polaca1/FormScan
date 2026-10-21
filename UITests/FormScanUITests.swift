import XCTest

final class FormScanUITests: XCTestCase {
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 30) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }
    private func screenshot(_ name: String) {
        // Allow native glass/sheet presentation animations to finish before capturing evidence.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testTableAutomaticAnalysisBothHeadersFillPreviewAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-table"]
        app.launch()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let status = app.descendants(matching: .any)["documentStatus"].firstMatch
        let analyzed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Análisis completado' AND label CONTAINS 'de 18 campos'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [analyzed], timeout: 60), .completed)
        screenshot("26-table-eighteen-cells")
        picker.buttons["Formulario"].tap()
        let fieldLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'insufficient' AND label CONTAINS[c] 'Possible causes'")).firstMatch
        XCTAssertTrue(fieldLabel.waitForExistence(timeout: 8))
        let value = app.textViews.matching(NSPredicate(format: "identifier CONTAINS[c] 'insufficient' AND identifier CONTAINS[c] 'Possible causes'")).firstMatch
        let entry = value.exists ? value : app.textFields.matching(NSPredicate(format: "identifier CONTAINS[c] 'insufficient' AND identifier CONTAINS[c] 'Possible causes'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let identifier = entry.identifier
        entry.tap(); entry.typeText("Water shortage 123")
        app.buttons["finishFormEditing"].tap()
        screenshot("27-table-row-and-column")
        picker.buttons["Documento"].tap()
        screenshot("28-table-filled-preview")
        app.buttons["closeDocument"].tap()
        app.terminate()
        app.launchArguments = ["-ui-testing-reopen"]
        app.launch()
        app.staticTexts["The environment"].firstMatch.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["Formulario"].tap()
        let restored = app.textViews[identifier].exists ? app.textViews[identifier] : app.textFields[identifier]
        XCTAssertEqual(restored.value as? String, "Water shortage 123")
    }

    func testHomeUsesFullScreenAndSupportsDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.navigationBars.firstMatch.frame.minY, 120)
        XCTAssertTrue(app.tabBars.buttons["Documentos"].exists)
        XCTAssertTrue(app.tabBars.buttons["Ajustes"].exists)
        XCTAssertFalse(app.buttons["mainMenu"].exists)
        screenshot("01-home-light")
        app.terminate()
        app.launchArguments += ["-ui-testing-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        screenshot("02-home-dark")
    }
    func testFillPreviewShareAndReopen() {
        executionTimeAllowance = 180
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
        let done = app.buttons["finishFormEditing"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        picker.buttons["Documento"].tap()
        let documentMode = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: picker.buttons["Documento"])
        XCTAssertEqual(XCTWaiter.wait(for: [documentMode], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["documentPreview"].firstMatch.waitForExistence(timeout: 5))
        screenshot("04-document-filled")
        waitUntilEnabled(app.buttons["exportPDF"])
        app.buttons["exportPDF"].tap()
        let copy = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Copy", "Copiar"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        screenshot("05-share-pdf")
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
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancelar", "Close", "Cerrar"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        screenshot("10-import-picker")
        cancel.tap()
        XCTAssertTrue(app.buttons["importDocument"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    func testAccessibilityTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["scanDocument"].waitForExistence(timeout: 10))
        for _ in 0..<3 where !app.buttons["scanDocument"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["scanDocument"].isHittable)
        if !app.buttons["importDocument"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["importDocument"].isHittable)
        screenshot("11-large-text")
    }
    func testManualFieldPlacement() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example"]
        app.launch()
        XCTAssertTrue(app.buttons["addField"].waitForExistence(timeout: 15))
        waitUntilEnabled(app.buttons["addField"])
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
        app.buttons["closeDocument"].tap()
        XCTAssertTrue(app.tabBars.buttons["Documentos"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Documentos"].tap()
        XCTAssertTrue(app.navigationBars["Documentos"].waitForExistence(timeout: 8))
        screenshot("18-document-library")
        app.staticTexts["Formulario de ejemplo"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["editorMode"].waitForExistence(timeout: 8))
    }
    func testSettingsExplainPrivacyWithoutModelControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let settings = app.tabBars.buttons["Ajustes"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12)); settings.tap()
        screenshot("19-settings")
        XCTAssertFalse(app.buttons["openModels"].exists)
        XCTAssertFalse(app.staticTexts["Modelos de IA"].exists)
        app.buttons["Privacidad"].tap()
        XCTAssertTrue(app.navigationBars["Privacidad"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Tus documentos"].exists)
        screenshot("17-privacy")
    }

    func testFirstLaunchAccessValidationAndExample() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["googleSignIn"].waitForExistence(timeout: 12))
        screenshot("29-account-welcome")
        let email = app.textFields["accountEmail"]
        email.tap(); email.typeText("incorrecto\n")
        let password = app.secureTextFields["accountPassword"]
        for _ in 0..<4 { if password.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(password.isHittable); password.tap(); password.typeText("prueba123\n")
        let submit = app.buttons["submitAccount"]
        for _ in 0..<4 { if submit.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(submit.isHittable); submit.tap()
        XCTAssertTrue(app.staticTexts["Introduce una dirección de correo válida."].waitForExistence(timeout: 5))
        if app.keyboards.firstMatch.exists { app.swipeUp() }
        let offline = app.buttons["continueOnDevice"]
        for _ in 0..<5 { if offline.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(offline.isHittable); offline.tap()
        let next = app.buttons["continueTutorial"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap(); next.tap(); next.tap()
        XCTAssertTrue(app.segmentedControls["editorMode"].waitForExistence(timeout: 15))
        screenshot("30-account-example")
    }

    func testRepeatedModeChangesKeepToolbarStableAndCheckboxHasPrintedText() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example"]
        app.launch()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let share = app.buttons["exportPDF"]
        let options = app.buttons["documentOptions"]
        let shareFrame = share.frame, optionsFrame = options.frame
        for _ in 0..<3 {
            picker.buttons["Formulario"].tap()
            XCTAssertEqual(share.frame.minX, shareFrame.minX, accuracy: 1)
            XCTAssertEqual(options.frame.minX, optionsFrame.minX, accuracy: 1)
            picker.buttons["Documento"].tap()
            XCTAssertEqual(share.frame.minX, shareFrame.minX, accuracy: 1)
            XCTAssertEqual(options.frame.minX, optionsFrame.minX, accuracy: 1)
        }
        screenshot("20-editor-stable")
        picker.buttons["Formulario"].tap()
        let checkbox = app.switches["He revisado los datos del formulario."]
        if !checkbox.isHittable { app.swipeUp() }
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        // The AX switch frame can include the entire label row on iOS 27.
        // Anchor to the adjacent Edit control: 12 pt spacing plus 20 pt
        // inside the visible track, independent of the label/row width.
        let edit = app.buttons["Editar He revisado los datos del formulario."]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let target = CGPoint(x: edit.frame.minX - 32, y: checkbox.frame.midY)
        XCTAssertTrue(checkbox.frame.contains(target))
        print("Switch AX:", checkbox.debugDescription, "Edit:", edit.frame, "Tap:", target)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.x, dy: target.y)).tap()
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: checkbox)
        XCTAssertEqual(XCTWaiter.wait(for: [marked], timeout: 5), .completed)
        screenshot("21-checkbox-label")
        picker.buttons["Documento"].tap()
        screenshot("25-checkbox-document")
        options.tap()
        XCTAssertTrue(app.buttons["Cambiar nombre"].waitForExistence(timeout: 5))
    }

    func testImportActualPDFThroughFilesAndReopenIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-import"]
        app.launch()
        app.buttons["importDocument"].tap()
        executionTimeAllowance = 180
        // Native Files controls can change AX roles across releases. Typed,
        // exact label queries also avoid an iOS 27 remote-view snapshot bug
        // where `label IN` returned no matches for a visible Browse button.
        func nativeElement(_ labels: [String], timeout: TimeInterval) -> XCUIElement? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                for label in labels {
                    for element in [app.buttons[label], app.staticTexts[label], app.descendants(matching: .any).matching(identifier: label).firstMatch] {
                        if element.exists && element.isHittable { return element }
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
            print("Native Files hierarchy:", app.debugDescription)
            return nil
        }
        guard let browse = nativeElement(["Browse", "Explorar"], timeout: 15) else {
            screenshot("22-import-missing-browse"); XCTFail("No se encuentra Explorar en Archivos"); return
        }
        browse.tap()
        guard let location = nativeElement(["On My iPhone", "En mi iPhone"], timeout: 15) else {
            screenshot("22-import-missing-location"); XCTFail("No se encuentra En mi iPhone"); return
        }
        location.tap()
        guard let folder = nativeElement(["FormScan"], timeout: 15) else {
            screenshot("22-import-missing-folder"); XCTFail("No se encuentra la carpeta FormScan"); return
        }
        folder.tap()
        guard let actualFile = nativeElement(["Importar prueba", "Importar prueba.pdf"], timeout: 15) else {
            screenshot("22-import-missing-file"); XCTFail("El archivo no aparece en Archivos"); return
        }
        screenshot("22-import-actual-file")
        let cell = app.cells.containing(.staticText, identifier: actualFile.label).firstMatch
        if cell.exists { cell.tap() }
        else {
            // In the icon grid, tap the document thumbnail rather than the
            // filename label (which has a separate interaction in Files).
            actualFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -55)).tap()
        }
        guard app.segmentedControls["editorMode"].waitForExistence(timeout: 25) else {
            screenshot("23-import-not-opened"); XCTFail("El PDF seleccionado no se ha abierto en el editor"); return
        }
        XCTAssertTrue(app.navigationBars["Importar prueba"].exists)
        screenshot("23-imported-pdf")
        app.terminate()
        app.launchArguments = ["-ui-testing-reopen"]
        app.launch()
        let saved = app.staticTexts["Importar prueba"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        XCTAssertTrue(app.segmentedControls["editorMode"].waitForExistence(timeout: 10))
    }
    func testNewDocumentsAnalyzeAutomaticallyAndPersistCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-example"]
        app.launch()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        waitUntilEnabled(app.buttons["exportPDF"])
        let status = app.descendants(matching: .any)["documentStatus"].firstMatch
        let analyzed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Análisis completado"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [analyzed], timeout: 30), .completed)
        XCTAssertTrue(status.label.contains("de 4 campos"), "The native checkbox must not gain a duplicate text field: \(status.label)")
        picker.buttons["Formulario"].tap()
        XCTAssertTrue(app.textViews["field-Nombre completo"].exists || app.textFields["field-Nombre completo"].exists)
        screenshot("24-auto-analysis")
    }

    func testPrivateCloudRestoreEditFreshInstallationAndRetry() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-cloud"]
        app.launch()
        let documents = app.tabBars.buttons["Documentos"]
        XCTAssertTrue(documents.waitForExistence(timeout: 12)); documents.tap()
        let recovered = app.staticTexts["Documento recuperado"].firstMatch
        XCTAssertTrue(recovered.waitForExistence(timeout: 15)); recovered.tap()
        let picker = app.segmentedControls["editorMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.buttons["Formulario"].tap()
        let name = app.textViews["field-Nombre completo"].exists ? app.textViews["field-Nombre completo"] : app.textFields["field-Nombre completo"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Guardado entre instalaciones")
        app.buttons["finishFormEditing"].tap()
        let check = app.switches["He revisado los datos del formulario."]
        XCTAssertEqual(check.value as? String, "1")
        screenshot("31-cloud-restored-form")
        app.buttons["closeDocument"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Guardado'"), object: app.staticTexts["cloudFixtureState"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        app.terminate()
        // Remove only the local library. The separate simulated account service
        // persists its own files and deliberately fails the first catalogue call.
        app.launchArguments = ["-ui-testing-reopen", "-ui-testing-cloud", "-ui-testing-cloud-new-install", "-ui-testing-cloud-error"]
        app.launch()
        let retry = app.buttons["Reintentar"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertFalse(recovered.exists, "A network failure must not be treated as an empty account")
        screenshot("32-cloud-retry")
        retry.tap()
        XCTAssertTrue(recovered.waitForExistence(timeout: 15)); recovered.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.buttons["Formulario"].tap()
        let restoredName = app.textViews["field-Nombre completo"].exists ? app.textViews["field-Nombre completo"] : app.textFields["field-Nombre completo"]
        XCTAssertEqual(restoredName.value as? String, "Guardado entre instalaciones")
        XCTAssertEqual(check.value as? String, "1")
        screenshot("33-cloud-fresh-install")
    }

}
