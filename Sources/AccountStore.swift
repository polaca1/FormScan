import Foundation
import Combine
import Auth
import AuthenticationServices
import UIKit

struct AccountConfiguration {
    let origin: URL
    let publicKey: String
    static let scheme = "com.polaca1.formscan"

    init(origin: String, publicKey: String) throws {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, (url.fragment == nil || url.fragment == "_=_" || url.fragment == ""),
              url.path.isEmpty || url.path == "/" else { throw AccountIssue.unavailable }
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var isPublic = key.hasPrefix("sb_publishable_") && key.count > 25
        if key.hasPrefix("eyJ"), let payload = key.split(separator: ".").dropFirst().first {
            var encoded = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isPublic = claims["role"] as? String == "anon"
            }
        }
        guard isPublic else { throw AccountIssue.unavailable }
        self.origin = url; self.publicKey = key
    }
    static func load(bundle: Bundle = .main) -> AccountConfiguration? {
        guard let url = bundle.url(forResource: "AccountConfiguration", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let origin = values["origin"], let key = values["publicKey"] else { return nil }
        return try? Self(origin: origin, publicKey: key)
    }
    static func callback(_ purpose: String, nonce: String) -> URL {
        URL(string: "\(scheme)://auth/\(purpose)/\(nonce)")!
    }
}

enum AccountIssue: LocalizedError {
    case unavailable, invalidEmail, weakPassword, passwordMismatch, invalidCallback, unverifiedEmail
    var errorDescription: String? {
        switch self {
        case .unavailable: "El acceso no está disponible en este momento. Inténtalo más tarde."
        case .invalidEmail: "Introduce una dirección de correo válida."
        case .weakPassword: "Usa una contraseña de al menos 8 caracteres."
        case .passwordMismatch: "Las contraseñas no coinciden."
        case .invalidCallback: "El enlace ha caducado o no corresponde a este intento. Solicita uno nuevo."
        case .unverifiedEmail: "Confirma tu correo antes de añadir una contraseña. También puedes entrar con Google usando ese mismo correo."
        }
    }
}

struct AccountIdentity: Equatable {
    let id: UUID
    let email: String
    init(_ user: User) { id = user.id; email = user.email ?? "" }
}

/// Only the expected native destination and a single PKCE code are accepted.
/// Server identity remains authoritative; email strings never grant data access.
enum AccountCallback {
    static func validate(_ url: URL, expected: URL) throws {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard url.scheme == expected.scheme, url.host == expected.host, url.path == expected.path,
              url.user == nil, url.password == nil, url.port == nil, (url.fragment == nil || url.fragment == "_=_" || url.fragment == ""),
              let query = components?.queryItems,
              query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code.utf8.count <= 4096,
              !query.contains(where: { ["access_token", "refresh_token", "id_token", "error", "error_code", "error_description"].contains($0.name) }) else {
            throw AccountIssue.invalidCallback
        }
    }
}

@MainActor
protocol OAuthLaunching {
    func authenticate(_ url: URL, scheme: String) async throws -> URL
}

