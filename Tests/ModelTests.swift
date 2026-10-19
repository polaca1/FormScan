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
    func testRecommendationsDependOnMemoryPowerAndTemperature() {
        let small = DeviceProfile(identifier: "iPhone14,5", memory: 4 * 1_073_741_824)
        let medium = DeviceProfile(identifier: "iPhone15,2", memory: 6 * 1_073_741_824)
        let large = DeviceProfile(identifier: "iPad16,3", memory: 16 * 1_073_741_824)
        XCTAssertEqual(small.recommended(lowPower: false, thermal: .nominal), .compact)
        XCTAssertEqual(medium.recommended(lowPower: false, thermal: .nominal), .nano)
        XCTAssertEqual(large.recommended(lowPower: true, thermal: .nominal), .compact)
        XCTAssertEqual(large.parallelism(lowPower: false, thermal: .serious), 1)
        XCTAssertEqual(small.parallelism(lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(medium.parallelism(lowPower: false, thermal: .nominal), 2)
        XCTAssertEqual(large.parallelism(lowPower: false, thermal: .nominal), 3)
    }

    func testNanoVariantsAreOneVoteAndCrossFamilyAgreementRefinesGeometry() throws {
        let nano = DetectedField(rect: CGRect(x: 10, y: 10, width: 100, height: 20), category: 0, confidence: 0.8)
        let compact = DetectedField(rect: CGRect(x: 12, y: 10, width: 100, height: 20), category: 0, confidence: 0.9)
        let detailed = DetectedField(rect: CGRect(x: 14, y: 10, width: 100, height: 20), category: 0, confidence: 0.85)
        let sameFamily = try XCTUnwrap(FieldEnsemble.fuse([.nano: [nano], .compact: [compact]]).first)
        XCTAssertEqual(sameFamily.rect.minX, 10)
        XCTAssertEqual(sameFamily.confidence, 0.8)
        let fused = FieldEnsemble.fuse([.nano: [nano], .compact: [compact], .detailed: [detailed]])
        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused[0].rect.minX, 12)
    }

    func testThreeRealModelsPublishProgressivelyAndPreserveDocumentEdits() async throws {
        let source = ExampleDocument.make(widgets: false)
        let image = source.page(at: 0)!.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        let jobs = try [(AIModel.nano, Bundle.main.url(forResource: "model", withExtension: "onnx")),
                        (.compact, Bundle(for: ModelTests.self).url(forResource: "nano-compact", withExtension: "onnx")),
                        (.detailed, Bundle(for: ModelTests.self).url(forResource: "ffdetr-mobile-int8", withExtension: "onnx"))].map {
            InferenceJob(model: $0.0, url: try XCTUnwrap($0.1))
        }
        var reports: [AIModel] = []
        await FieldEnsemble.run(image: image, jobs: jobs, parallelism: 3) { result, completed in
            reports.append(result.model)
            XCTAssertEqual(completed, reports.count)
            switch result.fields {
            case .success(let fields): XCTAssertFalse(fields.isEmpty)
            case .failure(let message): XCTFail(message)
            }
        }
        XCTAssertEqual(Set(reports), Set(AIModel.allCases))
        let document = ExampleDocument.make()
        let session = DocumentSession(item: SavedDocument(title: "Multi", pageCount: 1, fields: PDFFormWriter.embeddedFields(in: document)), document: document) { _, _ in }
        var name = try XCTUnwrap(session.item.fields.first)
        name.text = "Valor del usuario"; session.update(name)
        var checkbox = try XCTUnwrap(session.item.fields.first(where: \.checkbox))
        checkbox.checked = true; session.update(checkbox)
        await session.detect(jobs: jobs, parallelism: 2)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.item.analyzed, true)
        XCTAssertEqual(session.item.fields.first { $0.id == name.id }?.text, "Valor del usuario")
        XCTAssertEqual(session.item.fields.first { $0.id == checkbox.id }?.checked, true)
    }

}
