import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case heif, jpeg
    var uti: UTType { self == .heif ? .heic : .jpeg }
    var fileExtension: String { self == .heif ? "heic" : "jpg" }
}

struct RenderMetadata: Codable, Sendable {
    var simulationName: String
    var lutFileName: String?
    var exposureEV: Double
    var anchorEV: Double
    var appVersion: String

    var summary: String {
        String(format: "FilmLab %@ | %@ | LUT: %@ | EV %+.2f (anchor %+.2f)", appVersion, simulationName,
               lutFileName ?? "built-in", exposureEV, anchorEV)
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// Encodes the rendered Rec.709 image, keeping EXIF/TIFF/GPS from the DNG (spec 4.7).
enum ImageExporter {
    static func encode(_ image: CGImage, format: ExportFormat, dng: Data?, metadata: RenderMetadata) throws -> (Data, ExportFormat) {
        let props = properties(fromDNG: dng, metadata: metadata)
        if let data = write(image, uti: format.uti, properties: props) { return (data, format) }
        if format == .heif, let data = write(image, uti: ExportFormat.jpeg.uti, properties: props) {
            Log.error("HEIF encoding unavailable, exported JPEG instead")
            return (data, .jpeg)
        }
        throw CameraError.captureFailed("image encoding failed")
    }

    private static func write(_ image: CGImage, uti: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func properties(fromDNG dng: Data?, metadata: RenderMetadata) -> [CFString: Any] {
        var src: [CFString: Any] = [:]
        if let dng, let source = CGImageSourceCreateWithData(dng as CFData, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] { src = p }
        var exif = src[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = src[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment] = metadata.summary
        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
        exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
        tiff[kCGImagePropertyTIFFSoftware] = "FilmLab \(metadata.appVersion)"
        tiff[kCGImagePropertyTIFFImageDescription] = metadata.summary
        tiff[kCGImagePropertyTIFFOrientation] = 1
        var out: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyOrientation: 1,          // pixels are already upright
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        if let gps = src[kCGImagePropertyGPSDictionary] { out[kCGImagePropertyGPSDictionary] = gps }
        return out
    }
}
