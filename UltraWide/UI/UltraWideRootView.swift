import AVFoundation
import SwiftUI

private enum CameraPalette {
    static let accent = Color(red: 1.0, green: 0.73, blue: 0.16)
    static let surface = Color.black.opacity(0.46)
}

struct UltraWideRootView: View {
    @Bindable var model: CaptureUIModel
    @Environment(\.locale) private var locale
    @State private var showsDiscardConfirmation = false
    @State private var didPrepare = false

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
        if let session = model.previewSession,
           model.phase == .setup || model.phase == .capturing || model.phase == .reanchor || model.phase == .passReview {
            CameraPreviewView(session: session, rotationAngle: model.previewRotationAngle)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.54), .clear, .black.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
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
            if model.phase == .setup && !model.hasActiveSession && showsCameraOptions {
                cameraOptions.padding(.top, 14)
            }
            HStack {
                Spacer(minLength: 0)
                fieldIndicator(isLandscape: false)
                    .frame(width: min(176, availableWidth * 0.45))
            }
            .padding(.top, 18)
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
                fieldIndicator(isLandscape: true)
                    .frame(width: 240)
                Spacer(minLength: 10)
                VStack(spacing: 12) {
                    if model.phase == .setup && !model.hasActiveSession && showsCameraOptions {
                        cameraOptions
                    }
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
                        .background(CameraPalette.surface, in: Circle())
                }
                .accessibilityLabel(tr("Annuler la prise de vue", "Cancel capture"))
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 20, weight: .light))
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            Spacer()
            Text(model.selectedTarget.magnification(for: locale))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(CameraPalette.surface, in: Capsule())
                .accessibilityLabel(tr("Champ final", "Final field of view") + " " + model.selectedTarget.magnification(for: locale))
        }
        .buttonStyle(.plain)
    }

    private var showsCameraOptions: Bool {
        model.availableLenses.count > 1 || model.availableTargets.count > 1
    }

    private var cameraOptions: some View {
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
                                .background(model.selectedLens == lens ? CameraPalette.accent : .white.opacity(0.13), in: Capsule())
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
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(model.selectedTarget == target ? CameraPalette.accent : .white)
                                .background(.black.opacity(0.42), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .strokeBorder(model.selectedTarget == target ? CameraPalette.accent : .clear, lineWidth: 1.5)
                                }
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
            CoverageMap(sweep: model.sweep, locale: locale)
                .aspectRatio(isLandscape ? 4.0 / 3.0 : 3.0 / 4.0, contentMode: .fit)
            Text(fieldHint)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .background(CameraPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var fieldHint: String {
        if model.sweep.isFinishing { return tr("Terminé", "Finishing") }
        if model.phase == .setup {
            return model.hasActiveSession
                ? tr("Reprendre", "Resume")
                : tr("Pointez le centre", "Point at the center")
        }
        if model.sweep.isComplete { return tr("Couverture complète", "Coverage complete") }
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
                .background(CameraPalette.surface, in: Capsule())
                .frame(maxWidth: 350)
        } else if model.phase == .setup && model.previewSession == nil
                    && !model.hasActiveSession && !model.isStarting {
            Button(tr("Réactiver l’appareil photo", "Restart camera")) {
                model.send(.retry)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(CameraPalette.surface, in: Capsule())
        }
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
            .buttonStyle(.borderedProminent)
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
        HStack(spacing: 12) {
            Button(tr("Continuer", "Continue")) {
                model.send(.startSweep)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if model.sweep.isComplete {
                Button(model.issue == nil
                       ? tr("Assembler", "Stitch")
                       : tr("Réessayer", "Try again")) {
                    model.send(.assemble)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var processingScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(CameraPalette.accent)
            Text(tr("Assemblage…", "Stitching…"))
                .font(.headline)
            if let progress = model.processingProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(CameraPalette.accent)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(tr("Progression de l’assemblage", "Stitching progress"))
            }
            Spacer()
        }
        .padding(24)
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
                    .background(CameraPalette.surface, in: Circle())
            }
            .accessibilityLabel(tr("Nouvelle prise de vue", "New capture"))
            Spacer()
            Text(tr("Aperçu", "Preview"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reviewImage: some View {
        if let image = model.resultPreview {
            ZoomableReviewImage(image: image)
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
            if let issue = model.issue {
                issueNotice(issue)
            } else if model.saveState == .saved {
                Label(tr("Enregistrée dans Photos", "Saved to Photos"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(CameraPalette.accent)
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
                        Text(model.saveState == .saved ? tr("Enregistrée", "Saved") : tr("Enregistrer", "Save"))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.resultURL == nil || model.saveState != .idle)
                if let url = model.resultURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(tr("Partager l’image", "Share image"))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(CameraPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var unavailableScreen: some View {
        VStack(spacing: 18) {
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if model.issue?.canRetry != false {
                Button(tr("Réessayer", "Try again")) {
                    model.send(.retry)
                }
                .buttonStyle(.bordered)
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
                .background(CameraPalette.surface, in: Circle())
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

/// The filled area records actual camera footprints. The small amber frame is
/// the camera's current field of view, positioned inside the final image.
private struct CoverageMap: View {
    var sweep: CaptureUISweep
    var locale: Locale

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let bounds = CGRect(x: inset, y: inset,
                                width: max(0, size.width - 2 * inset),
                                height: max(0, size.height - 2 * inset))
            let outside = Path(roundedRect: bounds, cornerRadius: 18)
            context.fill(outside, with: .color(.white.opacity(0.06)))

            var inside = context
            inside.clip(to: outside)
            var covered = Path()
            for rect in sweep.coveredRects {
                let painted = mapped(rect, in: bounds)
                covered.addPath(Path(roundedRect: painted, cornerRadius: 7))
            }
            inside.fill(covered, with: .color(CameraPalette.accent.opacity(0.38)))
            context.stroke(outside, with: .color(.white.opacity(0.86)), lineWidth: 1.7)

            let lens = Path(roundedRect: mapped(sweep.viewRect, in: bounds), cornerRadius: 10)
            context.fill(lens, with: .color(CameraPalette.accent.opacity(0.20)))
            context.stroke(lens, with: .color(CameraPalette.accent), lineWidth: 2.6)
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
