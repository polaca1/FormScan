import Foundation
import Vision
import UIKit

struct RecognizedLine {
    let text: String
    // Image coordinates: origin at the upper left, in pixels.
    let rect: CGRect
}

enum FieldLabels {
    static func recognize(_ image: UIImage) throws -> [RecognizedLine] {
        guard let cg = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(text: text, rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                          width: box.width * width, height: box.height * height))
        }
    }

    static func label(for rect: CGRect, checkbox: Bool, lines: [RecognizedLine]) -> String? {
        if checkbox {
            let candidates = lines.filter { line in
                let tolerance = max(rect.height, line.rect.height) * 0.8
                let includesBox = line.rect.minX >= rect.minX - rect.width * 0.5 && line.rect.maxX > rect.maxX + rect.width * 2
                return abs(line.rect.midY - rect.midY) < tolerance &&
                    (line.rect.minX >= rect.maxX - 3 || line.rect.maxX <= rect.minX + 3 || includesBox)
            }
            // The words directly to the right of a box are its label in most
            // Spanish forms. Also support labels printed to the left.
            let best = candidates.min { score($0.rect, box: rect) < score($1.rect, box: rect) }
            guard let best, score(best.rect, box: rect) < max(rect.width * 14, 180) else { return nil }
            var text = best.text.trimmingCharacters(in: CharacterSet(charactersIn: " □☐☑✓✔▢◻☒"))
            var bottom = best.rect.maxY
            for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
                guard line.rect.minY >= bottom, line.rect.minY - bottom < best.rect.height * 0.9,
                      abs(line.rect.minX - best.rect.minX) < best.rect.height,
                      line.rect.minY - best.rect.minY < best.rect.height * 3 else { continue }
                text += " " + line.text; bottom = line.rect.maxY
            }
            return text
        }
        return lines.filter {
            $0.rect.maxY <= rect.minY + 4 && rect.minY - $0.rect.maxY < max(rect.height * 2, 70) &&
                $0.rect.maxX > rect.minX && $0.rect.minX < rect.maxX
        }.min {
            abs($0.rect.maxY - rect.minY) + abs($0.rect.minX - rect.minX) * 0.25 <
                abs($1.rect.maxY - rect.minY) + abs($1.rect.minX - rect.minX) * 0.25
        }?.text
    }

    private static func score(_ line: CGRect, box: CGRect) -> CGFloat {
        let right = line.minX >= box.maxX - 3
        let horizontal = right ? max(0, line.minX - box.maxX) : max(0, box.minX - line.maxX)
        return horizontal + abs(line.midY - box.midY) * 2 + (right ? 0 : box.width)
    }
}
