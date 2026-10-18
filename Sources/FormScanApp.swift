import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import VisionKit

@main
struct FormScanApp: App {
    @StateObject private var library = DocumentLibrary()
    private var testAppearance: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-dark") { return .dark }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup { LibraryView(library: library).tint(.blue).preferredColorScheme(testAppearance) }
    }
}

struct LibraryView: View {
    @ObservedObject var library: DocumentLibrary
    @State private var path: [UUID] = []
    @State private var scanner = false
    @State private var importer = false
    @State private var error: String?
    @State private var search = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    private var documents: [SavedDocument] {
        library.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
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
                        Label("Escanea varias páginas con recorte automático", systemImage: "viewfinder")
                        Label("Detecta y completa campos sin conexión", systemImage: "sparkles")
                        Label("Comparte el documento terminado en PDF", systemImage: "square.and.arrow.up")
                    } header: { Text("Del papel al documento listo") }
                    Section {
                        Button { openExample() } label: {
                            Label("Probar un formulario de ejemplo", systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("openExample")
                    } footer: {
                        Label("Tus documentos se guardan solo en este dispositivo.", systemImage: "lock.shield")
                    }
                } else {
                    Section {
                        ForEach(documents) { item in
                            NavigationLink(value: item.id) { DocumentRow(item: item, library: library) }
                                .swipeActions {
                                    Button("Eliminar", role: .destructive) { library.delete(item) }
                                }
                        }
                    } header: { Text("Recientes") } footer: {
                        Label("Guardado en tu dispositivo", systemImage: "lock.shield")
                    }
                    if documents.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("FormScan")
            .modifier(LibrarySearch(text: $search, enabled: !library.documents.isEmpty))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Importar PDF o imagen", systemImage: "folder") { importer = true }
                        Button("Formulario de ejemplo", systemImage: "doc.text") { openExample() }
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

private struct LibrarySearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar documentos")
        } else { content }
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
