import Foundation
import UIKit
import PDFKit
import onnxruntime_objc

struct DetectedField {
    var rect: CGRect
    var category: Int
    var confidence: Float
}

enum LocalFieldAI {
    static func detect(_ image: UIImage, threshold: Float = 0.32) throws -> [DetectedField] {
        guard let url = Bundle.main.url(forResource: "model", withExtension: "onnx"),
              let cg = image.cgImage else { throw NSError(domain: "FormScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Modelo ONNX no incluido"]) }
        let width = cg.width, height = cg.height
        let scale = min(640.0 / Double(width), 640.0 / Double(height))
        let rw = Int(Double(width) * scale), rh = Int(Double(height) * scale)
        let bytesPerRow = 640 * 4
        var pixels = [UInt8](repeating: 114, count: 640 * 640 * 4)
        pixels.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(data: ptr.baseAddress, width: 640, height: 640,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 640 - rh, width: rw, height: rh))
        }
        let plane = 640 * 640
        var input = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            input[i] = Float(pixels[i*4])
            input[plane+i] = Float(pixels[i*4+1])
            input[plane*2+i] = Float(pixels[i*4+2])
        }
        let env = try ORTEnv(loggingLevel: .warning)
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: nil)
        let tensor = try input.withUnsafeBufferPointer { buffer -> ORTValue in
            let data = buffer.withMemoryRebound(to: UInt8.self) { Data(buffer: $0) }
            return try ORTValue(tensorData: NSMutableData(data: data), elementType: .float,
                                shape: [1, 3, 640, 640])
        }
        let inputName = try session.inputNames().first ?? "images"
        let outputName = try session.outputNames().first ?? "output"
        let result = try session.run(withInputs: [inputName: tensor], outputNames: [outputName], runOptions: nil)
        guard let output = result[outputName],
              let outputData = try output.tensorData() as Data? else { return [] }
        let floats = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count % 8 == 0 else { return [] }
        var candidates: [DetectedField] = []
        for i in stride(from: 0, to: floats.count, by: 8) {
            let obj = floats[i+4]
            let scores = (0..<3).map { obj * floats[i+5+$0] }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }),
                  scores[best] >= threshold else { continue }
            let cx = Double(floats[i]), cy = Double(floats[i+1])
            let w = Double(floats[i+2]), h = Double(floats[i+3])
            let rect = CGRect(x: max(0, (cx-w/2)/scale),
                              y: max(0, (cy-h/2)/scale),
                              width: w/scale, height: h/scale)
            candidates.append(DetectedField(rect: rect, category: best, confidence: scores[best]))
        }
        candidates.sort { $0.confidence > $1.confidence }
        var selected: [DetectedField] = []
        for candidate in candidates {
            let overlap = selected.contains { prior in
                guard prior.category == candidate.category else { return false }
                let intersection = prior.rect.intersection(candidate.rect)
                if intersection.isNull { return false }
                let union = prior.rect.width*prior.rect.height + candidate.rect.width*candidate.rect.height - intersection.width*intersection.height
                return union > 0 && intersection.width*intersection.height/union > 0.6
            }
            if !overlap { selected.append(candidate) }
            if selected.count >= 150 { break }
        }
        return selected
    }
}
