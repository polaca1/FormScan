import SwiftUI
import PDFKit

private enum EditorMode: String, CaseIterable { case document = "Documento", form = "Formulario" }
private struct SharedPDF: Identifiable { let id = UUID(); let url: URL }

struct EditorView: View {
    @ObservedObject var session: DocumentSession
    @EnvironmentObject private var models: ModelStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var mode = EditorMode.document
    @State private var page = 0
    @State private var selection: FormEntry?
    @State private var placing: UUID?
    @State private var share: SharedPDF?
    @State private var renaming = false
    @State private var title = ""
    @State private var wideLayout = false
    @FocusState private var focusedField: UUID?

    var body: some View {
        Group {
            if wideLayout {
                HStack(spacing: 0) {
                    preview
                    Divider()
                    form.frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
                }
            } else {
                // Keep PDFKit and the form alive: switching modes must not
                // rebuild PDF pages, reset zoom or reconstruct the toolbar.
                ZStack {
                    preview
                        .opacity(mode == .document ? 1 : 0)
                        .allowsHitTesting(mode == .document)
                        .accessibilityHidden(mode != .document)
                    form
                        .opacity(mode == .form ? 1 : 0)
                        .allowsHitTesting(mode == .form)
                        .accessibilityHidden(mode != .form)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 820 } action: { wideLayout = $0 }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(session.item.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                if !wideLayout {
                    Picker("Vista del documento", selection: $mode) {
                        ForEach(EditorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("editorMode")
                }
                HStack {
                    Text("Página \(page + 1) de \(session.document.pageCount)")
                    Spacer()
                    Label("\(session.item.fields.filter(\.completed).count)/\(session.item.fields.count) completados", systemImage: "checkmark.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("documentStatus")
                .accessibilityLabel("Página \(page + 1) de \(session.document.pageCount). \(session.item.fields.filter(\.completed).count) de \(session.item.fields.count) campos completados. \(session.busy ? "Analizando" : session.item.analyzed == true ? "Análisis completado" : "Análisis pendiente")")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(session.progress).font(.subheadline)
                    Spacer()
                    Button("Cancelar") { session.cancelAnalysis() }
                }.padding().background(.bar)
            } else if placing != nil {
                HStack {
                    Text("Toca el documento para colocar el campo.").font(.subheadline)
                    Spacer()
                    Button("Cancelar") { placing = nil }
                }.padding().background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cerrar", systemImage: "xmark") { session.flush(); dismiss() }
                    .accessibilityIdentifier("closeDocument")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { focusedField = nil }
                    .accessibilityIdentifier("finishFormEditing")
            }
            ToolbarItem(placement: sharePlacement) {
                Button("Compartir", systemImage: "square.and.arrow.up") {
                    do { share = SharedPDF(url: try session.export()) }
                    catch { session.error = error.localizedDescription }
                }
                .accessibilityIdentifier("exportPDF").disabled(session.busy)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Cambiar nombre", systemImage: "pencil") { title = session.item.title; renaming = true }
                    Button("Ir a la primera página", systemImage: "doc") { page = 0; mode = .document }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Opciones del documento")
                .accessibilityIdentifier("documentOptions")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Detectar", systemImage: "sparkles") {
                    session.startAnalysis(using: models)
                    mode = .form
                }
                .labelStyle(.titleAndIcon).accessibilityLabel("Detectar campos con IA")
                .disabled(session.busy).accessibilityIdentifier("detectFields")
                .accessibilityValue(session.busy ? "Analizando" : session.item.analyzed == true ? "Análisis completado" : "Pendiente")
                Spacer()
                Menu {
                    Button("Campo de texto", systemImage: "text.cursor") { add(checkbox: false) }
                    Button("Casilla", systemImage: "checkmark.square") { add(checkbox: true) }
                } label: { Label("Añadir", systemImage: "plus") }
                .disabled(session.busy).accessibilityIdentifier("addField")
            }
        }
        .sheet(item: $selection) { selected in
            FieldInspector(session: session, id: selected.id) {
                placing = selected.id; selection = nil; mode = .document
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .alert("Cambiar nombre", isPresented: $renaming) {
            TextField("Nombre del documento", text: $title)
            Button("Guardar") { session.rename(title) }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("FormScan", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("Aceptar", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.flush() } }
        .onChange(of: mode) { _, _ in focusedField = nil }
        .onDisappear { session.flush() }
    }

    private var sharePlacement: ToolbarItemPlacement {
        #if IOS27_SDK
        if #available(iOS 27.0, *) { return .topBarPinnedTrailing }
        #endif
        return .topBarTrailing
    }
    private var preview: some View {
        PDFCanvas(document: session.document, fields: session.item.fields, revision: session.revision,
                  page: $page, placing: placing) { field in selection = field } place: { point, index in
            guard let id = placing, var field = session.item.fields.first(where: { $0.id == id }),
                  let pdfPage = session.document.page(at: index) else { return }
            let bounds = pdfPage.bounds(for: .cropBox)
            field.page = index
            field.rect.origin = CGPoint(x: min(max(point.x - field.rect.width / 2, bounds.minX), bounds.maxX - field.rect.width),
                                        y: min(max(point.y - field.rect.height / 2, bounds.minY), bounds.maxY - field.rect.height))
            session.update(field); placing = nil
        }
        .accessibilityIdentifier("documentPreview")
    }
    private var form: some View {
        Group {
            if session.item.fields.isEmpty {
                ContentUnavailableView {
                    Label(session.item.analyzed == true ? "Sin campos detectados" : "Completa tu documento", systemImage: "rectangle.and.text.magnifyingglass")
                } description: {
                    Text(session.item.analyzed == true ? "Puede que esta página no sea un formulario. Puedes añadir texto y casillas manualmente." : "Detecta los campos con IA local o añade un campo donde lo necesites.")
                } actions: {
                    Button("Añadir un campo") { add(checkbox: false) }.buttonStyle(.bordered)
                }
            } else {
                Form {
                    ForEach(0..<session.document.pageCount, id: \.self) { index in
                        let fields = session.item.fields.filter { $0.page == index }
                        if !fields.isEmpty {
                            Section("Página \(index + 1)") {
                                ForEach(fields) { field in
                                    HStack(alignment: .center, spacing: 12) {
                                        if field.checkbox {
                                            Toggle(field.label, isOn: Binding(get: { field.checked }, set: {
                                                var updated = field; updated.checked = $0; session.update(updated)
                                            }))
                                        } else {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                                                TextField("Escribe aquí", text: Binding(get: { field.text }, set: {
                                                    var updated = field; updated.text = $0; session.update(updated)
                                                }), axis: .vertical)
                                                .focused($focusedField, equals: field.id)
                                                .lineLimit(1...8).accessibilityIdentifier("field-\(field.label)")
                                            }
                                        }
                                        Button { selection = field } label: { Image(systemName: "slider.horizontal.3") }
                                            .buttonStyle(.borderless).accessibilityLabel("Editar \(field.label)")
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }.scrollDismissesKeyboard(.interactively)
            }
        }
    }
    private func add(checkbox: Bool) {
        let id = session.addField(checkbox: checkbox, page: page)
        selection = session.item.fields.first { $0.id == id }
    }
}

struct FieldInspector: View {
    @ObservedObject var session: DocumentSession
    let id: UUID
    let place: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var field: FormEntry? { session.item.fields.first { $0.id == id } }
    private func binding<T>(_ keyPath: WritableKeyPath<FormEntry, T>, fallback: T) -> Binding<T> {
        Binding(get: { field?[keyPath: keyPath] ?? fallback }, set: { value in
            guard var field else { return }; field[keyPath: keyPath] = value; session.update(field)
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                if let field {
                    Section("Campo") {
                        TextField("Etiqueta", text: binding(\.label, fallback: ""))
                        if field.checkbox { Toggle("Marcada", isOn: binding(\.checked, fallback: false)) }
                        else { TextField("Contenido", text: binding(\.text, fallback: ""), axis: .vertical).lineLimit(1...8) }
                    }
                    Section("Posición y tamaño") {
                        LabeledContent("Página", value: "\(field.page + 1)")
                        Button("Colocar en el documento", systemImage: "hand.tap") { place() }
                            .disabled(field.widgetName != nil)
                        if field.widgetName == nil {
                            LabeledContent("Ancho", value: "\(Int(field.rect.width)) pt")
                            Slider(value: Binding(get: { field.rect.width }, set: {
                                var updated = field; updated.rect.size.width = $0; session.update(updated)
                            }), in: 16...max(17, session.document.page(at: field.page)!.bounds(for: .cropBox).maxX - field.rect.minX))
                            .accessibilityLabel("Ancho del campo")
                            LabeledContent("Alto", value: "\(Int(field.rect.height)) pt")
                            Slider(value: Binding(get: { field.rect.height }, set: {
                                var updated = field; updated.rect.size.height = $0; session.update(updated)
                            }), in: 16...max(17, min(200, session.document.page(at: field.page)!.bounds(for: .cropBox).maxY - field.rect.minY)))
                            .accessibilityLabel("Alto del campo")
                        }
                    }
                    Section {
                        Button("Eliminar campo", role: .destructive) { session.remove(id); dismiss() }
                    }
                }
            }
            .navigationTitle("Editar campo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }
}
