import SwiftUI

/// Apply inside each navigation destination so the native tab bar's safe area
/// is included. An inset on TabView itself can cover its floating controls.
struct DocumentCloudInset: ViewModifier {
    @EnvironmentObject private var cloud: DocumentCloudController
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-cloud") {
                    Text(cloud.error != nil ? "Pendiente" : cloud.busy || cloud.hasPendingChanges ? "Guardando" : "Guardado")
                        .font(.caption2).accessibilityIdentifier("cloudFixtureState")
                }
                #endif
                DocumentCloudBanner()
            }
        }
    }
}

/// Normal successful saves are silent. Only failures and preserved conflicts
/// occupy space; no server, model or synchronization controls appear in settings.
struct DocumentCloudBanner: View {
    @EnvironmentObject private var cloud: DocumentCloudController
    var body: some View {
        if let message = cloud.error ?? cloud.notice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: cloud.error == nil ? "doc.on.doc" : "exclamationmark.icloud")
                    .foregroundStyle(cloud.error == nil ? Color.blue : Color.orange)
                Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if cloud.error != nil {
                    Button("Reintentar") { cloud.synchronize() }.font(.footnote.bold()).disabled(cloud.busy)
                }
                Button {
                    cloud.error = nil; cloud.notice = nil
                } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Cerrar aviso")
            }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.vertical, 6)
                .accessibilityIdentifier("documentCloudNotice")
        }
    }
}
