import SwiftUI
import PDFKit
import VisionKit
import UniformTypeIdentifiers

@main
struct FormScanApp: App {
    var body: some Scene { WindowGroup { FormScanView() } }
}

struct FormEntry: Identifiable {
    let id = UUID()
    var page: Int
    var rect: CGRect
    var label: String
    var text: String = ""
    var checked = false
    var checkbox = false
}

struct ScanSheet: UIViewControllerRepresentable {
    let finished: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ScanSheet
        init(parent: ScanSheet) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.finished((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            parent.dismiss()
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
    }
}

struct PDFPreview: UIViewRepresentable {
    var document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) { view.document = document }
}

struct FormScanView: View {
    @State private var document: PDFDocument?
    @State private var fields: [FormEntry] = []
    @State private var scanner = false
    @State private var importer = false
    @State private var mode = 0
    @State private var message = "Escanea o importa un documento"
    @State private var exported: URL?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("Modo", selection: $mode) {
                    Text("Documento").tag(0)
                    Text("Formulario").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal)
                if let document {
                    if mode == 0 {
                        PDFPreview(document: document)
                            .overlay(alignment: .bottomTrailing) {
                                Menu {
                                    Button("Añadir texto") { addField(checkbox: false) }
                                    Button("Añadir casilla") { addField(checkbox: true) }
                                } label: {
                                    Label("Añadir campo", systemImage: "plus.circle.fill")
                                        .padding(12).background(.regularMaterial).clipShape(Capsule())
                                }.padding()
                            }
                    } else {
                        Form {
                            ForEach($fields) { $field in
                                Section(field.label) {
                                    if field.checkbox {
                                        Toggle("Marcada", isOn: $field.checked)
                                    } else {
                                        TextField("Valor", text: $field.text)
                                    }
                                    Text("Página \(field.page + 1)").font(.caption)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Sin documento", systemImage: "doc.text.viewfinder",
                                           description: Text("Escanea o importa un PDF"))
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("FormScan")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { scanner = true } label: { Image(systemName: "camera.viewfinder") }
                    Button { importer = true } label: { Image(systemName: "square.and.arrow.down") }
                    if document != nil {
                        Button("Exportar") { exportPDF() }
                    }
                }
            }
            .sheet(isPresented: $scanner) { ScanSheet { images in
                let pdf = PDFDocument()
                for image in images {
                    if let page = PDFPage(image: image) { pdf.insert(page, at: pdf.pageCount) }
                }
                document = pdf
                fields = []
                message = "Escaneo importado"
            }}
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .image]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    if let pdf = PDFDocument(data: data) {
                        document = pdf
                    } else if let image = UIImage(data: data), let page = PDFPage(image: image) {
                        let pdf = PDFDocument()
                        pdf.insert(page, at: 0)
                        document = pdf
                    } else { message = "Formato no compatible"; return }
                    fields = []
                    message = "Documento importado"
                } catch { message = error.localizedDescription }
            }
            .sheet(isPresented: $showingShare) {
                if let exported { ShareSheet(items: [exported]) }
            }
        }
    }

    private func addField(checkbox: Bool) {
        guard let page = document?.page(at: 0) else { return }
        let bounds = page.bounds(for: .mediaBox)
        fields.append(FormEntry(page: 0, rect: CGRect(x: bounds.midX - 60, y: bounds.midY, width: checkbox ? 20 : 160, height: 25), label: checkbox ? "Casilla" : "Texto", checkbox: checkbox))
        mode = 1
    }

    private func exportPDF() {
        guard let document, let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data) else { return }
        for field in fields {
            guard let page = copy.page(at: field.page) else { continue }
            let annotation = PDFAnnotation(bounds: field.rect, forType: .freeText, withProperties: nil)
            annotation.contents = field.checkbox ? (field.checked ? "☑" : "☐") : field.text
            annotation.font = UIFont.systemFont(ofSize: 13)
            annotation.fontColor = .black
            annotation.color = .clear
            page.addAnnotation(annotation)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FormScan-filled.pdf")
        if let data = copy.dataRepresentation() {
            do {
                try data.write(to: url)
                exported = url
                showingShare = true
            } catch { message = error.localizedDescription }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
