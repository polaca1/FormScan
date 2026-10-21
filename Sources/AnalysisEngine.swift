import Foundation
import UIKit
import Combine

/// Private inference configuration. Resource choice never appears in the UI.
enum AIModel: String, CaseIterable, Identifiable, Codable {
    case nano, compact, detailed
    var id: String { rawValue }
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
    var resourceName: String {
        switch self { case .nano: "model"; case .compact: "nano-compact"; case .detailed: "ffdetr-mobile-int8" }
    }
}

struct DeviceProfile {
    let identifier: String
    let memory: UInt64
    init(identifier: String = "", memory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.identifier = identifier; self.memory = memory
    }
    /// Resource policy, not a claim of measured model accuracy on this device.
    func recommended(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> AIModel {
        memory < 5 * 1_073_741_824 || lowPower || thermal == .serious || thermal == .critical ? .compact : .nano
    }
    func parallelism(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        if lowPower || thermal == .serious || thermal == .critical || memory < 5 * 1_073_741_824 { return 1 }
        return memory >= 8 * 1_073_741_824 ? 3 : 2
    }
}

/// All inference resources ship with the app: first use and later analysis work
/// offline. Device memory, power and temperature choose execution order/parallelism.
@MainActor
final class AnalysisEngine: ObservableObject {
    let device: DeviceProfile
    private let bundle: Bundle
    init(device: DeviceProfile = DeviceProfile(), bundle: Bundle = .main) {
        self.device = device; self.bundle = bundle
    }
    var active: AIModel {
        device.recommended(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: ProcessInfo.processInfo.thermalState)
    }
    var analysisJobs: [InferenceJob] {
        ([active] + AIModel.allCases.filter { $0 != active }).compactMap { model in
            url(for: model).map { InferenceJob(model: model, url: $0) }
        }
    }
    var parallelism: Int {
        device.parallelism(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: ProcessInfo.processInfo.thermalState)
    }
    func url(for model: AIModel) -> URL? {
        bundle.url(forResource: model.resourceName, withExtension: "onnx")
    }
}
