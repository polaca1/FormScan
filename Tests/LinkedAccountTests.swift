import XCTest
import Auth
import PDFKit
@testable import FormScan

private final class LinkedAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

/// A stateful service contract, exercised through the real Auth SDK. It models
/// Supabase's documented verified-email linking; the app does not match users.
private actor LinkedAccountService {
    let id = UUID()
    var password: String?
    var confirmed = false
    var google = false
    private(set) var signups = 0
    func confirmEmail() { confirmed = true }
    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path
        let input: [String: Any] = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] } ?? [:]
        if path.hasSuffix("/signup") {
            signups += 1; password = input["password"] as? String
        }
        if request.url?.query?.contains("pkce") == true { google = true; confirmed = true }
        if request.httpMethod == "PUT", path.hasSuffix("/user") {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer linked-fixture", confirmed else { throw URLError(.userAuthenticationRequired) }
            password = input["password"] as? String
        }
        if request.url?.query?.contains("grant_type=password") == true {
            guard confirmed, password != nil, input["password"] as? String == password else { throw URLError(.userAuthenticationRequired) }
        }
        var user: [String: Any] = ["id": id.uuidString, "aud": "authenticated", "role": "authenticated",
            "email": "same@example.com", "app_metadata": ["providers": google ? ["google", "email"] : ["email"]],
            "user_metadata": [:], "created_at": "2026-10-01T12:00:00Z", "updated_at": "2026-10-01T12:00:00Z", "is_anonymous": false]
        if confirmed { user["email_confirmed_at"] = "2026-10-01T12:00:00Z" }
        let body: [String: Any]
        if path.hasSuffix("/logout") { body = [:] }
        else if path.hasSuffix("/user") || path.hasSuffix("/signup") { body = user }
        else { body = ["access_token": "linked-fixture", "refresh_token": "linked-refresh", "token_type": "bearer", "expires_in": 3600, "expires_at": Date().timeIntervalSince1970 + 3600, "user": user] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

@MainActor private final class LinkingBrowser: OAuthLaunching {
    func authenticate(_ url: URL, scheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        return URL(string: items.first { $0.name == "redirect_to" }!.value! + "?code=linked-code")!
    }
}

@MainActor final class LinkedAccountTests: XCTestCase {
    private func account(_ service: LinkedAccountService) -> AccountStore {
        let client = AuthClient(url: URL(string: "https://accounts.example.com/auth/v1")!, flowType: .pkce,
            storageKey: "linking", localStorage: LinkedAuthStorage(), fetch: { try await service.fetch($0) },
            autoRefreshToken: false, emitLocalSessionAsInitialSession: true)
        return AccountStore(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, browser: LinkingBrowser(), observe: false)
    }
    private func createDocument(_ workspace: DocumentWorkspace, owner: String) throws -> UUID {
        workspace.activate(owner)
        let library = try XCTUnwrap(workspace.library)
        let id = try library.add(ExampleDocument.make(), title: "Misma cuenta")
        let session = try XCTUnwrap(library.session(id: id))
        var field = try XCTUnwrap(session.item.fields.first); field.text = "Mis documentos"; session.update(field)
        try session.persistNow()
        return id
    }
    func testGoogleThenAddPasswordThenFreshPasswordLoginPreservesDocumentsAndUUID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LinkedAccountService(), google = account(service), workspace = DocumentWorkspace(root: root)
        await google.signInWithGoogle(); XCTAssertNil(google.error)
        let owner = try XCTUnwrap(google.workspaceKey), id = try createDocument(workspace, owner: owner)
        await google.updatePassword("fixture-password", confirmation: "fixture-password")
        XCTAssertNil(google.error); XCTAssertEqual(google.workspaceKey, owner)
        await google.signOut(); workspace.activate(nil)
        let fresh = account(service)
        await fresh.signIn(email: " SAME@Example.com ", password: "fixture-password")
        XCTAssertNil(fresh.error); XCTAssertEqual(fresh.workspaceKey, owner)
        workspace.activate(fresh.workspaceKey)
        XCTAssertEqual(workspace.library?.session(id: id)?.item.fields.first?.text, "Mis documentos")
        let signups = await service.signups; XCTAssertEqual(signups, 0, "Adding a password must never sign up another user")
        try workspace.library?.close()
    }
    func testConfirmedEmailThenGoogleThenPasswordKeepsAccountAndDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LinkedAccountService(), email = account(service), workspace = DocumentWorkspace(root: root)
        await email.signUp(email: "same@example.com", password: "fixture-password", confirmation: "fixture-password")
        XCTAssertNil(email.error); XCTAssertNil(email.user)
        await service.confirmEmail()
        await email.signIn(email: "same@example.com", password: "fixture-password")
        XCTAssertNil(email.error)
        let owner = try XCTUnwrap(email.workspaceKey), id = try createDocument(workspace, owner: owner)
        await email.signOut(); workspace.activate(nil)
        let google = account(service); await google.signInWithGoogle()
        XCTAssertNil(google.error); XCTAssertEqual(google.workspaceKey, owner)
        workspace.activate(google.workspaceKey)
        XCTAssertEqual(workspace.library?.session(id: id)?.item.fields.first?.text, "Mis documentos")
        await google.signOut()
        let fresh = account(service); await fresh.signIn(email: "same@example.com", password: "fixture-password")
        XCTAssertNil(fresh.error); XCTAssertEqual(fresh.workspaceKey, owner)
        let signups = await service.signups; XCTAssertEqual(signups, 1)
        try workspace.library?.close()
    }
}
