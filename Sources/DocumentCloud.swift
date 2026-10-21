import Foundation
import CryptoKit
import Combine

struct CloudLocalSnapshot {
    let item: SavedDocument
    let pdf: Data
    var fingerprint: String { get throws { try DocumentFingerprint.of(item) } }
}
enum DocumentFingerprint {
    static func of(_ item: SavedDocument) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(item)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CloudPending: Codable { let revision: UUID; let fingerprint: String; let deleted: Bool }
private struct CloudCheckpoint: Codable {
    var revision: UUID?
    var fingerprint: String?
    var pending: CloudPending?
}
private struct CloudJournal: Codable {
    let schema: Int
    let owner: UUID
    var documents: [String: CloudCheckpoint]
    var garbage: Set<String>? = nil
    init(owner: UUID) { schema = 1; self.owner = owner; documents = [:] }
}

@MainActor
final class DocumentCloudController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var restoring = false
    @Published private(set) var hasPendingChanges = false
    @Published var error: String?
    @Published var notice: String?
    private var library: DocumentLibrary?
    private var api: (any DocumentCloudAPI)?
    private var journal: CloudJournal?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var delayed: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    private var needsAnotherPass = false
    private var automatically = true

    deinit { task?.cancel(); delayed?.cancel(); periodic?.cancel() }
    func connect(library: DocumentLibrary, api: any DocumentCloudAPI, automatically: Bool = true) {
        disconnect()
        self.library = library; self.api = api; self.automatically = automatically
        do {
            let url = library.directory.appendingPathComponent(".cloud-state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                journal = try JSONDecoder().decode(CloudJournal.self, from: Data(contentsOf: url))
                guard journal?.schema == 1, journal?.owner == api.owner else { throw DocumentCloudIssue.localState }
            } else { journal = CloudJournal(owner: api.owner); try persist() }
            library.didChange = { [weak self] in self?.markChanged() }
            refreshPending()
            if automatically {
                synchronize()
                periodic = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        self?.synchronize()
                    }
                }
            }
        } catch { self.error = DocumentCloudIssue.localState.localizedDescription; journal = nil }
    }
    func disconnect() {
        generation = UUID(); task?.cancel(); delayed?.cancel(); periodic?.cancel()
        task = nil; delayed = nil; periodic = nil
        library?.didChange = nil; library = nil; api = nil; journal = nil
        busy = false; restoring = false; hasPendingChanges = false; error = nil; notice = nil; needsAnotherPass = false
    }
    private func persist() throws {
        guard let library, let journal else { throw DocumentCloudIssue.localState }
        try JSONEncoder().encode(journal).write(to: library.directory.appendingPathComponent(".cloud-state.json"), options: .atomic)
    }
    private func refreshPending() {
        guard let library, let journal else { return }
        hasPendingChanges = library.documents.contains { item in
            journal.documents[item.id.uuidString]?.fingerprint != (try? DocumentFingerprint.of(item))
        } || ((try? library.deletionRequests().isEmpty) == false)
    }
    private func markChanged() {
        refreshPending()
        guard automatically else { return }
        delayed?.cancel()
        delayed = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.synchronize()
        }
    }
    func synchronize() {
        guard let api, let library else { return }
        if journal == nil { connect(library: library, api: api, automatically: automatically); return }
        if busy { needsAnotherPass = true; return }
        task = Task { [weak self] in await self?.synchronizeNow() }
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
    }
    /// Public for deterministic transport tests; normal callers use synchronize().
    func synchronizeNow() async {
        guard !busy, let library, let api, journal != nil else { return }
        let epoch = generation
        busy = true; error = nil; needsAnotherPass = false
        restoring = library.documents.isEmpty
        defer {
            if epoch == generation {
                busy = false; restoring = false; task = nil; refreshPending()
                if needsAnotherPass { needsAnotherPass = false; markChanged() }
            }
        }
        do { try library.flushForCloud() }
        catch { self.error = FormScanError.saveFailed.localizedDescription; return }
        do {
            // A failed download is never interpreted as an empty remote account.
            let remote = try await api.catalogue()
            try check(epoch)
            guard Set(remote.map(\.id)).count == remote.count,
                  remote.allSatisfy({ $0.userID == api.owner && $0.metadata.id == $0.id }) else { throw DocumentCloudIssue.invalidDocument }
            let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
            for record in remote {
                let key = record.id.uuidString
                if var checkpoint = journal?.documents[key], checkpoint.pending?.revision == record.revision {
                    checkpoint.revision = record.revision
                    checkpoint.fingerprint = checkpoint.pending?.deleted == true ? nil : checkpoint.pending?.fingerprint
                    if let previous = journal?.documents[key]?.revision, previous != record.revision {
                        enqueueGarbage(SupabaseDocumentCloud.path(owner: api.owner, id: record.id, revision: previous))
                    }
                    if record.deleted, let path = record.objectKey { enqueueGarbage(path) }
                    checkpoint.pending = nil; journal?.documents[key] = checkpoint; try persist()
                }
            }
            let deletes = try library.deletionRequests()
            for (key, fingerprint) in deletes {
                try check(epoch)
                guard let id = UUID(uuidString: key) else { throw DocumentCloudIssue.localState }
                if let record = remoteByID[id] {
                    if record.deleted {
                        try acknowledge(record); try library.clearDeletionRequest(id)
                    } else {
                        let checkpoint = journal?.documents[key]
                        let remoteFingerprint = try DocumentFingerprint.of(record.metadata)
                        let matches = checkpoint?.revision == record.revision || (checkpoint?.revision == nil && fingerprint == remoteFingerprint)
                        if matches {
                            let revision = checkpoint?.pending.flatMap { $0.deleted ? $0.revision : nil } ?? UUID()
                            try setPending(id, revision: revision, fingerprint: fingerprint, deleted: true)
                            let result = try await api.commit(CloudCommit(id: id, expected: record.revision, revision: revision, objectKey: nil, metadata: nil, deleted: true))
                            try check(epoch)
                            if result.status == "saved", let saved = result.document, saved.deleted, saved.revision == revision {
                                try acknowledge(saved); try library.clearDeletionRequest(id)
                            } else { needsAnotherPass = true; error = DocumentCloudIssue.conflict.localizedDescription }
                        } else {
                            let data = try await api.download(record); try check(epoch)
                            try library.clearDeletionRequest(id)
                            try library.installCloud(record, pdf: data); try acknowledge(record)
                            notice = "Un documento cambió en otro dispositivo antes de eliminarlo. Se ha conservado esa versión."
                        }
                    }
                } else {
                    // A local document that was never uploaded needs no remote delete.
                    if journal?.documents[key]?.revision != nil { throw DocumentCloudIssue.conflict }
                    try library.clearDeletionRequest(id); journal?.documents[key] = nil; try persist()
                }
            }
            for record in remote {
                try check(epoch)
                let currentDeletes = try library.deletionRequests()
                if deletes[record.id.uuidString] != nil || currentDeletes[record.id.uuidString] != nil { continue }
                let key = record.id.uuidString
                var checkpoint = journal?.documents[key] ?? CloudCheckpoint()
                if checkpoint.pending?.revision == record.revision {
                    // The server may have committed successfully before a response
                    // was lost. Acknowledge the persisted snapshot, not newer edits.
                    checkpoint.revision = record.revision
                    checkpoint.fingerprint = checkpoint.pending?.deleted == true ? nil : checkpoint.pending?.fingerprint
                    checkpoint.pending = nil; journal?.documents[key] = checkpoint; try persist()
                }
                guard let local = library.documents.first(where: { $0.id == record.id }), library.hasLocalPDF(record.id) else {
                    if !record.deleted {
                        let data = try await api.download(record); try check(epoch)
                        guard library.activeDocumentID != record.id else { continue }
                        try library.installCloud(record, pdf: data)
                    }
                    try acknowledge(record)
                    continue
                }
                let localFingerprint = try DocumentFingerprint.of(local)
                checkpoint = journal?.documents[key] ?? CloudCheckpoint()
                if checkpoint.revision == record.revision && !record.deleted { continue }
                let remoteFingerprint = try DocumentFingerprint.of(record.metadata)
                let sameContents = !record.deleted && localFingerprint == remoteFingerprint
                if sameContents { try acknowledge(record); continue }
                // No checkpoint + an existing UUID with different contents is a
                // conflict, never permission to overwrite the remote version.
                let dirty = checkpoint.fingerprint != localFingerprint
                guard library.activeDocumentID != record.id else {
                    error = DocumentCloudIssue.conflict.localizedDescription
                    continue
                }
                if record.deleted {
                    if dirty { try library.preserveConflict(record.id); notice = "Se ha conservado una copia con los cambios de este dispositivo." }
                    try library.removeLocalVersion(record.id); try acknowledge(record)
                } else {
                    let data = try await api.download(record); try check(epoch)
                    // The user may have edited/opened the document while the
                    // download was in flight. Re-evaluate immediately before saving.
                    guard library.activeDocumentID != record.id else { continue }
                    let latest = try library.cloudSnapshot(record.id)
                    if let latest, checkpoint.fingerprint != (try latest.fingerprint) {
                        try library.preserveConflict(record.id)
                        notice = "El documento cambió en dos dispositivos. Se han conservado las dos versiones."
                    }
                    try library.installCloud(record, pdf: data); try acknowledge(record)
                }
            }
            for item in library.documents {
                try check(epoch)
                guard (try library.deletionRequests())[item.id.uuidString] == nil else { continue }
                var checkpoint = journal?.documents[item.id.uuidString] ?? CloudCheckpoint()
                if checkpoint.fingerprint == (try DocumentFingerprint.of(item)) { continue }
                guard let snapshot = try library.cloudSnapshot(item.id) else { continue }
                let fingerprint = try snapshot.fingerprint
                // An unresolved conflict in an open editor cannot overwrite the
                // server. It will be reconciled when that editor closes.
                if let remote = remoteByID[item.id], checkpoint.revision != remote.revision { continue }
                let pending = checkpoint.pending
                let revision = pending?.fingerprint == fingerprint && pending?.deleted == false ? pending!.revision : UUID()
                let expected = checkpoint.revision
                try setPending(item.id, revision: revision, fingerprint: fingerprint, deleted: false)
                let path = SupabaseDocumentCloud.path(owner: api.owner, id: item.id, revision: revision)
                try await api.upload(snapshot.pdf, path: path); try check(epoch)
                let result = try await api.commit(CloudCommit(id: item.id, expected: expected, revision: revision, objectKey: path, metadata: snapshot.item, deleted: false))
                try check(epoch)
                guard result.status == "saved", let saved = result.document, saved.revision == revision, !saved.deleted else {
                    if result.status == "conflict" {
                        enqueueGarbage(path); try persist()
                        needsAnotherPass = true; error = DocumentCloudIssue.conflict.localizedDescription; continue
                    }
                    throw DocumentCloudIssue.unavailable
                }
                if let expected, expected != revision { enqueueGarbage(SupabaseDocumentCloud.path(owner: api.owner, id: item.id, revision: expected)) }
                checkpoint.revision = revision; checkpoint.fingerprint = fingerprint; checkpoint.pending = nil
                journal?.documents[item.id.uuidString] = checkpoint; try persist()
                if let latest = library.documents.first(where: { $0.id == item.id }), (try DocumentFingerprint.of(latest)) != fingerprint { needsAnotherPass = true }
            }
            // Cleanup follows a confirmed commit, never an ambiguous failure.
            // Keep failed cleanup requests durable without reporting a saved
            // document as unsaved or accumulating every keystroke's PDF forever.
            for path in Array(journal?.garbage ?? []).prefix(20) {
                do {
                    try await api.remove(path: path); try check(epoch)
                    journal?.garbage?.remove(path); try persist()
                } catch is CancellationError { throw CancellationError() }
                catch { break }
            }
        } catch is CancellationError { return }
        catch {
            guard epoch == generation else { return }
            self.error = (error as? DocumentCloudIssue)?.localizedDescription ?? DocumentCloudIssue.unavailable.localizedDescription
        }
    }
    private func setPending(_ id: UUID, revision: UUID, fingerprint: String, deleted: Bool) throws {
        var checkpoint = journal?.documents[id.uuidString] ?? CloudCheckpoint()
        checkpoint.pending = CloudPending(revision: revision, fingerprint: fingerprint, deleted: deleted)
        journal?.documents[id.uuidString] = checkpoint; try persist()
    }
    private func enqueueGarbage(_ path: String) {
        var paths = journal?.garbage ?? []
        paths.insert(path); journal?.garbage = paths
    }
    private func acknowledge(_ record: CloudRecord) throws {
        if record.deleted, let path = record.objectKey { enqueueGarbage(path) }
        let fingerprint: String?
        if record.deleted { fingerprint = nil } else { fingerprint = try DocumentFingerprint.of(record.metadata) }
        journal?.documents[record.id.uuidString] = CloudCheckpoint(revision: record.revision,
            fingerprint: fingerprint, pending: nil)
        try persist()
    }
}
