import XCTest
import PDFKit
import Combine
@testable import FormScan

@MainActor
final class TableTests: XCTestCase {
    private func read(_ pdf: PDFDocument) throws -> (UIImage, [RecognizedLine], TableGrid) {
        let image = try XCTUnwrap(pdf.page(at: 0)).thumbnail(of: CGSize(width: 1400, height: 1800), for: .cropBox)
        let lines = try FieldLabels.recognize(image)
        let grid = TableGrid.detect(image, lines: lines)
        print("TABLE OCR:", lines.map(\.text), "CELLS:", grid.tables.map { $0.cells.count }, "FIELDS:", grid.fields.map(\.label))
        return (image, lines, grid)
    }

    func testPrintedSixByThreeTableUsesBothHeadersAndExactlyEighteenCells() throws {
        let (_, _, grid) = try read(ExampleTable.make())
        XCTAssertEqual(grid.tables.count, 1)
        XCTAssertEqual(grid.fields.count, 18, "Six real rows, three response columns, no invented continuation")
        let first = try XCTUnwrap(grid.fields.first)
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains("insufficient"))
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains("Possible causes"))
        XCTAssertEqual(Set(grid.fields.map(\.label)).count, 18)
        XCTAssertEqual(grid.fields.filter { $0.label.localizedCaseInsensitiveContains("Possible causes") }.count, 6)
        XCTAssertEqual(grid.fields.filter { $0.label.localizedCaseInsensitiveContains("policies") }.count, 6)
        XCTAssertEqual(grid.fields.filter { $0.label.localizedCaseInsensitiveContains("actions") }.count, 6)
    }

    func testOpenBottomDoesNotCreateUnboundedCellsAndPrintedAnswersAreNotBlankFields() throws {
        let (_, _, open) = try read(ExampleTable.make(openBottom: true))
        XCTAssertEqual(open.fields.count, 15, "An open row is not evidence for three closed cells")
        let (_, _, filled) = try read(ExampleTable.make(filledCell: true))
        XCTAssertEqual(filled.fields.count, 17)
        XCTAssertFalse(filled.fields.contains { $0.label.contains("Observed answer") || $0.label.contains("123") })
        XCTAssertEqual(filled.fields.filter { $0.label.localizedCaseInsensitiveContains("insufficient") }.count, 2)
        XCTAssertTrue(filled.tables.flatMap(\.cells).contains { $0.content.contains("123") })
    }

    func testTableDoesNotSwallowTextFieldsOrCheckboxesBelowItAndFusionKeepsBothTypes() throws {
        let (image, _, grid) = try read(ExampleTable.make(extraFields: true))
        let scale = CGFloat(image.cgImage!.width) / 842
        let text = DetectedField(rect: CGRect(x: 225*scale, y: 540*scale, width: 190*scale, height: 30*scale), category: 0, confidence: 0.9)
        let check = DetectedField(rect: CGRect(x: 450*scale, y: 543*scale, width: 22*scale, height: 22*scale), category: 1, confidence: 0.9)
        let phantom = DetectedField(rect: CGRect(x: 610*scale, y: 507*scale, width: 184*scale, height: 55*scale), category: 0, confidence: 0.98)
        XCTAssertFalse(grid.replaces(text))
        XCTAssertFalse(grid.replaces(check))
        XCTAssertTrue(grid.replaces(phantom))
        let (_, _, mixedGrid) = try read(ExampleTable.make(checkboxCell: true))
        XCTAssertEqual(mixedGrid.fields.count, 18)
        XCTAssertEqual(mixedGrid.fields.filter(\.checkbox).count, 1)
        XCTAssertEqual(mixedGrid.fields.filter { !$0.checkbox }.count, 17)
        var overlapping = check; overlapping.rect = text.rect
        let fused = FieldEnsemble.fuse([.nano: [text, overlapping]])
        XCTAssertEqual(Set(fused.map(\.category)), Set([0, 1]))
        XCTAssertEqual(fused.count, 2)
    }

    func testTableAnalysisRepairsLegacyPhantomsPreservesAnswersAndExportsInTheCorrectCell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleTable.make(), title: "Table")
        let session = try XCTUnwrap(library.session(id: id))
        for row in 0..<8 { for column in 0..<3 {
            let xs: [CGFloat] = [225, 425, 610, 794]
            session.item.fields.append(FormEntry(page: 0, rect: CGRect(x: xs[column], y: 595 - (175 + CGFloat(row+1)*55), width: xs[column+1]-xs[column], height: 55), label: ExampleTable.columns[column]))
        } }
        await session.detect()
        XCTAssertNil(session.error)
        XCTAssertEqual(session.item.fields.count, 18)
        XCTAssertTrue(session.item.fields.allSatisfy { $0.text.isEmpty && !$0.checkbox })
        var field = try XCTUnwrap(session.item.fields.first)
        field.text = "Water shortage 123"; session.update(field)
        await session.detect()
        XCTAssertEqual(session.item.fields.count, 18)
        XCTAssertEqual(session.item.fields.first { $0.id == field.id }?.text, field.text)
        let annotation = try XCTUnwrap(session.document.page(at: 0)?.annotations.first { $0.contents == field.text })
        XCTAssertEqual(annotation.bounds, field.rect)
        let exported = try XCTUnwrap(PDFDocument(url: session.export()))
        XCTAssertTrue(exported.string?.contains("Water shortage 123") == true)
        let reopened = try XCTUnwrap(DocumentLibrary(directory: directory).session(id: id))
        XCTAssertEqual(reopened.item.fields.count, 18)
        XCTAssertEqual(reopened.item.fields.first { $0.id == field.id }?.text, field.text)
        XCTAssertEqual(reopened.item.analysisVersion, DocumentSession.analysisVersion)
    }

    func testImageAndPDFCoordinatesRoundTripForAllPageRotations() {
        let rect = CGRect(x: 230, y: 400, width: 200, height: 90)
        let size = CGSize(width: 1400, height: 1800), bounds = CGRect(x: 20, y: 30, width: 595, height: 842)
        for rotation in [0, 90, 180, 270] {
            let pdf = PDFFormWriter.pdfRect(rect, imageSize: size, bounds: bounds, rotation: rotation)
            let actual = PDFFormWriter.imageRect(pdf, imageSize: size, bounds: bounds, rotation: rotation)
            XCTAssertEqual(actual.minX, rect.minX, accuracy: 0.01)
            XCTAssertEqual(actual.minY, rect.minY, accuracy: 0.01)
            XCTAssertEqual(actual.width, rect.width, accuracy: 0.01)
            XCTAssertEqual(actual.height, rect.height, accuracy: 0.01)
        }
    }

    func testAllClassesAndOverhangingBoxesNeedPrintedSupportBelowTable() throws {
        let (image, _, grid) = try read(ExampleTable.make())
        let scale = CGFloat(image.cgImage!.width) / 842
        for category in 0...2 {
            for x in [CGFloat(215), 610] {
                let phantom = DetectedField(rect: CGRect(x: x*scale, y: 507*scale, width: 200*scale, height: 55*scale), category: category, confidence: 0.99)
                XCTAssertTrue(grid.replaces(phantom), "No predicted class may invent a seventh row")
            }
        }
        let (signedImage, _, signedGrid) = try read(ExampleTable.reported(signature: true))
        let signedScale = CGFloat(signedImage.cgImage!.width) / 792
        let signature = DetectedField(rect: CGRect(x: 222*signedScale, y: 572*signedScale, width: 198*signedScale, height: 22*signedScale), category: 2, confidence: 0.9)
        XCTAssertEqual(signedGrid.fields.count, 18)
        XCTAssertFalse(signedGrid.replaces(signature), "A real labelled signature underline is preserved")
    }

    func testReportedWorksheetThinBordersAndThreeModelsDoNotAddSeventhRow() async throws {
        let pdf = ExampleTable.reported()
        let (_, _, grid) = try read(pdf)
        XCTAssertEqual(grid.tables.count, 1)
        XCTAssertEqual(grid.fields.count, 18)
        let (_, _, tail) = try read(ExampleTable.reported(tailRules: true))
        XCTAssertEqual(tail.fields.count, 18, "Unlabelled continuation lines are not response rows")
        let jobs = try [(AIModel.nano, Bundle.main.url(forResource: "model", withExtension: "onnx")),
                        (.compact, Bundle(for: TableTests.self).url(forResource: "nano-compact", withExtension: "onnx")),
                        (.detailed, Bundle(for: TableTests.self).url(forResource: "ffdetr-mobile-int8", withExtension: "onnx"))].map {
            InferenceJob(model: $0.0, url: try XCTUnwrap($0.1))
        }
        let session = DocumentSession(item: SavedDocument(title: "Reported", pageCount: 1, fields: []), document: pdf) { _, _ in }
        var maximum = 0
        let observation = session.$item.sink { maximum = max(maximum, $0.fields.count) }
        await session.detect(jobs: jobs, parallelism: 2)
        withExtendedLifetime(observation) {}
        XCTAssertNil(session.error)
        XCTAssertEqual(session.item.fields.count, 18)
        XCTAssertEqual(maximum, 18, "Every progressive model result must respect the printed boundary")
        XCTAssertEqual(Set(session.item.fields.map(\.label)).count, 18)
        XCTAssertTrue(session.item.fields.allSatisfy { $0.rect.minY >= 612 - 535 - 2 })
    }

    func testSavedTwentyOneFieldsUpgradeRepairsOnlyUneditedGhosts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleTable.reported(), title: "Upgrade")
        let session = try XCTUnwrap(library.session(id: id))
        ExampleTable.seedLegacyFields(in: session)
        let ghosts = Set(session.item.fields.suffix(3).map(\.id))
        session.item.fields[19].origin = "table"
        let (_, _, printed) = try read(session.document)
        session.item.fields[19].label = try XCTUnwrap(printed.fields.dropFirst(16).first).label
        session.item.fields[20].origin = nil
        session.item.fields[20].label = "Campo de texto"
        var answer = session.item.fields[0]
        answer.text = "Water shortage 123"; session.update(answer)
        let customID = session.item.fields[1].id
        session.item.fields[1].label = "My custom label"
        let manual = FormEntry(page: 0, rect: CGRect(x: 430, y: 28, width: 100, height: 22), label: "Texto", origin: "manual")
        session.item.fields.append(manual); session.flush()
        let models = AnalysisEngine()
        session.startAnalysis(using: models, automatic: true)
        for _ in 0..<600 {
            if session.item.analysisVersion == DocumentSession.analysisVersion && !session.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(session.error)
        XCTAssertEqual(session.item.analysisVersion, DocumentSession.analysisVersion)
        XCTAssertEqual(session.item.fields.count, 19, "18 real cells plus the explicit manual field")
        XCTAssertTrue(ghosts.isDisjoint(with: session.item.fields.map(\.id)))
        XCTAssertEqual(session.item.fields.first { $0.id == answer.id }?.text, answer.text)
        XCTAssertEqual(session.item.fields.first { $0.id == customID }?.label, "My custom label")
        XCTAssertTrue(session.item.fields.contains { $0.id == manual.id })
        let exported = try XCTUnwrap(PDFDocument(url: session.export()))
        XCTAssertTrue(exported.string?.contains(answer.text) == true)
        let reopened = try XCTUnwrap(DocumentLibrary(directory: directory).session(id: id))
        XCTAssertEqual(reopened.item.fields.count, 19)
        XCTAssertEqual(reopened.item.fields.first { $0.id == answer.id }?.text, answer.text)
    }

    func testOrdinaryFormsDoNotBecomeTables() throws {
        let (_, _, grid) = try read(ExampleDocument.make(widgets: false))
        XCTAssertTrue(grid.tables.isEmpty)
    }
}
