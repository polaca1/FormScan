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
    var recoveredText: String? = nil
    var widgetName: String?
    var origin: String?
    var completed: Bool { checkbox ? checked : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct SavedDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var modified = Date()
    var pageCount: Int
    var fields: [FormEntry]
    var analyzed: Bool? = nil
    var analysisVersion: Int? = nil
}

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [SavedDocument] = []
    let directory: URL
    @Published var error: String?
    var didChange: (() -> Void)?
    var activeDocumentID: UUID?
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
        documents = urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(SavedDocument.self, from: data)
        }.sorted { $0.modified > $1.modified }
    }

    func close() throws {
        for session in sessions.values { try session.prepareForClose() }
        for session in sessions.values { session.invalidate() }
        sessions.removeAll(); thumbnails.removeAll()
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
        guard let pdf = PDFDocument(url: pdfURL(item.id)), let page = pdf.page(at: 0) else { return nil }
        let image = withExtendedLifetime(pdf) { page.thumbnail(of: CGSize(width: 96, height: 128), for: .cropBox) }
        thumbnails[item.id] = image
        return image
    }
    func delete(_ item: SavedDocument) {
        do {
            var requests = try deletionRequests()
            requests[item.id.uuidString] = try DocumentFingerprint.of(sessions[item.id]?.item ?? item)
            try writeDeletionRequests(requests)
            try removeLocalVersion(item.id)
            didChange?()
        } catch { self.error = FormScanError.saveFailed.localizedDescription }
    }
    func deletionRequests() throws -> [String: String] {
        let url = directory.appendingPathComponent(".cloud-deletions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let requests = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        guard requests.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw DocumentCloudIssue.localState }
        return requests
    }
    private func writeDeletionRequests(_ requests: [String: String]) throws {
        try JSONEncoder().encode(requests).write(to: directory.appendingPathComponent(".cloud-deletions.json"), options: .atomic)
    }
    func clearDeletionRequest(_ id: UUID) throws {
        var requests = try deletionRequests(); requests[id.uuidString] = nil
        try writeDeletionRequests(requests)
    }
    func removeLocalVersion(_ id: UUID) throws {
        sessions[id]?.invalidate(); sessions[id] = nil; thumbnails[id] = nil
        for url in [pdfURL(id), metadataURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        documents.removeAll { $0.id == id }
    }
    func flushForCloud() throws {
        for session in sessions.values { try session.persistNow() }
    }
    func hasLocalPDF(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: pdfURL(id).path) }
    func cloudSnapshot(_ id: UUID) throws -> CloudLocalSnapshot? {
        guard var item = documents.first(where: { $0.id == id }) else { return nil }
        if let session = sessions[id] {
            try session.persistNow(); item = session.item
        } else {
            let repaired = FieldReconciliation.repair(item.fields)
            if repaired != item.fields {
                guard let pdf = PDFDocument(url: pdfURL(id)) else { throw DocumentCloudIssue.invalidDocument }
                item.fields = repaired; PDFFormWriter.synchronize(repaired, in: pdf); try save(item, pdf: pdf)
            }
        }
        return CloudLocalSnapshot(item: item, pdf: try Data(contentsOf: pdfURL(id)))
    }
    func installCloud(_ record: CloudRecord, pdf data: Data) throws {
        guard activeDocumentID != record.id, (try deletionRequests())[record.id.uuidString] == nil,
              let pdf = PDFDocument(data: data), !pdf.isLocked,
              pdf.pageCount > 0, pdf.pageCount == record.metadata.pageCount,
              record.metadata.id == record.id,
              Set(record.metadata.fields.map(\.id)).count == record.metadata.fields.count,
              record.metadata.fields.allSatisfy({ $0.page >= 0 && $0.page < pdf.pageCount && $0.rect.minX.isFinite && $0.rect.minY.isFinite && $0.rect.width.isFinite && $0.rect.height.isFinite }) else { throw DocumentCloudIssue.invalidDocument }
        sessions[record.id]?.invalidate(); sessions[record.id] = nil
        var item = record.metadata; item.fields = FieldReconciliation.repair(item.fields)
        PDFFormWriter.synchronize(item.fields, in: pdf)
        try save(item, pdf: pdf, force: true)
    }
    func preserveConflict(_ id: UUID) throws {
        guard let snapshot = try cloudSnapshot(id), let pdf = PDFDocument(data: snapshot.pdf) else { return }
        var copy = snapshot.item; copy.id = UUID(); copy.title += " (copia conservada)"; copy.modified = Date()
        try save(copy, pdf: pdf)
    }
    private func pdfURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).pdf") }
    private func metadataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).json") }
    private func save(_ item: SavedDocument, pdf: PDFDocument, force: Bool = false) throws {
        let changed = documents.first(where: { $0.id == item.id }) != item
        if !changed, !force,
           (try? pdfURL(item.id).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           (try? metadataURL(item.id).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return }
        guard let data = pdf.dataRepresentation() else { throw FormScanError.saveFailed }
        try data.write(to: pdfURL(item.id), options: .atomic)
        try JSONEncoder().encode(item).write(to: metadataURL(item.id), options: .atomic)
        documents.removeAll { $0.id == item.id }; documents.insert(item, at: 0)
        thumbnails[item.id] = nil
        if changed { didChange?() }
    }
}

