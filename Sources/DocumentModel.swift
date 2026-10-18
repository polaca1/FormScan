import SwiftUI
import PDFKit

enum FormScanError: LocalizedError {
    case invalidDocument, saveFailed, locked
    var errorDescription: String? {
        switch self {
        case .invalidDocument: "El archivo no contiene un PDF o una imagen compatible."
        case .saveFailed: "No se pudo guardar el documento. Comprueba el espacio disponible."
        case .locked: "Este PDF está protegido con contraseña. Importa una copia desbloqueada."
        }
    }
}

struct FormEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var page: Int
    var rect: CGRect
    var label: String
    var text = ""
    var checked = false
    var checkbox = false
    var widgetName: String?
    var completed: Bool { checkbox ? checked : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct SavedDocument: Identifiable, Codable {
    var id = UUID()
    var title: String
    var modified = Date()
    var pageCount: Int
    var fields: [FormEntry]
}

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [SavedDocument] = []
    private let directory: URL
    private var sessions: [UUID: DocumentSession] = [:]
    private var thumbnails: [UUID: UIImage] = [:]

    init(directory: URL? = nil) {
        let reset = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let testing = reset || ProcessInfo.processInfo.arguments.contains("-ui-testing-reopen")
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "UITestDocuments" : "Documents", isDirectory: true)
        if reset { try? FileManager.default.removeItem(at: self.directory) }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        documents = urls.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(SavedDocument.self, from: data)
        }.sorted { $0.modified > $1.modified }
    }

    func add(_ pdf: PDFDocument, title: String) throws -> UUID {
        guard !pdf.isLocked else { throw FormScanError.locked }
        guard pdf.pageCount > 0 else { throw FormScanError.invalidDocument }
        let item = SavedDocument(title: title, pageCount: pdf.pageCount, fields: PDFFormWriter.embeddedFields(in: pdf))
        try save(item, pdf: pdf)
        return item.id
    }
    func session(id: UUID) -> DocumentSession? {
        if let session = sessions[id] { return session }
        guard let item = documents.first(where: { $0.id == id }), let pdf = PDFDocument(url: pdfURL(id)) else { return nil }
        let session = DocumentSession(item: item, document: pdf) { [weak self] item, pdf in
            guard let self else { return }
            try self.save(item, pdf: pdf)
        }
        sessions[id] = session
        return session
    }
    func thumbnail(for item: SavedDocument) -> UIImage? {
        if let image = thumbnails[item.id] { return image }
        let image = PDFDocument(url: pdfURL(item.id))?.page(at: 0)?.thumbnail(of: CGSize(width: 96, height: 128), for: .cropBox)
        thumbnails[item.id] = image
        return image
    }
    func delete(_ item: SavedDocument) {
        try? FileManager.default.removeItem(at: pdfURL(item.id))
        try? FileManager.default.removeItem(at: metadataURL(item.id))
        sessions[item.id] = nil; thumbnails[item.id] = nil
        documents.removeAll { $0.id == item.id }
    }
    private func pdfURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).pdf") }
    private func metadataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).json") }
    private func save(_ item: SavedDocument, pdf: PDFDocument) throws {
        guard let data = pdf.dataRepresentation() else { throw FormScanError.saveFailed }
        try data.write(to: pdfURL(item.id), options: .atomic)
        try JSONEncoder().encode(item).write(to: metadataURL(item.id), options: .atomic)
        documents.removeAll { $0.id == item.id }; documents.insert(item, at: 0)
        thumbnails[item.id] = nil
    }
}

@MainActor
final class DocumentSession: ObservableObject {
    @Published var item: SavedDocument
    let document: PDFDocument
    @Published var revision = 0
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    private let save: (SavedDocument, PDFDocument) throws -> Void
    private var pendingSave: Task<Void, Never>?

