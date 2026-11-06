import CoreGraphics
import CoreMedia
import ImageIO
import XCTest
@testable import FilmLab

final class StorageTests: XCTestCase {
    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: OutputColor.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()!
    }

    private let meta = RenderMetadata(simulationName: "Classic Chrome", lutFileName: "XT5_FLog2_FGamut_to_ClassicChrome.cube",
                                      exposureEV: 0.33, anchorEV: -0.1, appVersion: "0.1.0")

    func testJPEGExportIsTaggedRec709WithMetadata() throws {
        let (data, format) = try ImageExporter.encode(image(), format: .jpeg, dng: nil, metadata: meta)
        XCTAssertEqual(format, .jpeg)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 64)
        XCTAssertEqual(img.colorSpace?.name, CGColorSpace.itur_709)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertTrue((tiff[kCGImagePropertyTIFFImageDescription] as? String)?.contains("Classic Chrome") == true)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware] as? String, "FilmLab 0.1.0")
    }

    func testHEIFExportOrFallback() throws {
        let (data, format) = try ImageExporter.encode(image(), format: .heif, dng: nil, metadata: meta)
        XCTAssertFalse(data.isEmpty)
        print("HEIF request produced \(format.rawValue), \(data.count) bytes")
    }

    func testCaptureStoreKeepsDNGBytesUnmodified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
        let locked = LockedCaptureSettings(exposureDurationSeconds: 0.01, iso: 100, exposureTargetBias: 0, whiteBalanceGains: [2, 1, 1.8],
                                           temperatureKelvin: 5200, tint: 0, lensPosition: 0.5, lensAperture: 1.78,
                                           deviceType: "wide", timestamp: Date())
        let result = CaptureResult(id: UUID(), dngData: bytes, rawPixelFormat: "rgg4", locked: locked,
                                   resolvedRAWDimensions: CMVideoDimensions(width: 4032, height: 3024))
        var rec = try store.save(result)
        XCTAssertEqual(try store.loadDNG(rec.id), bytes)
        try store.saveRendered(Data([1, 2, 3]), format: .jpeg, record: &rec)
        XCTAssertEqual(store.latest()?.id, rec.id)
        XCTAssertEqual(store.latest()?.renderedFile, "rendered.jpg")
        XCTAssertEqual(try store.loadDNG(rec.id), bytes)
    }
}
