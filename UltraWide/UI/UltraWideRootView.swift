import SwiftUI
import UIKit

struct UltraWideRootView: View {
    @Bindable var model: CaptureUIModel
    @AppStorage(AppPreferences.gridKey) private var showsGrid = false
    @AppStorage(AppPreferences.hapticsKey) private var hapticsEnabled = true
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showsSettings = false
    @State private var showsDiscardConfirmation = false
    @State private var didPrepare = false
    @State private var showsExposureControl = false
    @State private var visibleBlockReason: SweepCaptureBlockReason?

    /// On iPhone, only landscape has a compact height.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { background }
                .navigationTitle(model.phase == .review ? Text("Preview") : Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsSettings) {
            AppSettingsView(model: model)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog("Discard this capture?", isPresented: $showsDiscardConfirmation,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.send(.discard) }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Unsaved photos will be deleted.")
        }
        .sensoryFeedback(.success, trigger: model.phase) { _, phase in
            hapticsEnabled && phase == .review
        }
        .sensoryFeedback(.success, trigger: model.saveState) { _, state in
            hapticsEnabled && state == .saved
        }
        .sensoryFeedback(.selection, trigger: model.coverageFeedbackCount) { _, _ in hapticsEnabled }
        .onAppear {
            guard !didPrepare else { return }
            didPrepare = true
            model.send(.prepare)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-settings-preview") { showsSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-ui-exposure-preview") { showsExposureControl = true }
            if ProcessInfo.processInfo.arguments.contains("-ui-landscape"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
#endif
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { _ in
            // A rotation before the shutter tap needs a plan in the new orientation.
            if scenePhase == .active && model.phase == .setup { model.send(.prepare) }
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
    private var screen: some View {
        switch model.phase {
        case .setup, .capturing: sweepScreen
        case .reanchor: reanchorScreen
        case .passReview: interruptedScreen
        case .processing: processingScreen
        case .review: reviewScreen
        case .permission, .unavailable: unavailableScreen
        }
    }

    @ViewBuilder
    private var background: some View {
        if let session = model.previewSession,
           [.setup, .capturing, .reanchor, .passReview].contains(model.phase) {
            CameraPreviewView(session: session, rotationAngle: model.previewRotationAngle,
                allowsMetering: model.canAdjustCamera && !model.isStarting,
                onMeteringPoint: { model.send(.setMeteringPoint($0)) })
                .overlay {
                    if showsGrid {
                        CompositionGrid()
                            .stroke(.white.opacity(0.35), lineWidth: 0.5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    // Keeps the status bar and controls legible over bright scenes.
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
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: - Toolbar

    private enum ToolbarMode {
        case camera, cancel, review, settings
    }

    private var toolbarMode: ToolbarMode? {
        switch model.phase {
        case .review: .review
        case .permission, .unavailable: .settings
        // Assembly itself cannot be interrupted from the interface.
        case .processing: nil
        case .reanchor, .passReview: .cancel
        case .setup, .capturing: model.hasActiveSession ? .cancel : .camera
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let mode = toolbarMode {
            switch mode {
            case .camera: cameraToolbar
            case .cancel: cancelToolbar
            case .review: reviewToolbar
            case .settings: settingsToolbar
            }
        }
    }

    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            settingsButton.disabled(model.isStarting)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Toggle(isOn: $showsExposureControl) {
                Label("Adjust Exposure",
                      systemImage: model.exposureBias == 0 ? "plusminus.circle" : "plusminus.circle.fill")
            }
            .disabled(!model.canAdjustCamera || model.isStarting)
            lightingMenu
        }
    }

    private var cancelToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel Capture", systemImage: "xmark", role: .close) {
                showsDiscardConfirmation = true
            }
        }
    }

    @ToolbarContentBuilder
    private var reviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("New Capture", systemImage: "xmark", role: .close) {
                if model.saveState == .saved || model.resultURL == nil {
                    model.send(.discard)
                } else {
                    showsDiscardConfirmation = true
                }
            }
        }
        settingsToolbar
    }

    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { settingsButton }
    }

    private var settingsButton: some View {
        Button("App Settings", systemImage: "gearshape") {
            showsExposureControl = false
            showsSettings = true
        }
        .accessibilityIdentifier("appSettings")
    }

