import SwiftUI
import PDFKit

struct OnboardingView: View {
    let finish: (Bool) -> Void
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let example = ExampleDocument.make()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index <= step ? Color.blue : Color.secondary.opacity(0.2)).frame(height: 4)
                        }
                    }.accessibilityLabel("Paso \(step + 1) de 3")
                    if step == 0 {
                        Image(systemName: "text.viewfinder").font(.system(size: 72, weight: .light))
                            .foregroundStyle(.blue).padding(.vertical, 20).accessibilityHidden(true)
                        Text("Del papel a\nlo que importa.").font(.largeTitle.bold()).tracking(-1)
                        Text("Escanea o importa un documento. FormScan encuentra sus campos para que puedas completarlo con calma.")
                            .font(.title3).foregroundStyle(.secondary)
                        tip("camera.viewfinder", "Escanea varias páginas", "Recorte automático con el escáner de tu iPhone.")
                        tip("folder", "Abre tus PDF", "También puedes importar imágenes desde Archivos.")
                    } else if step == 1 {
                        Text("Escribe aquí.\nAparece en el PDF.").font(.largeTitle.bold()).tracking(-1)
                        Text("Cambia entre Documento y Formulario. Cada dato que escribas queda colocado en su campo y se guarda automáticamente.")
                            .font(.body).foregroundStyle(.secondary)
                        ExamplePreview(document: example)
                            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                        tip("slider.horizontal.3", "Tú tienes el control", "Revisa los campos, ajusta su tamaño o colócalos tocando el documento.")
                    } else {
                        Image(systemName: "checkmark.shield").font(.system(size: 64, weight: .light)).foregroundStyle(.blue)
                            .padding(.vertical, 20).accessibilityHidden(true)
                        Text("Tu documento.\nTu dispositivo.").font(.largeTitle.bold()).tracking(-1)
                        tip("checkmark.shield", "Análisis privado", "Los campos se detectan automáticamente en tu dispositivo. El análisis no envía tus documentos a servicios de IA.")
                        tip("doc.on.doc", "Vuelve cuando quieras", "Con una cuenta, tus documentos y sus campos se guardan para recuperarlos cuando vuelvas. Sin cuenta, permanecen solo en este dispositivo.")
                        tip("square.and.arrow.up", "Comparte el resultado", "Exporta un PDF con todos los datos incorporados.")
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity)
            }
            .id(step)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Bienvenido a FormScan").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Ahora no") { finish(false) }.accessibilityIdentifier("skipTutorial") }
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) { Button("Atrás", systemImage: "chevron.left") { withAnimation(reduceMotion ? nil : .default) { step -= 1 } } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        if step < 2 { withAnimation(reduceMotion ? nil : .default) { step += 1 } }
                        else { finish(true) }
                    } label: {
                        Text(step < 2 ? "Continuar" : "Probar con un documento de ejemplo")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent).accessibilityIdentifier("continueTutorial")
                    if step == 2 { Button("Ir a inicio") { finish(false) }.padding(.bottom, 4) }
                }
                .frame(maxWidth: 580).padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity)
            }
            .interactiveDismissDisabled()
        }
    }
    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExamplePreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.autoScales = true
        view.isUserInteractionEnabled = false; view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
