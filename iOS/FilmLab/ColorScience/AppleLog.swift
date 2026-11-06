import Foundation

/// Apple Log transfer function (Apple "Apple Log Profile" white paper).
enum AppleLog {
    static let r0 = -0.05641088
    static let rt = 0.01
    static let c = 47.28711236
    static let beta = 0.00964052
    static let gamma = 0.08550479
    static let delta = 0.69336945
    static let pt = c * (rt - r0) * (rt - r0)

    static func encode(_ r: Double) -> Double {
        if r >= rt { return gamma * log2(r + beta) + delta }
        if r >= r0 { return c * (r - r0) * (r - r0) }
        return 0
    }

    static func decode(_ p: Double) -> Double {
        if p >= pt { return pow(2, (p - delta) / gamma) - beta }
        return (max(p, 0) / c).squareRoot() + r0
    }
}