    init(item: SavedDocument, document: PDFDocument, save: @escaping (SavedDocument, PDFDocument) throws -> Void) {
        self.item = item; self.document = document; self.save = save
        PDFFormWriter.synchronize(item.fields, in: document)
    }
    func update(_ field: FormEntry) {
        guard let index = item.fields.firstIndex(where: { $0.id == field.id }) else { return }
        item.fields[index] = field
        if let name = field.widgetName {
            for sibling in item.fields.indices where item.fields[sibling].widgetName == name {
                item.fields[sibling].text = field.text
                item.fields[sibling].checked = field.checked
            }
        }
        changed()
    }
    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        item.title = trimmed; changed()
    }
    @discardableResult
    func addField(checkbox: Bool, page index: Int) -> UUID {
        let index = min(max(index, 0), document.pageCount - 1)
        let bounds = document.page(at: index)!.bounds(for: .cropBox)
        let field = FormEntry(page: index, rect: CGRect(x: bounds.midX - 80, y: bounds.midY, width: checkbox ? 22 : 160, height: 26),
                              label: checkbox ? "Casilla" : "Texto", checkbox: checkbox)
        item.fields.append(field); changed()
        return field.id
    }
    func remove(_ id: UUID) {
        if let field = item.fields.first(where: { $0.id == id }), let name = field.widgetName,
           let page = document.page(at: field.page) {
            page.annotations.filter { $0.fieldName == name }.forEach { page.removeAnnotation($0) }
        }
        item.fields.removeAll { $0.id == id }; changed()
    }
    func changed() {
        PDFFormWriter.synchronize(item.fields, in: document)
        revision += 1; item.modified = Date()
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }
    func flush() {
        pendingSave?.cancel()
        do { try save(item, document) } catch { self.error = error.localizedDescription }
    }
    func export() throws -> URL {
        PDFFormWriter.synchronize(item.fields, in: document)
        let first = document.page(at: 0)!.bounds(for: .cropBox)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        let data = renderer.pdfData { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .cropBox)
                context.beginPage(withBounds: CGRect(origin: .zero, size: bounds.size), pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState(); cg.translateBy(x: 0, y: bounds.height); cg.scaleBy(x: 1, y: -1)
                cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            }
        }
        let name = item.title.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-completado.pdf")
        try data.write(to: url, options: .atomic); flush()
        return url
    }
    func detect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; progress = "" }
        var found: [FormEntry] = []
        do {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                progress = "Analizando página \(index + 1) de \(document.pageCount)…"
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .cropBox)
                let image = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .cropBox)
                let detections = try await Task.detached(priority: .userInitiated) { try LocalFieldAI.detect(image) }.value
                try Task.checkCancellation()
                for detection in detections {
                    let rect = PDFFormWriter.pdfRect(detection.rect, imageSize: CGSize(width: image.cgImage!.width, height: image.cgImage!.height), bounds: bounds, rotation: page.rotation)
                    let exists = (item.fields + found).contains { $0.page == index && $0.rect.intersection(rect).area > min($0.rect.area, rect.area) * 0.5 }
                    if !exists, !rect.isEmpty {
                        found.append(FormEntry(page: index, rect: rect, label: detection.category == 1 ? "Casilla" : detection.category == 2 ? "Firma" : "Campo de texto", checkbox: detection.category == 1))
                    }
                }
            }
            found.sort { $0.page == $1.page ? $0.rect.midY > $1.rect.midY : $0.page < $1.page }
            item.fields.append(contentsOf: found); changed()
        } catch is CancellationError {
            return
        } catch { self.error = "No se pudo analizar: \(error.localizedDescription)" }
    }
}

extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

enum PDFFormWriter {
    static let prefix = "FormScan:"
    static func synchronize(_ fields: [FormEntry], in document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.annotations.filter { $0.userName?.hasPrefix(prefix) == true }.forEach { page.removeAnnotation($0) }
        }
        for field in fields {
            guard let page = document.page(at: field.page) else { continue }
            if let name = field.widgetName, let widget = page.annotations.first(where: { $0.fieldName == name }) {
                if field.checkbox { widget.buttonWidgetState = field.checked ? .onState : .offState }
                else { widget.widgetStringValue = field.text }
                continue
            }
            guard field.completed else { continue }
            let annotation = PDFAnnotation(bounds: field.rect, forType: .freeText, withProperties: nil)
            annotation.userName = prefix + field.id.uuidString
            annotation.contents = field.checkbox ? "✓" : field.text
            annotation.font = .systemFont(ofSize: min(field.checkbox ? 22 : 15, max(8, field.rect.height * 0.65)))
            annotation.fontColor = .black; annotation.color = .clear
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
            page.addAnnotation(annotation)
        }
    }
    static func embeddedFields(in document: PDFDocument) -> [FormEntry] {
        (0..<document.pageCount).flatMap { index -> [FormEntry] in
            guard let page = document.page(at: index) else { return [] }
            return page.annotations.compactMap { annotation -> FormEntry? in
                guard annotation.type == "Widget", let name = annotation.fieldName,
                      annotation.widgetFieldType == .text || annotation.widgetFieldType == .button else { return nil }
                return FormEntry(page: index, rect: annotation.bounds, label: name,
                                 text: annotation.widgetStringValue ?? "", checked: annotation.buttonWidgetState == .onState,
                                 checkbox: annotation.widgetFieldType == .button, widgetName: name)
            }
        }
    }
    static func pdfRect(_ rect: CGRect, imageSize: CGSize, bounds: CGRect, rotation: Int = 0) -> CGRect {
        let x = rect.minX / imageSize.width, y = rect.minY / imageSize.height
        let w = rect.width / imageSize.width, h = rect.height / imageSize.height
        let normalized: CGRect
        switch (rotation % 360 + 360) % 360 {
        case 90: normalized = CGRect(x: y, y: x, width: h, height: w)
        case 180: normalized = CGRect(x: 1 - x - w, y: y, width: w, height: h)
        case 270: normalized = CGRect(x: 1 - y - h, y: 1 - x - w, width: h, height: w)
        default: normalized = CGRect(x: x, y: 1 - y - h, width: w, height: h)
        }
        return CGRect(x: bounds.minX + normalized.minX * bounds.width, y: bounds.minY + normalized.minY * bounds.height,
                      width: normalized.width * bounds.width, height: normalized.height * bounds.height).intersection(bounds)
    }
}
