import Foundation
import UIKit
import CryptoKit
import PDFKit
import Darwin

enum AIModel: String, CaseIterable, Identifiable, Codable {
    case nano, compact, detailed
    var id: String { rawValue }
    var name: String {
        switch self { case .nano: "Nano equilibrado"; case .compact: "Nano compacto"; case .detailed: "FFDetr detallado" }
    }
    var subtitle: String {
        switch self {
        case .nano: "La opción para el día a día"
        case .compact: "Menos espacio, precisión muy similar"
        case .detailed: "Otra opción para formularios vacíos"
        }
    }
    var detail: String {
        switch self {
        case .nano: "FP32. Buen equilibrio entre precisión, memoria y tiempo de análisis. Recomendado para el iPhone 14 Pro y documentos ya rellenados."
        case .compact: "FP16. Ocupa aproximadamente la mitad. La precisión publicada es muy cercana a FP32; no implica mayor velocidad en CPU."
        case .detailed: "INT8, resolución de 1024 px. Puede detectar mejor campos en formularios vacíos; consume más memoria y tarda más. En formularios ya escritos puede rendir peor que Nano."
        }
    }
    var bytes: Int64 {
        switch self { case .nano: 3_728_816; case .compact: 1_918_066; case .detailed: 37_116_889 }
    }
    var checksum: String {
        switch self {
        case .nano: "d7ab44396154af79409c9f8a4fded6c9aa907ae6d283fbe5d2b533d3b7314ec1"
        case .compact: "88e2a21b65a7d481e0c65541be874b07f3fa5fcb50c2bd2d78a615fd82c0a523"
        case .detailed: "83adb3b1b6ed8ebe584c9046725913b541daccd9aee6d7bd18a00bbdebe6e33e"
        }
    }
    var downloadURL: URL {
        if self == .detailed { return URL(string: "https://github.com/polaca1/FormScan/releases/download/v2.0.0/ffdetr-mobile-int8.onnx")! }
        let file = self == .compact ? "model_fp16.onnx" : "model.onnx"
        return URL(string: "https://huggingface.co/nutrientdocs/form-field-v1-nano/resolve/7cbc1ecd55d59f6315a1415dddc59c3c8b115f05/\(file)")!
    }
    var sourceURL: URL {
        URL(string: self == .detailed ? "https://huggingface.co/jbarrow/FFDetr" : "https://huggingface.co/nutrientdocs/form-field-v1-nano")!
    }
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct DeviceProfile {
    let identifier: String
    let memory: UInt64
    init() {
        var system = utsname(); uname(&system)
        identifier = Mirror(reflecting: system.machine).children.compactMap { value in
            guard let byte = value.value as? Int8, byte != 0 else { return nil as String? }
            return String(UnicodeScalar(UInt8(bitPattern: byte)))
        }.joined()
        memory = ProcessInfo.processInfo.physicalMemory
    }
    var name: String {
        switch identifier {
        case "iPhone15,2": "iPhone 14 Pro"
        case "iPhone15,3": "iPhone 14 Pro Max"
        case "iPhone15,4": "iPhone 15"
        case "iPhone15,5": "iPhone 15 Plus"
        case "iPhone16,1": "iPhone 15 Pro"
        case "iPhone16,2": "iPhone 15 Pro Max"
        case "iPhone17,1": "iPhone 16 Pro"
        case "iPhone17,2": "iPhone 16 Pro Max"
        case "iPhone17,3": "iPhone 16"
        case "iPhone17,4": "iPhone 16 Plus"
        case "arm64", "x86_64": "Simulador"
        default: UIDevice.current.model
        }
    }
    var chip: String? { identifier.hasPrefix("iPhone15,") ? "A16 Bionic" : nil }
    var memoryDescription: String { ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) }
}

