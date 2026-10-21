import SwiftUI

private enum AccessMode: String, CaseIterable {
    case signIn = "Iniciar sesión", signUp = "Crear cuenta", reset = "Recuperar acceso"
}

struct AccountAccessView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    var allowsDeviceAccess = true
    @State private var mode = AccessMode.signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focused: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "text.viewfinder").font(.system(size: 64, weight: .light))
                            .foregroundStyle(.blue).accessibilityHidden(true)
                        Text("Menos papel.\nMás posibilidades.").font(.largeTitle.bold()).tracking(-1)
                        Text("Escanea, completa y comparte. Empieza con tu cuenta o prueba un documento de ejemplo.")
                            .font(.title3).foregroundStyle(.secondary)
                    }.padding(.top, 24)
                    if mode != .reset {
                        Button {
                            focused = nil
                            Task { await account.signInWithGoogle() }
                        } label: {
                            HStack(spacing: 12) {
                                Image("GoogleLogo").resizable().scaledToFit().frame(width: 20, height: 20)
                                    .accessibilityHidden(true)
                                Text("Continuar con Google").foregroundStyle(.primary)
                            }.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.glass).accessibilityIdentifier("googleSignIn")
                        HStack { Rectangle().frame(height: 0.5); Text("o con tu correo").font(.footnote).fixedSize(); Rectangle().frame(height: 0.5) }
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text(mode.rawValue).font(.title2.bold())
                        VStack(spacing: 0) {
                            TextField("Correo electrónico", text: $email)
                                .textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focused, equals: 0).submitLabel(mode == .reset ? .go : .next)
                                .onSubmit { if mode == .reset { submit() } else { focused = 1 } }
                                .padding(16).accessibilityIdentifier("accountEmail")
                            if mode != .reset {
                                Divider().padding(.leading, 16)
                                SecureField("Contraseña", text: $password)
                                    .textContentType(mode == .signUp ? .newPassword : .password)
                                    .focused($focused, equals: 1).submitLabel(mode == .signUp ? .next : .go)
                                    .onSubmit { if mode == .signUp { focused = 2 } else { submit() } }
                                    .padding(16).accessibilityIdentifier("accountPassword")
                            }
                            if mode == .signUp {
                                Divider().padding(.leading, 16)
                                SecureField("Repite la contraseña", text: $confirmation).textContentType(.newPassword)
                                    .focused($focused, equals: 2).submitLabel(.go).onSubmit(submit)
                                    .padding(16).accessibilityIdentifier("accountConfirmation")
                            }
                        }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        if mode == .signUp { Text("Usa al menos 8 caracteres. Te enviaremos un correo para confirmar la cuenta.").font(.footnote).foregroundStyle(.secondary) }
                        AccountMessages()
                        Button(action: submit) {
                            HStack {
                                if account.busy { ProgressView().tint(.white) }
                                Text(mode == .reset ? "Enviar enlace" : mode.rawValue)
                            }.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.glassProminent).accessibilityIdentifier("submitAccount")
                        if mode == .signIn {
                            Button("¿Olvidaste tu contraseña?") { changeMode(.reset) }.font(.subheadline)
                        }
                    }
                    VStack(spacing: 18) {
                        Button(mode == .signIn ? "Crear una cuenta" : "Ya tengo una cuenta") {
                            changeMode(mode == .signIn ? .signUp : .signIn)
                        }.accessibilityIdentifier("changeAccessMode")
                        if allowsDeviceAccess {
                            Button("Continuar sin cuenta") { account.continueOnDevice() }
                                .foregroundStyle(.secondary).accessibilityIdentifier("continueOnDevice")
                        }
                        Text("Tus documentos se analizan y guardan en este dispositivo. Iniciar sesión no crea una copia de tus PDF en la nube.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: 500).padding(28).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("FormScan").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !allowsDeviceAccess {
                        ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                    }
                }
                .disabled(account.busy)
        }.onChange(of: account.user) { _, user in if user != nil { dismiss() } }
    }
    private func changeMode(_ mode: AccessMode) {
        self.mode = mode; password = ""; confirmation = ""; focused = nil; account.clearMessages()
    }
    private func submit() {
        guard !account.busy else { return }
        do {
            _ = try AccountStore.email(email)
            if mode == .signUp { try AccountStore.password(password, confirmation: confirmation) }
            if mode == .signIn && password.isEmpty { throw AccountIssue.weakPassword }
        } catch { account.error = error.localizedDescription; return }
        focused = nil
        Task {
            switch mode {
            case .signIn: await account.signIn(email: email, password: password)
            case .signUp: await account.signUp(email: email, password: password, confirmation: confirmation)
            case .reset: await account.requestPasswordReset(email: email)
            }
        }
    }
}

