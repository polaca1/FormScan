import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var store: ModelStore
    @State private var operation: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "iphone.gen3").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.device.name).font(.headline)
                        Text([store.device.chip, "\(store.device.memoryDescription) de memoria física"].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                LabeledContent("Recomendado", value: AIModel.nano.name)
            } footer: {
                Text("Nano equilibrado es la recomendación para uso diario, incluido el iPhone 14 Pro con A16. Puedes comparar los tiempos reales de este dispositivo más abajo.")
            }
            Section("Modelo activo") {
                Picker("Selección", selection: Binding(get: { store.automatic ? "automatic" : store.selected.rawValue }, set: {
                    if $0 == "automatic" { store.useRecommended() }
                    else if let model = AIModel(rawValue: $0) { store.select(model) }
                })) {
                    Text("Automática (recomendada)").tag("automatic")
                    ForEach(AIModel.allCases) { model in
                        Text(model.name).tag(model.rawValue).disabled(!store.installed.contains(model))
                    }
                }
                .accessibilityIdentifier("modelSelector")
                Label(store.active.name, systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
            }
            Section("Modelos disponibles") {
                ForEach(AIModel.allCases) { model in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name).font(.headline)
                                Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(model.size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                        if store.downloading == model {
                            HStack {
                                ProgressView(); Text("Descargando y comprobando…").font(.subheadline)
                                Spacer()
                                Button("Cancelar") { operation?.cancel() }.font(.subheadline)
                            }
                        } else if store.installed.contains(model) {
                            HStack {
                                Button(store.active == model ? "En uso" : "Usar modelo") { store.select(model) }
                                    .disabled(store.active == model || store.benchmarking)
                                    .accessibilityIdentifier("use-\(model.rawValue)")
                                Spacer()
                                if model == .nano {
                                    Text("Incluido").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("Eliminar", role: .destructive) { store.remove(model) }
                                        .disabled(store.downloading != nil || store.benchmarking)
                                }
                            }.buttonStyle(.borderless)
                        } else {
                            Button("Instalar y usar", systemImage: "arrow.down.circle") {
                                operation = Task { await store.install(model) }
                            }
                            .disabled(store.downloading != nil || store.benchmarking)
                            .accessibilityIdentifier("install-\(model.rawValue)")
                        }
                        if let time = store.timings[model] {
                            Label(String(format: "%.0f ms en el ejemplo", time), systemImage: "stopwatch")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Link("Ficha del modelo · Apache 2.0", destination: model.sourceURL).font(.caption)
                    }.padding(.vertical, 8)
                }
            } footer: {
                Text("Solo necesitas internet para instalar modelos. Tus documentos se analizan siempre en el dispositivo. Nano compacto ahorra espacio; un modelo más grande no es siempre mejor para todas las páginas.")
            }
            Section("Comprueba tu dispositivo") {
                Button {
                    operation = Task { await store.benchmark() }
                } label: {
                    HStack {
                        if store.benchmarking { ProgressView() }
                        Label(store.benchmarking ? "Midiendo…" : "Medir modelos instalados", systemImage: "speedometer")
                    }
                }
                .disabled(store.benchmarking || store.downloading != nil)
                .accessibilityIdentifier("benchmarkModels")
            } footer: {
                Text("Se analiza el mismo formulario de ejemplo con cada modelo. El tiempo incluye la carga y cambia con la batería, la temperatura y el documento. Es una comparación de velocidad, no una medición de precisión.")
            }
        }
        .navigationTitle("Modelos de IA").navigationBarTitleDisplayMode(.inline)
        .alert("No se pudo completar", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Aceptar", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onDisappear { if store.benchmarking { operation?.cancel() } }
    }
}
