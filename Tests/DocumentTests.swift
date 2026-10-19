import XCTest
import PDFKit
@testable import FormScan

@MainActor
final class DocumentTests: XCTestCase {
    func testLiveEditsAndDeletionDoNotDuplicateAnnotations() throws {
        let pdf = ExampleDocument.make(widgets: false)
        let item = SavedDocument(title: "Prueba", pageCount: 1, fields: [])
        let session = DocumentSession(item: item, document: pdf) { _, _ in }
        let id = session.addField(checkbox: false, page: 0)
        var field = try XCTUnwrap(session.item.fields.first)
        field.text = "Ana García"; session.update(field)
        XCTAssertEqual(pdf.page(at: 0)?.annotations.filter { $0.contents == "Ana García" }.count, 1)
        field.text = "Luis Pérez"; session.update(field)
        let annotations = pdf.page(at: 0)!.annotations.filter { $0.userName?.hasPrefix(PDFFormWriter.prefix) == true }
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.contents, "Luis Pérez")
        session.remove(id)
        XCTAssertFalse(pdf.page(at: 0)!.annotations.contains { $0.userName?.hasPrefix(PDFFormWriter.prefix) == true })
    }

    func testEmbeddedWidgetLiveValueAndFlattenedExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleDocument.make(), title: "Inscripción")
        let session = try XCTUnwrap(library.session(id: id))
        var field = try XCTUnwrap(session.item.fields.first)
        field.text = "Ana Garcia"; session.update(field)
        XCTAssertEqual(session.document.page(at: 0)?.annotations.first?.widgetStringValue, "Ana Garcia")
        let exported = try session.export()
        let pdf = try XCTUnwrap(PDFDocument(url: exported))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Ana Garcia") == true, "El PDF compartido debe contener el valor escrito")
        XCTAssertFalse(pdf.page(at: 0)!.annotations.contains { $0.type == "Widget" })
        let reopened = DocumentLibrary(directory: directory)
        XCTAssertEqual(reopened.session(id: id)?.item.fields.first?.text, "Ana Garcia")
        XCTAssertEqual(reopened.session(id: id)?.document.page(at: 0)?.annotations.first?.widgetStringValue, "Ana Garcia")
    }

    func testCheckboxAndMultipageExport() throws {
        let pdf = ExampleDocument.make(widgets: false)
        pdf.insert(ExampleDocument.make(widgets: false).page(at: 0)!, at: 1)
        let session = DocumentSession(item: SavedDocument(title: "Dos páginas", pageCount: 2, fields: []), document: pdf) { _, _ in }
        session.addField(checkbox: true, page: 1)
        var field = try XCTUnwrap(session.item.fields.first)
        field.checked = true; session.update(field)
        XCTAssertEqual(pdf.page(at: 1)?.annotations.first?.contents, "✓")
        XCTAssertEqual(PDFDocument(url: try session.export())?.pageCount, 2)
        field.checked = false; session.update(field)
        XCTAssertEqual(pdf.page(at: 1)?.annotations.count, 0)
    }

    func testCoordinateMappingWithCropOriginAndRotation() {
        let bounds = CGRect(x: 20, y: 30, width: 600, height: 800)
        let rect = CGRect(x: 100, y: 200, width: 300, height: 100)
        let mapped = PDFFormWriter.pdfRect(rect, imageSize: CGSize(width: 1200, height: 1600), bounds: bounds)
        XCTAssertEqual(mapped.minX, 70, accuracy: 0.01)
        XCTAssertEqual(mapped.minY, 680, accuracy: 0.01)
        XCTAssertEqual(mapped.width, 150, accuracy: 0.01)
        let rotated = PDFFormWriter.pdfRect(rect, imageSize: CGSize(width: 1200, height: 1600), bounds: bounds, rotation: 90)
        XCTAssertEqual(rotated.minX, 95, accuracy: 0.01)
        XCTAssertEqual(rotated.minY, 30 + 800 / 12.0, accuracy: 0.01)
    }

    func testRealOfflineModelDetectsPrintedForm() throws {
        let source = ExampleDocument.make(widgets: false)
        let page = source.page(at: 0)!
        let image = page.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        let found = try LocalFieldAI.detect(image)
        XCTAssertGreaterThan(found.count, 0, "Debe ejecutarse el modelo ONNX real, sin red")
        let bounds = page.bounds(for: .cropBox)
        let mapped = found.map { PDFFormWriter.pdfRect($0.rect, imageSize: CGSize(width: image.cgImage!.width, height: image.cgImage!.height), bounds: bounds) }
        let firstTextBox = CGRect(x: 48, y: 842 - 212 - 40, width: 499, height: 40)
        XCTAssertTrue(mapped.contains { $0.intersection(firstTextBox).area > firstTextBox.area * 0.4 }, "La detección debe coincidir con el campo superior y su orientación")
    }

    func testDetectionPreservesEnteredValuesAndAvoidsDuplicates() async throws {
        let pdf = ExampleDocument.make(widgets: false)
        let session = DocumentSession(item: SavedDocument(title: "Prueba IA", pageCount: 1, fields: []), document: pdf) { _, _ in }
        await session.detect()
        XCTAssertNil(session.error)
        var field = try XCTUnwrap(session.item.fields.first)
        field.text = "Conservar este valor"; session.update(field)
        let count = session.item.fields.count
        await session.detect()
        XCTAssertEqual(session.item.fields.count, count)
        XCTAssertEqual(session.item.fields.first { $0.id == field.id }?.text, "Conservar este valor")
    }

    func testCheckboxUsesPrintedLabelRatherThanWidgetIdentifier() throws {
        let pdf = ExampleDocument.make()
        let checkbox = try XCTUnwrap(PDFFormWriter.embeddedFields(in: pdf).first(where: \.checkbox))
        XCTAssertEqual(checkbox.widgetName, "reviewed")
        XCTAssertEqual(checkbox.label, "He revisado los datos del formulario.")
    }

    func testRealOCRFindsCheckboxTextAndNearbyFieldName() throws {
        let pdf = ExampleDocument.make(widgets: false)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let image = page.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        let lines = try FieldLabels.recognize(image)
        let scale = CGFloat(image.cgImage!.width) / 595
        let box = CGRect(x: 48 * scale, y: 510 * scale, width: 22 * scale, height: 22 * scale)
        let label = try XCTUnwrap(FieldLabels.label(for: box, checkbox: true, lines: lines))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("He revisado"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("formulario"))
        let textBox = CGRect(x: 48 * scale, y: 212 * scale, width: 499 * scale, height: 40 * scale)
        XCTAssertEqual(FieldLabels.label(for: textBox, checkbox: false, lines: lines), "Nombre completo")
    }

    func testImportPDFAndImageSurviveRemovingOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Desde Archivos.pdf")
        try ExampleDocument.make().dataRepresentation()!.write(to: url)
        let data = try DocumentImport.read(url)
        try FileManager.default.removeItem(at: url)
        let directory = root.appendingPathComponent("library")
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(DocumentImport.decode(data), title: "Desde Archivos")
        XCTAssertEqual(DocumentLibrary(directory: directory).session(id: id)?.item.fields.count, 4)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            ("Imagen importada" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let imagePDF = try DocumentImport.decode(try XCTUnwrap(image.pngData()))
        let imageID = try library.add(imagePDF, title: "Imagen")
        XCTAssertEqual(DocumentLibrary(directory: directory).session(id: imageID)?.document.pageCount, 1)
        XCTAssertThrowsError(try DocumentImport.decode(Data("incompatible".utf8)))
    }
}
