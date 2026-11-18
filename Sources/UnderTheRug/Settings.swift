import Foundation
import simd

enum RugSize: String, CaseIterable {
    case small, medium, large

    /// Total width in points, fringe included. Rugs are always 3:2.
    var width: Float {
        switch self {
        case .small: return 420
        case .medium: return 570
        case .large: return 750
        }
    }

    var height: Float { width * 2 / 3 }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// What is remembered about one rug: its look and where it lies, in global screen points.
struct RugConfig: Codable {
    var id: UUID
    var style: String
    var size: String
    var x: Float
    var y: Float
    var angle: Float
}

/// What the app remembers between launches.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var rugs: [RugConfig] {
        get {
            if let data = defaults.data(forKey: "rugs"),
               let configs = try? JSONDecoder().decode([RugConfig].self, from: data) {
                return configs
            }
            return legacyRug.map { [$0] } ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "rugs")
            }
        }
    }

    /// The single rug of version 1, stored as loose keys.
    private static var legacyRug: RugConfig? {
        guard let center = defaults.array(forKey: "center") as? [Double], center.count == 2 else { return nil }
        return RugConfig(id: UUID(),
                         style: defaults.string(forKey: "style") ?? RugStyle.all[0].id,
                         size: defaults.string(forKey: "size") ?? RugSize.medium.rawValue,
                         x: Float(center[0]), y: Float(center[1]),
                         angle: (defaults.object(forKey: "angle") as? Double).map { Float($0) } ?? -0.035)
    }
}
