import Foundation
import simd

// Layouts must match the structs at the top of FilmEngine/Shaders.metal.

struct StageParams {
    var domainMin: SIMD4<Float>
    var domainMax: SIMD4<Float>
    var toFGamut: simd_float3x3
    var clipNegatives: UInt32

    init(lut: LUTTexture, exposureStops: Double) {
        let lo = SIMD3<Float>(lut.domainMin)
        let hi = SIMD3<Float>(lut.domainMax)
        domainMin = SIMD4(lo, Float(pow(2, exposureStops)))
        domainMax = SIMD4(hi, Float(lut.size))
        toFGamut = Gamut.rec2020ToFGamut.float3x3
        clipNegatives = SharedStage.clipNegativesBeforeEncode ? 1 : 0
    }
}

struct DecodeParams {
    enum Transfer: UInt32 {
        case appleLog = 0
        case bt709 = 1
    }

    var yParams: SIMD4<Float>
    var cParams: SIMD4<Float>
    var matrix: SIMD4<Float>
    var toRec2020: simd_float3x3
    var transfer: UInt32

    /// - Parameter codeScale: multiplier from a normalized texture sample to an integer code value.
    ///   10-bit data delivered in 16-bit containers (`.r16Unorm`) uses 65535/64; 8-bit uses 255.
    init(conversion: YCbCrConversion, codeScale: Double, transfer: Transfer, toRec2020: simd_double3x3) {
        let r = conversion.rangeParameters
        let m = conversion.matrixCoefficients
        yParams = SIMD4(Float(codeScale), Float(r.yOffset), Float(r.yScale), 0)
        cParams = SIMD4(Float(r.cOffset), Float(r.cScale), 0, 0)
        matrix = SIMD4(Float(m.crR), Float(m.cbG), Float(m.crG), Float(m.cbB))
        self.toRec2020 = toRec2020.float3x3
        self.transfer = transfer.rawValue
    }
}

struct PreviewParams {
    var uvTransform: SIMD4<Float>
}
