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
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
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
        view.backgroundColor = UIColor.secondarySystemGroupedBackground
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) { view.document = document }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum Design {
    static let accent = Color(red: 0.51, green: 0.30, blue: 0.96)
    static let background = Color(uiColor: .systemGroupedBackground)
}

struct FormScanView: View {
    @State private var document: PDFDocument?
    @State private var fields: [FormEntry] = []
    @State private var scanner = false
    @State private var importer = false
    @State private var mode = 0
    @State private var status = ""
    @State private var exported: URL?
    @State private var showingShare = false
    @State private var busy = false
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    editor(document)
                } else {
                    home
                }
            }
            .background(Design.background.ignoresSafeArea())
            .navigationTitle(document == nil ? "FormScan" : "Documento")
            .navigationBarTitleDisplayMode(document == nil ? .large : .inline)
            .tint(Design.accent)
            .toolbar {
                if document != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cerrar", systemImage: "chevron.left") {
                            document = nil
                            fields = []
                            status = ""
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Escanear otro", systemImage: "camera.viewfinder") { scanner = true }
                            Button("Importar otro", systemImage: "doc.badge.plus") { importer = true }
                            Button("Añadir texto", systemImage: "text.cursor") { addField(checkbox: false) }
                            Button("Añadir casilla", systemImage: "checkmark.square") { addField(checkbox: true) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $scanner) {
                ScanSheet { images in
                    let pdf = PDFDocument()
                    for image in images {
                        if let page = PDFPage(image: image) { pdf.insert(page, at: pdf.pageCount) }
                    }
                    open(pdf)
                }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    if let pdf = PDFDocument(data: data) {
                        open(pdf)
                    } else if let image = UIImage(data: data), let page = PDFPage(image: image) {
                        let pdf = PDFDocument()
                        pdf.insert(page, at: 0)
                        open(pdf)
                    } else {
                        status = "Formato no compatible"
                        showError = true
                    }
                } catch {
                    status = error.localizedDescription
                    showError = true
                }
            }
            .sheet(isPresented: $showingShare) {
                if let exported { ShareSheet(items: [exported]) }
            }
            .alert("FormScan", isPresented: $showError) {
                Button("Aceptar", role: .cancel) {}
            } message: { Text(status) }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Design.accent)
                        .frame(width: 72, height: 72)
                        .background(Design.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                    Text("Tus formularios,\nmás sencillos.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .tracking(-1.1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Escanea, identifica campos y completa documentos desde tu iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                VStack(spacing: 12) {
                    Button { scanner = true } label: {
                        Label("Escanear documento", systemImage: "viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 17))

                    Button { importer = true } label: {
                        Label("Importar PDF o imagen", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text("Cómo funciona")
                        .font(.title3.bold())
                    feature("1", "Captura", "Escanea varias páginas con recorte automático.", "camera.viewfinder")
                    feature("2", "Detecta", "Identifica zonas de formulario mediante IA local.", "sparkles.rectangle.stack")
                    feature("3", "Completa", "Revisa los campos y comparte un PDF.", "checkmark.doc")
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))

                Label("Procesamiento en el dispositivo · Sin cuenta", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
        }
    }

    private func feature(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Design.accent)
                .frame(width: 42, height: 42)
                .background(Design.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func editor(_ pdf: PDFDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(pdf.pageCount) páginas", systemImage: "doc.on.doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(fields.count) campos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Picker("Vista", selection: $mode) {
                Text("Documento").tag(0)
                Text("Campos").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if mode == 0 {
                PDFPreview(document: pdf)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 12)
            } else {
                if fields.isEmpty {
                    ContentUnavailableView("Sin campos", systemImage: "rectangle.and.text.magnifyingglass",
                                           description: Text("Detecta campos con IA o añádelos desde el menú."))
                        .frame(maxHeight: .infinity)
                } else {
                    Form {
                        ForEach($fields) { $field in
                            Section {
                                if field.checkbox {
                                    Toggle(field.label, isOn: $field.checked)
                                } else {
                                    TextField(field.label, text: $field.text, axis: .vertical)
                                        .lineLimit(1...3)
                                }
                            } footer: {
                                Text("Página \(field.page + 1)")
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }

            VStack(spacing: 9) {
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 12) {
                    Button {
                        detectFields()
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(Design.accent) }
                            else { Image(systemName: "sparkles") }
                            Text(busy ? "Analizando" : "Detectar IA")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    Button {
                        exportPDF()
                    } label: {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accent)
                    .disabled(busy)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)
        }
    }

    private func open(_ pdf: PDFDocument) {
        document = pdf
        fields = []
        mode = 0
        status = "Documento listo para editar"
    }

    private func detectFields() {
        guard let document else { return }
        busy = true
        status = "Analizando en el dispositivo…"
        // Keep PDFKit and SwiftUI state mutations on the main actor.
        DispatchQueue.main.async {
            var found: [FormEntry] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
                do {
                    for item in try LocalFieldAI.detect(image) {
                        let x = item.rect.minX / image.size.width * bounds.width
                        let y = (1 - item.rect.maxY / image.size.height) * bounds.height
                        let w = item.rect.width / image.size.width * bounds.width
                        let h = item.rect.height / image.size.height * bounds.height
                        found.append(FormEntry(page: index, rect: CGRect(x: x, y: y, width: w, height: h),
                            label: item.category == 1 ? "Casilla" : item.category == 2 ? "Firma" : "Campo de texto",
                            checkbox: item.category == 1))
                    }
                } catch {
                    busy = false
                    status = "No se pudo analizar: \(error.localizedDescription)"
                    showError = true
                    return
                }
            }
            fields = found
            mode = 1
            status = "\(found.count) campos detectados"
            busy = false
        }
    }

    private func addField(checkbox: Bool) {
        guard let page = document?.page(at: 0) else { return }
        let bounds = page.bounds(for: .mediaBox)
        fields.append(FormEntry(page: 0,
                                rect: CGRect(x: bounds.midX - 60, y: bounds.midY,
                                             width: checkbox ? 20 : 160, height: 25),
                                label: checkbox ? "Casilla" : "Texto", checkbox: checkbox))
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FormScan-completado.pdf")
        if let data = copy.dataRepresentation() {
            do {
                try data.write(to: url, options: .atomic)
                exported = url
                showingShare = true
            } catch {
                status = error.localizedDescription
                showError = true
            }
        }
    }
}
