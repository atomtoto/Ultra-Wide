import AVFoundation
import SwiftUI

enum CameraPalette {
    static let accent = Color(red: 1.0, green: 0.73, blue: 0.16)
}

/// Floating camera controls share native glass, with an opaque accessibility fallback.
private struct CameraGlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var isInteractive = false
    var isSelected = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(isSelected ? CameraPalette.accent : Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(isSelected ? 0 : 0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(
                .regular
                    .tint(isSelected ? CameraPalette.accent : .black.opacity(0.16))
                    .interactive(isInteractive),
                in: shape
            )
        }
    }
}

struct UltraWideRootView: View {
    @Bindable var model: CaptureUIModel
    @Environment(\.locale) private var locale
    @AppStorage(AppPreferences.gridKey) private var showsGrid = false
    @State private var showsSettings = false
    @State private var showsDiscardConfirmation = false
    @State private var didPrepare = false
    @State private var showsExposureControl = false
    @State private var visibleBlockReason: SweepCaptureBlockReason?

    var body: some View {
        ZStack {
            background

            switch model.phase {
            case .setup, .capturing:
                sweepScreen
            case .reanchor:
                reanchorScreen
            case .passReview:
                interruptedScreen
            case .processing:
                processingScreen
            case .review:
                reviewScreen
            case .permission, .unavailable:
                unavailableScreen
            }
        }
        .tint(CameraPalette.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsSettings) {
            AppSettingsView(model: model)
                .tint(CameraPalette.accent)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            tr("Supprimer cette prise de vue ?", "Discard this capture?"),
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(tr("Supprimer", "Discard"), role: .destructive) {
                model.send(.discard)
            }
            Button(tr("Continuer", "Continue"), role: .cancel) {}
        } message: {
            Text(tr("Les photos non enregistrées seront supprimées.", "Unsaved photos will be deleted."))
        }
        .onAppear {
            guard !didPrepare else { return }
            didPrepare = true
            model.send(.prepare)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-settings-preview") { showsSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-ui-exposure-preview") { showsExposureControl = true }
#endif
        }
        .task(id: model.sweep.blockReason) {
            let reason = model.sweep.blockReason
            if reason == .writing || reason == .awaitingCamera {
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
            }
            visibleBlockReason = reason
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .setup { showsExposureControl = false }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let session = model.previewSession,
           model.phase == .setup || model.phase == .capturing || model.phase == .reanchor || model.phase == .passReview {
            CameraPreviewView(session: session, rotationAngle: model.previewRotationAngle,
                allowsMetering: model.canAdjustCamera && !model.isStarting,
                onMeteringPoint: { model.send(.setMeteringPoint($0)) })
                .ignoresSafeArea()
                .overlay {
                    if showsGrid {
                        CompositionGrid()
                            .stroke(.white.opacity(0.35), lineWidth: 0.5)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.28), location: 0),
                            .init(color: .clear, location: 0.18),
                            .init(color: .clear, location: 0.82),
                            .init(color: .black.opacity(0.28), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var sweepScreen: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            Group {
                if isLandscape {
                    landscapeSweepScreen
                } else {
                    portraitSweepScreen(availableWidth: geometry.size.width)
                }
            }
            .padding(.horizontal, isLandscape ? 22 : 18)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func portraitSweepScreen(availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            captureTopBar
            if showsExposureControl && model.canAdjustCamera {
                exposureControl.padding(.top, 12)
            }
            if model.phase == .setup && !model.hasActiveSession && showsCameraOptions {
                cameraOptions.padding(.top, 14)
            }
            if !model.isSinglePhoto || model.hasActiveSession {
                HStack {
                    Spacer(minLength: 0)
                    fieldIndicator(isLandscape: false)
                        .frame(width: min(176, availableWidth * 0.45))
                        .allowsHitTesting(false)
                }
                .padding(.top, 18)
            }
            Spacer(minLength: 16)
            captureMessages
            shutterControls
                .padding(.top, 14)
        }
    }

    private var landscapeSweepScreen: some View {
        VStack(spacing: 0) {
            captureTopBar
            HStack(alignment: .center, spacing: 20) {
                if !model.isSinglePhoto || model.hasActiveSession {
                    fieldIndicator(isLandscape: true)
                        .frame(width: 240)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 10)
                VStack(spacing: 12) {
                    if model.phase == .setup && !model.hasActiveSession && showsCameraOptions {
                        cameraOptions
                    }
                    if showsExposureControl && model.canAdjustCamera { exposureControl }
                    Spacer(minLength: 0)
                    captureMessages
                    shutterControls
                }
                .frame(maxWidth: 290)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var captureTopBar: some View {
        HStack(spacing: 10) {
            if model.hasActiveSession {
                Button {
                    showsDiscardConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .modifier(CameraGlassSurface(shape: Circle(), isInteractive: true))
                }
                .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
            } else {
                settingsButton
                    .disabled(model.isStarting)
            }
            Spacer()
            if model.phase == .setup && !model.hasActiveSession {
                Button {
                    showsExposureControl.toggle()
                } label: {
                    Image(systemName: "plusminus.circle")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .modifier(CameraGlassSurface(shape: Circle(), isInteractive: !model.isStarting))
                }
                .disabled(!model.canAdjustCamera || model.isStarting)
                .accessibilityLabel(tr("Régler l’exposition", "Adjust exposure"))
                lightingMenu
            }
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button {
            showsExposureControl = false
            showsSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .modifier(CameraGlassSurface(shape: Circle(), isInteractive: true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Réglages de l’app", "App settings"))
        .accessibilityIdentifier("appSettings")
    }

    private var exposureControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .accessibilityHidden(true)
            Slider(value: Binding(get: { model.exposureBias },
                set: { model.send(.setExposureBias($0)) }), in: -2...2, step: 0.1)
                .accessibilityLabel(tr("Correction d’exposition", "Exposure compensation"))
            Text(model.exposureBias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()).locale(locale)))
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(minWidth: 38)
            Button {
                model.send(.setExposureBias(0))
            } label: { Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 36) }
                .accessibilityLabel(tr("Réinitialiser l’exposition", "Reset exposure"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(CameraGlassSurface(shape: Capsule()))
        .disabled(model.isStarting)
    }

    private var lightingMenu: some View {
        Menu {
            Picker(tr("Éclairage", "Lighting"), selection: Binding(
                get: { model.selectedLighting },
                set: { model.send(.selectLighting($0)) }
            )) {
                ForEach(CaptureLighting.allCases) { lighting in
                    Text(lightingTitle(lighting)).tag(lighting)
                }
            }
        } label: {
            Label(tr("Éclairage", "Lighting"), systemImage: "lightbulb")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .modifier(CameraGlassSurface(shape: Capsule(), isInteractive: !model.isStarting))
        }
        .disabled(model.hasActiveSession || model.isStarting || model.phase == .capturing)
        .accessibilityValue(lightingTitle(model.selectedLighting))
        .accessibilityHint(tr("Réduire le scintillement sous éclairage artificiel.",
                              "Reduce flicker under artificial lighting."))
    }

    private func lightingTitle(_ lighting: CaptureLighting) -> String {
        switch lighting {
        case .automatic: tr("Auto (région)", "Auto (region)")
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        }
    }

    private var showsCameraOptions: Bool {
        model.availableLenses.count > 1 || model.availableTargets.count > 1
    }

    private var cameraOptions: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: 10) {
                if model.availableLenses.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(model.availableLenses) { lens in
                            Button {
                                model.send(.selectLens(lens))
                            } label: {
                                Text(lens == .wide ? tr("Principal", "Main") : tr("Télé", "Tele"))
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(model.selectedLens == lens ? .black : .white)
                                    .modifier(CameraGlassSurface(
                                        shape: Capsule(),
                                        isInteractive: !model.isStarting,
                                        isSelected: model.selectedLens == lens
                                    ))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isStarting)
                            .accessibilityAddTraits(model.selectedLens == lens ? [.isSelected] : [])
                        }
                    }
                }
                if model.availableTargets.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(model.availableTargets) { target in
                            Button {
                                model.send(.selectTarget(target))
                            } label: {
                                Text(target.magnification(for: locale))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(model.selectedTarget == target ? .black : .white)
                                    .modifier(CameraGlassSurface(
                                        shape: Capsule(),
                                        isInteractive: !model.isStarting,
                                        isSelected: model.selectedTarget == target
                                    ))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isStarting)
                            .accessibilityAddTraits(model.selectedTarget == target ? [.isSelected] : [])
                        }
                    }
                }
            }
            .frame(maxWidth: 290)
        }
    }

