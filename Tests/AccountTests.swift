import XCTest
import Auth
import PDFKit
@testable import FormScan

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor AccountTransport {
    enum Mode { case session, confirmation, rejected, offline }
    var mode = Mode.session
    private(set) var requests: [URLRequest] = []
    static let userID = UUID(uuidString: "503909F4-34A1-4A49-B72F-DB371D01FEA7")!
    func setMode(_ mode: Mode) { self.mode = mode }
    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        let user: [String: Any] = ["id": Self.userID.uuidString, "aud": "authenticated", "role": "authenticated",
            "email": "person@example.com", "app_metadata": ["provider": "email"], "user_metadata": [:],
            "created_at": "2026-10-01T12:00:00Z", "updated_at": "2026-10-01T12:00:00Z", "is_anonymous": false]
        let body: [String: Any]
        var status = 200
        if mode == .rejected { status = 400; body = ["code": "invalid_credentials", "msg": "backend diagnostic must stay private"] }
        else if request.url!.path.hasSuffix("/recover") || request.url!.path.hasSuffix("/logout") { body = [:] }
        else if request.url!.path.hasSuffix("/user") || mode == .confirmation { body = user }
        else { body = ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "bearer", "expires_in": 3600, "expires_at": Date().timeIntervalSince1970 + 3600, "user": user] }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

@MainActor private final class OAuthFixture: OAuthLaunching {
    var wrongDestination = false
    var authorizeURL: URL?
    func authenticate(_ url: URL, scheme: String) async throws -> URL {
        authorizeURL = url
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let redirect = items.first { $0.name == "redirect_to" }!.value!
        return URL(string: (wrongDestination ? "com.polaca1.formscan://auth/callback/other" : redirect) + "?code=fixture-code")!
    }
}

