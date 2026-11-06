import CoreVideo
import Metal
import simd
import XCTest
@testable import FilmLab

final class FilmEngineTests: XCTestCase {
    var ctx: MetalContext!

    override func setUpWithError() throws {
        ctx = try XCTUnwrap(MetalContext.shared, "Metal unavailable")
    }

    private func run(_ body: (MTLComputeCommandEncoder) -> Void) throws {
        let cb = try XCTUnwrap(ctx.queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        body(enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
    }

    // MARK: Curves in Metal (spec 2.3)

    func testMetalCurves() throws {
        let j = try Fixtures.json("curves.json")
        let lin = Fixtures.doubles(j["linear"])
        let flogExpected = Fixtures.doubles(j["flog2_encode"])
        let codes = Fixtures.doubles(j["applelog_codes"])
        let alExpected = Fixtures.doubles(j["applelog_decode"])

        let inputs = (lin + codes + [0.18, 0.000889]).map(Float.init)
        let inBuf = try XCTUnwrap(ctx.device.makeBuffer(bytes: inputs, length: inputs.count * 4))
        let outBuf = try XCTUnwrap(ctx.device.makeBuffer(length: inputs.count * 8))
        try run { enc in
            enc.setComputePipelineState(ctx.curveEvalPipeline)
            enc.setBuffer(inBuf, offset: 0, index: 0)
            enc.setBuffer(outBuf, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        let out = outBuf.contents().bindMemory(to: Float.self, capacity: inputs.count * 2)
        for i in 0..<lin.count {
            XCTAssertEqual(Double(out[2 * i + 1]), flogExpected[i], accuracy: 2e-6, "F-Log2(\(lin[i]))")
        }
        for i in 0..<codes.count {
            let k = lin.count + i
            XCTAssertEqual(Double(out[2 * k]), alExpected[i], accuracy: max(abs(alExpected[i]) * 2e-5, 2e-6), "AppleLog⁻¹(\(codes[i]))")
        }
        let gray = lin.count + codes.count
        XCTAssertEqual(out[2 * gray + 1], 0.391, accuracy: 0.002)
        XCTAssertEqual(out[2 * (gray + 1) + 1], 0.100686, accuracy: 1e-5)
        // Apple Log code for 18% gray decodes back to 0.18.
        let alGray = Float(AppleLog.encode(0.18))
        XCTAssertEqual(Float(AppleLog.decode(Double(alGray))), 0.18, accuracy: 1e-6)
    }

    // MARK: LUT sampling (spec 2.4)

    func testMetalLUTSamplingMatchesPython() throws {
        let lut = try LUTTexture(lut: Fixtures.testLUT(), device: ctx.device)
        let j = try Fixtures.json("lut_samples.json")
        let inputs = Fixtures.triples(j["inputs"])
        let outputs = Fixtures.triples(j["outputs"])
        let packed = inputs.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
        let inBuf = try XCTUnwrap(ctx.device.makeBuffer(bytes: packed, length: packed.count * 16))
        let outBuf = try XCTUnwrap(ctx.device.makeBuffer(length: packed.count * 16))
        var params = StageParams(lut: lut, exposureStops: 0)
        try run { enc in
            enc.setComputePipelineState(ctx.lutSamplePipeline)
            enc.setBytes(&params, length: MemoryLayout<StageParams>.stride, index: 0)
            enc.setBuffer(inBuf, offset: 0, index: 1)
            enc.setBuffer(outBuf, offset: 0, index: 2)
            enc.setTexture(lut.texture, index: 0)
            enc.setSamplerState(ctx.lutSampler, index: 0)
            enc.dispatchThreads(MTLSize(width: packed.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        let out = outBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: packed.count)
        var maxErr = 0.0
        for i in 0..<packed.count {
            let o = SIMD3<Double>(Double(out[i].x), Double(out[i].y), Double(out[i].z))
            maxErr = max(maxErr, simd_reduce_max(simd_abs(o - outputs[i])))
        }
        print("Metal LUT sampling max abs error: \(maxErr), texture format \(lut.texture.pixelFormat.rawValue)")
        XCTAssertLessThan(maxErr, 1e-3)
    }

    // MARK: Full shared stage on a fixture image (M2 acceptance)

    private func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return try XCTUnwrap(ctx.device.makeTexture(descriptor: d))
    }

    private func readRGBA32(_ tex: MTLTexture) -> [SIMD4<Float>] {
        var px = [SIMD4<Float>](repeating: .zero, count: tex.width * tex.height)
        px.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * 16, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        }
        return px
    }

    func testStageImageMatchesPython() async throws {
        let j = try Fixtures.json("stage_image.json")
        let w = try XCTUnwrap(j["width"] as? Int), h = try XCTUnwrap(j["height"] as? Int)
        let input = Fixtures.triples(j["input"]).map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
        let src = try makeTexture(.rgba32Float, w, h)
        input.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16)
        }
        let dst = try makeTexture(.rgba32Float, w, h)
        let stage = FilmStage(context: ctx)
        let testLUT = try LUTTexture(lut: Fixtures.testLUT(), device: ctx.device)
        let neutral = try LUTTexture(lut: NeutralLUT.make(size: 33), device: ctx.device)

        let cases: [(String, LUTTexture, Double)] = [
            ("output_ev+0.0", testLUT, 0), ("output_ev+0.7", testLUT, 0.7),
            ("output_ev-1.3", testLUT, -1.3), ("output_neutral_ev+0.0", neutral, 0),
        ]
        for (key, lut, ev) in cases {
            try await stage.run(source: src, destination: dst, lut: lut, exposureStops: ev)
            let expected = Fixtures.triples(j[key])
            let out = readRGBA32(dst)
            var sum = 0.0, maxErr = 0.0
            for (o, e) in zip(out, expected) {
                let d = simd_abs(SIMD3<Double>(Double(o.x), Double(o.y), Double(o.z)) - e)
                sum += d.x + d.y + d.z
                maxErr = max(maxErr, simd_reduce_max(d))
            }
            let mae = sum / Double(expected.count * 3)
            print("Stage \(key): MAE \(mae), max \(maxErr)")
            XCTAssertLessThan(mae, 1e-3, key)
            XCTAssertLessThan(maxErr, 5e-3, key)
        }
    }

    // MARK: Preview Y'CbCr decode (10-bit, video and full range)

    private func makeYCbCrBuffer(format: OSType, samples: [(Int, Int, Int)]) throws -> CVPixelBuffer {
        let blocksX = 16, blocksY = samples.count / 16
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, blocksX * 2, blocksY * 2, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        for (i, s) in samples.enumerated() {
            let bx = i % blocksX, by = i / blocksX
            for dy in 0..<2 { for dx in 0..<2 { yBase[(by * 2 + dy) * yStride + bx * 2 + dx] = UInt16(s.0) << 6 } }
            cBase[by * cStride + bx * 2] = UInt16(s.1) << 6
            cBase[by * cStride + bx * 2 + 1] = UInt16(s.2) << 6
        }
        return buffer
    }

    func testPreviewDecodeMatchesPython() throws {
        let j = try Fixtures.json("preview_ycbcr.json")
        var cacheRef: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &cacheRef)
        let cache = try XCTUnwrap(cacheRef)
        for (key, format) in [("video_range", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                              ("full_range", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)] {
            let d = try XCTUnwrap(j[key] as? [String: Any])
            let y = Fixtures.doubles(d["y"]), cb = Fixtures.doubles(d["cb"]), cr = Fixtures.doubles(d["cr"])
            let expected = Fixtures.triples(d["linear"])
            let samples = (0..<y.count).map { (Int(y[$0]), Int(cb[$0]), Int(cr[$0])) }
            let buffer = try makeYCbCrBuffer(format: format, samples: samples)
            let planes = try XCTUnwrap(PreviewRenderer.planeTextures(buffer, cache: cache))
            var decode = try XCTUnwrap(PreviewRenderer.decodeParams(for: buffer, mode: .appleLog))
            let out = try makeTexture(.rgba32Float, planes.luma.width, planes.luma.height)
            var origin = SIMD2<UInt32>(0, 0)
            try run { enc in
                enc.setComputePipelineState(ctx.ycbcrToLinearPipeline)
                enc.setTexture(planes.luma, index: 0)
                enc.setTexture(planes.chroma, index: 1)
                enc.setTexture(out, index: 2)
                enc.setBytes(&decode, length: MemoryLayout<DecodeParams>.stride, index: 1)
                enc.setBytes(&origin, length: 8, index: 3)
                ctx.dispatch2D(enc, pipeline: ctx.ycbcrToLinearPipeline, width: out.width, height: out.height)
            }
            let px = readRGBA32(out)
            var maxRel = 0.0
            for i in 0..<samples.count {
                let p = px[(i / 16) * 2 * out.width + (i % 16) * 2]
                let o = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
                let rel = simd_abs(o - expected[i]) / simd_max(simd_abs(expected[i]), SIMD3(repeating: 0.01))
                maxRel = max(maxRel, simd_reduce_max(rel))
            }
            print("Preview decode \(key): max relative error \(maxRel)")
            XCTAssertLessThan(maxRel, 1e-3, key)
        }
    }

    func testAspectFill() {
        let t = PreviewRenderer.aspectFill(src: CGSize(width: 1080, height: 1920), dst: CGSize(width: 1206, height: 2622))
        // Source (9:16) is wider than the destination (~0.46): crop left/right.
        XCTAssertLessThan(t.x, 1)
        XCTAssertEqual(t.y, 1)
        XCTAssertEqual(t.z, (1 - t.x) / 2, accuracy: 1e-6)
    }
}
