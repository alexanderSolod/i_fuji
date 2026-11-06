import Metal

/// A `.cube` LUT uploaded as a 3D texture. x = red, y = green, z = blue (red fastest, as in the file).
final class LUTTexture: @unchecked Sendable {
    let texture: MTLTexture
    let size: Int
    let domainMin: SIMD3<Double>
    let domainMax: SIMD3<Double>

    init(lut: CubeLUT, device: MTLDevice) throws {
        let n = lut.size
        // Texels are read directly (manual trilinear in the shader), so fp32 needs no filtering support.
        let use32 = true
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = use32 ? .rgba32Float : .rgba16Float
        desc.width = n
        desc.height = n
        desc.depth = n
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw FilmEngineError.textureCreation }
        let region = MTLRegionMake3D(0, 0, 0, n, n, n)
        if use32 {
            var rgba = [Float](repeating: 1, count: n * n * n * 4)
            for (i, v) in lut.values.enumerated() {
                rgba[i * 4] = v.x; rgba[i * 4 + 1] = v.y; rgba[i * 4 + 2] = v.z
            }
            rgba.withUnsafeBytes {
                tex.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: n * 16, bytesPerImage: n * n * 16)
            }
        } else {
            var rgba = [Float16](repeating: 1, count: n * n * n * 4)
            for (i, v) in lut.values.enumerated() {
                rgba[i * 4] = Float16(v.x); rgba[i * 4 + 1] = Float16(v.y); rgba[i * 4 + 2] = Float16(v.z)
            }
            rgba.withUnsafeBytes {
                tex.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: n * 8, bytesPerImage: n * n * 8)
            }
        }
        texture = tex
        size = n
        domainMin = lut.domainMin
        domainMax = lut.domainMax
    }
}
