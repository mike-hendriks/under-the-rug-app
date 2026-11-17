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

/// What the app remembers between launches.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var style: RugStyle {
        get { RugStyle.named(defaults.string(forKey: "style") ?? "") }
        set { defaults.set(newValue.id, forKey: "style") }
    }

    static var size: RugSize {
        get { RugSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "size") }
    }

    static var center: SIMD2<Float>? {
        get {
            guard let a = defaults.array(forKey: "center") as? [Double], a.count == 2 else { return nil }
            return SIMD2(Float(a[0]), Float(a[1]))
        }
        set {
            if let v = newValue {
                defaults.set([Double(v.x), Double(v.y)], forKey: "center")
            } else {
                defaults.removeObject(forKey: "center")
            }
        }
    }

    static var angle: Float {
        get { (defaults.object(forKey: "angle") as? Double).map { Float($0) } ?? -0.035 }
        set { defaults.set(Double(newValue), forKey: "angle") }
    }
}
