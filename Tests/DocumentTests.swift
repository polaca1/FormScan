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
        XCTAssertEqual(pdf.page(at: 1)?.annotations.first(where: { $0.type == "Ink" })?.contents, "✓")
        XCTAssertEqual(PDFDocument(url: try session.export())?.pageCount, 2)
        field.checked = false; session.update(field)
        XCTAssertFalse(pdf.page(at: 1)!.annotations.contains { $0.type == "Ink" })
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
        field.text = "Conservar este valor"; field.label = "Campo de texto"; session.update(field)
        let count = session.item.fields.count
        await session.detect()
        XCTAssertEqual(session.item.fields.count, count)
        XCTAssertEqual(session.item.fields.first { $0.id == field.id }?.text, "Conservar este valor")
        XCTAssertNotEqual(session.item.fields.first { $0.id == field.id }?.label, "Campo de texto")
    }

    func testAppBundleExposesDocumentsToFiles() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
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
    func testCheckboxIsAVectorTickInLiveSavedAndFlattenedPDF() throws {
        let original = ExampleDocument.make()
        let session = DocumentSession(item: SavedDocument(title: "Casillas", pageCount: 1, fields: PDFFormWriter.embeddedFields(in: original)), document: original) { _, _ in }
        var field = try XCTUnwrap(session.item.fields.first(where: \.checkbox))
        func inkFraction(_ pdf: PDFDocument) throws -> Double {
            let side = 100
            var pixels = [UInt8](repeating: 255, count: side * side * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                let interior = field.rect.insetBy(dx: 3, dy: 3)
                context.scaleBy(x: CGFloat(side) / interior.width, y: CGFloat(side) / interior.height)
                context.translateBy(x: -interior.minX, y: -interior.minY)
                pdf.page(at: 0)!.draw(with: .cropBox, to: context)
            }
            return Double(stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 180 }.count) / Double(side * side)
        }
        XCTAssertLessThan(try inkFraction(original), 0.04, "An unchecked box must remain empty")
        field.checked = true; session.update(field)
        for pdf in [original, try XCTUnwrap(PDFDocument(data: original.dataRepresentation()!)), try XCTUnwrap(PDFDocument(url: session.export()))] {
            let fraction = try inkFraction(pdf)
            XCTAssertGreaterThan(fraction, 0.06, "The tick must actually render")
            XCTAssertLessThan(fraction, 0.45, "A gray filled rectangle is not a tick")
        }
        field.checked = false; session.update(field)
        XCTAssertLessThan(try inkFraction(try XCTUnwrap(PDFDocument(url: session.export()))), 0.04)
    }

    func testDeletingDocumentCancelsQueuedSaveAndAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleDocument.make(), title: "Eliminar")
        let session = try XCTUnwrap(library.session(id: id))
        var field = try XCTUnwrap(session.item.fields.first)
        field.text = "No recrear el archivo"; session.update(field)
        library.delete(try XCTUnwrap(library.documents.first))
        session.flush()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(DocumentLibrary(directory: directory).documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).pdf").path))
    }

}
