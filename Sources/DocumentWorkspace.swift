import Foundation
import Combine
import SwiftUI

/// Account UUIDs select local libraries. No email string is used as an identity.
@MainActor
final class DocumentWorkspace: ObservableObject {
    @Published private(set) var library: DocumentLibrary?
    @Published private(set) var key: String?
    @Published private(set) var error: String?
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    func activate(_ next: String?) {
        guard key != next || error != nil else { return }
        do {
            try library?.close()
            library = nil; key = nil; error = nil
            guard let next else { return }
            let directory = try directory(for: next)
            library = DocumentLibrary(directory: directory); key = next
        } catch {
            self.error = "No se pudo preparar la biblioteca. Tus documentos se conservan. Comprueba el espacio disponible y vuelve a intentarlo."
        }
    }
    private func directory(for key: String) throws -> URL {
        let files = FileManager.default
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") || ProcessInfo.processInfo.arguments.contains("-ui-testing-reopen") {
            let directory = root.appendingPathComponent("UITestDocuments", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-cloud-new-install") {
                try? files.removeItem(at: directory)
            }
            return directory
        }
        #endif
        let legacy = root.appendingPathComponent("Documents", isDirectory: true)
        let owner = root.appendingPathComponent("library-owner.txt")
        if key == "guest" {
            return files.fileExists(atPath: owner.path) ? root.appendingPathComponent("GuestDocuments", isDirectory: true) : legacy
        }
        guard let uuid = UUID(uuidString: key) else { throw FormScanError.saveFailed }
        let destination = root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        // Migrate the pre-account library once, with an atomic directory move.
        // A failed move leaves the original intact; a later account never adopts it.
        if !files.fileExists(atPath: owner.path) {
            if files.fileExists(atPath: legacy.path) && !files.fileExists(atPath: destination.path) {
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: legacy, to: destination)
            }
            try Data(uuid.uuidString.utf8).write(to: owner, options: .atomic)
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }
}

struct AccountRootView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var workspace = DocumentWorkspace()
    @StateObject private var cloud = DocumentCloudController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if account.restoring {
                ProgressView("Abriendo FormScan…")
            } else if account.recovering {
                NavigationStack {
                    AccountPasswordView().toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar sesión") { Task { await account.signOut() } }
                        }
                    }
                }
            } else if let key = account.workspaceKey {
                if let library = workspace.library, workspace.key == key, workspace.error == nil {
                    LibraryView(library: library).id(key)
                } else if let error = workspace.error {
                    ContentUnavailableView {
                        Label("Biblioteca no disponible", systemImage: "folder.badge.questionmark")
                    } description: { Text(error) } actions: {
                        Button("Volver a intentar") { workspace.activate(key) }.buttonStyle(.glassProminent)
                    }
                } else { ProgressView("Abriendo documentos…") }
            } else { AccountAccessView() }
        }
        .environmentObject(cloud)
        .task(id: account.workspaceKey) {
            cloud.disconnect()
            workspace.activate(account.workspaceKey)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-cloud"), let library = workspace.library {
                do { cloud.connect(library: library, api: try DocumentCloudUIFixture()) }
                catch { cloud.error = DocumentCloudIssue.unavailable.localizedDescription }
                return
            }
            #endif
            if let owner = account.user?.id, let library = workspace.library,
               workspace.key == owner.uuidString, let configuration = AccountConfiguration.load() {
                cloud.connect(library: library, api: SupabaseDocumentCloud(owner: owner, configuration: configuration) {
                    try await account.cloudAccessToken(for: owner)
                })
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { cloud.synchronize() }
        }
        .onOpenURL { url in Task { await account.handleCallback(url) } }
    }
}