struct AccountMessages: View {
    @EnvironmentObject private var account: AccountStore
    var body: some View {
        if let error = account.error {
            Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red)
                .accessibilityIdentifier("accountError")
        }
        if let notice = account.notice {
            Label(notice, systemImage: "envelope").font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("accountNotice")
        }
    }
}

struct AccountPasswordView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        Form {
            Section {
                SecureField("Nueva contraseña", text: $password).textContentType(.newPassword)
                SecureField("Repite la contraseña", text: $confirmation).textContentType(.newPassword)
            } footer: { Text("Usa al menos 8 caracteres. Esta contraseña pertenece a tu cuenta de FormScan.") }
            Section {
                AccountMessages()
                Button("Guardar contraseña") {
                    Task { await account.updatePassword(password, confirmation: confirmation) }
                }.disabled(account.busy)
            }
        }.navigationTitle("Cambiar contraseña").navigationBarTitleDisplayMode(.inline)
            .onAppear { account.clearMessages() }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var account: AccountStore
    let tutorial: () -> Void
    let beforeSignOut: () throws -> Void
    @State private var saveError: String?
    @State private var showAccess = false
    @State private var showSignOut = false
    var body: some View {
        List {
            Section("Cuenta") {
                if let user = account.user {
                    Label(user.email, systemImage: "person.crop.circle")
                    NavigationLink("Crear o cambiar contraseña") { AccountPasswordView() }
                    Button("Cerrar sesión", role: .destructive) { showSignOut = true }
                } else {
                    Button { showAccess = true } label: { Label("Iniciar sesión", systemImage: "person.crop.circle") }
                    Text("Estás usando FormScan sin cuenta.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(action: tutorial) { Label("Primeros pasos", systemImage: "book.closed") }
                NavigationLink { FormScanPrivacyView() } label: { Label("Privacidad", systemImage: "hand.raised") }
            }
            Section {
                LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }.navigationTitle("Ajustes")
            .sheet(isPresented: $showAccess) { AccountAccessView(allowsDeviceAccess: false) }
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showSignOut, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    do {
                        try beforeSignOut()
                        Task { await account.signOut() }
                    } catch { saveError = "No se pudieron guardar los últimos cambios. Comprueba el espacio disponible y vuelve a intentarlo antes de cerrar sesión." }
                }
            } message: { Text("Los documentos se conservarán en este dispositivo para cuando vuelvas a entrar en esta cuenta.") }
            .alert("No se pudo guardar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("Aceptar", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
    }
}

struct FormScanPrivacyView: View {
    var body: some View {
        List {
            Section("Tus documentos") {
                Text("El escaneo, la detección de campos y la edición se realizan en tu dispositivo. Tus PDF e imágenes no se envían al servicio de cuentas.")
                Text("La biblioteca se guarda en este dispositivo. Exporta los documentos que quieras conservar en otro lugar antes de eliminar la app.")
            }
            Section("Tu cuenta") {
                Text("El servicio de acceso utiliza tu correo y los datos necesarios para verificar tu identidad. FormScan no recibe tu contraseña de Google.")
                Text("Puedes cerrar sesión desde Ajustes. Iniciar sesión no sincroniza los documentos entre dispositivos.")
            }
            Section("Al compartir") { Text("Solo se comparte el PDF que exportes y con la aplicación que elijas.") }
        }.navigationTitle("Privacidad").navigationBarTitleDisplayMode(.inline)
    }
}
