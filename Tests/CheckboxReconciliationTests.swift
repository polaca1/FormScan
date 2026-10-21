import XCTest
import PDFKit
@testable import FormScan

@MainActor final class CheckboxReconciliationTests: XCTestCase {
    func testSavedTextDuplicateOnNativeCheckboxIsRepairedWithoutDiscardingItsValue() throws {
        let pdf = ExampleDocument.make()
        let fields = PDFFormWriter.embeddedFields(in: pdf)
        let checkbox = try XCTUnwrap(fields.first(where: \.checkbox))
        let duplicate = FormEntry(page: checkbox.page, rect: checkbox.rect, label: "Campo de texto", text: "Hola", origin: "model")
        let item = SavedDocument(title: "Duplicado", pageCount: 1, fields: fields + [duplicate], analyzed: true, analysisVersion: 3)
        let session = DocumentSession(item: item, document: pdf) { _, _ in }
        XCTAssertEqual(session.item.fields.count, 4)
        let repaired = try XCTUnwrap(session.item.fields.first(where: \.checkbox))
        XCTAssertEqual(repaired.id, checkbox.id)
        XCTAssertEqual(repaired.recoveredText, "Hola")
        XCTAssertFalse(repaired.checked)
        XCTAssertFalse(session.item.fields.contains { !$0.checkbox && FieldReconciliation.overlaps($0.rect, checkbox.rect) })
        let encoded = try JSONEncoder().encode(session.item)
        XCTAssertEqual(try JSONDecoder().decode(SavedDocument.self, from: encoded).fields.first(where: \.checkbox)?.recoveredText, "Hola")
    }
    func testThreeResourcesRespectNativeFieldTypesAndNeverAddTextOnCheckbox() async throws {
        let pdf = ExampleDocument.make()
        let session = DocumentSession(item: SavedDocument(title: "Ejemplo", pageCount: 1, fields: PDFFormWriter.embeddedFields(in: pdf)), document: pdf) { _, _ in }
        let jobs = AnalysisEngine().analysisJobs
        XCTAssertEqual(jobs.count, 3)
        await session.detect(jobs: jobs, parallelism: 2)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.item.fields.count, 4)
        XCTAssertEqual(session.item.fields.filter(\.checkbox).count, 1)
        XCTAssertEqual(session.item.fields.filter { !$0.checkbox }.count, 3)
        XCTAssertEqual(session.item.analysisVersion, 4)
    }
    func testCategoryDisagreementDropsOnlyTheCoincidentSquareAndPreservesManualFields() {
        let square = CGRect(x: 40, y: 80, width: 20, height: 20)
        let check = DetectedField(rect: square, category: 1, confidence: 0.8)
        let wrongText = DetectedField(rect: square.insetBy(dx: -1, dy: -1), category: 0, confidence: 0.9)
        let nextText = DetectedField(rect: CGRect(x: 75, y: 80, width: 180, height: 20), category: 0, confidence: 0.9)
        let fused = FieldEnsemble.fuse([.nano: [check, nextText], .detailed: [wrongText]])
        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused.filter { $0.category == 1 }.count, 1)
        let manual = FormEntry(page: 0, rect: square, label: "Texto manual", text: "Conservar", origin: "manual")
        let anchor = FormEntry(page: 0, rect: square, label: "Casilla real", checkbox: true, widgetName: "native")
        XCTAssertEqual(FieldReconciliation.repair([anchor, manual]).count, 2)
    }
}