@MainActor final class AccountTests: XCTestCase {
    private func makeClient(_ transport: AccountTransport, storage: MemoryAuthStorage = MemoryAuthStorage()) -> AuthClient {
        AuthClient(url: URL(string: "https://accounts.example.com/auth/v1")!, flowType: .pkce,
                   storageKey: "fixture.session", localStorage: storage,
                   fetch: { request in try await transport.fetch(request) }, autoRefreshToken: false,
                   emitLocalSessionAsInitialSession: true)
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AccountTests-" + UUID().uuidString)!
    }
    func testPublicConfigurationRejectsSecretKeysAndInsecureOrigins() throws {
        XCTAssertNotNil(AccountConfiguration.load())
        XCTAssertThrowsError(try AccountConfiguration(origin: "https://accounts.example.com", publicKey: "sb_secret_private"))
        XCTAssertThrowsError(try AccountConfiguration(origin: "http://accounts.example.com", publicKey: "sb_publishable_public_fixture_value"))
        XCTAssertThrowsError(try AccountConfiguration(origin: "https://user:password@accounts.example.com", publicKey: "sb_publishable_public_fixture_value"))
    }
    func testCallbackRejectsOtherAttemptsRepeatedCodesAndImplicitTokens() throws {
        let expected = AccountConfiguration.callback("callback", nonce: "expected")
        try AccountCallback.validate(URL(string: expected.absoluteString + "?code=valid")!, expected: expected)
        for suffix in ["?code=", "?code=one&code=two", "?code=one#access_token=token", "?code=one&id_token=token"] {
            XCTAssertThrowsError(try AccountCallback.validate(URL(string: expected.absoluteString + suffix)!, expected: expected))
        }
        XCTAssertThrowsError(try AccountCallback.validate(AccountConfiguration.callback("callback", nonce: "other"), expected: expected))
    }
    func testPasswordLoginPersistsAndRestoresSameIdentityOffline() async throws {
        let transport = AccountTransport(), storage = MemoryAuthStorage()
        let store = AccountStore(client: makeClient(transport, storage: storage), defaults: defaults(), observe: false)
        await store.signIn(email: " Person@Example.com ", password: "fixture-password")
        XCTAssertNil(store.error); XCTAssertEqual(store.user?.id, AccountTransport.userID)
        await transport.setMode(.offline)
        let restored = AccountStore(client: makeClient(transport, storage: storage), defaults: defaults(), observe: false)
        XCTAssertEqual(restored.user, store.user)
        XCTAssertEqual(restored.workspaceKey, AccountTransport.userID.uuidString)
    }
    func testSignupRequiringConfirmationDoesNotInventASession() async {
        let transport = AccountTransport(); await transport.setMode(.confirmation)
        let store = AccountStore(client: makeClient(transport), defaults: defaults(), observe: false)
        await store.signUp(email: "person@example.com", password: "fixture-password", confirmation: "fixture-password")
        XCTAssertNil(store.error); XCTAssertNil(store.user); XCTAssertNil(store.workspaceKey)
        XCTAssertTrue(store.notice?.contains("Revisa tu correo") == true)
    }
    func testGoogleUsesPKCEAndExchangesOnlyExpectedCallback() async throws {
        let transport = AccountTransport(), browser = OAuthFixture()
        let store = AccountStore(client: makeClient(transport), defaults: defaults(), browser: browser, observe: false)
        await store.signInWithGoogle()
        XCTAssertNil(store.error); XCTAssertEqual(store.user?.id, AccountTransport.userID)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(browser.authorizeURL), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "provider" }?.value, "google")
        XCTAssertFalse(query.first { $0.name == "code_challenge" }?.value?.isEmpty ?? true)
        let requests = await transport.requests
        let exchange = try XCTUnwrap(requests.first { $0.url?.query?.contains("pkce") == true })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(exchange.httpBody)) as? [String: Any])
        XCTAssertEqual(body["auth_code"] as? String, "fixture-code")
        XCTAssertFalse((body["code_verifier"] as? String)?.isEmpty ?? true)
    }
    func testGoogleWrongCallbackNeverExchangesCode() async {
        let transport = AccountTransport(), browser = OAuthFixture(); browser.wrongDestination = true
        let store = AccountStore(client: makeClient(transport), defaults: defaults(), browser: browser, observe: false)
        await store.signInWithGoogle()
        XCTAssertNil(store.user); XCTAssertNotNil(store.error)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testAddingPasswordUsesAuthenticatedUpdateAndKeepsUUID() async throws {
        let transport = AccountTransport()
        // Use a single client and transport for the complete login/update contract.
        let account = AccountStore(client: makeClient(transport), defaults: defaults(), observe: false)
        await account.signIn(email: "person@example.com", password: "fixture-password")
        let previous = account.user
        await account.updatePassword("new-fixture-password", confirmation: "new-fixture-password")
        XCTAssertNil(account.error); XCTAssertEqual(account.user, previous)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/signup") == true })
        let update = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" && $0.url?.path.hasSuffix("/user") == true })
        XCTAssertEqual(update.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
    }
    func testRecoveryUsesPKCEAndGenericNotice() async throws {
        let transport = AccountTransport(), prefs = defaults()
        let account = AccountStore(client: makeClient(transport), defaults: prefs, observe: false)
        await account.requestPasswordReset(email: "person@example.com")
        XCTAssertNil(account.error); XCTAssertNil(account.user)
        XCTAssertTrue(account.notice?.hasPrefix("Si existe una cuenta") == true)
        let requests = await transport.requests
        let recovery = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/recover") == true })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recovery.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["code_challenge"])
        let nonce = try XCTUnwrap(prefs.string(forKey: "account.pendingRecovery"))
        await account.handleCallback(URL(string: AccountConfiguration.callback("recovery", nonce: nonce).absoluteString + "?code=verified")!)
        XCTAssertEqual(account.user?.id, AccountTransport.userID); XCTAssertTrue(account.recovering)
        XCTAssertNil(prefs.string(forKey: "account.pendingRecovery"))
        await account.updatePassword("new-fixture-password", confirmation: "new-fixture-password")
        XCTAssertNil(account.error); XCTAssertFalse(account.recovering)
    }
    func testSignOutClearsLocalSessionEvenWhenNetworkFails() async {
        let transport = AccountTransport(), storage = MemoryAuthStorage()
        let client = makeClient(transport, storage: storage)
        let account = AccountStore(client: client, defaults: defaults(), observe: false)
        await account.signIn(email: "person@example.com", password: "fixture-password")
        XCTAssertNotNil(account.user)
        await transport.setMode(.offline); await account.signOut()
        XCTAssertNil(account.user); XCTAssertNil(client.currentSession); XCTAssertNil(account.workspaceKey)
    }
    func testRejectedLoginDoesNotExposeBackendDiagnosticOrCreateAccount() async {
        let transport = AccountTransport(); await transport.setMode(.rejected)
        let account = AccountStore(client: makeClient(transport), defaults: defaults(), observe: false)
        await account.signIn(email: "person@example.com", password: "incorrect")
        XCTAssertNil(account.user); XCTAssertEqual(account.error, "Correo o contraseña incorrectos.")
    }
    func testLibraryMigrationAndAccountIsolationPreserveDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = DocumentWorkspace(root: root)
        workspace.activate("guest")
        let library = try XCTUnwrap(workspace.library)
        let id = try library.add(ExampleDocument.make(), title: "Documento anterior")
        let session = try XCTUnwrap(library.session(id: id))
        var field = try XCTUnwrap(session.item.fields.first); field.text = "Conservar este valor"; session.update(field)
        let first = UUID().uuidString, second = UUID().uuidString
        workspace.activate(first)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.library?.session(id: id)?.item.fields.first?.text, "Conservar este valor")
        workspace.activate(second); XCTAssertEqual(workspace.library?.documents.count, 0)
        workspace.activate("guest"); XCTAssertEqual(workspace.library?.documents.count, 0)
        workspace.activate(first); XCTAssertEqual(workspace.library?.documents.first?.id, id)
    }
    func testFailedLibraryCloseKeepsAllSessionsEditableForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DocumentLibrary(directory: directory)
        let first = try library.add(ExampleDocument.make(), title: "Primero")
        let second = try library.add(ExampleDocument.make(), title: "Segundo")
        let sessions = try [first, second].map { try XCTUnwrap(library.session(id: $0)) }
        let blocked = directory.appendingPathComponent("\(second).json")
        let original = try Data(contentsOf: blocked)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.close())
        try FileManager.default.removeItem(at: blocked)
        try original.write(to: blocked)
        for session in sessions {
            var field = try XCTUnwrap(session.item.fields.first)
            field.text = "Editado después del fallo"; session.update(field); session.flush()
        }
        let restored = DocumentLibrary(directory: directory)
        for id in [first, second] {
            XCTAssertEqual(restored.session(id: id)?.item.fields.first?.text, "Editado después del fallo")
        }
        try library.close()
    }
    func testInvalidWorkspaceNeverShowsPreviousAccountDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = DocumentWorkspace(root: root)
        workspace.activate(UUID().uuidString)
        _ = try XCTUnwrap(workspace.library).add(ExampleDocument.make(), title: "Privado")
        workspace.activate("not-a-uuid")
        XCTAssertNil(workspace.library); XCTAssertNil(workspace.key); XCTAssertNotNil(workspace.error)
    }
}