@MainActor
final class DocumentSession: ObservableObject {
    static let analysisVersion = 4
    @Published var item: SavedDocument
    let document: PDFDocument
    @Published var revision = 0
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    private let save: (SavedDocument, PDFDocument) throws -> Void
    private var pendingSave: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var editedDuringAnalysis = Set<UUID>()
    private var rejectedDuringAnalysis: [FormEntry] = []
    private var valid = true
    func invalidate() {
        valid = false; pendingSave?.cancel(); analysisTask?.cancel()
    }
    func startAnalysis(using models: AnalysisEngine, automatic: Bool = false) {
        guard !busy, analysisTask == nil, !automatic || item.analyzed != true || (item.analysisVersion ?? 0) < Self.analysisVersion else { return }
        let jobs = models.analysisJobs, parallelism = models.parallelism
        analysisTask = Task { [weak self] in
            guard let self else { return }
            await self.detect(jobs: jobs, parallelism: parallelism)
            self.analysisTask = nil
        }
    }
    func cancelAnalysis() { analysisTask?.cancel() }


    init(item: SavedDocument, document: PDFDocument, save: @escaping (SavedDocument, PDFDocument) throws -> Void) {
        self.item = item; self.document = document; self.save = save
        self.item.fields = FieldReconciliation.repair(item.fields)
        PDFFormWriter.synchronize(self.item.fields, in: document)
    }
    func update(_ field: FormEntry) {
        guard let index = item.fields.firstIndex(where: { $0.id == field.id }) else { return }
        item.fields[index] = field
        if busy { editedDuringAnalysis.insert(field.id) }
        if let name = field.widgetName {
            for sibling in item.fields.indices where item.fields[sibling].widgetName == name {
                if busy { editedDuringAnalysis.insert(item.fields[sibling].id) }
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
                              label: checkbox ? "Casilla" : "Texto", checkbox: checkbox, origin: "manual")
        item.fields.append(field); changed()
        return field.id
    }
    func remove(_ id: UUID) {
        if busy, let field = item.fields.first(where: { $0.id == id }) { rejectedDuringAnalysis.append(field) }
        if let field = item.fields.first(where: { $0.id == id }), let name = field.widgetName,
           let page = document.page(at: field.page) {
            page.annotations.filter { $0.fieldName == name }.forEach { page.removeAnnotation($0) }
        }
        item.fields.removeAll { $0.id == id }; changed()
    }
    func changed() {
        guard valid else { return }
        PDFFormWriter.synchronize(item.fields, in: document)
        revision += 1; item.modified = Date()
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }
    func flush() {
        guard valid else { return }
        pendingSave?.cancel()
        do { try save(item, document) } catch { self.error = error.localizedDescription }
    }
    func persistNow() throws {
        pendingSave?.cancel()
        try save(item, document)
    }
    func prepareForClose() throws {
        analysisTask?.cancel()
        try persistNow()
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
    func detect(model: AIModel = .nano, modelURL: URL? = nil) async {
        guard let url = modelURL ?? Bundle.main.url(forResource: "model", withExtension: "onnx") else { return }
        await detect(jobs: [InferenceJob(model: model, url: url)], parallelism: 1)
    }
    func detect(jobs: [InferenceJob], parallelism: Int) async {
        guard valid, !busy, !jobs.isEmpty else { return }
        busy = true; editedDuringAnalysis.removeAll(); rejectedDuringAnalysis.removeAll()
        defer { busy = false; progress = ""; editedDuringAnalysis.removeAll(); rejectedDuringAnalysis.removeAll() }
        var failures: [String] = []
        var successful = false
        do {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .cropBox), rotation = page.rotation
                // Analyze the original printed page, not FormScan's own answers
                // or PDFKit's widget appearances from a previous edit.
                let visibility = page.annotations.filter { $0.userName?.hasPrefix(PDFFormWriter.prefix) == true || $0.type == "Widget" }.map { ($0, $0.shouldDisplay) }
                visibility.forEach { $0.0.shouldDisplay = false }
                let image = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .cropBox)
                for (annotation, visible) in visibility { annotation.shouldDisplay = visible }
                let imageSize = CGSize(width: image.cgImage!.width, height: image.cgImage!.height)
                progress = "Leyendo página \(index + 1) de \(document.pageCount)…"
                let lines = await Task.detached(priority: .userInitiated) { (try? FieldLabels.recognize(image)) ?? [] }.value
                let grid = await Task.detached(priority: .userInitiated) { TableGrid.detect(image, lines: lines) }.value
                // One-time repair of untouched detections from older versions.
                // Values, native widgets, manual fields and custom labels survive.
                item.fields.removeAll { field in
                    guard field.page == index, field.widgetName == nil, !field.completed,
                          field.origin != "manual", !editedDuringAnalysis.contains(field.id) else { return false }
                    let imageRect = PDFFormWriter.imageRect(field.rect, imageSize: imageSize, bounds: bounds, rotation: rotation)
                    if field.origin == "table", grid.matchesCell(imageRect, checkbox: field.checkbox) { return false }
                    return grid.owns(imageRect) && (field.origin == "model" || grid.replacesLegacy(label: field.label))
                }
                let tableFields = grid.fields
                var results: [AIModel: [DetectedField]] = [:]
                // Only fields created during this analysis can be refined or removed.
                // Existing fields and anything the user edits stay authoritative.
                var provisional: [UUID: FormEntry] = [:]
                await FieldEnsemble.run(image: image, jobs: jobs, parallelism: parallelism) { result, completed in
                    guard !Task.isCancelled else { return }
                    progress = "Revisando campos de la página \(index + 1) de \(document.pageCount)…"
                    switch result.fields {
                    case .failure(let message): failures.append(message)
                    case .success(let fields):
                        successful = true
                        results[result.model] = fields
                        let modelFields = FieldEnsemble.fuse(results).filter { !grid.replaces($0) }
                        let fused = tableFields.map { DetectedField(rect: $0.rect, category: $0.checkbox ? 1 : 0, confidence: 1) } + modelFields
                        var retained = Set<UUID>()
                        for detection in fused {
                            let rect = PDFFormWriter.pdfRect(detection.rect, imageSize: imageSize, bounds: bounds, rotation: rotation)
                            guard !rect.isEmpty, !rejectedDuringAnalysis.contains(where: {
                                $0.page == index && $0.rect.intersection(rect).area > min($0.rect.area, rect.area) * 0.5
                            }) else { continue }
                            let checkbox = detection.category == 1
                            guard !FieldReconciliation.conflictsWithExplicitType(rect: rect, checkbox: checkbox, page: index, fields: item.fields) else { continue }
                            let table = tableFields.first { $0.rect == detection.rect }
                            let label = table?.label ?? FieldLabels.label(for: detection.rect, checkbox: checkbox, lines: lines)
                            if let existing = item.fields.firstIndex(where: {
                                $0.page == index && $0.checkbox == checkbox && $0.rect.intersection(rect).area > min($0.rect.area, rect.area) * 0.5
                            }) {
                                let field = item.fields[existing]
                                retained.insert(field.id)
                                if provisional[field.id] == field, !editedDuringAnalysis.contains(field.id) {
                                    item.fields[existing].rect = rect
                                    item.fields[existing].checkbox = checkbox
                                    if let label { item.fields[existing].label = label }
                                    provisional[field.id] = item.fields[existing]
                                } else if field.checkbox == checkbox, let label,
                                          (["Casilla", "Opción sin etiqueta", "Campo de texto", "Firma"].contains(field.label) || (table != nil && !field.completed && grid.replacesLegacy(label: field.label))) {
                                    item.fields[existing].label = label
                                }
                            } else {
                                let fallback = checkbox ? "Opción sin etiqueta" : detection.category == 2 ? "Firma" : "Campo de texto"
                                let field = FormEntry(page: index, rect: rect, label: label ?? fallback, checkbox: checkbox, origin: table == nil ? "model" : "table")
                                item.fields.append(field); provisional[field.id] = field; retained.insert(field.id)
                            }
                        }
                        item.fields.removeAll { field in
                            !retained.contains(field.id) && provisional[field.id] == field && !editedDuringAnalysis.contains(field.id)
                        }
                        item.fields = FieldReconciliation.repair(item.fields)
                        item.fields.sort {
                            if $0.page != $1.page { return $0.page < $1.page }
                            return abs($0.rect.maxY - $1.rect.maxY) < 4 ? $0.rect.minX < $1.rect.minX : $0.rect.maxY > $1.rect.maxY
                        }
                        changed()
                    }
                }
            }
            try Task.checkCancellation()
            if successful { item.analyzed = true; item.analysisVersion = Self.analysisVersion; changed(); flush() }
            if !failures.isEmpty {
                #if DEBUG
                print("Analysis diagnostics:", failures)
                #endif
                error = successful ? "Algunos campos no se han podido revisar. Puedes volver a analizar el documento." : "No se pudo analizar el documento. Vuelve a intentarlo."
            }
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
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
                if field.checkbox {
                    widget.widgetControlType = .checkBoxControl
                    widget.buttonWidgetState = field.checked ? .onState : .offState
                    // PDFKit's generated button appearance varies by PDF producer.
                    // Preserve its editable state but render our portable vector appearance.
                    widget.shouldDisplay = false; widget.shouldPrint = false
                } else { widget.widgetStringValue = field.text; continue }
            }
            if field.checkbox {
                let outline = PDFAnnotation(bounds: field.rect, forType: .square, withProperties: nil)
                outline.userName = prefix + field.id.uuidString + ":outline"
                outline.color = .black; outline.interiorColor = nil
                let edge = PDFBorder(); edge.lineWidth = 0.8; outline.border = edge
                page.addAnnotation(outline)
                if field.checked {
                    let mark = PDFAnnotation(bounds: field.rect, forType: .ink, withProperties: nil)
                    mark.userName = prefix + field.id.uuidString; mark.color = .black; mark.contents = "✓"
                    let border = PDFBorder(); border.lineWidth = max(1.5, min(field.rect.width, field.rect.height) * 0.10); mark.border = border
                    let path = UIBezierPath()
                    let w = field.rect.width, h = field.rect.height
                    path.move(to: CGPoint(x: w * 0.18, y: h * 0.5))
                    path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.25))
                    path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.82))
                    mark.add(path); page.addAnnotation(mark)
                }
                continue
            }
            guard field.completed else { continue }
            let annotation = PDFAnnotation(bounds: field.rect, forType: .freeText, withProperties: nil)
            annotation.userName = prefix + field.id.uuidString
            annotation.contents = field.text
            // PDF standard fonts survive serialization without SF UI font substitution.
            annotation.font = UIFont(name: "Helvetica", size: min(15, max(8, field.rect.height * 0.65)))
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
                let checkbox = annotation.widgetFieldType == .button
                let region = CGRect(x: annotation.bounds.maxX + 2, y: annotation.bounds.minY - annotation.bounds.height * 0.25,
                                    width: max(0, page.bounds(for: .cropBox).maxX - annotation.bounds.maxX - 8), height: annotation.bounds.height * 1.5)
                let printed = checkbox ? page.selection(for: region)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                let label = printed.flatMap { $0.isEmpty ? nil : $0 } ?? name
                return FormEntry(page: index, rect: annotation.bounds, label: label,
                                 text: annotation.widgetStringValue ?? "", checked: annotation.buttonWidgetState == .onState,
                                 checkbox: checkbox, widgetName: name)
            }
        }
    }
    static func imageRect(_ rect: CGRect, imageSize: CGSize, bounds: CGRect, rotation: Int = 0) -> CGRect {
        let x = (rect.minX - bounds.minX) / bounds.width
        let y = (rect.minY - bounds.minY) / bounds.height
        let w = rect.width / bounds.width, h = rect.height / bounds.height
        let normalized: CGRect
        switch (rotation % 360 + 360) % 360 {
        case 90: normalized = CGRect(x: y, y: x, width: h, height: w)
        case 180: normalized = CGRect(x: 1 - x - w, y: y, width: w, height: h)
        case 270: normalized = CGRect(x: 1 - y - h, y: 1 - x - w, width: h, height: w)
        default: normalized = CGRect(x: x, y: 1 - y - h, width: w, height: h)
        }
        return CGRect(x: normalized.minX * imageSize.width, y: normalized.minY * imageSize.height,
                      width: normalized.width * imageSize.width, height: normalized.height * imageSize.height)
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
