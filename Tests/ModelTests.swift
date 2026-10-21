import XCTest
import PDFKit
import CryptoKit
@testable import FormScan

@MainActor
final class ModelTests: XCTestCase {
    func testAllThreeResourcesAreBundledVerifiedAndRunOffline() async throws {
        let engine = AnalysisEngine()
        XCTAssertEqual(Set(engine.analysisJobs.map(\.model)), Set(AIModel.allCases))
        let document = ExampleDocument.make(widgets: false)
        let image = document.page(at: 0)!.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        for model in AIModel.allCases {
            let url = try XCTUnwrap(engine.url(for: model))
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, Int(model.bytes))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), model.checksum)
            let fields = try await Task.detached { try LocalFieldAI.detect(image, model: model, modelURL: url) }.value
            XCTAssertFalse(fields.isEmpty)
        }
    }

    func testAnalysisIgnoresLegacyUserModelPreferences() {
        let defaults = UserDefaults.standard
        defaults.set("detailed", forKey: "ai.model")
        defaults.set(false, forKey: "ai.multi")
        defer { defaults.removeObject(forKey: "ai.model"); defaults.removeObject(forKey: "ai.multi") }
        let engine = AnalysisEngine(device: DeviceProfile(memory: 6 * 1_073_741_824))
        XCTAssertEqual(engine.analysisJobs.count, 3)
        XCTAssertEqual(Set(engine.analysisJobs.map(\.model)), Set(AIModel.allCases))
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
