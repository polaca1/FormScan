import XCTest
import PDFKit
@testable import FormScan

@MainActor
final class TypingTests: XCTestCase {
    func testTypingKeepsOtherPagesAndTextAnnotationInstancesIntact() throws {
        let pdf = ExampleDocument.make(widgets: false)
        pdf.insert(ExampleDocument.make(widgets: false).page(at: 0)!, at: 1)
        let first = FormEntry(page: 0, rect: CGRect(x: 50, y: 300, width: 300, height: 28), label: "Primero", text: "A")
        let second = FormEntry(page: 1, rect: first.rect, label: "Segundo", text: "Sin cambios")
        let session = DocumentSession(item: SavedDocument(title: "Dos páginas", pageCount: 2, fields: [first, second]), document: pdf) { _, _ in }
        let firstAnnotation = try XCTUnwrap(pdf.page(at: 0)?.annotations.first)
        let secondAnnotation = try XCTUnwrap(pdf.page(at: 1)?.annotations.first)
        var edit = first
        let start = CFAbsoluteTimeGetCurrent()
        for index in 1...200 {
            edit.text = "Texto con acentos: revisión \(index)"; session.update(edit)
        }
        print("Typing regression: 200 incremental edits in \(CFAbsoluteTimeGetCurrent() - start) seconds")
        XCTAssertTrue(pdf.page(at: 0)?.annotations.first === firstAnnotation)
        XCTAssertTrue(pdf.page(at: 1)?.annotations.first === secondAnnotation)
        XCTAssertEqual(firstAnnotation.contents, edit.text)
        edit.text = ""; session.update(edit)
        XCTAssertTrue(pdf.page(at: 0)!.annotations.isEmpty)
        XCTAssertTrue(pdf.page(at: 1)?.annotations.first === secondAnnotation)
        session.invalidate()
    }

    func testRepeatedTypingSavesMetadataWithoutRewritingPDFAndRestoresExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleDocument.make(), title: "Escritura")
        let pdfURL = directory.appendingPathComponent("\(id).pdf")
        let original = try Data(contentsOf: pdfURL)
        library.activeDocumentID = id
        let thumbnail = try XCTUnwrap(library.thumbnail(for: library.documents[0]))
        let session = try XCTUnwrap(library.session(id: id))
        var text = try XCTUnwrap(session.item.fields.first(where: { !$0.checkbox }))
        for index in 1...20 {
            text.text = "Texto persistente \(index)"; session.update(text)
            try session.persistNow()
            XCTAssertEqual(try Data(contentsOf: pdfURL), original, "A typing pause must not serialize the scanned PDF")
        }
        XCTAssertTrue(library.thumbnail(for: library.documents[0]) === thumbnail, "The hidden library must not re-render on a typing pause")
        library.activeDocumentID = nil
        XCTAssertFalse(library.thumbnail(for: library.documents[0]) === thumbnail)
        var check = try XCTUnwrap(session.item.fields.first(where: \.checkbox))
        check.checked = true; session.update(check); try session.persistNow()
        let restored = try XCTUnwrap(DocumentLibrary(directory: directory).session(id: id))
        XCTAssertEqual(restored.item.fields.first?.text, text.text)
        XCTAssertEqual(restored.document.page(at: 0)?.annotations.first?.widgetStringValue, text.text)
        XCTAssertTrue(restored.item.fields.first(where: \.checkbox)?.checked == true)
        let exported = try XCTUnwrap(PDFDocument(url: restored.export()))
        XCTAssertTrue(exported.string?.contains(text.text) == true)
        XCTAssertEqual(try Data(contentsOf: pdfURL), original)
        session.invalidate(); restored.invalidate()
    }

    func testDeletingEmbeddedWidgetPersistsItsRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let id = try library.add(ExampleDocument.make(), title: "Quitar campo")
        let session = try XCTUnwrap(library.session(id: id))
        let field = try XCTUnwrap(session.item.fields.first)
        session.remove(field.id); try session.persistNow()
        let restored = try XCTUnwrap(DocumentLibrary(directory: directory).session(id: id))
        XCTAssertFalse(restored.item.fields.contains { $0.id == field.id })
        XCTAssertFalse(restored.document.page(at: 0)!.annotations.contains { $0.fieldName == field.widgetName })
        session.invalidate(); restored.invalidate()
    }
}
