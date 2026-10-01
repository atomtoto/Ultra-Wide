import Foundation

/// A regional default is a starting point, not detection of a lamp's driver.
/// The explicit choices also cover travel and regions with two mains standards.
enum CaptureLighting: String, CaseIterable, Identifiable, Sendable {
    case automatic, hz50, hz60
    static let preferenceKey = "captureLighting"
    var id: String { rawValue }

    static func saved(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    var mainsFrequency: Double {
        frequency(timeZone: .current, region: Locale.current.region?.identifier)
    }

    func frequency(timeZone: TimeZone, region: String?) -> Double {
        switch self {
        case .hz50: return 50
        case .hz60: return 60
        case .automatic:
            let zone = timeZone.identifier
            if zone.hasPrefix("Europe/") || zone.hasPrefix("Africa/") || zone.hasPrefix("Australia/") {
                return 50
            }
            let american50 = ["America/Argentina/", "America/Santiago", "America/Montevideo",
                              "America/Asuncion", "America/La_Paz", "America/Jamaica"]
            if american50.contains(where: { zone.hasPrefix($0) }) { return 50 }
            if zone.hasPrefix("America/") || zone == "Pacific/Honolulu" || zone == "Pacific/Guam"
                || zone == "Asia/Seoul" || zone == "Asia/Taipei" || zone == "Asia/Manila"
                || zone == "Asia/Riyadh" { return 60 }
            // Japan's east uses 50 Hz; west uses 60 Hz. The explicit selector
            // avoids claiming that a locale can disambiguate the two.
            if zone == "Asia/Tokyo" { return 50 }
            if zone.hasPrefix("Asia/") || zone.hasPrefix("Pacific/") { return 50 }
            let regions60: Set<String> = ["US", "CA", "MX", "BR", "CO", "PE", "EC", "VE", "KR", "TW", "PH", "SA"]
            return region.map { regions60.contains($0) ? 60 : 50 } ?? 50
        }
    }
}

enum SweepExposurePolicy {
    struct Setting: Equatable, Sendable {
        let duration: Double
        let iso: Double
        let integratesFlickerCycle: Bool
    }

    /// Preserve the exposure measured by AVFoundation while integrating whole
    /// 100/120 Hz cycles. Choose the shortest feasible duration, with ISO in
    /// range. A bright scene can require a shorter shutter at minimum ISO.
    static func setting(meteredDuration: Double, meteredISO: Double,
                        minimumDuration: Double, maximumDuration: Double,
                        minimumISO: Double, maximumISO: Double,
                        frameDuration: Double, mainsFrequency: Double) -> Setting? {
        let values = [meteredDuration, meteredISO, minimumDuration, maximumDuration,
                      minimumISO, maximumISO, frameDuration, mainsFrequency]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumDuration <= maximumDuration, minimumISO <= maximumISO,
              mainsFrequency == 50 || mainsFrequency == 60 else { return nil }
        let longest = min(maximumDuration, frameDuration)
        guard longest >= minimumDuration else { return nil }
        let energy = meteredDuration * meteredISO
        guard energy.isFinite else { return nil }
        let period = 1 / (2 * mainsFrequency)
        let firstCycle = Int(min(13, max(1, ceil(minimumDuration / period - 1e-8))))
        let lastCycle = Int(min(12, max(0, floor(longest / period + 1e-8))))
        if firstCycle <= lastCycle {
            for count in firstCycle...lastCycle {
                let duration = Double(count) * period
                let iso = energy / duration
                if iso >= minimumISO * (1 - 1e-7), iso <= maximumISO * (1 + 1e-7) {
                    return Setting(duration: duration, iso: min(maximumISO, max(minimumISO, iso)),
                                   integratesFlickerCycle: true)
                }
            }
        }
        // Do not burn highlights to force a complete cycle that the physical
        // sensor cannot expose at minimum ISO. Retain a valid measured exposure.
        let duration = min(longest, max(minimumDuration, meteredDuration))
        return Setting(duration: duration, iso: min(maximumISO, max(minimumISO, energy / duration)),
                       integratesFlickerCycle: false)
    }
}
