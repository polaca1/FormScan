import XCTest
import PDFKit
@testable import FormScan

@MainActor
final class ModelTests: XCTestCase {
    func testInstallBothOptionalModelsRunInferencePersistAndRemove() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = ModelStore(directory: directory, defaults: defaults)
        XCTAssertEqual(store.active, .nano)
        let document = ExampleDocument.make(widgets: false)
        let image = document.page(at: 0)!.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        for (model, filename) in [(AIModel.compact, "nano-compact"), (.detailed, "ffdetr-mobile-int8")] {
            let url = try XCTUnwrap(Bundle(for: ModelTests.self).url(forResource: filename, withExtension: "onnx"))
            await store.install(model, from: url)
            XCTAssertNil(store.error)
            XCTAssertTrue(store.installed.contains(model))
            XCTAssertEqual(store.active, model)
            let installedURL = try XCTUnwrap(store.url(for: model))
            let fields = try await Task.detached { try LocalFieldAI.detect(image, model: model, modelURL: installedURL) }.value
            XCTAssertGreaterThan(fields.count, 0, "El modelo opcional debe detectar campos reales en el ejemplo")
        }
        let reopened = ModelStore(directory: directory, defaults: defaults)
        XCTAssertEqual(reopened.active, .detailed)
        reopened.remove(.detailed)
        XCTAssertEqual(reopened.active, .nano)
        XCTAssertFalse(reopened.installed.contains(.detailed))
        XCTAssertTrue(reopened.installed.contains(.compact))
    }

    func testCorruptedModelCannotReplaceCurrentSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = directory.appendingPathComponent("bad.onnx")
        try Data(repeating: 0, count: Int(AIModel.compact.bytes)).write(to: corrupt)
        let store = ModelStore(directory: directory, defaults: defaults)
        await store.install(.compact, from: corrupt)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.active, .nano)
        XCTAssertFalse(store.installed.contains(.compact))
        XCTAssertNil(store.downloading)
    }
}
