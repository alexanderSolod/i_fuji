import Foundation
import simd

/// CPU (Double precision) implementation of the shared film-simulation stage.
/// The Metal kernel in FilmEngine/Shaders.metal is the production path; this one
/// exists for tests and for checking the shader against the Python reference.
enum SharedStage {
    /// Spec v2 step 3 clips negatives before the F-Log2 encode. Keep in sync with
    /// research/reference/shared_stage.py and FilmEngine/Shaders.metal.
    static let clipNegativesBeforeEncode = true

    static func toFLog2(_ linRec2020: SIMD3<Double>, exposureStops: Double = 0) -> SIMD3<Double> {
        var lin = Gamut.rec2020ToFGamut * (linRec2020 * pow(2, exposureStops))
        if clipNegativesBeforeEncode { lin = simd_max(lin, .zero) }
        let code = SIMD3(FLog2.encode(lin.x), FLog2.encode(lin.y), FLog2.encode(lin.z))
        return simd_clamp(code, .zero, .one)
    }

    static func apply(_ linRec2020: SIMD3<Double>, lut: CubeLUT, exposureStops: Double = 0) -> SIMD3<Double> {
        simd_clamp(lut.apply(toFLog2(linRec2020, exposureStops: exposureStops)), .zero, .one)
    }
}