@MainActor
final class NativeOAuthBrowser: NSObject, OAuthLaunching, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    func authenticate(_ url: URL, scheme: String) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let error { self?.finish(.failure(error)) }
                        else if let url { self?.finish(.success(url)) }
                        else { self?.finish(.failure(AccountIssue.invalidCallback)) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                if !session.start() { finish(.failure(AccountIssue.unavailable)) }
            }
        } onCancel: {
            Task { @MainActor in
                self.session?.cancel()
                self.finish(.failure(CancellationError()))
            }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation; continuation = nil; session = nil
        pending?.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var user: AccountIdentity?
    @Published private(set) var restoring = true
    @Published private(set) var busy = false
    @Published private(set) var recovering = false
    @Published private(set) var guest = false
    @Published var error: String?
    @Published var notice: String?
    let configured: Bool
    private let client: AuthClient?
    private let defaults: UserDefaults
    private let browser: any OAuthLaunching
    private var observation: Task<Void, Never>?
    private let guestKey = "account.continueOnDevice"

    init(configuration: AccountConfiguration? = AccountConfiguration.load(), client: AuthClient? = nil,
         defaults: UserDefaults = .standard, browser: (any OAuthLaunching)? = nil, observe: Bool = true) {
        self.defaults = defaults; self.browser = browser ?? NativeOAuthBrowser()
        configured = configuration != nil || client != nil
        guest = defaults.bool(forKey: guestKey)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ui-testing") || args.contains("-ui-testing-reopen") {
            self.client = nil; guest = !args.contains("-ui-testing-welcome"); restoring = false
            if args.contains("-ui-testing-welcome") { defaults.removeObject(forKey: "onboarding.complete") }
            return
        }
        #endif
        if let client { self.client = client }
        else if let configuration {
            self.client = AuthClient(url: configuration.origin.appendingPathComponent("auth/v1"),
                                     headers: ["apikey": configuration.publicKey], flowType: .pkce,
                                     storageKey: "formscan.auth.v1",
                                     localStorage: KeychainLocalStorage(service: "com.polaca1.formscan.auth"),
                                     emitLocalSessionAsInitialSession: true)
        } else { self.client = nil }
        user = self.client?.currentUser.map(AccountIdentity.init)
        guard let client = self.client, observe else { restoring = false; return }
        observation = Task { [weak self, changes = client.authStateChanges] in
            for await (event, session) in changes {
                guard !Task.isCancelled else { break }
                self?.user = session.map { AccountIdentity($0.user) }
                self?.restoring = false
                if event == .passwordRecovery { self?.recovering = true }
                if event == .signedOut { self?.recovering = false }
            }
        }
    }
    deinit { observation?.cancel() }
    var workspaceKey: String? { restoring || recovering ? nil : user?.id.uuidString ?? (guest ? "guest" : nil) }
    func continueOnDevice() { guest = true; defaults.set(true, forKey: guestKey); clearMessages() }
    func clearMessages() { error = nil; notice = nil }
    static func email(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw AccountIssue.invalidEmail }
        return email
    }
    static func password(_ value: String, confirmation: String? = nil) throws {
        guard value.count >= 8 else { throw AccountIssue.weakPassword }
        if let confirmation, value != confirmation { throw AccountIssue.passwordMismatch }
    }
    private func perform(_ work: (AuthClient) async throws -> Void) async {
        guard !busy else { return }; busy = true; clearMessages()
        defer { busy = false }
        do { guard let client else { throw AccountIssue.unavailable }; try await work(client) }
        catch is CancellationError { }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { }
        catch { self.error = Self.message(error) }
    }
    func signIn(email: String, password: String) async {
        await perform { client in
            let address = try Self.email(email)
            guard !password.isEmpty else { throw AccountIssue.weakPassword }
            let session = try await client.signIn(email: address, password: password)
            user = AccountIdentity(session.user)
        }
    }
    func signUp(email: String, password: String, confirmation: String) async {
        await perform { client in
            let address = try Self.email(email); try Self.password(password, confirmation: confirmation)
            let nonce = UUID().uuidString
            let response = try await client.signUp(email: address, password: password,
                                                  redirectTo: AccountConfiguration.callback("confirm", nonce: nonce))
            defaults.set(nonce, forKey: "account.pendingConfirm")
            if let session = response.session { user = AccountIdentity(session.user) }
            else { notice = "Revisa tu correo para confirmar la cuenta. Si ya entrabas con Google, continúa con Google y elige Crear o cambiar contraseña en Ajustes; conservarás tus documentos." }
        }
    }
    func signInWithGoogle() async {
        await perform { client in
            guard user == nil else { throw AccountIssue.unavailable }
            let expected = AccountConfiguration.callback("callback", nonce: UUID().uuidString)
            let session = try await client.signInWithOAuth(provider: .google, redirectTo: expected,
                                                           queryParams: [("prompt", "select_account")]) { [browser] url in
                let result = try await browser.authenticate(url, scheme: AccountConfiguration.scheme)
                try AccountCallback.validate(result, expected: expected)
                return result
            }
            user = AccountIdentity(session.user)
        }
    }
    func requestPasswordReset(email: String) async {
        await perform { client in
            let address = try Self.email(email), nonce = UUID().uuidString
            try await client.resetPasswordForEmail(address, redirectTo: AccountConfiguration.callback("recovery", nonce: nonce))
            defaults.set(nonce, forKey: "account.pendingRecovery")
            notice = "Si existe una cuenta con ese correo, recibirás un enlace para elegir una contraseña nueva."
        }
    }
    func updatePassword(_ password: String, confirmation: String) async {
        await perform { client in
            try Self.password(password, confirmation: confirmation)
            guard let previous = user else { throw AccountIssue.unavailable }
            // Validate the server session before adding password access to a
            // Google account. The authenticated UUID owns the documents; a
            // client-entered email must never select or merge accounts.
            let session = try await client.session
            guard session.user.id == previous.id else { throw AccountIssue.unavailable }
            let verified = try await client.user()
            guard verified.id == previous.id, verified.email?.lowercased() == previous.email.lowercased() else { throw AccountIssue.unavailable }
            guard verified.emailConfirmedAt != nil else { throw AccountIssue.unverifiedEmail }
            let updated = try await client.update(user: UserAttributes(password: password))
            guard updated.id == previous.id, updated.email?.lowercased() == previous.email.lowercased() else { throw AccountIssue.unavailable }
            user = AccountIdentity(updated); recovering = false; notice = "Contraseña guardada. Puedes entrar con este correo y contraseña o con Google usando el mismo correo verificado. Tus documentos siguen en la misma cuenta."
        }
    }
    func handleCallback(_ url: URL) async {
        guard url.scheme == AccountConfiguration.scheme, url.host == "auth" else { return }
        await perform { client in
            let recovery = url.path.hasPrefix("/recovery/")
            let key = recovery ? "account.pendingRecovery" : "account.pendingConfirm"
            guard let nonce = defaults.string(forKey: key) else { throw AccountIssue.invalidCallback }
            let expected = AccountConfiguration.callback(recovery ? "recovery" : "confirm", nonce: nonce)
            try AccountCallback.validate(url, expected: expected)
            let session = try await client.session(from: url)
            defaults.removeObject(forKey: key)
            user = AccountIdentity(session.user); recovering = recovery
        }
    }
    func cloudAccessToken(for owner: UUID) async throws -> String {
        guard let client, user?.id == owner else { throw DocumentCloudIssue.session }
        let session = try await client.session
        guard session.user.id == owner, user?.id == owner else { throw DocumentCloudIssue.session }
        return session.accessToken
    }
    func signOut() async {
        guard !busy else { return }; busy = true; clearMessages()
        defer { busy = false }
        // SDK removes this device's Keychain session before making the revocation
        // request, so closing the local session also works without connectivity.
        do { try await client?.signOut(scope: .local) } catch { }
        user = nil; recovering = false; guest = false; defaults.removeObject(forKey: guestKey)
    }
    static func message(_ error: Error) -> String {
        if let issue = error as? AccountIssue { return issue.localizedDescription }
        if let auth = error as? AuthError {
            switch auth.errorCode.rawValue {
            case "invalid_credentials": return "Correo o contraseña incorrectos."
            case "email_not_confirmed": return "Confirma tu correo antes de entrar. Revisa también la carpeta de spam."
            case "weak_password": return "Elige una contraseña más larga y difícil de adivinar."
            case "over_request_rate_limit", "over_email_send_rate_limit": return "Has hecho varios intentos. Espera unos minutos y vuelve a probar."
            case "same_password": return "Elige una contraseña diferente de la anterior."
            case "reauthentication_needed", "session_expired", "session_not_found": return "Vuelve a iniciar sesión para continuar."
            default: return "No se ha podido completar el acceso. Inténtalo de nuevo."
            }
        }
        if error is URLError { return "No se ha podido conectar. Comprueba tu conexión e inténtalo de nuevo." }
        return "No se ha podido completar la operación. Inténtalo de nuevo."
    }
}
