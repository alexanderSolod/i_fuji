import AVFoundation
import Foundation

struct LensInfo: Identifiable, Hashable, Sendable {
    let id: String          // AVCaptureDevice.uniqueID
    let name: String        // "1x", "0.5x", "4x"...
    let deviceType: String
    var supportsBayerRAW: Bool?
}

/// What the current session configuration delivers.
struct CameraStatus: Equatable, Sendable {
    var lensID: String?
    var previewMode: PreviewInputMode = .approximateRec709
    var bayerRAWFormat: String?
    var rawDimensions: CMVideoDimensions?
    var videoPixelFormat: String?
    var videoDimensions: CMVideoDimensions?
    var reconfigureMs: Double = 0

    var rawAvailable: Bool { bayerRAWFormat != nil }

    var rawLabel: String {
        guard rawAvailable, let d = rawDimensions else { return "RAW unavailable" }
        let mp = Double(d.width) * Double(d.height) / 1_000_000
        return String(format: "RAW %.0fMP", mp.rounded())
    }

    var previewLabel: String { previewMode == .appleLog ? "Preview: Apple Log" : "Preview approx." }
}

extension CMVideoDimensions: @retroactive Equatable {
    public static func == (a: CMVideoDimensions, b: CMVideoDimensions) -> Bool { a.width == b.width && a.height == b.height }
}

/// Camera values in effect when the shutter was pressed (spec 4.3).
struct LockedCaptureSettings: Codable, Sendable {
    var exposureDurationSeconds: Double
    var iso: Float
    var exposureTargetBias: Float
    var whiteBalanceGains: [Float]       // R, G, B
    var temperatureKelvin: Float
    var tint: Float
    var lensPosition: Float
    var lensAperture: Float
    var deviceType: String
    var timestamp: Date
}

struct CaptureResult: Sendable {
    let id: UUID
    let dngData: Data
    let rawPixelFormat: String
    let locked: LockedCaptureSettings
    let resolvedRAWDimensions: CMVideoDimensions
    var flashFired = false
}

enum CameraError: Error, LocalizedError {
    case notAuthorized
    case noDevice
    case configurationFailed(String)
    case rawUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access is off. Enable it in Settings > FilmLab."
        case .noDevice: return "No back camera found."
        case .configurationFailed(let m): return "Camera configuration failed: \(m)"
        case .rawUnavailable: return "Bayer RAW is not available with this camera configuration."
        case .captureFailed(let m): return "Capture failed: \(m)"
        }
    }
}
