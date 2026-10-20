#if DEBUG
import UIKit
import PDFKit

/// Deterministic printed regression fixture: six problems by three response
/// columns, with the empty top-left corner left open as in the reported table.
enum ExampleTable {
    static let rows = ["insufficient water supply", "desertification / deforestation", "too much rubbish (sea/country)",
                       "polluted river", "air pollution", "disappearance of some animal species"]
    static let columns = ["Possible causes", "Pro-green policies", "Your environmentally-friendly everyday actions"]
    static func make(extraFields: Bool = false, filledCell: Bool = false, openBottom: Bool = false) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595))
        let data = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            func text(_ value: String, _ rect: CGRect, bold: Bool = false, size: CGFloat = 13) {
                (value as NSString).draw(in: rect, withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black])
            }
            text("The environment", CGRect(x: 340, y: 52, width: 300, height: 22), bold: true)
            text("Look at the environmental problems. Write possible causes, policies and everyday actions.", CGRect(x: 48, y: 85, width: 746, height: 30))
            let xs: [CGFloat] = [48, 225, 425, 610, 794]
            cg.setStrokeColor(UIColor(white: 0.6, alpha: 1).cgColor); cg.setLineWidth(0.8)
            for x in xs {
                cg.move(to: CGPoint(x: x, y: x == 48 ? 175 : 130)); cg.addLine(to: CGPoint(x: x, y: 505)); cg.strokePath()
            }
            for y in [CGFloat(130)] + (0...6).map({ 175 + CGFloat($0) * 55 }) {
                if openBottom && y == 505 { continue }
                cg.move(to: CGPoint(x: y == 130 ? 225 : 48, y: y)); cg.addLine(to: CGPoint(x: 794, y: y)); cg.strokePath()
            }
            for i in columns.indices { text(columns[i], CGRect(x: xs[i+1] + 6, y: 135, width: xs[i+2] - xs[i+1] - 12, height: 38), bold: true, size: 11) }
            for i in rows.indices { text(rows[i], CGRect(x: 57, y: 184 + CGFloat(i)*55, width: 160, height: 45), bold: true) }
            if filledCell { text("Observed answer 123", CGRect(x: 232, y: 188, width: 185, height: 35)) }
            if extraFields {
                text("Name", CGRect(x: 225, y: 515, width: 120, height: 20))
                cg.stroke(CGRect(x: 225, y: 540, width: 190, height: 30))
                cg.stroke(CGRect(x: 450, y: 543, width: 22, height: 22))
                text("I have reviewed this document", CGRect(x: 485, y: 545, width: 300, height: 24))
            }
        }
        return PDFDocument(data: data)!
    }
}
#endif
