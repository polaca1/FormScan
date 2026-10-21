import XCTest
@testable import FormScan

private actor CloudHTTPFixture {
    enum Mode { case normal, duplicate, mismatch, unauthorized, quota }
    var mode = Mode.normal
    var requests: [URLRequest] = []
    var pdf = Data("fixture-pdf-bytes".utf8)
    var catalogue = Data("[]".utf8)
    func set(_ mode: Mode) { self.mode = mode }
    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        var status = 200
        var body = catalogue
        if mode == .unauthorized { status = 401; body = Data("{}".utf8) }
        else if mode == .quota { status = 507; body = Data("{}".utf8) }
        else if request.httpMethod == "POST", request.url!.path.contains("/storage/") {
            if mode == .duplicate || mode == .mismatch { status = 400; body = Data(#"{"statusCode":"409","error":"Duplicate"}"#.utf8) }
            else { body = Data("{}".utf8) }
        } else if request.url!.path.contains("/object/authenticated/") {
            body = mode == .mismatch ? Data("different".utf8) : pdf
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

@MainActor final class CloudTransportTests: XCTestCase {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func client(_ http: CloudHTTPFixture) throws -> SupabaseDocumentCloud {
        let config = try AccountConfiguration(origin: "https://cloud.example.com", publicKey: "sb_publishable_fixture_public_value")
        return SupabaseDocumentCloud(owner: owner, configuration: config, token: { "fixture-user-session" }, fetch: { request in try await http.fetch(request) })
    }
    func testRequestsUseAuthenticatedPrivateStorageAndNoPublicDownloadURL() async throws {
        let http = CloudHTTPFixture(), api = try client(http)
        _ = try await api.catalogue()
        let id = UUID(), revision = UUID()
        let path = SupabaseDocumentCloud.path(owner: owner, id: id, revision: revision)
        try await api.upload(Data("fixture-pdf-bytes".utf8), path: path)
        let metadata = SavedDocument(id: id, title: "Privado", pageCount: 1, fields: [])
        _ = try await api.download(CloudRecord(userID: owner, id: id, revision: revision, objectKey: path, metadata: metadata, deletedAt: nil))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-user-session" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "apikey")?.hasPrefix("sb_publishable_") == true })
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/public/") })
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-upsert"), "false")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertTrue(requests[2].url!.path.contains("/object/authenticated/"))
    }
    func testDuplicateUploadIsAcceptedOnlyWhenStoredBytesMatch() async throws {
        let http = CloudHTTPFixture(), api = try client(http)
        let path = SupabaseDocumentCloud.path(owner: owner, id: UUID(), revision: UUID())
        await http.set(.duplicate)
        try await api.upload(Data("fixture-pdf-bytes".utf8), path: path)
        await http.set(.mismatch)
        do { try await api.upload(Data("fixture-pdf-bytes".utf8), path: path); XCTFail("Must reject different bytes at the same revision") }
        catch let issue as DocumentCloudIssue { XCTAssertEqual(issue.localizedDescription, DocumentCloudIssue.conflict.localizedDescription) }
    }
    func testForeignObjectPathsAndForeignCatalogueAreRejected() async throws {
        let http = CloudHTTPFixture(), api = try client(http)
        let id = UUID(), revision = UUID(), other = UUID()
        let metadata = SavedDocument(id: id, title: "Ajeno", pageCount: 1, fields: [])
        let foreign = CloudRecord(userID: other, id: id, revision: revision, objectKey: SupabaseDocumentCloud.path(owner: other, id: id, revision: revision), metadata: metadata, deletedAt: nil)
        do { _ = try await api.download(foreign); XCTFail("Foreign file must not be requested") } catch { }
        do { try await api.remove(path: "\(other)/folder/file.pdf"); XCTFail("Foreign prefix must not be deleted") } catch { }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        await http.setCatalogue(try JSONEncoder().encode([foreign]))
        do { _ = try await api.catalogue(); XCTFail("Wrong owner must be rejected") } catch { }
    }
    func testExpiredSessionAndQuotaErrorsRemainActionableWithoutBackendDiagnostics() async throws {
        let http = CloudHTTPFixture(), api = try client(http)
        await http.set(.unauthorized)
        do { _ = try await api.catalogue(); XCTFail("Must fail") }
        catch let error as DocumentCloudIssue { XCTAssertEqual(error.localizedDescription, DocumentCloudIssue.session.localizedDescription) }
        await http.set(.quota)
        do { try await api.upload(Data(), path: SupabaseDocumentCloud.path(owner: owner, id: UUID(), revision: UUID())); XCTFail("Must fail") }
        catch let error as DocumentCloudIssue { XCTAssertEqual(error.localizedDescription, DocumentCloudIssue.quota.localizedDescription) }
    }
    func testInitialRevisionAndDeleteParametersEncodeExplicitNullsForRPC() throws {
        let commit = CloudCommit(id: UUID(), expected: nil, revision: UUID(), objectKey: nil, metadata: nil, deleted: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(commit)) as? [String: Any])
        XCTAssertTrue(json["p_expected_revision"] is NSNull)
        XCTAssertTrue(json["p_object_key"] is NSNull)
        XCTAssertTrue(json["p_metadata"] is NSNull)
        XCTAssertEqual(json["p_deleted"] as? Bool, true)
    }
}

private extension CloudHTTPFixture {
    func setCatalogue(_ data: Data) { catalogue = data }
}
