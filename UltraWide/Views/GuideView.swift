import SwiftUI

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Eyebrow(text: "Un autre point de vue")
                    Text("Plus de scène.\nLe même objectif.").font(.system(size: 40, weight: .light, design: .serif)).tracking(-1)
                    Image(systemName: "rectangle.portrait.rotate").font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(Palette.mint).frame(maxWidth: .infinity).padding(.vertical, 18)
                    step("01", "Choisissez votre objectif", "Le capteur principal ou le téléobjectif, lorsqu’il est disponible. Chaque photo provient du même capteur.")
                    step("02", "Déclenchez, puis pivotez", "Tenez l’iPhone verticalement. Partez d’un côté de la scène et pivotez lentement vers l’autre, en gardant l’objectif au même endroit et à la même hauteur.")
                    step("03", "Laissez la vue s’assembler", "Les photos sont alignées, leurs raccords adoucis et les bords recadrés. Le résultat reste dans votre galerie, prêt à être partagé.")
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Pour un beau résultat", systemImage: "sun.max").font(.system(size: 14, weight: .semibold))
                        Text("Privilégiez une scène immobile, distante et bien éclairée. Les sujets proches, les vagues, les passants et les déplacements de l’iPhone peuvent laisser des raccords visibles. Le téléobjectif élargit son propre cadrage ; il ne remplace pas toujours un ultra-grand-angle.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }.padding(20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
                    PrimaryButton(title: "À moi de voir plus grand", symbol: "arrow.right") { dismiss() }
                    Text("Traitement sur l’iPhone · Aucun compte · Aucun envoi de photos")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }.padding(26)
            }.background(Palette.background).foregroundStyle(Palette.cream)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }.tint(Palette.mint)
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.mint).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 17, weight: .medium))
                Text(detail).font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
        }
    }
}