    private func fieldIndicator(isLandscape: Bool) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(tr("CHAMP FINAL", "FINAL FRAME"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if model.phase == .capturing {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(CameraPalette.accent)
                        .accessibilityHidden(true)
                }
            }
            Group {
                if model.isSinglePhoto && !model.hasActiveSession {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(CameraPalette.accent, lineWidth: 2)
                        .overlay {
                            Image(systemName: "camera")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                } else {
                    CoverageMap(sweep: model.sweep, locale: locale)
                }
            }
            .aspectRatio(isLandscape ? 4.0 / 3.0 : 3.0 / 4.0, contentMode: .fit)
            Text(fieldHint)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .modifier(CameraGlassSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
        .accessibilityElement(children: .contain)
    }

    private var fieldHint: String {
        if model.sweep.isFinishing {
            return model.sweep.isVerifyingAlignment
                ? tr("Vérification…", "Checking…")
                : tr("Finalisation…", "Finishing…")
        }
        if model.phase == .setup {
            return model.hasActiveSession
                ? tr("Reprendre", "Resume")
                : model.isSinglePhoto
                    ? tr("Photo prête", "Ready to capture")
                    : tr("Pointez le centre", "Point at the center")
        }
        if model.sweep.isComplete { return tr("Couverture complète", "Coverage complete") }
        if model.phase == .passReview {
            return model.sweep.capturedField != nil ? tr("Champ capturé disponible", "Captured field available")
                : tr("Cadre à compléter", "Fill the frame")
        }
        if model.phase == .capturing, model.sweep.guidanceDirection != nil {
            return tr("Complétez le cadre", "Fill the frame")
        }
        if model.sweep.isVerifyingAlignment && model.phase != .capturing {
            return tr("Vérification…", "Checking…")
        }
        return tr("Balayez librement", "Sweep freely")
    }

    @ViewBuilder
    private var captureMessages: some View {
        if let issue = model.issue {
            issueNotice(issue)
                .frame(maxWidth: 350)
        } else if let banner = model.banner {
            Text(banner.text(for: locale))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .modifier(CameraGlassSurface(shape: Capsule()))
                .frame(maxWidth: 350)
        } else if model.phase == .capturing && !model.sweep.isFinishing {
            HStack(spacing: 10) {
                if visibleBlockReason == nil, let vector = model.sweep.guidanceDirection,
                   hypot(vector.dx, vector.dy) > 0.03 {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .rotationEffect(.radians(atan2(vector.dx, -vector.dy)))
                        .foregroundStyle(CameraPalette.accent)
                        .accessibilityHidden(true)
                }
                Text(visibleBlockReason.map(blockMessage) ?? directionMessage)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .modifier(CameraGlassSurface(shape: Capsule()))
            .frame(maxWidth: 350)
        } else if model.phase == .setup && model.previewSession == nil
                    && !model.hasActiveSession && !model.isStarting {
            Button(tr("Réactiver l’appareil photo", "Restart camera")) {
                model.send(.retry)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
    }

    private func blockMessage(_ reason: SweepCaptureBlockReason) -> String {
        switch reason {
        case .tooFast: tr("Ralentissez légèrement le mouvement", "Move a little more slowly")
        case .tooDark: tr("Cette zone est trop sombre", "This area is too dark")
        case .awaitingCamera: tr("En attente d’une image de la caméra…", "Waiting for a camera image…")
        case .writing: tr("Enregistrement des images…", "Saving images…")
        case .insufficientDetail: tr("Visez une zone avec plus de détails", "Aim at an area with more detail")
        case .alignmentFailed: tr("Ces vues ne s’alignent pas. Revenez vers une zone déjà capturée.",
                                  "These views cannot be aligned. Return toward an area already captured.")
        }
    }

    private var directionMessage: String {
        guard let vector = model.sweep.guidanceDirection, hypot(vector.dx, vector.dy) > 0.03 else {
            return model.sweep.isVerifyingAlignment ? tr("Vérification des images…", "Checking images…")
                : tr("Balayez pour compléter le cadre", "Sweep to fill the frame")
        }
        if abs(vector.dx) > abs(vector.dy) * 2.4 {
            return vector.dx > 0 ? tr("Vers la droite", "Move right") : tr("Vers la gauche", "Move left")
        }
        if abs(vector.dy) > abs(vector.dx) * 2.4 {
            return vector.dy > 0 ? tr("Vers le bas", "Move down") : tr("Vers le haut", "Move up")
        }
        if vector.dy < 0 {
            return vector.dx < 0 ? tr("Vers le haut à gauche", "Move up and left") : tr("Vers le haut à droite", "Move up and right")
        }
        return vector.dx < 0 ? tr("Vers le bas à gauche", "Move down and left") : tr("Vers le bas à droite", "Move down and right")
    }

    private var shutterControls: some View {
        HStack {
            Spacer()
            Button {
                if model.phase == .capturing {
                    model.send(.stopSweep)
                } else if model.hasRecoverableSession {
                    model.send(.resume)
                } else {
                    model.send(.startSweep)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 82, height: 82)
                    if model.isStarting || model.sweep.isFinishing {
                        ProgressView()
                            .tint(CameraPalette.accent)
                    } else if model.phase == .capturing {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(CameraPalette.accent)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.white)
                            .frame(width: 66, height: 66)
                    }
                }
                .frame(width: 92, height: 92)
                .contentShape(Circle())
                .modifier(CameraGlassSurface(shape: Circle(), isInteractive: !shutterDisabled))
            }
            .buttonStyle(.plain)
            .disabled(shutterDisabled)
            .opacity(shutterDisabled ? 0.5 : 1)
            .accessibilityLabel(shutterAccessibilityLabel)
            Spacer()
        }
    }

    private var shutterDisabled: Bool {
        if model.phase == .capturing { return model.sweep.isFinishing }
        if model.hasRecoverableSession { return model.isStarting }
        return model.previewSession == nil || model.availableTargets.isEmpty || model.isStarting
    }

    private var shutterAccessibilityLabel: String {
        if model.phase == .capturing { return tr("Arrêter le balayage", "Stop sweep") }
        if model.hasActiveSession { return tr("Reprendre le balayage", "Resume sweep") }
        if model.isSinglePhoto { return tr("Prendre la photo", "Take photo") }
        return tr("Démarrer le balayage", "Start sweep")
    }

    private var reanchorScreen: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            VStack(spacing: 16) {
                HStack {
                    closeButton
                    Spacer()
                }
                if isLandscape {
                    HStack(spacing: 20) {
                        reanchorReference
                            .frame(maxWidth: .infinity)
                        reanchorActions
                            .frame(maxWidth: 300)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                    reanchorReference
                        .frame(maxWidth: 290, maxHeight: 330)
                    reanchorActions
                    Spacer(minLength: 0)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var reanchorReference: some View {
        if let image = model.reanchorImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .opacity(0.46)
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(CameraPalette.accent, lineWidth: 2)
                }
                .accessibilityLabel(tr("Vue de référence", "Reference view"))
        }
    }

    private var reanchorActions: some View {
        VStack(spacing: 16) {
            Text(tr("Alignez la vue centrale", "Align the center view"))
                .font(.headline)
            if let issue = model.issue { issueNotice(issue) }
            Button(tr("Continuer", "Continue")) {
                model.send(.confirmReanchor)
            }
            .foregroundStyle(.black)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.isStarting)
        }
    }

    private var interruptedScreen: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            VStack(spacing: 16) {
                HStack {
                    closeButton
                    Spacer()
                }
                if isLandscape {
                    HStack(spacing: 24) {
                        fieldIndicator(isLandscape: true)
                            .frame(width: 215)
                        VStack(spacing: 16) {
                            if let issue = model.issue { issueNotice(issue) }
                            interruptedActions
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                    fieldIndicator(isLandscape: false)
                        .frame(maxWidth: 240)
                    if let issue = model.issue { issueNotice(issue) }
                    interruptedActions
                    Spacer(minLength: 0)
                }
            }
            .padding(20)
        }
    }

    private var interruptedActions: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 12) {
                Button(tr("Continuer", "Continue")) {
                    model.send(.startSweep)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                if model.sweep.isComplete {
                    Button(model.issue == nil
                           ? tr("Assembler", "Stitch")
                           : tr("Réessayer", "Try again")) {
                        model.send(.assemble)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else if model.sweep.capturedField != nil {
                    Button(tr("Utiliser le champ capturé", "Use captured field")) {
                        model.send(.useCapturedField)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Text(tr("Un cadre légèrement réduit, sans zones manquantes.",
                            "A slightly smaller frame, with no missing areas."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var processingScreen: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            Group {
                if model.sweep.previewImage == nil {
                    processingStatus
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLandscape {
                    HStack(spacing: 28) {
                        assemblyPreview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        processingStatus
                            .frame(maxWidth: 260)
                    }
                } else {
                    VStack(spacing: 28) {
                        Spacer(minLength: 0)
                        assemblyPreview
                            .frame(maxWidth: 390, maxHeight: geometry.size.height * 0.56)
                        processingStatus
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var assemblyPreview: some View {
        if let image = model.sweep.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel(tr("Aperçu de l’image en cours d’assemblage", "Preview of the image being assembled"))
        }
    }

    private var processingStatus: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(CameraPalette.accent)
            Text(model.sweep.previewImage != nil
                 ? tr("Finalisation…", "Finishing…")
                 : tr("Assemblage…", "Stitching…"))
                .font(.headline)
            if let progress = model.processingProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(CameraPalette.accent)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(tr("Progression de l’assemblage", "Stitching progress"))
            }
        }
    }

    private var reviewScreen: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            Group {
                if isLandscape {
                    HStack(spacing: 16) {
                        VStack(spacing: 8) {
                            reviewHeader
                            reviewImage
                        }
                        .frame(maxWidth: .infinity)
                        reviewActions
                            .frame(maxWidth: 310)
                    }
                } else {
                    VStack(spacing: 12) {
                        reviewHeader
                        reviewImage
                        reviewActions
                    }
                }
            }
            .padding(18)
        }
    }

    private var reviewHeader: some View {
        HStack {
            Button {
                if model.saveState == .saved || model.resultURL == nil {
                    model.send(.newCapture)
                } else {
                    showsDiscardConfirmation = true
                }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .modifier(CameraGlassSurface(shape: Circle(), isInteractive: true))
            }
            .accessibilityLabel(tr("Nouvelle prise de vue", "New capture"))
            Spacer()
            Text(tr("Aperçu", "Preview"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            settingsButton
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reviewImage: some View {
        if let image = model.resultPreview {
            ZoomableReviewImage(preview: image, url: model.resultURL, pixelSize: model.resultPixelSize)
                .accessibilityLabel(tr("Aperçu de l’image assemblée", "Preview of stitched image"))
        } else {
            Image(systemName: "photo")
                .font(.system(size: 60, weight: .ultraLight))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    private var reviewActions: some View {
        VStack(spacing: 14) {
            if let size = model.resultPixelSize {
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.resultWasCropped, let magnification = model.resultMagnification {
                Text(tr("Champ capturé", "Captured field") + " · "
                    + magnification.formatted(.number.precision(.fractionLength(2)).locale(locale)) + "×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.saveState == .idle {
                    Button(tr("Continuer le balayage", "Continue sweeping")) { model.send(.continueAfterCrop) }
                        .buttonStyle(.glass)
                }
            }
            if let issue = model.issue {
                issueNotice(issue)
            } else if model.saveState == .saved {
                Label(tr("Enregistrée dans Photos", "Saved to Photos"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(CameraPalette.accent)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        model.send(.saveToPhotos)
                    } label: {
                        HStack(spacing: 8) {
                            if model.saveState == .saving {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: model.saveState == .saved ? "checkmark" : "square.and.arrow.down")
                            }
                            Text(model.saveState == .saved ? tr("Enregistrée", "Saved") : tr("Enregistrer", "Save"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .disabled(model.resultURL == nil || model.saveState != .idle)
                    if let url = model.resultURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(tr("Partager l’image", "Share image"))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
    }

    private var unavailableScreen: some View {
        VStack(spacing: 18) {
            HStack { Spacer(); settingsButton }
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(CameraPalette.accent)
                .accessibilityHidden(true)
            Text(issueTitle(model.issue?.kind))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.issue?.detail?.text(for: locale) ?? tr("Réessayez.", "Try again."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if model.phase == .permission {
                Button(tr("Ouvrir Réglages", "Open Settings")) {
                    model.send(.openSettings)
                }
                .foregroundStyle(.black)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            if model.issue?.canRetry != false {
                Button(tr("Réessayer", "Try again")) {
                    model.send(.retry)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.isStarting)
            }
        }
        .padding(28)
    }

    private var closeButton: some View {
        Button {
            showsDiscardConfirmation = true
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .modifier(CameraGlassSurface(shape: Circle(), isInteractive: true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
    }

    private func issueNotice(_ issue: CaptureUIIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CameraPalette.accent)
                .accessibilityHidden(true)
            Text(issue.detail?.text(for: locale) ?? issueTitle(issue.kind))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if issue.canRetry {
                Button(tr("Réessayer", "Retry")) {
                    model.send(issue.kind == .saveFailure ? .saveToPhotos : .retry)
                }
                .font(.footnote.weight(.semibold))
            } else if issue.kind == .photoLibraryPermission {
                Button(tr("Réglages", "Settings")) {
                    model.send(.openSettings)
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 14))
    }

    private func issueTitle(_ kind: CaptureUIIssue.Kind?) -> String {
        switch kind {
        case .cameraPermission: tr("Accès à l’appareil photo", "Camera access")
        case .motionPermission: tr("Accès aux mouvements", "Motion access")
        case .cameraUnavailable: tr("Appareil photo indisponible", "Camera unavailable")
        case .captureFailure: tr("Prise de vue interrompue", "Capture interrupted")
        case .stitchingFailure: tr("Assemblage impossible", "Couldn’t stitch image")
        case .photoLibraryPermission: tr("Accès à Photos", "Photos access")
        case .saveFailure: tr("Enregistrement impossible", "Couldn’t save image")
        case nil: tr("Une erreur est survenue", "Something went wrong")
        }
    }

    private func tr(_ french: String, _ english: String) -> String {
        locale.captureLanguageIsFrench ? french : english
    }
}

#Preview("Cadre de capture") {
    let model = CaptureUIModel()
    model.phase = .capturing
    model.sweep = CaptureUISweep(
        viewRect: CGRect(x: 0.48, y: 0.11, width: 0.42, height: 0.48),
        coveredRects: [
            CGRect(x: 0.28, y: 0.25, width: 0.45, height: 0.48),
            CGRect(x: 0.48, y: 0.11, width: 0.42, height: 0.48)
        ],
        coverageFraction: 0.62,
        isRecording: true
    )
    return UltraWideRootView(model: model)
}

/// Aligned image footprints cover the progressive photo. The amber frame guides
/// the current camera position without counting it as verified coverage.
private struct CoverageMap: View {
    var sweep: CaptureUISweep
    var locale: Locale

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let cornerRadius: CGFloat = 18
            let bounds = CGRect(x: inset, y: inset,
                                width: max(0, size.width - 2 * inset),
                                height: max(0, size.height - 2 * inset))
            let outside = Path(roundedRect: bounds, cornerRadius: cornerRadius)
            context.fill(outside, with: .color(.white.opacity(0.06)))

            var inside = context
            inside.clip(to: outside)
            if let image = sweep.previewImage {
                inside.draw(Image(uiImage: image), in: bounds)
            }
            var covered = Path()
            if !sweep.coveredPolygons.isEmpty {
                for polygon in sweep.coveredPolygons where polygon.count >= 3 {
                    covered.move(to: mapped(polygon[0], in: bounds))
                    for point in polygon.dropFirst() {
                        covered.addLine(to: mapped(point, in: bounds))
                    }
                    covered.closeSubpath()
                }
            } else {
                for rect in sweep.coveredRects {
                    let painted = mapped(rect, in: bounds)
                    covered.addPath(Path(roundedRect: painted, cornerRadius: 7))
                }
            }
            inside.fill(covered, with: .color(CameraPalette.accent.opacity(sweep.previewImage == nil ? 0.38 : 0.08)))
            context.stroke(outside, with: .color(.white.opacity(0.86)), lineWidth: 1.7)

            let lens = Path(roundedRect: mapped(sweep.viewRect, in: bounds), cornerRadius: cornerRadius)
            inside.fill(lens, with: .color(CameraPalette.accent.opacity(sweep.previewImage == nil ? 0.20 : 0.06)))
            context.stroke(lens, with: .color(CameraPalette.accent), lineWidth: 2.6)
            if !sweep.isRecording, let crop = sweep.capturedField {
                inside.stroke(Path(roundedRect: mapped(crop, in: bounds), cornerRadius: cornerRadius),
                    with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locale.captureLanguageIsFrench ? "Couverture du champ final" : "Final field coverage")
        .accessibilityValue(coverageValue)
    }

    private var coverageValue: String {
        let rounded = Int((min(max(sweep.coverageFraction, 0), 1) * 100).rounded())
        let percent = sweep.isComplete ? 100 : min(99, rounded)
        return locale.captureLanguageIsFrench ? "\(percent) pour cent" : "\(percent) percent"
    }

    private func mapped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + rect.minX * bounds.width,
               y: bounds.minY + rect.minY * bounds.height,
               width: max(0, rect.width * bounds.width),
               height: max(0, rect.height * bounds.height))
    }

    private func mapped(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + point.x * bounds.width,
                y: bounds.minY + point.y * bounds.height)
    }
}

private struct CompositionGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = rect.minX + rect.width * fraction
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}
