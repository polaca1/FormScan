import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import VisionKit

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
            LibraryView(library: library).environmentObject(models).tint(.blue).preferredColorScheme(testAppearance)
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: DocumentLibrary
    @EnvironmentObject private var models: ModelStore
    @State private var path: [UUID] = []
    @State private var scanner = false
    @State private var importer = false
    @State private var error: String?
    @State private var tutorial = false
    @State private var tutorialChecked = false
    @AppStorage("onboarding.complete") private var onboarded = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var actionLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if library.documents.isEmpty {
                    welcome
                        .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Section {
                        Button { openExample() } label: {
                            Label("Probar un formulario de ejemplo", systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("openExample")
                    } footer: {
                        Label("Tus documentos se guardan solo en este dispositivo.", systemImage: "lock.shield")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Todo en su sitio.").font(.title2.bold())
                        Text("Retoma un documento o empieza uno nuevo.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Section {
                        ForEach(Array(library.documents.prefix(3))) { item in
                            NavigationLink(value: item.id) { DocumentRow(item: item, library: library) }
                                .swipeActions {
                                    Button("Eliminar", role: .destructive) { library.delete(item) }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Recientes")
                            Spacer()
                            NavigationLink("Ver todos") { AllDocumentsView(library: library) }
                        }
                    } footer: {
                        Label("Guardado en tu dispositivo", systemImage: "lock.shield")
                    }
                }
                Section("Tu espacio") {
                    NavigationLink { AllDocumentsView(library: library) } label: {
                        Label {
                            HStack { Text("Todos los documentos"); Spacer(); Text("\(library.documents.count)").foregroundStyle(.secondary) }
                        } icon: { Image(systemName: "folder") }
                    }.accessibilityIdentifier("allDocuments")
                    NavigationLink { ModelSettingsView(store: models) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Modelos de IA")
                                Text(models.active.name).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "cpu") }
                    }.accessibilityIdentifier("openModels")
                    Button { tutorial = true } label: { Label("Guía de primeros pasos", systemImage: "book.closed") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("FormScan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        NavigationLink { AllDocumentsView(library: library) } label: { Label("Documentos", systemImage: "folder") }
                        NavigationLink { ModelSettingsView(store: models) } label: { Label("Modelos de IA", systemImage: "cpu") }
                        Button("Primeros pasos", systemImage: "book.closed") { tutorial = true }
                    } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Menú principal").accessibilityIdentifier("mainMenu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Importar PDF o imagen", systemImage: "folder") { importer = true }
                        Button("Formulario de ejemplo", systemImage: "doc.text") { openExample() }
                        Button("Ver tutorial", systemImage: "book.closed") { tutorial = true }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nuevo documento")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassEffectContainer(spacing: 16) {
                    actionLayout {
                        Button { importer = true } label: {
                            Label("Importar", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass).accessibilityIdentifier("importDocument")
                        Button { startScanner() } label: {
                            Label("Escanear", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("scanDocument")
                    }.font(.headline)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .navigationDestination(for: UUID.self) { id in
                if let session = library.session(id: id) { EditorView(session: session) }
                else { ContentUnavailableView("No se pudo abrir", systemImage: "doc.badge.ellipsis") }
            }
        }
        .fullScreenCover(isPresented: $tutorial) {
            OnboardingView { example in
                onboarded = true; tutorial = false
                if example { openExample() }
            }
        }
        .fullScreenCover(isPresented: $scanner) {
            ScannerView { result in
                switch result {
                case .success(let images):
                    let pdf = PDFDocument()
                    images.compactMap { PDFPage(image: $0) }.forEach { pdf.insert($0, at: pdf.pageCount) }
                    importDocument(pdf, title: "Escaneo")
                case .failure(let failure): error = failure.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let pdf: PDFDocument
                if let document = PDFDocument(data: data) { pdf = document }
                else if let image = UIImage(data: data), let page = PDFPage(image: image) {
                    pdf = PDFDocument(); pdf.insert(page, at: 0)
                } else { throw FormScanError.invalidDocument }
                importDocument(pdf, title: url.deletingPathExtension().lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .alert("No se pudo completar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onAppear {
            if !tutorialChecked {
                tutorialChecked = true
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-ui-testing-onboarding") || (!arguments.contains("-ui-testing") && !arguments.contains("-ui-testing-reopen") && !onboarded) { tutorial = true }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-example"), library.documents.isEmpty { openExample() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 76, weight: .light)).foregroundStyle(.blue)
            .frame(maxWidth: .infinity, minHeight: 158).accessibilityHidden(true)
            Text("Menos papel.\nTodo resuelto.").font(.largeTitle.bold()).tracking(-1)
            Text("Escanea un formulario, completa sus campos y llévatelo listo para compartir.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 8)
    }
    private func startScanner() {
        guard VNDocumentCameraViewController.isSupported else {
            error = "El escáner necesita una cámara compatible. Puedes importar un PDF o una imagen."
            return
        }
        scanner = true
    }
    private func openExample() { importDocument(ExampleDocument.make(), title: "Formulario de ejemplo") }
    private func importDocument(_ pdf: PDFDocument, title: String) {
        do { path.append(try library.add(pdf, title: title)) }
        catch { self.error = error.localizedDescription }
    }
}

struct AllDocumentsView: View {
    @ObservedObject var library: DocumentLibrary
    @State private var search = ""
    private var documents: [SavedDocument] {
        library.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            ForEach(documents) { item in
                NavigationLink(value: item.id) { DocumentRow(item: item, library: library) }
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
