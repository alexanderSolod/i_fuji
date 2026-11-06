import CoreImage
import Metal
import QuartzCore

/// Still path: Bayer DNG -> CIRAWFilter (linear, no shaping) -> scene-linear Rec.2020 rgba16Float
/// -> shared stage -> Rec.709 8-bit image.
final class RAWDeveloper: @unchecked Sendable {
    struct Output {
        let image: CGImage
        /// Mean scene-linear Rec.2020 of the 32x32 center patch, before EV and anchor.
        let linearCenter: SIMD3<Float>
        let baselineExposure: Float
        let renderMs: Double
    }

    struct RAWInfo: Codable, Sendable {
        var baselineExposure: Float
        var width: Int
        var height: Int
        var settings: [String: String]
    }

    let context: MetalContext
    init(context: MetalContext) { self.context = context }

    /// Fixed decode settings. Everything that shapes the image is off (spec 4.5).
    static func makeFilter(dng: Data) throws -> CIRAWFilter {
        guard let f = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else {
            throw FilmEngineError.commandFailed("CIRAWFilter could not open the DNG")
        }
        f.boostAmount = 0                 // linear response, no tone curve
        f.boostShadowAmount = 0
        f.isGamutMappingEnabled = false
        f.extendedDynamicRangeAmount = 0
        if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        if f.isSharpnessSupported { f.sharpnessAmount = 0 }
        if f.isContrastSupported { f.contrastAmount = 0 }
        if f.isDetailSupported { f.detailAmount = 0 }
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
        if f.isMoireReductionSupported { f.moireReductionAmount = 0 }
        f.exposure = 0
        // baselineExposure is left at the DNG's value (CIRAWFilter initializes it from the file).
        return f
    }

    static func info(of f: CIRAWFilter) -> RAWInfo {
        let size = f.nativeSize
        return RAWInfo(baselineExposure: f.baselineExposure, width: Int(size.width), height: Int(size.height), settings: [
            "boostAmount": "\(f.boostAmount)", "boostShadowAmount": "\(f.boostShadowAmount)",
            "localToneMapAmount": f.isLocalToneMapSupported ? "\(f.localToneMapAmount)" : "n/a",
            "extendedDynamicRangeAmount": "\(f.extendedDynamicRangeAmount)",
            "sharpnessAmount": f.isSharpnessSupported ? "\(f.sharpnessAmount)" : "n/a",
            "luminanceNR": f.isLuminanceNoiseReductionSupported ? "\(f.luminanceNoiseReductionAmount)" : "n/a",
            "colorNR": f.isColorNoiseReductionSupported ? "\(f.colorNoiseReductionAmount)" : "n/a",
            "gamutMapping": "\(f.isGamutMappingEnabled)", "lensCorrection": "\(f.isLensCorrectionEnabled)",
            "baselineExposure": "\(f.baselineExposure)", "neutralTemperature": "\(f.neutralTemperature)",
        ])
    }

    private func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else { throw FilmEngineError.textureCreation }
        return t
    }

    /// Renders a CIImage into an rgba16Float texture in extended linear Rec.2020, row 0 = top of the image.
    func renderLinear(_ image: CIImage) throws -> MTLTexture {
        let extent = image.extent.integral
        let tex = try makeTexture(.rgba16Float, Int(extent.width), Int(extent.height))
        let dest = CIRenderDestination(mtlTexture: tex, commandBuffer: nil)
        dest.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        dest.isFlipped = true   // Core Image is bottom-left origin; Metal rows start at the top.
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let task = try context.ciContext.startTask(toRender: moved, to: dest)
        _ = try task.waitUntilCompleted()
        return tex
    }

    func linearTexture(dng: Data) throws -> (MTLTexture, RAWInfo) {
        let filter = try Self.makeFilter(dng: dng)
        guard let image = filter.outputImage else { throw FilmEngineError.commandFailed("CIRAWFilter produced no image") }
        return (try renderLinear(image), Self.info(of: filter))
    }

    func render(dng: Data, lut: LUTTexture, exposureStops: Double) async throws -> Output {
        let t0 = CACurrentMediaTime()
        let (linear, info) = try linearTexture(dng: dng)
        let out = try makeTexture(.rgba8Unorm, linear.width, linear.height)
        try await FilmStage(context: context).run(source: linear, destination: out, lut: lut, exposureStops: exposureStops)
        let center = Self.centerMean(linear)
        let image = try Self.cgImage(from: out)
        let ms = (CACurrentMediaTime() - t0) * 1000
        Log.info(String(format: "Rendered %dx%d still in %.0f ms, baselineExposure %.2f, center linear %.4f %.4f %.4f",
                        linear.width, linear.height, ms, info.baselineExposure, center.x, center.y, center.z))
        return Output(image: image, linearCenter: center, baselineExposure: info.baselineExposure, renderMs: ms)
    }

    static func centerMean(_ tex: MTLTexture, size: Int = 32) -> SIMD3<Float> {
        let s = min(size, tex.width, tex.height)
        var px = [Float16](repeating: 0, count: s * s * 4)
        px.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: s * 8,
                         from: MTLRegionMake2D((tex.width - s) / 2, (tex.height - s) / 2, s, s), mipmapLevel: 0)
        }
        var sum = SIMD3<Float>.zero
        for i in 0..<(s * s) { sum += SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) }
        return sum / Float(s * s)
    }

    static func cgImage(from tex: MTLTexture) throws -> CGImage {
        let bpr = tex.width * 4
        var data = Data(count: bpr * tex.height)
        data.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: tex.width, height: tex.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                                  space: OutputColor.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FilmEngineError.textureCreation }
        return image
    }
}
