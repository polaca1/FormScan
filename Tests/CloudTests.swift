import XCTest
import PDFKit
@testable import FormScan

@MainActor private final class CloudServerFixture: DocumentCloudAPI {
    let owner: UUID
    var records: [UUID: CloudRecord] = [:]
    var files: [String: Data] = [:]
    var offline = false
    var loseNextCommitResponse = false
    var uploads = 0
    var commits = 0
    var downloads = 0
    var catalogues = 0
    var onDownload: (() -> Void)?
    init(owner: UUID = UUID()) { self.owner = owner }
    func catalogue() async throws -> [CloudRecord] {
        catalogues += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return Array(records.values)
    }
    func download(_ record: CloudRecord) async throws -> Data {
        downloads += 1
        guard !offline, record.userID == owner, let path = record.objectKey, let data = files[path] else { throw DocumentCloudIssue.unavailable }
        onDownload?(); onDownload = nil
        return data
    }
    func upload(_ data: Data, path: String) async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        if let previous = files[path], previous != data { throw DocumentCloudIssue.conflict }
        uploads += 1; files[path] = data
    }
    func remove(path: String) async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        guard !records.values.contains(where: { !$0.deleted && $0.objectKey == path }) else { throw DocumentCloudIssue.conflict }
        files[path] = nil
    }
    func commit(_ commit: CloudCommit) async throws -> CloudCommitResult {
        if offline { throw URLError(.notConnectedToInternet) }
        commits += 1
        if let current = records[commit.id], current.revision == commit.revision { return CloudCommitResult(status: "saved", document: current) }
        guard records[commit.id]?.revision == commit.expected else { return CloudCommitResult(status: "conflict", document: records[commit.id]) }
        let record: CloudRecord
        if commit.deleted {
            guard let old = records[commit.id] else { return CloudCommitResult(status: "missing", document: nil) }
            record = CloudRecord(userID: owner, id: old.id, revision: commit.revision, objectKey: old.objectKey, metadata: old.metadata, deletedAt: "2026-10-21T12:00:00Z")
        } else {
            guard let metadata = commit.metadata, let path = commit.objectKey, files[path] != nil else { throw DocumentCloudIssue.invalidDocument }
            record = CloudRecord(userID: owner, id: commit.id, revision: commit.revision, objectKey: path, metadata: metadata, deletedAt: nil)
        }
        records[record.id] = record
        if loseNextCommitResponse { loseNextCommitResponse = false; throw URLError(.networkConnectionLost) }
        return CloudCommitResult(status: "saved", document: record)
    }
    func changeRemote(_ id: UUID, text: String) {
        let old = records[id]!
        var item = old.metadata; item.fields[0].text = text; item.modified = item.modified.addingTimeInterval(10)
        let revision = UUID()
        let canonical = SupabaseDocumentCloud.path(owner: owner, id: id, revision: revision)
        records[id] = CloudRecord(userID: owner, id: id, revision: revision, objectKey: canonical, metadata: item, deletedAt: nil)
        files[canonical] = files[old.objectKey!] // Values are synchronized from metadata on restore.
    }
}

