import Foundation
import simd

/// The built-in "Neutral" simulation, expressed as a LUT in the F-Log2 domain so it
/// runs through the same shader as the Fujifilm LUTs:
/// F-Log2 -> linear F-Gamut (= Rec.2020) -> Rec.709 primaries -> clip -> BT.709 OETF.
/// Mirrors `neutral_table` in research/reference/shared_stage.py.
enum NeutralLUT {
    static func make(size n: Int = 33) -> CubeLUT {
        let toRec2020 = Gamut.rec2020ToFGamut.inverse
        let to709 = Gamut.rec2020ToRec709
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(n * n * n)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let code = SIMD3<Double>(Double(r), Double(g), Double(b)) / Double(n - 1)
                    let lin = toRec2020 * SIMD3(FLog2.decode(code.x), FLog2.decode(code.y), FLog2.decode(code.z))
                    let l709 = simd_clamp(to709 * lin, SIMD3(repeating: 0), SIMD3(repeating: 1))
                    values.append(SIMD3<Float>(SIMD3(BT709Transfer.oetf(l709.x),
                                                     BT709Transfer.oetf(l709.y),
                                                     BT709Transfer.oetf(l709.z))))
                }
            }
        }
        return CubeLUT(title: "Neutral", size: n, domainMin: .zero, domainMax: .one, values: values)
    }
}
