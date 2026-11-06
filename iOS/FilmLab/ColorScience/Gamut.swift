import Foundation
import simd

/// RGB gamut math built from chromaticity primaries, mirroring
/// `gamut_matrix` in research/reference/bake_applelog_to_fuji.py.
enum Gamut {
    typealias XY = (x: Double, y: Double)

    struct Primaries {
        let red: XY
        let green: XY
        let blue: XY
    }

    static let d65: XY = (0.3127, 0.3290)
    static let rec2020 = Primaries(red: (0.708, 0.292), green: (0.170, 0.797), blue: (0.131, 0.046))
    /// F-Gamut is specified with the same primaries as Rec.2020 (D65).
    static let fGamut = Primaries(red: (0.708, 0.292), green: (0.170, 0.797), blue: (0.131, 0.046))
    static let rec709 = Primaries(red: (0.640, 0.330), green: (0.300, 0.600), blue: (0.150, 0.060))

    static func rgbToXYZ(_ p: Primaries, white: XY = d65) -> simd_double3x3 {
        func xyz(_ c: XY) -> SIMD3<Double> { SIMD3(c.x / c.y, 1, (1 - c.x - c.y) / c.y) }
        let m = simd_double3x3(columns: (xyz(p.red), xyz(p.green), xyz(p.blue)))
        let s = m.inverse * xyz(white)
        return simd_double3x3(columns: (m.columns.0 * s.x, m.columns.1 * s.y, m.columns.2 * s.z))
    }

    static func matrix(from src: Primaries, to dst: Primaries, white: XY = d65) -> simd_double3x3 {
        rgbToXYZ(dst, white: white).inverse * rgbToXYZ(src, white: white)
    }

    static let rec2020ToFGamut = matrix(from: rec2020, to: fGamut)
    static let rec2020ToRec709 = matrix(from: rec2020, to: rec709)
    static let rec709ToRec2020 = matrix(from: rec709, to: rec2020)
    static let xyzToRec2020 = rgbToXYZ(rec2020).inverse
}

extension simd_double3x3 {
    var float3x3: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(columns.0), SIMD3<Float>(columns.1), SIMD3<Float>(columns.2)))
    }
}
