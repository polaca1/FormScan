import SwiftUI
import PDFKit
import VisionKit

struct ScannerView: UIViewControllerRepresentable {
    let finished: (Result<[UIImage], Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ScannerView
        init(parent: ScannerView) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.dismiss(); parent.finished(.success((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss(); parent.finished(.failure(error))
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

struct PDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    let fields: [FormEntry]
    let revision: Int
    @Binding var page: Int
    let placing: UUID?
    let select: (FormEntry) -> Void
    let place: (CGPoint, Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = .secondarySystemGroupedBackground
        view.pageShadowsEnabled = true
        view.pageOverlayViewProvider = context.coordinator
        view.isInMarkupMode = true
        view.document = document
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document }
        if let current = view.currentPage, document.index(for: current) != page, let target = document.page(at: page) {
            view.go(to: target)
        }
        for overlay in context.coordinator.overlays { overlay.fields = fields; overlay.setNeedsDisplay() }
        if context.coordinator.lastRevision != revision {
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { view.annotationsChanged(on: page) }
            }
            context.coordinator.lastRevision = revision
        }
        view.documentView?.setNeedsDisplay()
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        var parent: PDFCanvas
        weak var pdfView: PDFView?
        var overlays: [FieldOverlay] = []
        var lastRevision = -1
        init(parent: PDFCanvas) { self.parent = parent }
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let overlay = FieldOverlay()
            overlay.pdfView = view; overlay.page = page; overlay.fields = parent.fields
            overlay.backgroundColor = .clear; overlay.isUserInteractionEnabled = false
            overlays.append(overlay)
            return overlay
        }
        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            overlays.removeAll { $0 === overlayView }
        }
        @objc func pageChanged() {
            guard let view = pdfView, let page = view.currentPage else { return }
            let index = parent.document.index(for: page)
            DispatchQueue.main.async { [weak self] in self?.parent.page = index }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = pdfView, let page = view.page(for: gesture.location(in: view), nearest: false) else { return }
            let point = view.convert(gesture.location(in: view), to: page)
            let index = parent.document.index(for: page)
            if parent.placing != nil { parent.place(point, index); return }
            if let field = parent.fields.first(where: { $0.page == index && $0.rect.insetBy(dx: -8, dy: -8).contains(point) }) { parent.select(field) }
        }
    }
}

final class FieldOverlay: UIView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var fields: [FormEntry] = []
    override func draw(_ rect: CGRect) {
        guard let pdfView, let page, let document = pdfView.document else { return }
        for field in fields where field.page == document.index(for: page) {
            let bounds = convert(pdfView.convert(field.rect, from: page), from: pdfView)
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: 3)
            UIColor.systemBlue.withAlphaComponent(field.completed ? 0.12 : 0.07).setFill(); path.fill()
            UIColor.systemBlue.withAlphaComponent(0.5).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

enum ExampleDocument {
    static func make(widgets: Bool = true) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: UIColor = .black) {
                (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color])
            }
            text("FORMSCAN", x: 48, y: 48, size: 12, color: .systemBlue)
            text("Tu próximo paso, en papel.", x: 48, y: 86, size: 27)
            text("FORMULARIO DE INSCRIPCIÓN", x: 48, y: 132, size: 11, color: .darkGray)
            for (label, y) in [("Nombre completo", 212.0), ("Correo electrónico", 310.0), ("Fecha", 408.0)] {
                text(label, x: 48, y: y - 28, size: 13)
                UIColor.lightGray.setStroke()
                let path = UIBezierPath(rect: CGRect(x: 48, y: y, width: 499, height: 40)); path.lineWidth = 1; path.stroke()
            }
            UIBezierPath(rect: CGRect(x: 48, y: 510, width: 22, height: 22)).stroke()
            text("He revisado los datos del formulario.", x: 86, y: 512, size: 14)
            text("Creado para que puedas probar la edición y la exportación.", x: 48, y: 740, size: 11, color: .darkGray)
        }
        let pdf = PDFDocument(data: data)!
        if widgets, let page = pdf.page(at: 0) {
            for (name, y) in [("Nombre completo", 212.0), ("Correo electrónico", 310.0), ("Fecha", 408.0)] {
                let annotation = PDFAnnotation(bounds: CGRect(x: 52, y: 842 - y - 36, width: 491, height: 32), forType: .widget, withProperties: nil)
                annotation.widgetFieldType = .text; annotation.fieldName = name
                annotation.font = .systemFont(ofSize: 15); annotation.fontColor = .black; annotation.color = .clear
                page.addAnnotation(annotation)
            }
        }
        return pdf
    }
}
