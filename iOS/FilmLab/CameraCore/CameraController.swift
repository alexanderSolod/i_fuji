@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Owns the AVCaptureSession. All session work happens on `sessionQueue`; frames are delivered
/// on `videoQueue` straight to the preview renderer.
final class CameraController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "filmlab.camera.session")
    private let videoQueue = DispatchQueue(label: "filmlab.camera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var bayerFormat: OSType?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var outputsAdded = false

    weak var renderer: PreviewRenderer?
    private(set) var status = CameraStatus()

    static let lensTypes: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]

    // MARK: Permissions and discovery

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Physical back cameras only (never a virtual multi-camera device).
    static func physicalBackLenses() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: lensTypes, mediaType: .video, position: .back).devices
            .filter { !$0.isVirtualDevice }
    }

    static func lensName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5x"
        case .builtInTelephotoCamera: return "Tele"
        default: return "1x"
        }
    }

    // MARK: Session

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async { cont.resume(with: Result { try work() }) }
        }
    }

    /// Configures the session for `lensID` (or the back wide camera) and starts it.
    func start(lensID: String?) async throws -> CameraStatus {
        try await run { [self] in
            let status = try configure(lensID: lensID)
            if !session.isRunning { session.startRunning() }
            return status
        }
    }

    func stop() {
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func device(for lensID: String?) -> AVCaptureDevice? {
        if let lensID, let d = AVCaptureDevice(uniqueID: lensID), !d.isVirtualDevice { return d }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func bayerTypes() -> [OSType] {
        photoOutput.availableRawPhotoPixelFormatTypes.filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    /// Spec 3.1: try an Apple Log format that also offers Bayer RAW; otherwise keep Bayer RAW and
    /// use an approximate non-log preview.
    private func configure(lensID: String?) throws -> CameraStatus {
        let t0 = CACurrentMediaTime()
        guard let device = device(for: lensID) else { throw CameraError.noDevice }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if deviceInput?.device != device {
            if let old = deviceInput { session.removeInput(old) }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configurationFailed("cannot add input") }
            session.addInput(input)
            deviceInput = input
        }
        if !outputsAdded {
            guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
                throw CameraError.configurationFailed("cannot add outputs")
            }
            session.addOutput(photoOutput)
            session.addOutput(videoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            outputsAdded = true
        }
        photoOutput.isAppleProRAWEnabled = false

        var mode = PreviewInputMode.approximateRec709
        var bayer: OSType?

        for format in Self.appleLogFormats(device) {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeColorSpace = .appleLog
            device.unlockForConfiguration()
            // availableRawPhotoPixelFormatTypes reflects the configuration once committed.
            session.commitConfiguration()
            session.beginConfiguration()
            if let b = bayerTypes().first {
                mode = .appleLog
                bayer = b
                Log.info("Apple Log + Bayer RAW OK: \(Self.describe(format)), RAW \(fourCC(b))")
                break
            }
            Log.info("Apple Log format without Bayer RAW: \(Self.describe(format))")
        }

        if bayer == nil {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            try device.lockForConfiguration()
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            device.unlockForConfiguration()
            session.commitConfiguration()
            session.beginConfiguration()
            bayer = bayerTypes().first
            Log.info("Fallback preset .photo: format \(Self.describe(device.activeFormat)), Bayer RAW \(bayer.map(fourCC) ?? "none")")
        }
        bayerFormat = bayer

        // Video output pixel format: prefer the format's native 4:2:0 subtype.
        let available = videoOutput.availableVideoPixelFormatTypes
        let native = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        let preferred: [OSType] = mode == .appleLog
            ? [native, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
            : [native, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        let pixelFormat = preferred.first { available.contains($0) && PreviewRenderer.format(of: $0) != nil }
        if let pixelFormat {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        } else {
            Log.error("No supported 4:2:0 video format. Available: \(available.map(fourCC))")
        }

        for output in [videoOutput, photoOutput] as [AVCaptureOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }

        // 12MP Bayer RAW: largest supported photo size at or below ~12.6MP.
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let raw = dims.filter { Int($0.width) * Int($0.height) <= 12_600_000 }
            .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) } ?? dims.first
        if let raw { photoOutput.maxPhotoDimensions = raw }

        let videoDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var s = CameraStatus(lensID: device.uniqueID, previewMode: mode, bayerRAWFormat: bayer.map(fourCC),
                             rawDimensions: bayer == nil ? nil : raw, videoPixelFormat: pixelFormat.map(fourCC),
                             videoDimensions: videoDims)
        s.reconfigureMs = (CACurrentMediaTime() - t0) * 1000
        Log.info(String(format: "Configured %@: %@, %@, video %@, %.0f ms", Self.lensName(device), s.rawLabel,
                        s.previewLabel, s.videoPixelFormat ?? "?", s.reconfigureMs))
        status = s
        return s
    }

    static func appleLogFormats(_ device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        device.formats
            .filter { $0.supportedColorSpaces.contains(.appleLog) }
            .sorted { a, b in
                // Prefer formats with the largest photo dimensions, then 1080p-class video for preview cost.
                let pa = a.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
                let pb = b.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
                if pa != pb { return pa > pb }
                let va = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let vb = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(Int(va.width) - 1920) < abs(Int(vb.width) - 1920)
            }
    }

    static func describe(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let fps = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }.joined(separator: "/")
        let photo = f.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
        let cs = f.supportedColorSpaces.map { cs -> String in
            switch cs {
            case .sRGB: return "sRGB"
            case .P3_D65: return "P3"
            case .HLG_BT2020: return "HLG"
            case .appleLog: return "AppleLog"
            default: return "cs\(cs.rawValue)"
            }
        }.joined(separator: ",")
        return "\(d.width)x\(d.height) \(fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))) \(fps)fps photo[\(photo)] [\(cs)]"
    }

    // MARK: Capture

    func capture() async throws -> CaptureResult {
        let (settings, processor): (AVCapturePhotoSettings, PhotoCaptureProcessor) = try await run { [self] in
            guard let bayerFormat, let device = deviceInput?.device else { throw CameraError.rawUnavailable }
            let settings = AVCapturePhotoSettings(rawPixelFormatType: bayerFormat)
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            settings.flashMode = .off
            let gains = device.deviceWhiteBalanceGains
            let tt = device.temperatureAndTintValues(for: gains)
            let locked = LockedCaptureSettings(
                exposureDurationSeconds: device.exposureDuration.seconds, iso: device.iso,
                exposureTargetBias: device.exposureTargetBias,
                whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain],
                temperatureKelvin: tt.temperature, tint: tt.tint, lensPosition: device.lensPosition,
                lensAperture: device.lensAperture, deviceType: device.deviceType.rawValue, timestamp: Date())
            let p = PhotoCaptureProcessor(locked: locked, rawFormat: fourCC(bayerFormat))
            inFlight[settings.uniqueID] = p
            return (settings, p)
        }
        defer { sessionQueue.async { [self] in inFlight[settings.uniqueID] = nil } }
        return try await withCheckedThrowingContinuation { cont in
            processor.continuation = cont
            sessionQueue.async { [self] in photoOutput.capturePhoto(with: settings, delegate: processor) }
        }
    }

    // MARK: Focus / exposure

    /// `point` is in device coordinates (0,0 top-left of the unrotated sensor, 1,1 bottom-right).
    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = deviceInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer?.enqueue(pb)
    }
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let locked: LockedCaptureSettings
    let rawFormat: String
    var continuation: CheckedContinuation<CaptureResult, Error>?
    private var dng: Data?
    private var dims = CMVideoDimensions(width: 0, height: 0)

    init(locked: LockedCaptureSettings, rawFormat: String) {
        self.locked = locked
        self.rawFormat = rawFormat
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { Log.error("Photo processing error: \(error.localizedDescription)"); return }
        guard photo.isRawPhoto else { return }
        dng = photo.fileDataRepresentation()
        dims = photo.resolvedSettings.rawPhotoDimensions
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        defer { continuation = nil }
        if let error { continuation?.resume(throwing: CameraError.captureFailed(error.localizedDescription)); return }
        guard let dng else { continuation?.resume(throwing: CameraError.captureFailed("no RAW data")); return }
        Log.info("Captured Bayer DNG \(dims.width)x\(dims.height) (\(rawFormat)), \(dng.count / 1024) KB, "
                 + String(format: "%.4fs ISO %.0f", locked.exposureDurationSeconds, locked.iso))
        continuation?.resume(returning: CaptureResult(id: UUID(), dngData: dng, rawPixelFormat: rawFormat,
                                                      locked: locked, resolvedRAWDimensions: dims))
    }
}
