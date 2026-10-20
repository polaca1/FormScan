import SwiftUI
import PDFKit
import VisionKit

private struct EditorDestination: Identifiable { let id: UUID }
private enum AppSection: Hashable { case home, documents, settings }

@main
struct FormScanApp: App {
    @StateObject private var library = DocumentLibrary()
    @StateObject private var models = ModelStore()
    private var testAppearance: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-dark") { return .dark }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup {
            LibraryView(library: library).environmentObject(models).preferredColorScheme(testAppearance)
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: DocumentLibrary
    @EnvironmentObject private var models: ModelStore
    @State private var section = AppSection.home
    @State private var openedDocument: EditorDestination?
    @State private var scanner = false
    @State private var importer = false
    @State private var pickerClosed = true
    @State private var pickedURL: URL?
    @State private var scannedPages: [UIImage]?
    @State private var importing = false
    @State private var error: String?
    @State private var tutorial = false
    @State private var tutorialChecked = false
    @State private var tutorialExample = false
    @AppStorage("onboarding.complete") private var onboarded = false

    private var navigation: some View {
        TabView(selection: $section) {
            Tab("Inicio", systemImage: "house", value: AppSection.home) {
                NavigationStack {
                    StartView(scan: startScanner, importFile: presentImporter, example: openExample)
                        .navigationTitle("Inicio")
                }
            }
            Tab("Documentos", systemImage: "folder", value: AppSection.documents) {
                NavigationStack {
                    AllDocumentsView(library: library) { openedDocument = EditorDestination(id: $0) }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu("Añadir documento", systemImage: "plus") {
                                    Button("Importar archivo", systemImage: "folder", action: presentImporter)
                                    Button("Escanear", systemImage: "camera.viewfinder", action: startScanner)
                                }
                            }
                        }

                }
            }
            Tab("Ajustes", systemImage: "gearshape", value: AppSection.settings) {
                NavigationStack {
                    List {
                        Section {
                            NavigationLink { ModelSettingsView(store: models) } label: {
                                Label("Modelos de IA", systemImage: "cpu")
                            }.accessibilityIdentifier("openModels")
                        }
                        Section {
                            Button { tutorial = true } label: {
                                Label("Primeros pasos", systemImage: "book.closed")
                            }.buttonStyle(.borderless)
                        }
                    }.navigationTitle("Ajustes")
                }
            }
        }
    }

    var body: some View {
        navigation
        .fullScreenCover(item: $openedDocument) { destination in
            NavigationStack {
                if let session = library.session(id: destination.id) { EditorView(session: session) }
                else { ContentUnavailableView("No se pudo abrir", systemImage: "doc.badge.ellipsis") }
            }
        }
        .sheet(isPresented: $importer, onDismiss: {
            pickerClosed = true; importPickedFile()
        }) {
            DocumentPicker { url in pickedURL = url; importer = false }
        }
        .fullScreenCover(isPresented: $scanner, onDismiss: importScannedPages) {
            ScannerView { result in
                switch result {
                case .success(let images): scannedPages = images
                case .failure(let failure): error = failure.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $tutorial, onDismiss: {
            if tutorialExample { tutorialExample = false; openExample() }
        }) {
            OnboardingView { example in
                onboarded = true; tutorialExample = example; tutorial = false
            }
        }
        .overlay {
            if importing {
                ProgressView("Importando…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .alert("No se pudo completar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: pickedURL) { _, _ in
            // Providers may deliver their URL before or after the dismissal callback.
            if pickerClosed { importPickedFile() }
        }
        .onAppear {
            guard !tutorialChecked else { return }
            tutorialChecked = true
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-ui-testing-onboarding") || (!args.contains("-ui-testing") && !args.contains("-ui-testing-reopen") && !onboarded) { tutorial = true }
            if args.contains("-ui-testing-example"), library.documents.isEmpty { openExample() }
            if args.contains("-ui-testing-reopen") { section = .documents }
            #if DEBUG
            if args.contains("-ui-testing-table"), library.documents.isEmpty { openReportedTable() }
            if args.contains("-ui-testing-import") { prepareImportFixture() }
            #endif
        }
    }
    private func presentImporter() {
        guard !importing else { return }
        pickerClosed = false; importer = true
    }
    private func startScanner() {
        guard VNDocumentCameraViewController.isSupported else {
            error = "El escáner necesita una cámara compatible. Puedes importar un PDF o una imagen."
            return
        }
        scanner = true
    }
    private func openExample() { openDocument(ExampleDocument.make(), title: "Formulario de ejemplo") }
    private func openDocument(_ pdf: PDFDocument, title: String) {
        do {
            let id = try library.add(pdf, title: title)
            section = .documents
            library.session(id: id)?.startAnalysis(using: models, automatic: true)
            openedDocument = EditorDestination(id: id)
        } catch { self.error = error.localizedDescription }
    }
    private func importPickedFile() {
        guard let url = pickedURL else { return }
        pickedURL = nil; importing = true
        #if DEBUG
        print("FormScan import: reading the selected file after dismissal")
        #endif
        Task {
            defer { importing = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try DocumentImport.read(url) }.value
                openDocument(try DocumentImport.decode(data), title: url.deletingPathExtension().lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func importScannedPages() {
        guard let images = scannedPages else { return }
        scannedPages = nil
        let pdf = PDFDocument()
        images.compactMap { PDFPage(image: $0) }.forEach { pdf.insert($0, at: pdf.pageCount) }
        openDocument(pdf, title: "Escaneo")
    }
    #if DEBUG
    private func openReportedTable() {
        do {
            let id = try library.add(ExampleTable.reported(), title: "The environment")
            guard let session = library.session(id: id) else { return }
            ExampleTable.seedLegacyFields(in: session)
            section = .documents
            session.startAnalysis(using: models, automatic: true)
            openedDocument = EditorDestination(id: id)
        } catch { self.error = error.localizedDescription }
    }
    private func prepareImportFixture() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? ExampleDocument.make().dataRepresentation()?.write(to: directory.appendingPathComponent("Importar prueba.pdf"), options: .atomic)
    }
    #endif
}

private struct StartView: View {
    let scan: () -> Void
    let importFile: () -> Void
    let example: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "text.viewfinder").font(.system(size: 54, weight: .light))
                    .foregroundStyle(.blue).padding(.top, 36).accessibilityHidden(true)
                Text("Completa tu próximo documento.").font(.largeTitle.bold())
                Text("Escanea una hoja o abre un archivo para empezar.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(spacing: 14) {
                    Button(action: scan) {
                        Label("Escanear", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.glassProminent).accessibilityIdentifier("scanDocument")
                    Button(action: importFile) {
                        Label("Importar archivo", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.glass).accessibilityIdentifier("importDocument")
                }.font(.headline)
                Button("Probar un ejemplo", action: example).accessibilityIdentifier("openExample")
                    .padding(.top, 4)
            }.frame(maxWidth: 540, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
}

struct AllDocumentsView: View {
    @ObservedObject var library: DocumentLibrary
    let open: (UUID) -> Void
    @State private var search = ""
    private var documents: [SavedDocument] {
        library.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            ForEach(documents) { item in
                Button { open(item.id) } label: { DocumentRow(item: item, library: library) }
                    .buttonStyle(.plain)
                    .swipeActions { Button("Eliminar", role: .destructive) { library.delete(item) } }
            }
        }
        .navigationTitle("Documentos")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar documentos")
        .overlay {
            if library.documents.isEmpty {
                ContentUnavailableView("Tu biblioteca empieza aquí", systemImage: "folder", description: Text("Escanea o importa un documento desde Inicio. Quedará guardado en este espacio."))
            } else if documents.isEmpty { ContentUnavailableView.search(text: search) }
        }
    }
}

struct DocumentRow: View {
    let item: SavedDocument
    let library: DocumentLibrary
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let image = library.thumbnail(for: item) { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "doc.text").font(.title).foregroundStyle(.blue) }
            }
            .frame(width: 48, height: 64)
            .background(.white, in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.08)))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(2)
                Text("\(item.pageCount) pág. · \(item.fields.count) campos").font(.subheadline).foregroundStyle(.secondary)
                Text(item.modified, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 6)
        }
    }
}
