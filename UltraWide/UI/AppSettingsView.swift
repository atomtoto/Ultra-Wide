import SwiftUI

struct AppSettingsView: View {
    @Bindable var model: CaptureUIModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferences.gridKey) private var showsGrid = false
    @AppStorage(AppPreferences.hapticsKey) private var hapticsEnabled = true
    @AppStorage(AppPreferences.outputResolutionKey) private var outputResolution = OutputResolution.mp16.rawValue
    @State private var icons = AppIconStore()

    var body: some View {
        NavigationStack {
            Form {
                iconSection
                Section {
                    Picker(selection: $outputResolution) {
                        ForEach(OutputResolution.allCases) { resolution in
                            Text("\(resolution.rawValue) MP").tag(resolution.rawValue)
                        }
                    } label: {
                        Label("Maximum Resolution", systemImage: "photo")
                    }
                    .accessibilityIdentifier("outputResolution")
                } header: {
                    Text("Output Image")
                } footer: {
                    Text("Applies to future captures, for Photos and sharing. Higher resolutions can increase assembly time and file size. The result depends on source images and iPhone memory, without upscaling.")
                }
                Section {
                    Toggle(isOn: $showsGrid) {
                        Label("Composition Grid", systemImage: "grid")
                    }
                    Toggle(isOn: $hapticsEnabled) {
                        Label("Haptic Feedback", systemImage: "waveform")
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("The grid helps you compose your image. Haptics signal coverage gains and successful captures or saves.")
                }
                Section {
                    Picker(selection: Binding(get: { model.selectedLighting },
                                              set: { model.send(.selectLighting($0)) })) {
                        ForEach(CaptureLighting.allCases) { lighting in
                            Text(lighting.title).tag(lighting)
                        }
                    } label: {
                        Label("Lighting", systemImage: "lightbulb")
                    }
                    .disabled(model.phase != .setup || model.hasActiveSession || model.isStarting)
                } header: {
                    Text("Anti-Flicker")
                } footer: {
                    Text("Auto uses your region. Choose 50 Hz or 60 Hz to adapt the sweep to artificial lighting. Change this setting before a new capture.")
                }
                Section {
                    LabeledContent("Version", value: version)
                    Label("Photos Processed on This iPhone", systemImage: "iphone")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    Text("Your images stay on your device. Saving to Photos and sharing happen only when you ask.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        .onAppear { icons.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { icons.refresh() }
        }
        .alert("Couldn’t Change the Icon",
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
                    Text("A Different Point of View.")
                        .font(.title3.weight(.semibold))
                    Text("Choose an icon that feels like you.")
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
            Text("App Icon")
        } footer: {
            if icons.isSupported {
                Text("Tap an icon to use it on your Home Screen. You can return to the original at any time.")
            } else {
                Text("Changing the app icon isn’t available on this device.")
            }
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
                Text(icon.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if icons.pendingIcon == icon {
                    ProgressView()
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.fill.quaternary),
                        in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!icons.isSupported || icons.pendingIcon != nil)
        .accessibilityLabel(Text(icon.title))
        .accessibilityValue(selected ? Text("Current Icon") : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appIcon.\(icon.rawValue)")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "1"))"
    }
}
