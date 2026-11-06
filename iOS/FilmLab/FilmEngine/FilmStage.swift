import Metal

/// Runs the shared film-simulation stage on scene-linear Rec.2020 textures (still path, tests).
struct FilmStage {
    let context: MetalContext

    /// Encodes the stage into `commandBuffer`. `source` holds scene-linear Rec.2020 RGB,
    /// `destination` receives display-referred Rec.709 RGB in 0...1.
    func encode(source: MTLTexture, destination: MTLTexture, lut: LUTTexture, exposureStops: Double,
                commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        var params = StageParams(lut: lut, exposureStops: exposureStops)
        enc.setComputePipelineState(context.filmStagePipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setTexture(lut.texture, index: 2)
        enc.setSamplerState(context.lutSampler, index: 0)
        enc.setBytes(&params, length: MemoryLayout<StageParams>.stride, index: 0)
        context.dispatch2D(enc, pipeline: context.filmStagePipeline, width: destination.width, height: destination.height)
        enc.endEncoding()
    }

    func run(source: MTLTexture, destination: MTLTexture, lut: LUTTexture, exposureStops: Double) async throws {
        guard let cb = context.queue.makeCommandBuffer() else { throw FilmEngineError.commandFailed("no command buffer") }
        encode(source: source, destination: destination, lut: lut, exposureStops: exposureStops, commandBuffer: cb)
        try await cb.commitAndWait()
    }
}

extension MTLCommandBuffer {
    func commitAndWait() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            addCompletedHandler { _ in cont.resume() }
            commit()
        }
        if let error { throw FilmEngineError.commandFailed(error.localizedDescription) }
    }
}
