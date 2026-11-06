import Foundation

/// ITU-R BT.709 OETF and its inverse.
enum BT709Transfer {
    static func oetf(_ l: Double) -> Double {
        let l = max(l, 0)
        return l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099
    }

    static func inverseOETF(_ v: Double) -> Double {
        let v = max(v, 0)
        return v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
    }
}