    private var lightingMenu: some View {
        Menu {
            Picker("Anti-Flicker", selection: Binding(
                get: { model.selectedLighting },
                set: { model.send(.selectLighting($0)) }
            )) {
                ForEach(CaptureLighting.allCases) { lighting in
                    Text(lighting.title).tag(lighting)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // A filled bulb marks a manual mains frequency, like the filled
            // exposure symbol marks a manual correction.
            Label("Lighting", systemImage: model.selectedLighting == .automatic ? "lightbulb" : "lightbulb.fill")
        }
        .disabled(model.hasActiveSession || model.isStarting || model.phase == .capturing)
        .accessibilityValue(Text(model.selectedLighting.title))
        .accessibilityHint("Reduces flicker under artificial lighting.")
    }

    // MARK: - Camera

    private var sweepScreen: some View {
        Group {
            if isLandscape {
                landscapeSweepScreen
            } else {
                portraitSweepScreen
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var portraitSweepScreen: some View {
        VStack(spacing: 0) {
            if showsExposureControl && model.canAdjustCamera {
                exposureControl.padding(.bottom, 12)
            }
            if showsCameraOptions { cameraOptions }
            if showsFieldIndicator {
                fieldIndicator(isLandscape: false)
                    .frame(maxWidth: 176)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 18)
            }
            Spacer(minLength: 16)
            captureMessages
            shutterControls
                .padding(.top, 14)
        }
    }

    private var landscapeSweepScreen: some View {
        HStack(alignment: .center, spacing: 20) {
            if showsFieldIndicator {
                fieldIndicator(isLandscape: true)
                    .frame(maxWidth: 240)
            }
            Spacer(minLength: 10)
            VStack(spacing: 12) {
                if showsCameraOptions { cameraOptions }
                if showsExposureControl && model.canAdjustCamera { exposureControl }
                Spacer(minLength: 0)
                captureMessages
                shutterControls
            }
            .frame(maxWidth: 300)
        }
    }

    private var showsCameraOptions: Bool {
        model.phase == .setup && !model.hasActiveSession
            && (model.availableLenses.count > 1 || model.availableTargets.count > 1)
    }

    private var showsFieldIndicator: Bool {
        !model.isSinglePhoto || model.hasActiveSession
    }

    private var exposureControl: some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { model.exposureBias },
                                  set: { model.send(.setExposureBias($0)) }),
                   in: -2...2, step: 0.1) {
                Text("Exposure Compensation")
            } minimumValueLabel: {
                Image(systemName: "sun.min")
            } maximumValueLabel: {
                Image(systemName: "sun.max")
            }
            .accessibilityValue(Text("\(model.exposureBias, format: Self.exposureFormat) EV"))
            Text(model.exposureBias, format: Self.exposureFormat)
                .font(.caption.monospacedDigit().weight(.medium))
                .accessibilityHidden(true)
            Button("Reset Exposure", systemImage: "arrow.counterclockwise") {
                model.send(.setExposureBias(0))
            }
            .labelStyle(.iconOnly)
            .disabled(model.exposureBias == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .cameraGlass(in: .capsule)
        .disabled(model.isStarting)
    }

    private static let exposureFormat = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(1)).sign(strategy: .always())

    private var cameraOptions: some View {
        VStack(spacing: 8) {
            if model.availableLenses.count > 1 {
                Picker("Lens", selection: Binding(get: { model.selectedLens },
                                                  set: { model.send(.selectLens($0)) })) {
                    ForEach(model.availableLenses) { lens in
                        Text(lens.title).tag(lens)
                    }
                }
            }
            if model.availableTargets.count > 1 {
                Picker("Framing", selection: Binding(get: { model.selectedTarget },
                                                     set: { model.send(.selectTarget($0)) })) {
                    ForEach(model.availableTargets) { target in
                        Text(verbatim: target.title).tag(target)
                    }
                }
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isStarting)
        .padding(6)
        .cameraGlass(in: .rect(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: 320)
    }

    private func fieldIndicator(isLandscape: Bool) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack {
                    Text("Final Frame")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.phase == .capturing {
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                Group {
                    if model.isSinglePhoto && !model.hasActiveSession {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.tint, lineWidth: 2)
                            .overlay {
                                Image(systemName: "camera")
                                    .font(.title.weight(.light))
                                    .foregroundStyle(.secondary)
                            }
                    } else {
                        CoverageMap(sweep: model.sweep)
                    }
                }
                .aspectRatio(isLandscape ? 4.0 / 3.0 : 3.0 / 4.0, contentMode: .fit)
            }
            // Taps outside the resume button reach the camera for metering.
            .allowsHitTesting(false)
            if model.phase == .setup && model.hasRecoverableSession {
                Button("Resume Sweep") {
                    model.send(.resume)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.isStarting)
            } else {
                Text(fieldHint)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsHitTesting(false)
            }
        }
        .padding()
        .cameraGlass(in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var fieldHint: LocalizedStringResource {
        if model.sweep.isFinishing {
            return model.sweep.isVerifyingAlignment ? "Checking…" : "Finishing…"
        }
        if model.phase == .setup {
            return model.hasActiveSession ? "Resume"
                : model.isSinglePhoto ? "Ready to Capture" : "Point at the Center"
        }
        if model.sweep.isComplete { return "Coverage Complete" }
        if model.phase == .passReview {
            return model.sweep.capturedField != nil ? "Captured Field Available" : "Fill the Frame"
        }
        if model.phase == .capturing, model.sweep.guidanceDirection != nil {
            return "Fill the Frame"
        }
        if model.sweep.isVerifyingAlignment && model.phase != .capturing {
            return "Checking…"
        }
        return "Sweep Freely"
    }

    @ViewBuilder
    private var captureMessages: some View {
        if let issue = model.issue {
            issueNotice(issue)
                .frame(maxWidth: 350)
        } else if let banner = model.banner {
            Text(banner)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .cameraGlass(in: .rect(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: 350)
        } else if model.phase == .capturing && !model.sweep.isFinishing {
            HStack(spacing: 10) {
                if visibleBlockReason == nil, let vector = model.sweep.guidanceDirection,
                   hypot(vector.dx, vector.dy) > 0.03 {
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.semibold))
                        .rotationEffect(.radians(atan2(vector.dx, -vector.dy)))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Text(visibleBlockReason.map(blockMessage) ?? directionMessage)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .cameraGlass(in: .capsule)
            .frame(maxWidth: 350)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else if model.phase == .setup && model.previewSession == nil
                    && !model.hasActiveSession && !model.isStarting {
            Button("Restart Camera") {
                model.send(.retry)
            }
            .buttonStyle(.glass)
        }
    }

    private func blockMessage(_ reason: SweepCaptureBlockReason) -> LocalizedStringResource {
        switch reason {
        case .tooFast: "Move a little more slowly"
        case .tooDark: "This area is too dark"
        case .awaitingCamera: "Waiting for a camera image…"
        case .writing: "Saving images…"
        case .insufficientDetail: "Aim at an area with more detail"
        case .alignmentFailed: "These views can’t be aligned. Return toward an area already captured."
        }
    }

    private var directionMessage: LocalizedStringResource {
        guard let vector = model.sweep.guidanceDirection, hypot(vector.dx, vector.dy) > 0.03 else {
            return model.sweep.isVerifyingAlignment ? "Checking images…" : "Sweep to fill the frame"
        }
        if abs(vector.dx) > abs(vector.dy) * 2.4 {
            return vector.dx > 0 ? "Move right" : "Move left"
        }
        if abs(vector.dy) > abs(vector.dx) * 2.4 {
            return vector.dy > 0 ? "Move down" : "Move up"
        }
        if vector.dy < 0 {
            return vector.dx < 0 ? "Move up and left" : "Move up and right"
        }
        return vector.dx < 0 ? "Move down and left" : "Move down and right"
    }

    /// The shutter is app-specific: it starts, stops or resumes a sweep.
    private var shutterControls: some View {
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
                        .tint(.accentColor)
                } else if model.phase == .capturing {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.tint)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                }
            }
            .frame(width: 92, height: 92)
            .contentShape(.circle)
            .cameraGlass(in: .circle, isInteractive: !shutterDisabled)
        }
        .buttonStyle(.plain)
        .disabled(shutterDisabled)
        .opacity(shutterDisabled ? 0.5 : 1)
        .accessibilityLabel(shutterAccessibilityLabel)
        .frame(maxWidth: .infinity)
    }

    private var shutterDisabled: Bool {
        if model.phase == .capturing { return model.sweep.isFinishing }
        if model.hasRecoverableSession { return model.isStarting }
        return model.previewSession == nil || model.availableTargets.isEmpty || model.isStarting
    }

    private var shutterAccessibilityLabel: Text {
        if model.phase == .capturing { return Text("Stop Sweep") }
        if model.hasActiveSession { return Text("Resume Sweep") }
        if model.isSinglePhoto { return Text("Take Photo") }
        return Text("Start Sweep")
    }

    // MARK: - Interrupted sweep

    private var reanchorScreen: some View {
        Group {
            if isLandscape {
                HStack(spacing: 20) {
                    reanchorReference
                        .frame(maxWidth: .infinity)
                    reanchorActions
                        .frame(maxWidth: 300)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    reanchorReference
                        .frame(maxWidth: 290, maxHeight: 330)
                    reanchorActions
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20)
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
                        .strokeBorder(.tint, lineWidth: 2)
                }
                .accessibilityLabel("Reference View")
        }
    }

    private var reanchorActions: some View {
        VStack(spacing: 16) {
            Text("Align the Center View")
                .font(.headline)
            if let issue = model.issue { issueNotice(issue) }
            Button("Continue") {
                model.send(.confirmReanchor)
            }
            .foregroundStyle(.black)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.isStarting)
        }
    }

