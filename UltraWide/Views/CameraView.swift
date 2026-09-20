import SwiftUI

struct CameraView: View {
    @EnvironmentObject private var model: CaptureModel
    @EnvironmentObject private var library: PanoramaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenGuide") private var hasSeenGuide = false
    @State private var showGuide = false
    @State private var showLibrary = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 740
            VStack(spacing: compact ? 15 : 22) {
                header
                viewfinder
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 29))
                    .overlay(RoundedRectangle(cornerRadius: 29).stroke(.white.opacity(0.12), lineWidth: 1))
                if model.phase == .capturing { captureGuidance }
                else { sweepSelector }
                controls
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                    Text(model.isDemo ? "DÉMONSTRATION · IMAGES SIMULÉES" : "PLUSIEURS PHOTOS. UNE NOUVELLE PERSPECTIVE.")
                }.font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.1)
                    .foregroundStyle(Palette.secondary).padding(.bottom, 3)
            }
            .padding(.horizontal, 22).padding(.top, 10)
        }
        .background(Palette.background).foregroundStyle(Palette.cream)
        .task {
            await model.prepare()
            if !hasSeenGuide && !ProcessInfo.processInfo.arguments.contains("--uitesting") { showGuide = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.prepare() } }
            else if phase == .background { model.suspend() }
        }
        .sheet(isPresented: $showGuide, onDismiss: { hasSeenGuide = true }) { GuideView() }
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .sheet(item: $model.result) { result in ResultView(result: result) }
        .alert("Capture impossible", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Compris", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .overlay { if model.phase == .assembling { processingOverlay } }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 1) {
                    Text("ultra").font(.system(size: 29, weight: .light))
                    Text("wide").font(.system(size: 29, weight: .semibold))
                    Circle().fill(Palette.mint).frame(width: 6, height: 6).padding(.leading, 3).offset(y: 7)
                }.tracking(-1.5).accessibilityLabel("Ultra Wide")
                Eyebrow(text: "Voyez au-delà du cadre")
            }
            Spacer()
            RoundButton(symbol: "questionmark", label: "Guide de prise de vue") { showGuide = true }
                .disabled(model.isBusy)
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                if model.isDemo {
                    Image(uiImage: DemoScene.image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if model.phase != .denied && model.phase != .unavailable {
                    CameraPreview(session: model.camera.session)
                } else { Palette.surface }

                if model.phase == .denied || model.phase == .unavailable {
                    unavailableState
                } else {
                    LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    grid.opacity(0.35)
                    VStack {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.mint).frame(width: 5, height: 5)
                            Text(model.isDemo ? "DÉMO" : model.phase == .capturing ? "CAPTURE" : "PRÊT À EXPLORER")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.3)
                            Spacer()
                            Image(systemName: "viewfinder").font(.system(size: 14))
                            Text("\(Int(model.targetDegrees))°").font(.system(size: 12, design: .monospaced))
                        }.padding(18)
                        Spacer()
                        horizon
                        Spacer()
                        VStack(spacing: 13) {
                            if model.phase != .capturing {
                                Text("Un petit mouvement.\nUne grande perspective.")
                                    .font(.system(size: 26, weight: .light, design: .serif))
                                    .multilineTextAlignment(.center).lineSpacing(2).shadow(radius: 10)
                            } else {
                                Label("\(model.frameCount) photos", systemImage: "square.stack.3d.up")
                                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                            }
                            lensSelector
                        }.padding(.bottom, 23)
                    }
                    if model.phase == .loading { ProgressView().tint(Palette.mint) }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Viseur de l’appareil photo")
    }

    private var grid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    let x = geometry.size.width * fraction, y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }.stroke(.white.opacity(0.45), lineWidth: 0.5)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var horizon: some View {
        HStack(spacing: 9) {
            Capsule().fill(.white.opacity(0.65)).frame(width: 30, height: 1)
            RoundedRectangle(cornerRadius: 3).stroke(Palette.mint, lineWidth: 1.3).frame(width: 22, height: 10)
            Capsule().fill(.white.opacity(0.65)).frame(width: 30, height: 1)
        }.rotationEffect(.degrees(-model.reading.roll)).accessibilityHidden(true)
    }

    private var lensSelector: some View {
        HStack(spacing: 4) {
            ForEach(model.lenses) { lens in
                Button { Task { await model.chooseLens(lens) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: lens.isTelephoto ? "camera.macro" : "camera.aperture")
                        Text(lens.name)
                    }.font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .foregroundStyle(model.selectedLens == lens ? Palette.background : .white)
                        .background(model.selectedLens == lens ? Palette.mint : .clear, in: Capsule())
                }.disabled(model.isBusy)
                    .accessibilityAddTraits(model.selectedLens == lens ? .isSelected : [])
            }
        }.padding(4).background(.black.opacity(0.45), in: Capsule())
    }

    private var sweepSelector: some View {
        VStack(spacing: 13) {
            HStack {
                Eyebrow(text: "Amplitude du mouvement")
                Spacer()
                Text("\(Int(model.targetDegrees))°").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.mint)
            }
            HStack(spacing: 4) {
                ForEach(SweepSize.allCases) { size in
                    Button { model.sweepSize = size } label: {
                        Text(size.title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(model.sweepSize == size ? Palette.cream : Palette.secondary)
                            .background(model.sweepSize == size ? .white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.sweepSize == size ? .white.opacity(0.13) : .clear, lineWidth: 1))
                    }.accessibilityAddTraits(model.sweepSize == size ? .isSelected : [])
                }
            }.padding(4).background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                .disabled(model.isBusy)
        }
    }

    private var captureGuidance: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.guidance).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer()
                Text("\(Int(model.progress * 100)) %").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.mint)
            }
            ProgressView(value: model.progress).tint(Palette.mint)
            Text("Pivotez autour de l’objectif, sans vous déplacer.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.frame(height: 78).accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack {
            VStack(spacing: 7) {
                RoundButton(symbol: model.phase == .capturing ? "xmark" : "square.stack", label: model.phase == .capturing ? "Annuler la capture" : "Ouvrir la galerie") {
                    if model.phase == .capturing { model.cancel() } else { showLibrary = true }
                }.accessibilityIdentifier("galleryButton")
                Text(model.phase == .capturing ? "Annuler" : "Galerie").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.frame(maxWidth: .infinity)
            Button {
                if model.phase == .capturing { model.finish() } else { model.start() }
            } label: {
                ZStack {
                    Circle().stroke(Palette.mint.opacity(0.4), lineWidth: 1).frame(width: 82, height: 82)
                    Circle().fill(Palette.mint).frame(width: 68, height: 68)
                    if model.phase == .capturing {
                        RoundedRectangle(cornerRadius: 5).fill(Palette.background).frame(width: 23, height: 23)
                    } else {
                        Image(systemName: "camera.aperture").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Palette.background)
                    }
                }
            }.disabled(model.phase != .ready && !(model.phase == .capturing && model.canFinish))
                .opacity(model.phase == .ready || model.phase == .capturing ? 1 : 0.35)
                .accessibilityLabel(model.phase == .capturing ? "Terminer la capture" : "Commencer la capture")
                .accessibilityIdentifier("captureButton")
                .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right").font(.system(size: 21, weight: .light)).frame(height: 38)
                Text(model.phase == .capturing ? "Pivotez" : "Puis pivotez").font(.system(size: 10))
            }.foregroundStyle(Palette.secondary).frame(maxWidth: .infinity).accessibilityHidden(true)
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill").font(.system(size: 38, weight: .light)).foregroundStyle(Palette.mint)
            Text(model.phase == .denied ? "Ouvrez une nouvelle perspective." : "L’appareil photo est indisponible.")
                .font(.system(size: 25, weight: .light, design: .serif)).multilineTextAlignment(.center)
            Text(model.phase == .denied ? "Autorisez l’appareil photo dans Réglages pour commencer." : "Vérifiez que l’appareil photo n’est pas utilisé, puis réessayez.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            PrimaryButton(title: model.phase == .denied ? "Ouvrir Réglages" : "Réessayer", symbol: "arrow.up.right") {
                if model.phase == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                else { Task { await model.prepare() } }
            }
        }.padding(28)
    }

    private var processingOverlay: some View {
        ZStack {
            Palette.background.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Palette.mint)
                Eyebrow(text: "La vue prend forme")
                Text("Assemblage des\nperspectives.").font(.system(size: 37, weight: .light, design: .serif)).multilineTextAlignment(.center)
                ProgressView(value: model.progress).tint(Palette.mint).frame(width: 200)
                Text("\(model.frameCount) photos · \(Int(model.progress * 100)) %").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
                Button("Annuler") { model.cancel() }.font(.system(size: 13)).padding(.top, 16)
            }
        }.accessibilityIdentifier("processingOverlay")
    }
}