@MainActor final class CloudTests: XCTestCase {
    private var directories: [URL] = []
    private func library() -> DocumentLibrary {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return DocumentLibrary(directory: directory)
    }
    private func cleanup() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; directories = [] }
    private func connect(_ library: DocumentLibrary, _ server: CloudServerFixture) -> DocumentCloudController {
        let cloud = DocumentCloudController(); cloud.connect(library: library, api: server, automatically: false)
        return cloud
    }
    private func edit(_ library: DocumentLibrary, _ id: UUID, _ value: String) throws {
        let session = try XCTUnwrap(library.session(id: id))
        var field = try XCTUnwrap(session.item.fields.first); field.text = value; session.update(field); session.flush()
    }
    func testUploadThenFreshInstallationRecoversAnswersCheckboxAndExport() async throws {
        defer { cleanup() }
        let first = library(), server = CloudServerFixture(), cloud = DocumentCloudController()
        let id = try first.add(ExampleDocument.make(), title: "Privado")
        try edit(first, id, "Restaurado desde la cuenta")
        let session = try XCTUnwrap(first.session(id: id)); var check = try XCTUnwrap(session.item.fields.first(where: \.checkbox))
        check.checked = true; session.update(check)
        cloud.connect(library: first, api: server, automatically: false); await cloud.synchronizeNow()
        XCTAssertNil(cloud.error); XCTAssertFalse(cloud.hasPendingChanges)
        let second = library(), restored = connect(second, server)
        await restored.synchronizeNow()
        XCTAssertNil(restored.error); XCTAssertEqual(second.documents.count, 1)
        let recovered = try XCTUnwrap(second.session(id: id))
        XCTAssertEqual(recovered.item.fields.first?.text, "Restaurado desde la cuenta")
        XCTAssertTrue(recovered.item.fields.first(where: \.checkbox)?.checked == true)
        XCTAssertNotNil(PDFDocument(url: try recovered.export()))
    }
    func testEmptyNewInstallationNeverUploadsWhenRemoteDownloadFails() async throws {
        defer { cleanup() }
        let server = CloudServerFixture(), original = library()
        let id = try original.add(ExampleDocument.make(), title: "Existe")
        let first = connect(original, server); await first.synchronizeNow()
        let revision = server.records[id]?.revision, uploads = server.uploads
        server.offline = true
        let empty = library(), new = connect(empty, server)
        await new.synchronizeNow()
        XCTAssertNotNil(new.error); XCTAssertTrue(empty.documents.isEmpty)
        XCTAssertEqual(server.uploads, uploads); XCTAssertEqual(server.records[id]?.revision, revision)
        server.offline = false; await new.synchronizeNow()
        XCTAssertEqual(empty.documents.first?.id, id)
    }
    func testOfflineEditsRemainPendingAcrossRestartAndRetry() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Sin conexión")
        server.offline = true; try edit(local, id, "Pendiente")
        await cloud.synchronizeNow(); XCTAssertTrue(cloud.hasPendingChanges); XCTAssertNotNil(cloud.error)
        cloud.disconnect()
        let reopened = DocumentLibrary(directory: local.directory), retry = connect(reopened, server)
        server.offline = false; await retry.synchronizeNow()
        XCTAssertNil(retry.error); XCTAssertEqual(server.records[id]?.metadata.fields.first?.text, "Pendiente")
        XCTAssertFalse(retry.hasPendingChanges)
    }
    func testSimultaneousEditsKeepBothVersionsInsteadOfOverwritingRemote() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Conflicto")
        await cloud.synchronizeNow(); try edit(local, id, "Cambio local")
        server.changeRemote(id, text: "Cambio remoto")
        await cloud.synchronizeNow()
        XCTAssertNil(cloud.error); XCTAssertNotNil(cloud.notice)
        XCTAssertEqual(local.documents.count, 2)
        XCTAssertEqual(server.records[id]?.metadata.fields.first?.text, "Cambio remoto")
        let copy = try XCTUnwrap(local.documents.first { $0.id != id })
        XCTAssertEqual(copy.fields.first?.text, "Cambio local")
        XCTAssertEqual(server.records[copy.id]?.metadata.fields.first?.text, "Cambio local")
    }
    func testRemoteUpdatesWaitForActiveEditorAndPreserveTypingDuringDownload() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Abierto")
        await cloud.synchronizeNow(); local.activeDocumentID = id
        server.changeRemote(id, text: "Otro dispositivo")
        await cloud.synchronizeNow()
        XCTAssertNotNil(cloud.error); XCTAssertEqual(local.documents.count, 1)
        XCTAssertEqual(local.documents.first?.fields.first?.text, "")
        local.activeDocumentID = nil
        server.onDownload = { try? self.edit(local, id, "Escrito durante la descarga") }
        await cloud.synchronizeNow()
        XCTAssertEqual(local.documents.count, 2)
        XCTAssertTrue(local.documents.contains { $0.fields.first?.text == "Escrito durante la descarga" })
    }
    func testDeleteUsesTombstoneAndDoesNotRestoreItFromStaleCatalogue() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Eliminar")
        await cloud.synchronizeNow(); local.delete(try XCTUnwrap(local.documents.first))
        await cloud.synchronizeNow()
        XCTAssertNil(cloud.error); XCTAssertTrue(local.documents.isEmpty)
        XCTAssertTrue(server.records[id]?.deleted == true)
        XCTAssertTrue(server.files.isEmpty)
        let fresh = library(), restored = connect(fresh, server); await restored.synchronizeNow()
        XCTAssertTrue(fresh.documents.isEmpty)
    }
    func testDeletionCannotDestroyNewerRemoteEdits() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Cambió")
        await cloud.synchronizeNow(); local.delete(try XCTUnwrap(local.documents.first))
        server.changeRemote(id, text: "Conservar la edición nueva")
        await cloud.synchronizeNow()
        XCTAssertNil(cloud.error); XCTAssertNotNil(cloud.notice)
        XCTAssertEqual(local.documents.first?.fields.first?.text, "Conservar la edición nueva")
        XCTAssertFalse(server.records[id]?.deleted == true)
    }
    func testLostCommitResponseIsReconciledWithoutDuplicateUploadOrLostNewEdits() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Respuesta perdida")
        server.loseNextCommitResponse = true; await cloud.synchronizeNow()
        XCTAssertNotNil(cloud.error); XCTAssertEqual(server.records.count, 1)
        cloud.disconnect()
        let next = connect(local, server)
        await next.synchronizeNow()
        XCTAssertNil(next.error); XCTAssertEqual(server.uploads, 1); XCTAssertEqual(server.records.count, 1)
        try edit(local, id, "Después de recuperar")
        await next.synchronizeNow()
        XCTAssertEqual(server.records[id]?.metadata.fields.first?.text, "Después de recuperar")
        XCTAssertEqual(server.files.count, 1, "Confirmed old revisions must not consume quota indefinitely")
    }
    func testDeleteAfterLostUploadResponseStillDeletesTheCommittedDocument() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        _ = try local.add(ExampleDocument.make(), title: "Eliminar pendiente")
        server.loseNextCommitResponse = true; await cloud.synchronizeNow()
        local.delete(try XCTUnwrap(local.documents.first)); await cloud.synchronizeNow()
        XCTAssertNil(cloud.error); XCTAssertTrue(local.documents.isEmpty)
        XCTAssertTrue(server.records.values.allSatisfy(\.deleted)); XCTAssertTrue(server.files.isEmpty)
    }
    func testCorruptOrForeignJournalCannotUploadDocumentsUnderAnotherAccount() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture()
        _ = try local.add(ExampleDocument.make(), title: "No mezclar")
        let cloud = connect(local, server); await cloud.synchronizeNow(); cloud.disconnect()
        let other = CloudServerFixture(), isolated = connect(local, other)
        await isolated.synchronizeNow()
        XCTAssertNotNil(isolated.error); XCTAssertEqual(other.catalogues, 0); XCTAssertEqual(other.uploads, 0)
        try Data("invalid-json".utf8).write(to: local.directory.appendingPathComponent(".cloud-state.json"))
        let corrupt = connect(local, server), previous = server.uploads
        await corrupt.synchronizeNow()
        XCTAssertNotNil(corrupt.error); XCTAssertEqual(server.uploads, previous)
        XCTAssertEqual(local.documents.count, 1)
    }
    func testDeleteDuringDownloadRemainsPendingInsteadOfBeingUndone() async throws {
        defer { cleanup() }
        let local = library(), server = CloudServerFixture(), cloud = connect(local, server)
        let id = try local.add(ExampleDocument.make(), title: "Borrar durante descarga")
        await cloud.synchronizeNow(); server.changeRemote(id, text: "Cambio")
        server.onDownload = { if let item = local.documents.first { local.delete(item) } }
        await cloud.synchronizeNow()
        XCTAssertTrue(local.documents.isEmpty)
        XCTAssertFalse(try local.deletionRequests().isEmpty)
    }
}
