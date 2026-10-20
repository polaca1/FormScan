#if DEBUG
import UIKit
import PDFKit

/// Deterministic printed regression fixture: six problems by three response
/// columns, with the empty top-left corner left open as in the reported table.
enum ExampleTable {
    static let rows = ["insufficient water supply", "desertification / deforestation", "too much rubbish (sea/country)",
                       "polluted river", "air pollution", "disappearance of some animal species"]
    static let columns = ["Possible causes", "Pro-green policies", "Your environmentally-friendly everyday actions"]
    static func make(extraFields: Bool = false, filledCell: Bool = false, openBottom: Bool = false, checkboxCell: Bool = false) -> PDFDocument {
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
            if checkboxCell { cg.stroke(CGRect(x: 625, y: 190, width: 22, height: 22)) }
            if extraFields {
                text("Name", CGRect(x: 225, y: 515, width: 120, height: 20))
                cg.stroke(CGRect(x: 225, y: 540, width: 190, height: 30))
                cg.stroke(CGRect(x: 450, y: 543, width: 22, height: 22))
                text("I have reviewed this document", CGRect(x: 485, y: 545, width: 300, height: 24))
            }
        }
        return PDFDocument(data: data)!
    }
    /// Screenshot-shaped reproduction, not the user's original PDF. Thin rules
    /// exercise antialiasing; tail rules have no seventh printed row label.
    static func reported(thinRules: Bool = true, tailRules: Bool = false, signature: Bool = false) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 792, height: 612))
        let data = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            func text(_ value: String, _ rect: CGRect, bold: Bool = false, size: CGFloat = 11) {
                (value as NSString).draw(in: rect, withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black])
            }
            text("The environment", CGRect(x: 320, y: 76, width: 200, height: 18), bold: true)
            text("1 Look at the environmental problems listed below; think about the reasons why they happen and try to think of possible measures to deal with them. What do you personally do to contribute to solving them?", CGRect(x: 45, y: 105, width: 707, height: 30), size: 10)
            let xs: [CGFloat] = [45, 222, 420, 584, 752]
            cg.setStrokeColor(UIColor(white: thinRules ? 0.72 : 0.55, alpha: 1).cgColor)
            cg.setLineWidth(thinRules ? 0.2 : 0.6)
            for x in xs {
                cg.move(to: CGPoint(x: x, y: x == 45 ? 172 : 140))
                cg.addLine(to: CGPoint(x: x, y: tailRules && x != 45 ? 590 : 535)); cg.strokePath()
            }
            for y in [CGFloat(140)] + (0...6).map({ 172 + CGFloat($0) * 60.5 }) {
                cg.move(to: CGPoint(x: y == 140 ? 222 : 45, y: y))
                cg.addLine(to: CGPoint(x: 752, y: y)); cg.strokePath()
            }
            if tailRules { cg.move(to: CGPoint(x: 222, y: 590)); cg.addLine(to: CGPoint(x: 752, y: 590)); cg.strokePath() }
            for i in columns.indices { text(columns[i], CGRect(x: xs[i+1] + 6, y: 143, width: xs[i+2] - xs[i+1] - 12, height: 28), bold: true, size: 10) }
            for i in rows.indices {
                text("\(i+1).", CGRect(x: 61, y: 177 + CGFloat(i)*60.5, width: 20, height: 22), bold: true)
                text(rows[i], CGRect(x: 86, y: 177 + CGFloat(i)*60.5, width: 129, height: 52), bold: true)
            }
            if signature {
                text("Signature", CGRect(x: 222, y: 547, width: 160, height: 20))
                cg.move(to: CGPoint(x: 222, y: 594)); cg.addLine(to: CGPoint(x: 420, y: 594)); cg.strokePath()
            }
        }
        return PDFDocument(data: data)!
    }

    /// Upgrade fixture with the same 21-field failure reported in the screenshot.
    static func seedLegacyFields(in session: DocumentSession) {
        let xs: [CGFloat] = [222, 420, 584, 752]
        for row in 0..<7 { for column in 0..<3 {
            session.item.fields.append(FormEntry(page: 0,
                rect: CGRect(x: xs[column] + 2, y: 612 - (172 + CGFloat(row+1)*60.5) + 2,
                             width: xs[column+1]-xs[column]-4, height: 56.5),
                label: row < 6 ? rows[row] + " · " + columns[column] : "Firma",
                origin: row < 6 ? "table" : "model"))
        } }
        session.item.analyzed = true; session.item.analysisVersion = 2
        session.flush()
    }

}
#endif
