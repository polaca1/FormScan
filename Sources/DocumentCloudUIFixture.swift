#if DEBUG
import Foundation
import PDFKit

/// Simulator-only account service. Never compiled into a distributed IPA and
/// never contacts the production service or creates a real account.
@MainActor final class DocumentCloudUIFixture: DocumentCloudAPI {
    let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    private let directory: URL
    private let offline: Bool
    init() throws {
        let arguments = ProcessInfo.processInfo.arguments
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestCloudServer")
        offline = arguments.contains("-ui-testing-cloud-error")
        if arguments.contains("-ui-testing") { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("record.json").path) {
            let pdf = ExampleDocument.make()
            var fields = PDFFormWriter.embeddedFields(in: pdf)
            if let index = fields.firstIndex(where: \.checkbox) { fields[index].checked = true }
            let item = SavedDocument(title: "Documento recuperado", pageCount: pdf.pageCount, fields: fields,
                                     analyzed: true, analysisVersion: DocumentSession.analysisVersion)
            PDFFormWriter.synchronize(fields, in: pdf)
            let revision = UUID()
            let canonical = SupabaseDocumentCloud.path(owner: owner, id: item.id, revision: revision)
            try pdf.dataRepresentation()!.write(to: file(canonical), options: .atomic)
            try store(CloudRecord(userID: owner, id: item.id, revision: revision, objectKey: canonical, metadata: item, deletedAt: nil))
        }
    }
    private func file(_ path: String) -> URL { directory.appendingPathComponent(String(path.split(separator: "/").last!)) }
    private func record() throws -> CloudRecord { try JSONDecoder().decode(CloudRecord.self, from: Data(contentsOf: directory.appendingPathComponent("record.json"))) }
    private func store(_ record: CloudRecord) throws { try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("record.json"), options: .atomic) }
    func catalogue() async throws -> [CloudRecord] {
        if offline { throw DocumentCloudIssue.unavailable }
        return [try record()]
    }
    func download(_ record: CloudRecord) async throws -> Data { try Data(contentsOf: file(record.objectKey!)) }
    func upload(_ data: Data, path: String) async throws { try data.write(to: file(path), options: .atomic) }
    func remove(path: String) async throws {
        let url = file(path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func commit(_ change: CloudCommit) async throws -> CloudCommitResult {
        let old = try record()
        guard old.revision == change.expected else { return CloudCommitResult(status: "conflict", document: old) }
        let next = CloudRecord(userID: owner, id: change.id, revision: change.revision,
                               objectKey: change.objectKey ?? old.objectKey, metadata: change.metadata ?? old.metadata,
                               deletedAt: change.deleted ? "2026-10-21T00:00:00Z" : nil)
        try store(next)
        return CloudCommitResult(status: "saved", document: next)
    }
}
#endif
