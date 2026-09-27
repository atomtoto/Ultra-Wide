import AVFoundation
import SwiftUI

private enum CameraPalette {
    static let accent = Color(red: 0.69, green: 0.88, blue: 1.0)
    static let dim = Color(red: 0.10, green: 0.13, blue: 0.18)
}

struct UltraWideRootView: View {
    @Bindable var model: CaptureUIModel
    @Environment(\.locale) private var locale
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDiscardConfirmation = false
    @State private var didPrepare = false

    var body: some View {
        ZStack {
            background

            switch model.phase {
            case .setup:
                setupScreen
            case .reanchor:
                reanchorScreen
            case .capturing:
                captureScreen
            case .passReview:
                passReviewScreen
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
        }
    }

    @ViewBuilder
    private var background: some View {
        if model.phase == .review {
            Color.black.ignoresSafeArea()
        } else if let session = model.previewSession,
                  model.phase == .setup || model.phase == .reanchor || model.phase == .capturing || model.phase == .passReview {
            CameraPreviewView(session: session, rotationAngle: model.previewRotationAngle)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.58), .clear, .black.opacity(0.70)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
        } else {
            ZStack {
                Color(red: 0.035, green: 0.055, blue: 0.085)
                RadialGradient(
                    colors: [CameraPalette.dim.opacity(0.9), .clear],
                    center: .init(x: 0.55, y: 0.43),
                    startRadius: 15,
                    endRadius: 420
                )
                Image(systemName: "viewfinder")
                    .font(.system(size: 178, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.08))
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
    }

    private var setupScreen: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading) {
                        brandHeader
                        Spacer()
                        Text(tr("Une seule photo. Un champ plus vaste.", "One photo. A wider view."))
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    ScrollView {
                        setupPanel
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 460)
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    brandHeader
                    ScrollView {
                        setupPanel
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                VStack(spacing: 0) {
                    brandHeader
                    Spacer(minLength: 20)
                    setupPanel
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 23, weight: .light))
                .accessibilityHidden(true)
            Text("ULTRA WIDE")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(2.2)
            Spacer()
            if model.hasRecoverableSession {
                Text(tr("Session retrouvée", "Session available"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Voyez plus large.", "See beyond the frame."))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                Text(tr(
                    "Tournez doucement l’iPhone. Nous assemblerons chaque détail en une seule photo.",
                    "Slowly rotate your iPhone. We’ll combine every detail into one photo."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel(tr("OBJECTIF", "LENS"))
                HStack(spacing: 8) {
                    lensButton(.wide)
                    lensButton(.tele)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel(tr("CHAMP FINAL", "FINAL FIELD OF VIEW"))
                    Spacer()
                    Text(tr("équivalent", "equivalent"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.availableTargets) { target in
                            Button {
                                model.send(.selectTarget(target))
                            } label: {
                                Text(target.magnification(for: locale))
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minWidth: 55, minHeight: 44)
                                    .padding(.horizontal, 5)
                                    .background(
                                        model.selectedTarget == target ? CameraPalette.accent : .white.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                                    .foregroundStyle(model.selectedTarget == target ? .black : .white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.selectedTarget == target ? [.isSelected] : [])
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "circle.grid.3x3")
                    .foregroundStyle(CameraPalette.accent)
                    .accessibilityHidden(true)
                Text(estimateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasRecoverableSession {
                HStack(spacing: 10) {
                    Button {
                        model.send(.resume)
                    } label: {
                        Group {
                            if model.isStarting {
                                ProgressView().tint(.black)
                            } else {
                                Label(tr("Reprendre", "Resume"), systemImage: "arrow.clockwise")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isStarting)
                    Button(role: .destructive) {
                        showsDiscardConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(tr("Supprimer la session retrouvée", "Discard recovered session"))
                }
            } else {
                Button {
                    model.send(.start)
                } label: {
                    HStack(spacing: 9) {
                        if model.isStarting {
                            ProgressView().tint(.black)
                        } else {
                            Text(tr("Commencer", "Start capture"))
                            Image(systemName: "arrow.right")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.availableTargets.isEmpty || model.isStarting)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
    }

    private var estimateText: String {
        let count = model.estimatedPhotos.formatted(.number.locale(locale))
        return locale.captureLanguageIsFrench
            ? "Environ \(count) photos. Restez au même endroit et privilégiez les scènes immobiles."
            : "About \(count) photos. Stay in one spot and choose a still scene."
    }

    private func lensButton(_ lens: CaptureUILens) -> some View {
        let available = model.availableLenses.contains(lens)
        let selected = model.selectedLens == lens
        return Button {
            model.send(.selectLens(lens))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: lens == .wide ? "camera" : "camera.macro")
                    .font(.system(size: 17, weight: .medium))
                    .accessibilityHidden(true)
                Text(lens == .wide ? tr("Principal", "Main") : tr("Téléobjectif", "Telephoto"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? .white.opacity(0.21) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? CameraPalette.accent : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(available ? "" : tr("Indisponible sur cet iPhone", "Unavailable on this iPhone"))
    }

    private var reanchorScreen: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 16) {
                    VStack(spacing: 8) {
                        reanchorHeader
                        reanchorReference
                    }
                    .frame(maxWidth: .infinity)
                    ScrollView {
                        reanchorPanel
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 350)
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    reanchorHeader
                    reanchorReference.frame(height: 170)
                    ScrollView {
                        reanchorPanel
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                VStack(spacing: 12) {
                    reanchorHeader
                    reanchorReference
                        .frame(maxHeight: .infinity)
                    reanchorPanel
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var reanchorHeader: some View {
        HStack {
            Button {
                showsDiscardConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
            Spacer()
            Text(tr("REALIGNEMENT", "REALIGNMENT"))
                .font(.caption.weight(.bold))
                .tracking(1.5)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var reanchorReference: some View {
        GeometryReader { geometry in
            // Follow the orientation saved with the capture, even if the user
            // temporarily holds the phone differently while resuming.
            let aspect: CGFloat = model.previewRotationAngle == 90 ? 3 / 4 : 4 / 3
            let width = min(geometry.size.width, geometry.size.height * aspect, 450)
            let height = width / aspect
            ZStack {
                if let image = model.reanchorImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .opacity(0.45)
                } else {
                    Color.white.opacity(0.08)
                }
                Image(systemName: "viewfinder")
                    .font(.system(size: 58, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.78))
                    .accessibilityHidden(true)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CameraPalette.accent.opacity(0.8), lineWidth: 1.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Superposition translucide de la photo de référence", "Translucent overlay of the reference photo"))
    }

    private var reanchorPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("Retrouvez votre point de départ", "Find your starting point"))
                .font(.title2.weight(.semibold))
            Text(tr(
                "Revenez au même endroit et faites coïncider les contours de la scène avec l’image translucide.",
                "Return to the same spot and match the scene’s edges with the translucent image."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if model.reanchorImage == nil {
                Text(tr(
                    "La photo de référence est introuvable. Annulez cette session pour recommencer.",
                    "The reference photo is unavailable. Cancel this session to start again."
                ))
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            if let issue = model.issue {
                issueNotice(issue)
            }
            Button {
                model.send(.confirmReanchor)
            } label: {
                Group {
                    if model.isStarting {
                        ProgressView().tint(.black)
                    } else {
                        Label(tr("Repère aligné, continuer", "Aligned, continue"), systemImage: "checkmark")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.reanchorImage == nil || model.isStarting)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var captureScreen: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 18) {
                    VStack(spacing: 0) {
                        captureHeader
                        Spacer(minLength: 0)
                        guideReticle.frame(height: 120)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    ScrollView {
                        capturePanel
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 360)
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    captureHeader
                    guideReticle.frame(height: 90)
                    ScrollView {
                        capturePanel
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                VStack(spacing: 0) {
                    captureHeader
                    Spacer(minLength: 0)
                    guideReticle.frame(height: 190)
                    Spacer(minLength: 0)
                    ScrollView {
                        capturePanel
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 370)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var guideReticle: some View {
        CaptureGuideReticle(guidance: model.guidance)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(guidanceText)
    }

    private var captureHeader: some View {
        VStack(spacing: 13) {
            HStack(alignment: .center) {
                Button {
                    model.send(.pause)
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Mettre en pause", "Pause capture"))
                Spacer()
                VStack(spacing: 2) {
                    Text(model.currentPass == 1 ? tr("PREMIER PASSAGE", "FIRST PASS") : tr("SECOND PASSAGE", "SECOND PASS"))
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                    Text(model.selectedLens == .wide ? tr("Objectif principal", "Main lens") : tr("Téléobjectif", "Telephoto"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsDiscardConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
            }

            HStack(spacing: 10) {
                ProgressView(value: Double(model.capturedPhotos), total: Double(max(model.plannedPhotos, 1)))
                    .tint(CameraPalette.accent)
                Text("\(model.capturedPhotos)/\(model.plannedPhotos)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progressAccessibilityText)
        }
    }

    private var capturePanel: some View {
        VStack(spacing: 15) {
            VStack(spacing: 4) {
                Text(guidanceText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(model.capturedPhotos == 0
                     ? tr("Cadrez la scène, puis appuyez sur le déclencheur pour fixer la vue centrale.",
                          "Frame the scene, then tap the shutter to set the center view.")
                     : model.currentPass == 2 && !model.guidance.hasTarget
                     ? tr("Touchez une case de la carte pour choisir la vue à refaire.",
                          "Tap a cell in the view map to choose a shot to retake.")
                     : tr("La photo se prend automatiquement quand l’iPhone est stable.",
                          "A photo is taken automatically when the iPhone is steady."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !model.coverage.isEmpty {
                ScrollView(.vertical) {
                    CoverageGrid(cells: model.coverage, locale: locale, allowsRetake: model.remainingRetakes > 0) { id in
                        model.send(.retake(id))
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 125)
            }

            HStack(alignment: .center) {
                Button {
                    model.send(.finishPass)
                } label: {
                    Text(tr("Terminer", "Finish pass"))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 86, minHeight: 44)
                }
                .disabled(!model.canFinishPass)
                .accessibilityHint(tr("Affiche les prises avant assemblage", "Review shots before stitching"))

                Spacer()
                Button {
                    model.send(.capture)
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                        .padding(5)
                        .overlay {
                            Circle().strokeBorder(.white, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!model.canCapture)
                .opacity(model.canCapture ? 1 : 0.45)
                .accessibilityLabel(tr("Prendre la photo maintenant", "Take photo now"))

                Spacer()
                Text(model.currentPass == 1
                     ? "\(model.capturedPhotos)/\(model.maximumPhotos)"
                     : "\(model.refinementPhotos)/\(model.maximumRefinementPhotos)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 86)
                    .accessibilityLabel(limitAccessibilityText)
            }

            if let issue = model.issue {
                issueNotice(issue)
            } else if let banner = model.banner {
                Text(banner.text(for: locale))
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
    }

    private var guidanceText: String {
        if model.capturedPhotos == 0 && model.currentPass == 1 {
            return tr("Composez la vue centrale", "Compose the center view")
        }
        if !model.guidance.hasTarget && model.currentPass == 2 {
            return tr("Choisissez une vue à améliorer", "Choose a view to improve")
        }
        if model.guidance.isCapturing {
            return tr("Capture en cours…", "Taking photo…")
        }
        if model.guidance.isAligned && model.guidance.isStable {
            return tr("Ne bougez plus", "Hold steady")
        }
        if model.guidance.isAligned {
            return tr("Stabilisez l’iPhone", "Steady your iPhone")
        }
        return tr("Alignez les deux cercles", "Align the two circles")
    }

    private var progressAccessibilityText: String {
        locale.captureLanguageIsFrench
            ? "\(model.capturedPhotos) photos sur \(model.plannedPhotos) prises"
            : "\(model.capturedPhotos) of \(model.plannedPhotos) photos captured"
    }

    private var limitAccessibilityText: String {
        if model.currentPass == 1 {
            return locale.captureLanguageIsFrench
                ? "Limite de \(model.maximumPhotos) photos"
                : "Limit of \(model.maximumPhotos) photos"
        }
        return locale.captureLanguageIsFrench
            ? "\(model.refinementPhotos) reprises sur \(model.maximumRefinementPhotos)"
            : "\(model.refinementPhotos) of \(model.maximumRefinementPhotos) refinement shots"
    }

    private var passReviewScreen: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(alignment: .top, spacing: 18) {
                    passReviewCloseButton
                    Spacer()
                    ScrollView {
                        passReviewPanel
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 430)
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    HStack {
                        passReviewCloseButton
                        Spacer()
                    }
                    ScrollView {
                        passReviewPanel
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        passReviewCloseButton
                        Spacer()
                    }
                    Spacer()
                    passReviewPanel
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var passReviewCloseButton: some View {
        Button {
            showsDiscardConfirmation = true
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
    }

    private var passReviewPanel: some View {
        VStack(alignment: .leading, spacing: 17) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CameraPalette.accent)
                    .accessibilityHidden(true)
                Text(tr("Vues capturées", "Views captured"))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(passReviewDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let issue = model.issue {
                    issueNotice(issue)
                }

                if !model.coverage.isEmpty {
                    CoverageGrid(cells: model.coverage, locale: locale, allowsRetake: false) { id in
                        model.send(.retake(id))
                    }
                    .padding(.vertical, 8)
                }

                if model.canRefine {
                    Button {
                        model.send(.beginRefinementPass)
                    } label: {
                        Label(tr("Améliorer avec un second passage", "Improve with a second pass"), systemImage: "viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    model.send(.assemble)
                } label: {
                    Label(tr("Assembler l’image", "Stitch image"), systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var passReviewDescription: String {
        if model.currentPass == 1 {
            return tr(
                "Vous pouvez repasser sur les zones à améliorer, ou créer l’image maintenant.",
                "You can revisit areas that need more detail, or create the image now."
            )
        }
        return tr(
            "Le second passage est terminé. Vous pouvez créer votre image.",
            "The second pass is complete. You can create your image."
        )
    }

    private var processingScreen: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 5)
                    .frame(width: 108, height: 108)
                ProgressView()
                    .controlSize(.large)
                    .tint(CameraPalette.accent)
            }
            .accessibilityHidden(true)
            Text(tr("Création de votre image", "Creating your image"))
                .font(.title2.weight(.semibold))
            Text(tr("Assemblage des vues et harmonisation de la lumière…", "Stitching views and balancing the light…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let progress = model.processingProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(CameraPalette.accent)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(tr("Progression de l’assemblage", "Stitching progress"))
            }
            Spacer()
            if let issue = model.issue {
                issueNotice(issue)
            }
        }
        .padding(28)
    }

    private var reviewScreen: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        reviewHeader
                        reviewImage
                    }
                    .frame(maxWidth: .infinity)
                    ScrollView {
                        reviewPanel
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 350)
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    reviewHeader
                    reviewImage.frame(height: 160)
                    ScrollView {
                        reviewPanel
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                VStack(spacing: 0) {
                    reviewHeader
                    Spacer(minLength: 12)
                    reviewImage
                    Spacer(minLength: 12)
                    reviewPanel
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Nouvelle prise de vue", "New capture"))
            Spacer()
            Text(tr("APERÇU", "PREVIEW"))
                .font(.caption.weight(.bold))
                .tracking(1.7)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var reviewImage: some View {
        if let image = model.resultPreview {
            ZoomableReviewImage(image: image)
                .accessibilityLabel(tr("Aperçu de l’image assemblée", "Preview of stitched image"))
        } else {
            Image(systemName: "photo")
                .font(.system(size: 70, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tr("Votre photo", "Your photo"))
                            .font(.title2.weight(.semibold))
                        if let size = model.resultPixelSize {
                            Text("\(Int(size.width)) × \(Int(size.height)) px")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(model.selectedLens == .wide ? tr("Principal", "Main") : tr("Téléobjectif", "Telephoto"))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }

                if let issue = model.issue {
                    issueNotice(issue)
                } else if model.saveState == .saved {
                    Label(tr("Enregistrée dans Photos", "Saved to Photos"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }

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
                            Text(model.saveState == .saved
                                 ? tr("Enregistrée", "Saved")
                                 : tr("Enregistrer", "Save to Photos"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.resultURL == nil || model.saveState != .idle)

                    if let url = model.resultURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(tr("Partager l’image", "Share image"))
                    }
                }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var unavailableScreen: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(CameraPalette.accent)
                .frame(width: 104, height: 104)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
                .accessibilityHidden(true)
            Text(issueTitle(model.issue?.kind))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.issue?.detail?.text(for: locale) ?? tr(
                "Vérifiez les autorisations et réessayez.",
                "Check permissions and try again."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.phase == .permission {
                Button {
                    model.send(.openSettings)
                } label: {
                    Text(tr("Ouvrir Réglages", "Open Settings"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
            }
            if model.issue?.canRetry != false {
                Button {
                    model.send(.retry)
                } label: {
                    Group {
                        if model.isStarting {
                            ProgressView()
                        } else {
                            Text(tr("Réessayer", "Try again"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .disabled(model.isStarting)
            }
        }
        .padding(28)
    }

    private func issueNotice(_ issue: CaptureUIIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(issue.detail?.text(for: locale) ?? issueTitle(issue.kind))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if issue.canRetry {
                Button(tr("Réessayer", "Retry")) {
                    switch issue.kind {
                    case .saveFailure:
                        model.send(.saveToPhotos)
                    default:
                        model.send(.retry)
                    }
                }
                .font(.footnote.weight(.semibold))
            } else if case .photoLibraryPermission = issue.kind {
                Button(tr("Réglages", "Settings")) {
                    model.send(.openSettings)
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
    }

    private func issueTitle(_ kind: CaptureUIIssue.Kind?) -> String {
        switch kind {
        case .cameraPermission:
            tr("Accès à l’appareil photo", "Camera access")
        case .motionPermission:
            tr("Accès aux mouvements", "Motion access")
        case .cameraUnavailable:
            tr("Appareil photo indisponible", "Camera unavailable")
        case .captureFailure:
            tr("Prise de vue interrompue", "Capture interrupted")
        case .stitchingFailure:
            tr("Assemblage impossible", "Couldn’t stitch image")
        case .photoLibraryPermission:
            tr("Accès à Photos", "Photos access")
        case .saveFailure:
            tr("Enregistrement impossible", "Couldn’t save image")
        case nil:
            tr("Une erreur est survenue", "Something went wrong")
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(1.25)
            .foregroundStyle(.secondary)
    }

    private func tr(_ french: String, _ english: String) -> String {
        locale.captureLanguageIsFrench ? french : english
    }
}

private struct CaptureGuideReticle: View {
    var guidance: CaptureUIGuidance

    var body: some View {
        GeometryReader { geometry in
            let distance = min(geometry.size.width * 0.3, 115)
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.86), lineWidth: 2)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 5, height: 5)
                Circle()
                    .strokeBorder(guidance.isAligned ? CameraPalette.accent : .white.opacity(0.72), lineWidth: 3)
                    .background(Circle().fill(CameraPalette.accent.opacity(guidance.isAligned ? 0.22 : 0.06)))
                    .frame(width: 38, height: 38)
                    .offset(
                        x: min(max(guidance.horizontalOffset, -1), 1) * distance,
                        y: min(max(guidance.verticalOffset, -1), 1) * 76
                    )
                if guidance.isAligned && guidance.isStable {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(CameraPalette.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CoverageGrid: View {
    var cells: [CaptureUICoverageCell]
    var locale: Locale
    var allowsRetake: Bool
    var onRetake: (String) -> Void

    private var columnCount: Int {
        max(1, (cells.map(\.column).max() ?? 0) + 1)
    }

    private var orderedCells: [CaptureUICoverageCell] {
        cells.sorted {
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.column < $1.column
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columnCount), spacing: 7) {
            ForEach(orderedCells) { cell in
                Button {
                    onRetake(cell.id)
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(fillColor(for: cell.state))
                        .frame(height: 28)
                        .overlay {
                            if cell.state == .needsRetake {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!allowsRetake || (cell.state != .needsRetake && cell.state != .captured))
                .accessibilityLabel(accessibilityText(for: cell))
                .accessibilityHint(allowsRetake && (cell.state == .needsRetake || cell.state == .captured)
                    ? (locale.captureLanguageIsFrench ? "Touchez pour refaire cette vue" : "Tap to retake this view")
                    : "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locale.captureLanguageIsFrench ? "Carte des vues" : "View map")
    }

    private func fillColor(for state: CaptureUICoverageCell.State) -> Color {
        switch state {
        case .pending: .white.opacity(0.16)
        case .current: .white
        case .captured: CameraPalette.accent
        case .needsRetake: .orange
        }
    }

    private func accessibilityText(for cell: CaptureUICoverageCell) -> String {
        let status: String
        switch cell.state {
        case .pending: status = locale.captureLanguageIsFrench ? "à prendre" : "pending"
        case .current: status = locale.captureLanguageIsFrench ? "actuelle" : "current"
        case .captured: status = locale.captureLanguageIsFrench ? "capturée" : "captured"
        case .needsRetake: status = locale.captureLanguageIsFrench ? "à refaire" : "needs retake"
        }
        return locale.captureLanguageIsFrench
            ? "Vue ligne \(cell.row + 1), colonne \(cell.column + 1), \(status)"
            : "View row \(cell.row + 1), column \(cell.column + 1), \(status)"
    }
}

private struct ZoomableReviewImage: View {
    var image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value.magnification, 1), 5)
                            offset = clamped(offset, in: geometry.size)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            lastOffset = offset
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = clamped(
                                CGSize(width: lastOffset.width + value.translation.width,
                                       height: lastOffset.height + value.translation.height),
                                in: geometry.size
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                        lastScale = scale
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                .clipped()
        }
    }

    private func clamped(_ value: CGSize, in container: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(container.width / image.size.width,
                      container.height / image.size.height)
        let xLimit = max(0, (image.size.width * fit * scale - container.width) / 2)
        let yLimit = max(0, (image.size.height * fit * scale - container.height) / 2)
        return CGSize(width: min(max(value.width, -xLimit), xLimit),
                      height: min(max(value.height, -yLimit), yLimit))
    }
}
