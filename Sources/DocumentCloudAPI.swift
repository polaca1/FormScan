import Foundation
import CryptoKit

struct CloudRecord: Codable {
    let userID: UUID
    let id: UUID
    let revision: UUID
    let objectKey: String?
    let metadata: SavedDocument
    let deletedAt: String?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", id, revision, objectKey = "object_key", metadata, deletedAt = "deleted_at"
    }
    var deleted: Bool { deletedAt != nil }
}

struct CloudCommit: Encodable {
    let id: UUID
    let expected: UUID?
    let revision: UUID
    let objectKey: String?
    let metadata: SavedDocument?
    let deleted: Bool
    enum CodingKeys: String, CodingKey {
        case id = "p_id", expected = "p_expected_revision", revision = "p_revision"
        case objectKey = "p_object_key", metadata = "p_metadata", deleted = "p_deleted"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(expected, forKey: .expected)
        try c.encode(revision, forKey: .revision); try c.encode(objectKey, forKey: .objectKey)
        try c.encode(metadata, forKey: .metadata); try c.encode(deleted, forKey: .deleted)
    }
}
struct CloudCommitResult: Decodable { let status: String; let document: CloudRecord? }

enum DocumentCloudIssue: LocalizedError {
    case unavailable, session, quota, invalidDocument, conflict, tooLarge, localState
    var errorDescription: String? {
        switch self {
        case .unavailable: "No se ha podido conectar con tu cuenta. Los cambios siguen guardados en este dispositivo."
        case .session: "Vuelve a iniciar sesión para guardar los cambios en tu cuenta. Los documentos se conservan en este dispositivo."
        case .quota: "No queda espacio disponible en tu cuenta. Tus documentos se conservan en este dispositivo."
        case .invalidDocument: "No se pudo recuperar una copia válida del documento. La copia de este dispositivo se conserva."
        case .conflict: "Hay cambios en otro dispositivo. Cierra el documento para incorporarlos sin interrumpir tu edición."
        case .tooLarge: "Este PDF supera el límite de 50 MB. Se conserva en este dispositivo; puedes exportarlo para guardarlo en otro lugar."
        case .localState: "No se pudo leer el registro de guardado. Tus documentos se conservan; no se reemplazará ninguna copia de tu cuenta."
        }
    }
}

@MainActor protocol DocumentCloudAPI {
    var owner: UUID { get }
    func catalogue() async throws -> [CloudRecord]
    func download(_ record: CloudRecord) async throws -> Data
    func upload(_ data: Data, path: String) async throws
    func remove(path: String) async throws
    func commit(_ commit: CloudCommit) async throws -> CloudCommitResult
}

@MainActor final class SupabaseDocumentCloud: DocumentCloudAPI {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let owner: UUID
    private let configuration: AccountConfiguration
    private let token: @MainActor () async throws -> String
    private let fetch: Fetch
    static let bucket = "formscan-documents"
    init(owner: UUID, configuration: AccountConfiguration,
         token: @escaping @MainActor () async throws -> String,
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.owner = owner; self.configuration = configuration; self.token = token; self.fetch = fetch
    }
    static func path(owner: UUID, id: UUID, revision: UUID) -> String {
        "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\(revision.uuidString.lowercased()).pdf"
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         type: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        let access = try await token()
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: configuration.origin)?.absoluteURL,
              url.scheme == configuration.origin.scheme, url.host == configuration.origin.host else { throw DocumentCloudIssue.unavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 120
        request.setValue(configuration.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw DocumentCloudIssue.unavailable }
        return (data, response)
    }
    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw DocumentCloudIssue.session
        case 413: throw DocumentCloudIssue.tooLarge
        case 402, 507: throw DocumentCloudIssue.quota
        default: throw DocumentCloudIssue.unavailable
        }
    }
    func catalogue() async throws -> [CloudRecord] {
        var records: [CloudRecord] = [], offset = 0
        repeat {
            let (data, response) = try await request("/rest/v1/formscan_documents?select=*&order=id.asc&limit=100&offset=\(offset)")
            try validate(response)
            let page = try JSONDecoder().decode([CloudRecord].self, from: data)
            guard page.allSatisfy({ $0.userID == owner && $0.metadata.id == $0.id }) else { throw DocumentCloudIssue.invalidDocument }
            records.append(contentsOf: page)
            if page.count < 100 { return records }
            offset += 100
        } while offset < 100_000
        throw DocumentCloudIssue.unavailable
    }
    func download(_ record: CloudRecord) async throws -> Data {
        guard record.userID == owner, !record.deleted,
              record.objectKey == Self.path(owner: owner, id: record.id, revision: record.revision) else { throw DocumentCloudIssue.invalidDocument }
        let (data, response) = try await request("/storage/v1/object/authenticated/\(Self.bucket)/\(record.objectKey!)")
        try validate(response)
        return data
    }
    func upload(_ data: Data, path: String) async throws {
        guard path.hasPrefix(owner.uuidString.lowercased() + "/"), !path.contains("..") else { throw DocumentCloudIssue.invalidDocument }
        guard data.count <= 52_428_800 else { throw DocumentCloudIssue.tooLarge }
        let (body, response) = try await request("/storage/v1/object/\(Self.bucket)/\(path)", method: "POST", body: data, type: "application/pdf")
        let failure = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let duplicate = response.statusCode == 409 || (response.statusCode == 400 &&
            (["Duplicate", "AssetAlreadyExists"].contains(failure?["error"] as? String ?? "") || failure?["statusCode"] as? String == "409"))
        if duplicate {
            // A previous attempt may have uploaded the immutable revision before
            // losing its response. Reuse it only when the stored bytes match.
            let (existing, downloaded) = try await request("/storage/v1/object/authenticated/\(Self.bucket)/\(path)")
            try validate(downloaded)
            guard SHA256.hash(data: existing) == SHA256.hash(data: data) else { throw DocumentCloudIssue.conflict }
        } else { try validate(response) }
    }
    func remove(path: String) async throws {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == Substring(owner.uuidString.lowercased()),
              UUID(uuidString: String(parts[1])) != nil,
              path.hasSuffix(".pdf"), UUID(uuidString: String(parts[2].dropLast(4))) != nil else { throw DocumentCloudIssue.invalidDocument }
        let body = try JSONSerialization.data(withJSONObject: ["prefixes": [path]])
        let (_, response) = try await request("/storage/v1/object/\(Self.bucket)", method: "DELETE", body: body)
        try validate(response)
    }
    func commit(_ commit: CloudCommit) async throws -> CloudCommitResult {
        if !commit.deleted {
            guard commit.objectKey == Self.path(owner: owner, id: commit.id, revision: commit.revision),
                  commit.metadata?.id == commit.id else { throw DocumentCloudIssue.invalidDocument }
        }
        let (data, response) = try await request("/rest/v1/rpc/formscan_commit_document", method: "POST", body: JSONEncoder().encode(commit))
        try validate(response)
        let result = try JSONDecoder().decode(CloudCommitResult.self, from: data)
        if let record = result.document {
            guard record.userID == owner, record.id == commit.id, record.metadata.id == commit.id else { throw DocumentCloudIssue.invalidDocument }
        }
        guard ["saved", "conflict", "missing"].contains(result.status) else { throw DocumentCloudIssue.unavailable }
        return result
    }
}
