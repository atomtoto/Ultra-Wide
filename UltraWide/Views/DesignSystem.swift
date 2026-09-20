import SwiftUI

enum Palette {
    static let background = Color(red: 0.035, green: 0.065, blue: 0.068)
    static let surface = Color(red: 0.08, green: 0.115, blue: 0.12)
    static let mint = Color(red: 0.73, green: 0.94, blue: 0.77)
    static let cream = Color(red: 0.94, green: 0.94, blue: 0.87)
    static let secondary = Color(red: 0.58, green: 0.66, blue: 0.64)
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(2).foregroundStyle(Palette.secondary)
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                .frame(width: 46, height: 46).background(.white.opacity(0.065), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
        }.foregroundStyle(Palette.cream).accessibilityLabel(label)
    }
}

struct PrimaryButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(Palette.background).background(Palette.mint, in: RoundedRectangle(cornerRadius: 19))
        }
    }
}
