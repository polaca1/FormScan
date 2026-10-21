import Foundation
import UIKit
import PDFKit
import OnnxRuntimeBindings

enum AnalysisError: Error { case invalidOutput }

struct DetectedField {
    var rect: CGRect
    var category: Int
    var confidence: Float
}

enum LocalFieldAI {
    static func detect(_ image: UIImage, model: AIModel = .nano, modelURL: URL? = nil, threshold: Float = 0.32) throws -> [DetectedField] {
        guard let url = modelURL ?? Bundle.main.url(forResource: "model", withExtension: "onnx"),
              let cg = image.cgImage else { throw NSError(domain: "FormScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Modelo ONNX no incluido"]) }
        let width = cg.width, height = cg.height
        let side = model == .detailed ? 1024 : 640
        let scale = min(Double(side) / Double(width), Double(side) / Double(height))
        let rw = model == .detailed ? side : Int(Double(width) * scale)
        let rh = model == .detailed ? side : Int(Double(height) * scale)
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 114, count: side * side * 4)
        pixels.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(data: ptr.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            // Match the model's top-left letterbox (padding only at right/bottom).
            context.draw(cg, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        }
        let plane = side * side
        var input = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            input[i] = Float(pixels[i*4])
            input[plane+i] = Float(pixels[i*4+1])
            input[plane*2+i] = Float(pixels[i*4+2])
            if model == .detailed {
                input[i] = (input[i] / 255 - 0.485) / 0.229
                input[plane+i] = (input[plane+i] / 255 - 0.456) / 0.224
                input[plane*2+i] = (input[plane*2+i] / 255 - 0.406) / 0.225
            }
        }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        try options.setIntraOpNumThreads(Int32(constrained ? 2 : min(4, ProcessInfo.processInfo.activeProcessorCount)))
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        let tensor = try input.withUnsafeBufferPointer { buffer -> ORTValue in
            let data = Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
            return try ORTValue(tensorData: NSMutableData(data: data), elementType: .float,
                                shape: [1, 3, NSNumber(value: side), NSNumber(value: side)])
        }
        let inputName = try session.inputNames().first ?? "images"
        let outputNames = try session.outputNames()
        let outputName = outputNames.first ?? "output"
        let result = try session.run(withInputs: [inputName: tensor], outputNames: Set(outputNames), runOptions: nil)
        if model == .detailed {
            return try decodeDETR(result, width: width, height: height, threshold: threshold)
        }
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
            let rect = CGRect(x: (cx-w/2)/scale, y: (cy-h/2)/scale,
                              width: w/scale, height: h/scale)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isNull, !rect.isEmpty else { continue }
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

    private static func decodeDETR(_ outputs: [String: ORTValue], width: Int, height: Int, threshold: Float) throws -> [DetectedField] {
        guard let boxes = outputs["dets"], let labels = outputs["labels"] else { throw AnalysisError.invalidOutput }
        let boxData = try boxes.tensorData() as Data
        let labelData = try labels.tensorData() as Data
        let values = boxData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let scores = labelData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard values.count == 1200, scores.count == 1200 else { throw AnalysisError.invalidOutput }
        var candidates: [DetectedField] = []
        for index in 0..<300 {
            let offset = index * 4
            let probabilities = (0..<3).map { 1 / (1 + exp(-scores[offset + $0])) }
            guard let category = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }), probabilities[category] >= threshold else { continue }
            let cx = CGFloat(values[offset]), cy = CGFloat(values[offset+1])
            let w = CGFloat(values[offset+2]), h = CGFloat(values[offset+3])
            let rect = CGRect(x: (cx-w/2) * CGFloat(width), y: (cy-h/2) * CGFloat(height), width: w * CGFloat(width), height: h * CGFloat(height))
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !rect.isNull, !rect.isEmpty { candidates.append(DetectedField(rect: rect, category: category, confidence: probabilities[category])) }
        }
        candidates.sort { $0.confidence > $1.confidence }
        var selected: [DetectedField] = []
        for candidate in candidates {
            if !selected.contains(where: {
                let intersection = $0.rect.intersection(candidate.rect).area
                let union = $0.rect.area + candidate.rect.area - intersection
                return union > 0 && intersection / union > 0.45
            }) { selected.append(candidate) }
            if selected.count >= 150 { break }
        }
        return selected
    }
}
