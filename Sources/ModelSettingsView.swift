import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var store: ModelStore
    @State private var operation: Task<Void, Never>?

    private var selection: Binding<String> {
        Binding<String>(get: { store.automatic ? "automatic" : store.selected.rawValue }, set: { value in
            if value == "automatic" { store.useRecommended() }
            else if let model = AIModel(rawValue: value) { store.select(model) }
        })
    }
    private var deviceDescription: String {
        var parts: [String] = []
        if let chip = store.device.chip { parts.append(chip) }
        parts.append("\(store.device.memoryDescription) de memoria física")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            deviceSection
            selectionSection
            Section {
                ForEach(AIModel.allCases) { model in ModelOptionRow(store: store, model: model) }
            } header: { Text("Modelos disponibles") } footer: {
                Text("Solo necesitas internet para instalar modelos. Tus documentos se analizan siempre en el dispositivo. Nano compacto ahorra espacio; un modelo más grande no es siempre mejor para todas las páginas.")
            }
            benchmarkSection
        }
        .navigationTitle("Modelos de IA").navigationBarTitleDisplayMode(.inline)
        .alert("No se pudo completar", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Aceptar", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onDisappear { if store.benchmarking { operation?.cancel() } }
    }

    private var deviceSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "iphone.gen3").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.device.name).font(.headline)
                    Text(deviceDescription).font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
            LabeledContent("Recomendado", value: AIModel.nano.name)
        } footer: {
            Text("Nano equilibrado es la recomendación para uso diario, incluido el iPhone 14 Pro con A16. Puedes comparar los tiempos reales de este dispositivo más abajo.")
        }
    }

    private var selectionSection: some View {
        Section("Modelo activo") {
            Picker("Selección", selection: selection) {
                Text("Automática (recomendada)").tag("automatic")
                ForEach(AIModel.allCases) { model in
                    Text(model.name).tag(model.rawValue).disabled(!store.installed.contains(model))
                }
            }.accessibilityIdentifier("modelSelector")
            Label(store.active.name, systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
        }
    }

    private var benchmarkSection: some View {
        Section {
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
        } header: { Text("Comprueba tu dispositivo") } footer: {
            Text("Se analiza el mismo formulario de ejemplo con cada modelo. El tiempo incluye la carga y cambia con la batería, la temperatura y el documento. Es una comparación de velocidad, no una medición de precisión.")
        }
    }
}

private struct ModelOptionRow: View {
    @ObservedObject var store: ModelStore
    let model: AIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
            controls
            if let time = store.timings[model] {
                Label(String(format: "%.0f ms en el ejemplo", time), systemImage: "stopwatch")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Link("Ficha del modelo · Apache 2.0", destination: model.sourceURL).font(.caption)
        }
        // Each control must act independently inside a List row. Automatic style
        // otherwise also opens the model's external link when installing it.
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.headline)
                Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(model.size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var controls: some View {
        if store.downloading == model {
            HStack {
                ProgressView()
                Text("Descargando y comprobando…").font(.subheadline)
                Spacer()
                Button("Cancelar") { store.cancelInstall() }.font(.subheadline)
            }
        } else if store.installed.contains(model) {
            installedControls
        } else {
            Button("Instalar y usar", systemImage: "arrow.down.circle") { store.beginInstall(model) }
                .disabled(store.downloading != nil || store.benchmarking)
                .accessibilityIdentifier("install-\(model.rawValue)")
        }
    }
    private var installedControls: some View {
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
    }
}
