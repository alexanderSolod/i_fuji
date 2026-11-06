import Foundation
import simd

/// Y'CbCr -> R'G'B' conversion parameters for the preview path.
struct YCbCrConversion: Equatable {
    var kr: Double
    var kb: Double
    var bitDepth: Int
    var fullRange: Bool

    static func bt2020(bitDepth: Int, fullRange: Bool) -> YCbCrConversion {
        YCbCrConversion(kr: 0.2627, kb: 0.0593, bitDepth: bitDepth, fullRange: fullRange)
    }

    static func bt709(bitDepth: Int, fullRange: Bool) -> YCbCrConversion {
        YCbCrConversion(kr: 0.2126, kb: 0.0722, bitDepth: bitDepth, fullRange: fullRange)
    }

    /// Integer code value range parameters: (yOffset, yScale, cOffset, cScale) such that
    /// Y' = (code - yOffset) * yScale and Cb = (code - cOffset) * cScale.
    var rangeParameters: (yOffset: Double, yScale: Double, cOffset: Double, cScale: Double) {
        let s = pow(2, Double(bitDepth - 8))
        let mid = pow(2, Double(bitDepth - 1))
        let maxCode = pow(2, Double(bitDepth)) - 1
        if fullRange { return (0, 1 / maxCode, mid, 1 / maxCode) }
        return (16 * s, 1 / (219 * s), mid, 1 / (224 * s))
    }

    /// (crToR, cbToG, crToG, cbToB) for the non-constant-luminance matrix.
    var matrixCoefficients: (crR: Double, cbG: Double, crG: Double, cbB: Double) {
        let kg = 1 - kr - kb
        let crR = 2 * (1 - kr)
        let cbB = 2 * (1 - kb)
        return (crR, -kb * cbB / kg, -kr * crR / kg, cbB)
    }

    func rgb(y yCode: Double, cb cbCode: Double, cr crCode: Double) -> SIMD3<Double> {
        let p = rangeParameters
        let m = matrixCoefficients
        let y = (yCode - p.yOffset) * p.yScale
        let cb = (cbCode - p.cOffset) * p.cScale
        let cr = (crCode - p.cOffset) * p.cScale
        return SIMD3(y + m.crR * cr, y + m.cbG * cb + m.crG * cr, y + m.cbB * cb)
    }
}
