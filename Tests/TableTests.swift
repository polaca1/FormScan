import XCTest
import PDFKit
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
        XCTAssertEqual(reopened.item.analysisVersion, 2)
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

    func testOrdinaryFormsDoNotBecomeTables() throws {
        let (_, _, grid) = try read(ExampleDocument.make(widgets: false))
        XCTAssertTrue(grid.tables.isEmpty)
    }
}