    private var interruptedScreen: some View {
        Group {
            if isLandscape {
                HStack(spacing: 24) {
                    fieldIndicator(isLandscape: true)
                        .frame(maxWidth: 215)
                    VStack(spacing: 16) {
                        if let issue = model.issue { issueNotice(issue) }
                        interruptedActions
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    fieldIndicator(isLandscape: false)
                        .frame(maxWidth: 240)
                    if let issue = model.issue { issueNotice(issue) }
                    interruptedActions
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20)
    }

    private var interruptedActions: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 12) {
                Button("Continue") {
                    model.send(.startSweep)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                if model.sweep.isComplete {
                    Button(model.issue == nil ? "Stitch" : "Try Again") {
                        model.send(.assemble)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else if model.sweep.capturedField != nil {
                    Button("Use Captured Field") {
                        model.send(.useCapturedField)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Text("A slightly smaller frame, with no missing areas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Assembly

    private var processingScreen: some View {
        Group {
            if model.sweep.previewImage == nil {
                processingStatus
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
                        .frame(maxWidth: 390)
                    processingStatus
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var assemblyPreview: some View {
        if let image = model.sweep.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("Preview of the image being assembled")
        }
    }

    @ViewBuilder
    private var processingStatus: some View {
        let title: LocalizedStringResource = model.sweep.previewImage != nil ? "Finishing…" : "Stitching…"
        if let progress = model.processingProgress {
            let fraction = min(max(progress, 0), 1)
            ProgressView(value: fraction) {
                Text(title).font(.headline)
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
            .frame(maxWidth: 240)
        } else {
            ProgressView {
                Text(title).font(.headline)
            }
            .controlSize(.large)
        }
    }

    // MARK: - Result

    private var reviewScreen: some View {
        Group {
            if isLandscape {
                HStack(spacing: 16) {
                    reviewImage
                        .frame(maxWidth: .infinity)
                    reviewActions
                        .frame(maxWidth: 310)
                }
            } else {
                VStack(spacing: 12) {
                    reviewImage
                    reviewActions
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var reviewImage: some View {
        if let image = model.resultPreview {
            ZoomableReviewImage(preview: image, url: model.resultURL, pixelSize: model.resultPixelSize)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle.weight(.ultraLight))
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    private var reviewActions: some View {
        VStack(spacing: 14) {
            if let size = model.resultPixelSize {
                Text(verbatim: "\(Int(size.width).formatted()) × \(Int(size.height).formatted()) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.resultWasCropped, let magnification = model.resultMagnification {
                Text("Captured field · \(magnification.formatted(.number.precision(.fractionLength(2))))×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.saveState == .idle {
                    Button("Continue Sweeping") { model.send(.continueAfterCrop) }
                        .buttonStyle(.glass)
                }
            }
            if let issue = model.issue {
                issueNotice(issue)
            } else if model.saveState == .saved {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        model.send(.saveToPhotos)
                    } label: {
                        Group {
                            if model.saveState == .saving {
                                ProgressView()
                                    .tint(.black)
                            } else if model.saveState == .saved {
                                Label("Saved", systemImage: "checkmark")
                            } else {
                                Label("Save", systemImage: "square.and.arrow.down")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .disabled(model.resultURL == nil || model.saveState != .idle)
                    if let url = model.resultURL {
                        ShareLink(item: url) {
                            Label("Share Image", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .font(.headline)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    }
                }
                .controlSize(.extraLarge)
            }
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Issues

    private var unavailableScreen: some View {
        ContentUnavailableView {
            Label {
                Text(issueTitle(model.issue?.kind))
            } icon: {
                Image(systemName: model.phase == .permission ? "camera.badge.ellipsis" : "camera.fill")
                    .foregroundStyle(.tint)
            }
        } description: {
            if let detail = model.issue?.detail {
                Text(detail)
            } else {
                Text("Try again.")
            }
        } actions: {
            if model.phase == .permission {
                Button("Open Settings") { openAppSettings() }
                    .foregroundStyle(.black)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            if model.issue?.canRetry != false {
                Button("Try Again") { model.send(.retry) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isStarting)
            }
        }
    }

    private func issueNotice(_ issue: CaptureUIIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Group {
                if let detail = issue.detail {
                    Text(detail)
                } else {
                    Text(issueTitle(issue.kind))
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            if issue.canRetry {
                Button("Retry") {
                    model.send(issue.kind == .saveFailure ? .saveToPhotos : .retry)
                }
                .font(.footnote.weight(.semibold))
            } else if issue.kind == .photoLibraryPermission {
                Button("Settings") { openAppSettings() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .cameraGlass(in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func issueTitle(_ kind: CaptureUIIssue.Kind?) -> LocalizedStringResource {
        switch kind {
        case .cameraPermission: "Camera Access"
        case .motionPermission: "Motion Access"
        case .cameraUnavailable: "Camera Unavailable"
        case .captureFailure: "Capture Interrupted"
        case .stitchingFailure: "Couldn’t Stitch Image"
        case .photoLibraryPermission: "Photos Access"
        case .saveFailure: "Couldn’t Save Image"
        case nil: "Something Went Wrong"
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private extension View {
    /// Floating camera controls use native Liquid Glass, slightly darkened for
    /// legibility over bright scenes. The system adapts it to Reduce
    /// Transparency and Increase Contrast.
    func cameraGlass(in shape: some Shape, isInteractive: Bool = false) -> some View {
        glassEffect(.regular.tint(.black.opacity(0.16)).interactive(isInteractive), in: shape)
    }
}

#Preview("Capture frame") {
    let model = CaptureUIModel()
    model.phase = .capturing
    model.hasActiveSession = true
    model.sweep = CaptureUISweep(
        viewRect: CGRect(x: 0.48, y: 0.11, width: 0.42, height: 0.48),
        coveredPolygons: [
            [CGPoint(x: 0.28, y: 0.25), CGPoint(x: 0.73, y: 0.25),
             CGPoint(x: 0.73, y: 0.73), CGPoint(x: 0.28, y: 0.73)]
        ],
        coverageFraction: 0.62,
        isRecording: true
    )
    return UltraWideRootView(model: model)
}

/// Aligned image footprints cover the progressive photo. The accent frame
/// guides the current camera position without counting it as verified coverage.
private struct CoverageMap: View {
    var sweep: CaptureUISweep

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
            for polygon in sweep.coveredPolygons where polygon.count >= 3 {
                covered.move(to: mapped(polygon[0], in: bounds))
                for point in polygon.dropFirst() {
                    covered.addLine(to: mapped(point, in: bounds))
                }
                covered.closeSubpath()
            }
            let accent = Color.accentColor
            inside.fill(covered, with: .color(accent.opacity(sweep.previewImage == nil ? 0.38 : 0.08)))
            context.stroke(outside, with: .color(.white.opacity(0.86)), lineWidth: 1.7)

            let lens = Path(roundedRect: mapped(sweep.viewRect, in: bounds), cornerRadius: cornerRadius)
            inside.fill(lens, with: .color(accent.opacity(sweep.previewImage == nil ? 0.20 : 0.06)))
            context.stroke(lens, with: .color(accent), lineWidth: 2.6)
            if !sweep.isRecording, let crop = sweep.capturedField {
                inside.stroke(Path(roundedRect: mapped(crop, in: bounds), cornerRadius: cornerRadius),
                    with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Final frame coverage")
        .accessibilityValue(Text(coverageValue, format: .percent.precision(.fractionLength(0))))
    }

    /// Never announce 100% before the verified coverage is actually complete.
    private var coverageValue: Double {
        if sweep.isComplete { return 1 }
        return min(0.99, (min(max(sweep.coverageFraction, 0), 1) * 100).rounded() / 100)
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
