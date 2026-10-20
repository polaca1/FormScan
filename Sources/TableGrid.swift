import UIKit

/// Printed table structure is evidence, not a prediction. Coordinates use the
/// same top-left image space as OCR and the local models.
struct TableGrid {
    struct Cell {
        let rect: CGRect
        let content: String
    }
    struct Table {
        let cells: [Cell]
        var bounds: CGRect { cells.reduce(CGRect.null) { $0.union($1.rect) } }
    }
    struct Field {
        let rect: CGRect
        let label: String
        let checkbox: Bool
    }
    let tables: [Table]
    private var printedBoxes: [CGRect] = []
    private var horizontalRules: [Rule] = []
    private var recognizedLines: [RecognizedLine] = []

    var fields: [Field] {
        tables.flatMap { table in
            table.cells.compactMap { cell -> Field? in
                guard cell.content.isEmpty else { return nil }
                let row = table.cells.filter {
                    !$0.content.isEmpty && $0.rect.maxX <= cell.rect.minX + 3 &&
                    abs($0.rect.midY - cell.rect.midY) < min($0.rect.height, cell.rect.height) * 0.4
                }.min { $0.rect.minX < $1.rect.minX }?.content
                let column = table.cells.filter {
                    !$0.content.isEmpty && $0.rect.maxY <= cell.rect.minY + 3 &&
                    abs($0.rect.midX - cell.rect.midX) < min($0.rect.width, cell.rect.width) * 0.4
                }.min { $0.rect.minY < $1.rect.minY }?.content
                // Do not turn an empty header/corner into a response field.
                guard let row, let column else { return nil }
                let checkbox = printedBoxes.first {
                    cell.rect.insetBy(dx: 2, dy: 2).contains($0) && $0.area < cell.rect.area * 0.3 &&
                        $0.width / $0.height > 0.7 && $0.width / $0.height < 1.4
                }
                return Field(rect: checkbox ?? cell.rect.insetBy(dx: 3, dy: 3),
                             label: row + " · " + column, checkbox: checkbox != nil)
            }
        }.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) < 3 ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
        }
    }

    /// Printed structure owns overlapping model boxes, independent of their
    /// predicted class. A "signature" is not permission to invent another row.
    func owns(_ rect: CGRect) -> Bool {
        guard !rect.isEmpty, !rect.isNull else { return false }
        return tables.contains { table in
            if table.bounds.intersection(rect).area > rect.area * 0.25 { return true }
            let rowHeight = table.cells.map { $0.rect.height }.sorted()[table.cells.count / 2]
            let overlap = max(0, min(rect.maxX, table.bounds.maxX) - max(rect.minX, table.bounds.minX))
            // Model boxes are approximate: do not require both X edges to lie
            // within three pixels of the table. Slightly oversized boxes leaked.
            let continuation = rect.midY > table.bounds.maxY - rowHeight * 0.15 &&
                rect.minY < table.bounds.maxY + rowHeight * 2.5 &&
                overlap > min(rect.width, table.bounds.width) * 0.65
            guard continuation else { return false }
            return !hasPrintedControl(rect, below: table.bounds.maxY)
        }
    }

    func replaces(_ detection: DetectedField) -> Bool { owns(detection.rect) }

    func matchesCell(_ rect: CGRect, checkbox: Bool) -> Bool {
        fields.contains {
            $0.checkbox == checkbox && $0.rect.intersection(rect).area > max($0.rect.area, rect.area) * 0.65
        }
    }

    func replacesLegacy(label: String) -> Bool {
        ["Campo de texto", "Firma", "Opción sin etiqueta", "Casilla"].contains(label) ||
        tables.contains { $0.cells.contains { !$0.content.isEmpty && normalized($0.content) == normalized(label) } } ||
        fields.contains { normalized($0.label) == normalized(label) }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private func hasPrintedControl(_ rect: CGRect, below bottom: CGFloat) -> Bool {
        if printedBoxes.contains(where: {
            $0.minY > bottom + 3 && $0.intersection(rect).area > rect.area * 0.75 && $0.area < rect.area * 1.6
        }) { return true }
        // A separate labelled underline/signature field is valid too. The
        // table's bottom border must never stand in for a missing lower edge.
        return rect.minY > bottom + 3 &&
            FieldLabels.label(for: rect, checkbox: false, lines: recognizedLines) != nil &&
            horizontalRules.contains {
                abs($0.axis - rect.maxY) < max(4, rect.height * 0.25) &&
                    $0.start >= rect.minX - rect.width * 0.15 && $0.end <= rect.maxX + rect.width * 0.15 &&
                    $0.end - $0.start >= rect.width * 0.65
            }
    }

    private struct Rule {
        var axis: CGFloat
        var start: CGFloat
        var end: CGFloat
    }

    static func detect(_ image: UIImage, lines: [RecognizedLine]) -> TableGrid {
        guard let source = image.cgImage else { return TableGrid(tables: []) }
        // Bound CPU/memory for imported large scans. Work in an explicit RGBA
        // raster so transparent PDFs and image orientation have no byte-order ambiguity.
        let scale = min(1, 1600 / CGFloat(max(source.width, source.height)))
        let width = Int(CGFloat(source.width) * scale), height = Int(CGFloat(source.height) * scale)
        guard width > 0, height > 0 else { return TableGrid(tables: []) }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return TableGrid(tables: []) }
        // Anti-aliased thin gray rules can be brighter than 210 on a white
        // PDF. Estimate paper luminance instead of treating them as blank.
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            histogram[(Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3] += 1
        }
        var cumulative = 0, paper = 255
        for value in histogram.indices {
            cumulative += histogram[value]
            if cumulative >= width * height * 9 / 10 { paper = value; break }
        }
        let inkLimit = min(245, paper - 8) * 3
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < inkLimit
        }
        func rules(horizontal: Bool) -> [Rule] {
            let length = horizontal ? width : height, count = horizontal ? height : width
            let minimum = horizontal ? max(18, width / 90) : max(18, height / 90)
            var result: [Rule] = []
            for axis in 0..<count {
                var start: Int?, last = 0
                func finish() {
                    guard let from = start, last - from >= minimum else { return }
                    let rule = Rule(axis: CGFloat(axis), start: CGFloat(from), end: CGFloat(last))
                    if let index = result.lastIndex(where: {
                        abs($0.axis - rule.axis) <= 3 && abs($0.start - rule.start) <= 5 && abs($0.end - rule.end) <= 5
                    }) {
                        result[index].axis = (result[index].axis + rule.axis) / 2
                        result[index].start = min(result[index].start, rule.start)
                        result[index].end = max(result[index].end, rule.end)
                    } else { result.append(rule) }
                }
                for offset in 0..<length {
                    let ink = horizontal ? dark(offset, axis) : dark(axis, offset)
                    if ink { if start == nil { start = offset }; last = offset }
                    else if start != nil && offset - last > 2 { finish(); start = nil }
                }
                finish()
            }
            return result
        }
        let horizontal = rules(horizontal: true), vertical = rules(horizontal: false)
        func coordinates(_ rules: [Rule]) -> [CGFloat] {
            var result: [CGFloat] = []
            for value in rules.map(\.axis).sorted() {
                if let last = result.last, value - last < 4 { continue }
                result.append(value)
            }
            return result
        }
        let xs = coordinates(vertical)
        // Dense graphics/photographs are not tables. Avoid combinatorial work.
        guard xs.count >= 3, xs.count <= 128, horizontal.count <= 2048 else { return TableGrid(tables: []) }
        func covered(_ rules: [Rule], axis: CGFloat, from: CGFloat, to: CGFloat) -> Bool {
            rules.contains { abs($0.axis - axis) < 4 && $0.start <= from + 4 && $0.end >= to - 4 }
        }
        var rectangles: [CGRect] = []
        for (i, left) in xs.enumerated() {
            for right in xs.dropFirst(i + 1) where right - left >= 24 {
                let ys = coordinates(horizontal.filter { $0.start <= left + 4 && $0.end >= right - 4 })
                for (top, bottom) in zip(ys, ys.dropFirst()) where bottom - top >= 16 {
                    guard covered(vertical, axis: left, from: top, to: bottom),
                          covered(vertical, axis: right, from: top, to: bottom),
                          !xs.contains(where: { $0 > left + 4 && $0 < right - 4 && covered(vertical, axis: $0, from: top, to: bottom) }) else { continue }
                    rectangles.append(CGRect(x: left / scale, y: top / scale, width: (right - left) / scale, height: (bottom - top) / scale))
                }
            }
        }
        var components: [[CGRect]] = []
        for rect in rectangles {
            let neighbors = components.indices.filter { index in
                components[index].contains { other in
                    let nearX = abs(rect.maxX - other.minX) < 6 || abs(other.maxX - rect.minX) < 6
                    let nearY = abs(rect.maxY - other.minY) < 6 || abs(other.maxY - rect.minY) < 6
                    return (nearX && min(rect.maxY, other.maxY) - max(rect.minY, other.minY) > 8) ||
                        (nearY && min(rect.maxX, other.maxX) - max(rect.minX, other.minX) > 8)
                }
            }
            var group = [rect]
            for index in neighbors.reversed() { group += components.remove(at: index) }
            components.append(group)
        }
        let tables = components.compactMap { group -> Table? in
            guard group.count >= 6 else { return nil }
            let cells = group.map { rect -> Cell in
                let content = lines.filter { rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                    .sorted { abs($0.rect.midY - $1.rect.midY) < 4 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
                    .map(\.text).joined(separator: " ")
                return Cell(rect: rect, content: content)
            }
            // Require printed row AND column context; lined paper is not a form table.
            let table = Table(cells: cells)
            let candidate = TableGrid(tables: [table])
            return candidate.fields.count >= 2 ? table : nil
        }
        return TableGrid(tables: tables, printedBoxes: rectangles,
                         horizontalRules: horizontal.map { Rule(axis: $0.axis / scale, start: $0.start / scale, end: $0.end / scale) },
                         recognizedLines: lines)
    }
}