enum ModelError: LocalizedError {
    case invalidDownload, invalidChecksum
    var errorDescription: String? {
        switch self {
        case .invalidDownload: "La descarga del modelo no se ha completado. Vuelve a intentarlo con conexión a internet."
        case .invalidChecksum: "El archivo descargado no coincide con el modelo verificado. Vuelve a descargarlo."
        }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var selected: AIModel
    @Published private(set) var automatic: Bool
    @Published private(set) var installed: Set<AIModel> = [.nano]
    @Published private(set) var downloading: AIModel?
    @Published private(set) var benchmarking = false
    @Published private(set) var timings: [AIModel: Double] = [:]
    @Published var error: String?
    let device = DeviceProfile()
    private let directory: URL
    private let defaults: UserDefaults

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var location = self.directory; try? location.setResourceValues(values)
        selected = AIModel(rawValue: defaults.string(forKey: "ai.model") ?? "") ?? .nano
        automatic = defaults.object(forKey: "ai.automatic") as? Bool ?? true
        for model in AIModel.allCases where model != .nano {
            let path = self.directory.appendingPathComponent("\(model.rawValue).onnx")
            if (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(model.bytes) { installed.insert(model) }
        }
        if !installed.contains(selected) { selected = .nano }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") { selected = .nano; automatic = true }
    }
    var active: AIModel { automatic || !installed.contains(selected) ? .nano : selected }
    func url(for model: AIModel) -> URL? {
        if model == .nano { return Bundle.main.url(forResource: "model", withExtension: "onnx") }
        guard installed.contains(model) else { return nil }
        return directory.appendingPathComponent("\(model.rawValue).onnx")
    }
    func select(_ model: AIModel) {
        guard installed.contains(model), !benchmarking else { return }
        selected = model; automatic = false; persist()
    }
    func useRecommended() { selected = .nano; automatic = true; persist() }
    private func persist() {
        defaults.set(selected.rawValue, forKey: "ai.model"); defaults.set(automatic, forKey: "ai.automatic")
    }
    func install(_ model: AIModel, from overrideURL: URL? = nil) async {
        guard model != .nano, downloading == nil, !benchmarking else { return }
        downloading = model
        defer { downloading = nil }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            if let overrideURL, overrideURL.isFileURL { try FileManager.default.copyItem(at: overrideURL, to: staging) }
            else {
                let (temporary, response) = try await URLSession.shared.download(from: overrideURL ?? model.downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelError.invalidDownload }
                try FileManager.default.moveItem(at: temporary, to: staging)
            }
            try Task.checkCancellation()
            let sample = ExampleDocument.make(widgets: false)
            let image = sample.page(at: 0)!.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
            try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: staging, options: .mappedIfSafe)
                guard data.count == model.bytes else { throw ModelError.invalidDownload }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == model.checksum else { throw ModelError.invalidChecksum }
                // A downloaded model is selectable only after a real inference succeeds.
                _ = try LocalFieldAI.detect(image, model: model, modelURL: staging)
            }.value
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent("\(model.rawValue).onnx")
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: destination) }
            installed.insert(model); select(model)
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ model: AIModel) {
        guard model != .nano, downloading == nil, !benchmarking else { return }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("\(model.rawValue).onnx"))
            installed.remove(model); timings[model] = nil
            if selected == model { useRecommended() }
        } catch { self.error = error.localizedDescription }
    }
    func benchmark() async {
        guard !benchmarking, downloading == nil else { return }
        benchmarking = true
        defer { benchmarking = false }
        let sample = ExampleDocument.make(widgets: false)
        let image = sample.page(at: 0)!.thumbnail(of: CGSize(width: 1190, height: 1684), for: .cropBox)
        for model in AIModel.allCases where installed.contains(model) {
            guard let url = url(for: model) else { continue }
            do {
                try Task.checkCancellation()
                let elapsed = try await Task.detached(priority: .userInitiated) {
                    let start = Date()
                    _ = try LocalFieldAI.detect(image, model: model, modelURL: url)
                    return Date().timeIntervalSince(start) * 1000
                }.value
                timings[model] = elapsed
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription; return }
        }
    }
}
