import CoreVideo
import Metal
import MetalKit
import QuartzCore

/// How the preview frames should be decoded to scene-linear Rec.2020.
enum PreviewInputMode: Equatable, Sendable {
    /// Apple Log, BT.2020 primaries. Exact.
    case appleLog
    /// Non-log video treated as BT.709 transfer and primaries. Approximate ("Preview approx.").
    case approximateRec709
}

/// Draws camera frames through the shared stage into an MTKView. Thread-safe: frames arrive on the
/// capture queue, drawing happens on the main thread.
final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    struct Stats: Sendable {
        var fps: Double
        var gpuMs: Double
        var bufferSize: CGSize
        var pixelFormat: String
    }

    let context: MetalContext
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()

    private var pendingBuffer: CVPixelBuffer?
    private var lut: LUTTexture?
    private var exposureStops: Double = 0
    private var inputMode: PreviewInputMode = .appleLog
    private var meterRequested = false

    private var frameTimes: [CFTimeInterval] = []
    private var lastStatsReport: CFTimeInterval = 0
    private var lastGPUMs: Double = 0

    /// Called on the main thread about once per second.
    var onStats: ((Stats) -> Void)?
    /// Mean scene-linear Rec.2020 of the 32x32 center patch, before EV and anchor. Main thread.
    var onMeter: ((SIMD3<Float>) -> Void)?

    init(context: MetalContext) {
        self.context = context
        super.init()
        CVMetalTextureCacheCreate(nil, nil, context.device, nil, &textureCache)
    }

    func configure(view: MTKView) {
        view.device = context.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.delegate = self
        (view.layer as? CAMetalLayer)?.colorspace = OutputColor.colorSpace
    }

    func enqueue(_ buffer: CVPixelBuffer) {
        lock.withLock { pendingBuffer = buffer }
    }

    func update(lut: LUTTexture?, exposureStops: Double, inputMode: PreviewInputMode) {
        lock.withLock {
            self.lut = lut
            self.exposureStops = exposureStops
            self.inputMode = inputMode
        }
    }

    func requestMeter() { lock.withLock { meterRequested = true } }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let (buffer, lut, ev, mode, meter) = lock.withLock { () -> (CVPixelBuffer?, LUTTexture?, Double, PreviewInputMode, Bool) in
            defer { pendingBuffer = nil; meterRequested = false }
            return (pendingBuffer, self.lut, exposureStops, inputMode, meterRequested)
        }
        guard let buffer, let lut, let cache = textureCache,
              let planes = Self.planeTextures(buffer, cache: cache),
              let decode = Self.decodeParams(for: buffer, mode: mode),
              let drawable = view.currentDrawable,
              let cb = context.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }

        let dst = drawable.texture
        var stage = StageParams(lut: lut, exposureStops: ev)
        var dec = decode
        var preview = PreviewParams(uvTransform: Self.aspectFill(src: CGSize(width: planes.luma.width, height: planes.luma.height),
                                                                 dst: CGSize(width: dst.width, height: dst.height)))
        enc.setComputePipelineState(context.previewPipeline)
        enc.setTexture(planes.luma, index: 0)
        enc.setTexture(planes.chroma, index: 1)
        enc.setTexture(dst, index: 2)
        enc.setTexture(lut.texture, index: 3)
        enc.setSamplerState(context.lutSampler, index: 0)
        enc.setSamplerState(context.planeSampler, index: 1)
        enc.setBytes(&stage, length: MemoryLayout<StageParams>.stride, index: 0)
        enc.setBytes(&dec, length: MemoryLayout<DecodeParams>.stride, index: 1)
        enc.setBytes(&preview, length: MemoryLayout<PreviewParams>.stride, index: 2)
        context.dispatch2D(enc, pipeline: context.previewPipeline, width: dst.width, height: dst.height)

        var meterTexture: MTLTexture?
        if meter {
            meterTexture = encodeMeter(enc, planes: planes, decode: &dec)
        }
        enc.endEncoding()

        let keepAlive = planes
        cb.addCompletedHandler { [weak self] cb in
            _ = keepAlive
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if let tex = meterTexture, let self {
                let mean = Self.meanRGB(tex)
                DispatchQueue.main.async { self.onMeter?(mean) }
            }
            self?.lock.withLock { self?.lastGPUMs = gpuMs }
        }
        cb.present(drawable)
        cb.commit()
        recordFrame(buffer: buffer)
    }

    private func encodeMeter(_ enc: MTLComputeCommandEncoder, planes: Planes, decode: inout DecodeParams) -> MTLTexture? {
        let size = 32
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: desc) else { return nil }
        var origin = SIMD2<UInt32>(UInt32(max(0, planes.luma.width / 2 - size / 2)) & ~1,
                                   UInt32(max(0, planes.luma.height / 2 - size / 2)) & ~1)
        enc.setComputePipelineState(context.ycbcrToLinearPipeline)
        enc.setTexture(planes.luma, index: 0)
        enc.setTexture(planes.chroma, index: 1)
        enc.setTexture(tex, index: 2)
        enc.setBytes(&decode, length: MemoryLayout<DecodeParams>.stride, index: 1)
        enc.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        context.dispatch2D(enc, pipeline: context.ycbcrToLinearPipeline, width: size, height: size)
        return tex
    }

    private func recordFrame(buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        guard now - lastStatsReport >= 1 else { return }
        lastStatsReport = now
        let stats = Stats(fps: Double(frameTimes.count),
                          gpuMs: lock.withLock { lastGPUMs },
                          bufferSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                          pixelFormat: fourCC(CVPixelBufferGetPixelFormatType(buffer)))
        Log.debug(String(format: "Preview %.0f fps, GPU %.2f ms, %@ %.0fx%.0f", stats.fps, stats.gpuMs,
                         stats.pixelFormat, stats.bufferSize.width, stats.bufferSize.height))
        onStats?(stats)
    }

    // MARK: Helpers

    struct Planes {
        let lumaRef: CVMetalTexture
        let chromaRef: CVMetalTexture
        let luma: MTLTexture
        let chroma: MTLTexture
    }

    static func planeTextures(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> Planes? {
        let tenBit = format(of: buffer)?.bitDepth == 10
        func plane(_ i: Int, _ fmt: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            var ref: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(buffer, i)
            let h = CVPixelBufferGetHeightOfPlane(buffer, i)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, fmt, w, h, i, &ref) == kCVReturnSuccess,
                  let ref, let tex = CVMetalTextureGetTexture(ref) else { return nil }
            return (ref, tex)
        }
        guard let y = plane(0, tenBit ? .r16Unorm : .r8Unorm),
              let c = plane(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
        return Planes(lumaRef: y.0, chromaRef: c.0, luma: y.1, chroma: c.1)
    }

    struct BufferFormat {
        let bitDepth: Int
        let fullRange: Bool
    }

    static func format(of buffer: CVPixelBuffer) -> BufferFormat? {
        format(of: CVPixelBufferGetPixelFormatType(buffer))
    }

    static func format(of type: OSType) -> BufferFormat? {
        switch type {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return BufferFormat(bitDepth: 10, fullRange: false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return BufferFormat(bitDepth: 10, fullRange: true)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return BufferFormat(bitDepth: 8, fullRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return BufferFormat(bitDepth: 8, fullRange: true)
        default: return nil
        }
    }

    static func decodeParams(for buffer: CVPixelBuffer, mode: PreviewInputMode) -> DecodeParams? {
        guard let f = format(of: buffer) else { return nil }
        return decodeParams(format: f, mode: mode)
    }

    static func decodeParams(format f: BufferFormat, mode: PreviewInputMode) -> DecodeParams {
        // 10-bit samples sit in the high bits of 16-bit containers, so an .r16Unorm read is code * 64 / 65535.
        let codeScale = f.bitDepth == 10 ? 65535.0 / 64.0 : 255.0
        switch mode {
        case .appleLog:
            return DecodeParams(conversion: .bt2020(bitDepth: f.bitDepth, fullRange: f.fullRange),
                                codeScale: codeScale, transfer: .appleLog, toRec2020: matrix_identity_double3x3)
        case .approximateRec709:
            return DecodeParams(conversion: .bt709(bitDepth: f.bitDepth, fullRange: f.fullRange),
                                codeScale: codeScale, transfer: .bt709, toRec2020: Gamut.rec709ToRec2020)
        }
    }

    /// Maps destination UV (0..1) to source UV for aspect-fill.
    static func aspectFill(src: CGSize, dst: CGSize) -> SIMD4<Float> {
        let srcAspect = src.width / src.height
        let dstAspect = dst.width / dst.height
        if srcAspect > dstAspect {
            let s = Float(dstAspect / srcAspect)
            return SIMD4(s, 1, (1 - s) / 2, 0)
        } else {
            let s = Float(srcAspect / dstAspect)
            return SIMD4(1, s, 0, (1 - s) / 2)
        }
    }

    static func meanRGB(_ tex: MTLTexture) -> SIMD3<Float> {
        var px = [SIMD4<Float>](repeating: .zero, count: tex.width * tex.height)
        px.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * 16, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        }
        let sum = px.reduce(SIMD4<Float>.zero, +)
        let mean = sum / Float(max(px.count, 1))
        return SIMD3(mean.x, mean.y, mean.z)
    }
}

func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}
