import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: PanoramaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: SavedPanorama?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Eyebrow(text: "Vos horizons")
                    Text("La vue d’ensemble.").font(.system(size: 36, weight: .light, design: .serif)).tracking(-1)
                    if library.items.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "rectangle.stack").font(.system(size: 55, weight: .ultraLight)).foregroundStyle(Palette.mint)
                            Text("Votre premier horizon\nvous attend.").font(.system(size: 28, weight: .light, design: .serif)).multilineTextAlignment(.center)
                            Text("Vos panoramas apparaîtront ici,\nenregistrés sur cet iPhone.")
                                .font(.system(size: 14)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                            PrimaryButton(title: "Prendre une photo", symbol: "camera") { dismiss() }
                        }.padding(.vertical, 70)
                    } else {
                        Text("\(library.items.count) panorama\(library.items.count > 1 ? "s" : "")")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
                        LazyVStack(spacing: 24) {
                            ForEach(library.items) { item in
                                NavigationLink {
                                    PanoramaDetail(item: item)
                                        .toolbar { ToolbarItem(placement: .topBarTrailing) {
                                            Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash") }
                                        } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 11) {
                                        StoredImage(url: library.url(for: item)).aspectRatio(CGFloat(item.width) / CGFloat(item.height), contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                        HStack {
                                            Text(item.isDemo ? "Exploration · Démo" : item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            Spacer()
                                            Text(item.megapixels).foregroundStyle(Palette.secondary)
                                        }.font(.system(size: 12, weight: .medium))
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(25)
            }.background(Palette.background).foregroundStyle(Palette.cream)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
                .confirmationDialog("Supprimer ce panorama de la galerie ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Supprimer", role: .destructive) {
                        if let deleting {
                            do { try library.delete(deleting); dismiss() }
                            catch { library.errorMessage = error.localizedDescription }
                        }
                        deleting = nil
                    }
                } message: { Text("Les copies déjà enregistrées dans Photos seront conservées.") }
                .alert("Galerie", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                    Button("OK", role: .cancel) { library.errorMessage = nil }
                } message: { Text(library.errorMessage ?? "") }
        }.tint(Palette.mint)
    }
}
