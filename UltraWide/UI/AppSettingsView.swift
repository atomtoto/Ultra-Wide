import SwiftUI

struct AppSettingsView: View {
    @Bindable var model: CaptureUIModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferences.gridKey) private var showsGrid = false
    @AppStorage(AppPreferences.hapticsKey) private var hapticsEnabled = true
    @State private var icons = AppIconStore()

    var body: some View {
        NavigationStack {
            Form {
                iconSection
                Section {
                    Toggle(isOn: $showsGrid) {
                        Label(tr("Grille de cadrage", "Composition grid"), systemImage: "grid")
                    }
                    Toggle(isOn: $hapticsEnabled) {
                        Label(tr("Retour haptique", "Haptic feedback"), systemImage: "waveform")
                    }
                } header: {
                    Text(tr("Prise de vue", "Capture"))
                } footer: {
                    Text(tr("La grille aide à composer l’image. Les vibrations signalent les gains de couverture et la réussite d’une capture ou d’un enregistrement.",
                            "The grid helps you compose your image. Haptics signal coverage gains and successful captures or saves."))
                }
                Section {
                    Picker(selection: Binding(get: { model.selectedLighting },
                                              set: { model.send(.selectLighting($0)) })) {
                        ForEach(CaptureLighting.allCases) { lighting in
                            Text(lightingTitle(lighting)).tag(lighting)
                        }
                    } label: {
                        Label(tr("Éclairage", "Lighting"), systemImage: "lightbulb")
                    }
                    .disabled(model.phase != .setup || model.hasActiveSession || model.isStarting)
                } header: {
                    Text(tr("Anti-scintillement", "Anti-flicker"))
                } footer: {
                    Text(tr("Auto utilise votre région. Choisissez 50 Hz ou 60 Hz pour adapter le balayage à l’éclairage artificiel. Ce réglage se modifie avant une nouvelle prise de vue.",
                            "Auto uses your region. Choose 50 Hz or 60 Hz to adapt the sweep to artificial lighting. Change this setting before a new capture."))
                }
                Section {
                    LabeledContent(tr("Version", "Version"), value: version)
                    Label(tr("Photos traitées sur cet iPhone", "Photos processed on this iPhone"), systemImage: "iphone")
                        .foregroundStyle(.secondary)
                } header: {
                    Text(tr("À propos", "About"))
                } footer: {
                    Text(tr("Vos images restent sur votre appareil. L’enregistrement dans Photos et le partage se font à votre demande.",
                            "Your images stay on your device. Saving to Photos and sharing happen at your request."))
                }
            }
            .navigationTitle(tr("Réglages", "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Terminé", "Done"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .onAppear { icons.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { icons.refresh() }
        }
        .alert(tr("Impossible de changer l’icône", "Couldn’t change the icon"),
               isPresented: Binding(get: { icons.errorMessage != nil }, set: { if !$0 { icons.errorMessage = nil } })) {
            Button("OK", role: .cancel) { icons.errorMessage = nil }
        } message: {
            Text(icons.errorMessage ?? "")
        }
    }

    private var iconSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Un autre point de vue.", "A different point of view."))
                        .font(.title3.weight(.semibold))
                    Text(tr("Choisissez l’icône qui vous ressemble.", "Choose an icon that feels like you."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 12)], spacing: 12) {
                    ForEach(AppIcon.allCases) { icon in
                        iconButton(icon)
                    }
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text(tr("Icône de l’app", "App icon"))
        } footer: {
            Text(icons.isSupported
                 ? tr("Touchez une icône pour l’utiliser sur l’écran d’accueil. Vous pouvez revenir à l’originale à tout moment.",
                      "Tap an icon to use it on your Home Screen. You can return to the original at any time.")
                 : tr("Le changement d’icône n’est pas disponible sur cet appareil.",
                      "Changing the app icon is unavailable on this device."))
        }
    }

    private func iconButton(_ icon: AppIcon) -> some View {
        let selected = icons.selectedName == icon.alternateName
        return Button {
            Task { await icons.select(icon) }
        } label: {
            VStack(spacing: 10) {
                Image(icon.previewName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text(icon.title(for: locale))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if icons.pendingIcon == icon {
                    ProgressView().frame(height: 18)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? CameraPalette.accent : Color.secondary)
                        .frame(height: 18)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(selected ? CameraPalette.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(selected ? CameraPalette.accent : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(!icons.isSupported || icons.pendingIcon != nil)
        .accessibilityLabel(icon.title(for: locale))
        .accessibilityValue(selected ? tr("Icône actuelle", "Current icon") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appIcon.\(icon.rawValue)")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "1"))"
    }

    private func lightingTitle(_ lighting: CaptureLighting) -> String {
        switch lighting {
        case .automatic: tr("Auto (région)", "Auto (region)")
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        }
    }

    private func tr(_ french: String, _ english: String) -> String {
        locale.captureLanguageIsFrench ? french : english
    }
}
