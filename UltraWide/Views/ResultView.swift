import SwiftUI

struct ResultView: View {
    let result: CaptureResult
    @EnvironmentObject private var library: PanoramaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SavedPanorama?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    PanoramaDetail(item: saved, isNew: true)
                } else {
                    VStack(spacing: 24) {
                        if let image = UIImage(data: result.image.jpeg) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        Text("Votre nouvelle perspective.").font(.system(size: 30, weight: .light, design: .serif))
                        if let error {
                            Text(error).font(.system(size: 14)).multilineTextAlignment(.center)
                            PrimaryButton(title: "Réessayer l’enregistrement", symbol: "arrow.clockwise") { Task { await save() } }
                        } else { ProgressView("Enregistrement dans la galerie…") }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Terminé") {
                    if saved == nil { confirmDiscard = true } else { dismiss() }
                }.disabled(saving).accessibilityIdentifier("resultDone")
            } }
        }.tint(Palette.mint).foregroundStyle(Palette.cream)
            .interactiveDismissDisabled(saved == nil)
            .confirmationDialog("Quitter sans enregistrer cette image ?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Abandonner l’image", role: .destructive) { dismiss() }
            }
            .task { await save() }
    }

    private func save() async {
        guard saved == nil, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do { saved = try await library.store(result) }
        catch { self.error = error.localizedDescription }
    }
}

struct PanoramaDetail: View {
    let item: SavedPanorama
    var isNew = false
    @EnvironmentObject private var library: PanoramaLibrary
    @State private var exported = false
    @State private var exporting = false
    @State private var error: String?
    @State private var showImage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Eyebrow(text: item.isDemo ? "Panorama de démonstration" : "Une perspective, réinventée")
                Text(isNew ? "Vous voyez\nplus grand." : "Au-delà\ndu cadre.")
                    .font(.system(size: 43, weight: .light, design: .serif)).tracking(-1)
                Button { showImage = true } label: {
                    StoredImage(url: library.url(for: item), maxPixel: 1800)
                        .aspectRatio(CGFloat(item.width) / CGFloat(item.height), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
                                .padding(12).background(.black.opacity(0.4), in: Circle()).padding(12)
                        }
                }.buttonStyle(.plain).accessibilityLabel("Agrandir le panorama")
                HStack {
                    stat("DÉFINITION", item.megapixels)
                    Spacer()
                    stat("ASSEMBLAGE", "\(item.frameCount) photos")
                    Spacer()
                    stat("OBJECTIF", item.lensName)
                }
                Text("\(item.width) × \(item.height) px · JPEG · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                Divider().overlay(Palette.secondary.opacity(0.3))
                Label("Enregistré dans votre galerie", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Palette.mint).accessibilityIdentifier("savedConfirmation")
                PrimaryButton(title: exported ? "Ajouté à Photos" : exporting ? "Enregistrement…" : "Enregistrer dans Photos",
                              symbol: exported ? "checkmark" : "square.and.arrow.down") {
                    exporting = true
                    Task {
                        defer { exporting = false }
                        do { try await PanoramaLibrary.exportToPhotos(library.url(for: item)); exported = true }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(exporting || exported)
                ShareLink(item: library.url(for: item)) {
                    Label("Partager le panorama", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(16)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
                }
            }.padding(25)
        }.background(Palette.background).foregroundStyle(Palette.cream)
            .alert("Enregistrement dans Photos", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
                Button("Réglages") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } message: { Text(error ?? "") }
            .fullScreenCover(isPresented: $showImage) {
                ZStack(alignment: .topTrailing) {
                    ZoomableImage(url: library.url(for: item)).ignoresSafeArea()
                    RoundButton(symbol: "xmark", label: "Fermer l’image") { showImage = false }.padding(22)
                }.background(.black)
            }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 13, weight: .medium))
        }
    }
}

struct StoredImage: View {
    let url: URL
    var maxPixel = 700
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(Palette.surface).overlay(ProgressView().tint(Palette.mint)) }
        }.task(id: url) {
            let url = url, size = maxPixel
            image = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url), let cg = try? PanoramaStitcher.decode(data, maxPixel: size) else { return nil as UIImage? }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.backgroundColor = .black
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(contentsOfFile: url.path)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
