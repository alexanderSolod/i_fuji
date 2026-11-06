import CoreImage
import Metal

enum FilmEngineError: Error, LocalizedError {
    case noMetalDevice
    case missingFunction(String)
    case textureCreation
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "Metal is not available on this device."
        case .missingFunction(let n): return "Missing Metal function \(n)."
        case .textureCreation: return "Could not create a Metal texture."
        case .commandFailed(let m): return "GPU command failed: \(m)"
        }
    }
}

/// Shared Metal device, pipelines and samplers.
final class MetalContext: @unchecked Sendable {
    static let shared: MetalContext? = try? MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let filmStagePipeline: MTLComputePipelineState
    let previewPipeline: MTLComputePipelineState
    let ycbcrToLinearPipeline: MTLComputePipelineState
    let curveEvalPipeline: MTLComputePipelineState
    let lutSamplePipeline: MTLComputePipelineState
    /// Linear filter, clamp-to-edge (spec 2.4).
    let lutSampler: MTLSamplerState
    let planeSampler: MTLSamplerState
    lazy var ciContext: CIContext = CIContext(mtlDevice: device, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FilmEngineError.noMetalDevice
        }
        self.device = device
        self.queue = queue
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalContext.self))
        self.library = library

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw FilmEngineError.missingFunction(name) }
            return try device.makeComputePipelineState(function: fn)
        }
        filmStagePipeline = try pipeline("film_stage_kernel")
        previewPipeline = try pipeline("preview_kernel")
        ycbcrToLinearPipeline = try pipeline("ycbcr_to_linear_kernel")
        curveEvalPipeline = try pipeline("curve_eval_kernel")
        lutSamplePipeline = try pipeline("lut_sample_kernel")

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .notMipmapped
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        s.rAddressMode = .clampToEdge
        s.normalizedCoordinates = true
        guard let lutSampler = device.makeSamplerState(descriptor: s),
              let planeSampler = device.makeSamplerState(descriptor: s) else { throw FilmEngineError.noMetalDevice }
        self.lutSampler = lutSampler
        self.planeSampler = planeSampler
    }

    func dispatch2D(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
