import Observation
import UIKit

enum AppIcon: String, CaseIterable, Identifiable {
    case original = "UltraWide"
    case amber = "UltraWideAmber"
    case aurora = "UltraWideAurora"
    case graphite = "UltraWideGraphite"

    var id: String { rawValue }
    var alternateName: String? { self == .original ? nil : rawValue }
    var previewName: String { "\(rawValue)Preview" }

    var title: LocalizedStringResource {
        switch self {
        case .original: "Original"
        case .amber: "Amber"
        case .aurora: "Aurora"
        case .graphite: "Graphite"
        }
    }
}

/// The system owns the selected icon; never persist a second, potentially stale choice.
@MainActor
@Observable
final class AppIconStore {
    private(set) var selectedName: String?
    private(set) var pendingIcon: AppIcon?
    private(set) var isSupported = false
    var errorMessage: String?

    @ObservationIgnored private let currentName: @MainActor () -> String?
    @ObservationIgnored private let supportsIcons: @MainActor () -> Bool
    @ObservationIgnored private let applyIcon: @MainActor (String?) async throws -> Void

    init(
        currentName: @escaping @MainActor () -> String? = { UIApplication.shared.alternateIconName },
        supportsIcons: @escaping @MainActor () -> Bool = { UIApplication.shared.supportsAlternateIcons },
        applyIcon: @escaping @MainActor (String?) async throws -> Void = { try await UIApplication.shared.setAlternateIconName($0) }
    ) {
        self.currentName = currentName
        self.supportsIcons = supportsIcons
        self.applyIcon = applyIcon
        refresh()
    }

    func refresh() {
        selectedName = currentName()
        isSupported = supportsIcons()
    }

    func select(_ icon: AppIcon) async {
        guard pendingIcon == nil else { return }
        refresh()
        guard isSupported, selectedName != icon.alternateName else { return }
        pendingIcon = icon
        errorMessage = nil
        defer {
            refresh()
            pendingIcon = nil
        }
        do {
            try await applyIcon(icon.alternateName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
