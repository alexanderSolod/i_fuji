import Foundation

/// Fujifilm F-Log2 transfer function (Fujifilm "F-Log2 Data Sheet").
enum FLog2 {
    static let a = 5.555556
    static let b = 0.064829
    static let c = 0.245281
    static let d = 0.384316
    static let e = 8.799461
    static let f = 0.092864
    static let cut1 = 0.000889
    static let cut2 = 0.100686

    static func encode(_ x: Double) -> Double {
        if x >= cut1 { return c * log10(max(a * x + b, 1e-10)) + d }
        return e * x + f
    }

    static func decode(_ y: Double) -> Double {
        if y >= cut2 { return (pow(10, (y - d) / c) - b) / a }
        return (y - f) / e
    }
}
