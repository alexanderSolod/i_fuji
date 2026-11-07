import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let library = SimulationLibrary()
    let camera = CameraController()
    let renderer: PreviewRenderer?
    let developer: RAWDeveloper?
    let store = CaptureStore()

    @Published var selectedSimulationID: String {
        didSet { UserDefaults.standard.set(selectedSimulationID, forKey: "selectedSimulationID"); updatePreview() }
    }
    @Published var ev: Double = 0 { didSet { updatePreview() } }
    @Published var flashMode: AVCaptureDevice.FlashMode {
        didSet { UserDefaults.standard.set(flashMode.rawValue, forKey: "flashMode") }
    }
    /// Digital zoom on top of the selected lens: a center crop of the preview and the rendered photo.
    @Published var zoom: Double = 1 { didSet { updatePreview() } }
    static let maxZoom = 4.0
    /// Brings saved photos close to the viewfinder's brightness, measured on device (see DEVELOPMENT_LOG.md).
    /// Adjustable on the debug screen.
    static let defaultStillAnchorEV = 2.0
    @Published var previewAnchorEV: Double {
        didSet { UserDefaults.standard.set(previewAnchorEV, forKey: "previewAnchorEV"); updatePreview() }
    }
    @Published var stillAnchorEV: Double { didSet { UserDefaults.standard.set(stillAnchorEV, forKey: "stillAnchorEV") } }
    @Published var exportFormat: ExportFormat {
        didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: "exportFormat") }
    }
    @Published var skippedImport = UserDefaults.standard.bool(forKey: "skippedImport") {
        didSet { UserDefaults.standard.set(skippedImport, forKey: "skippedImport") }
    }

    @Published private(set) var cameraStatus = CameraStatus()
    @Published private(set) var lenses: [LensInfo] = []
    @Published private(set) var lastCapture: CaptureRecord?
    @Published private(set) var lastImage: UIImage?
    @Published private(set) var isCapturing = false
    @Published private(set) var previewStats: PreviewRenderer.Stats?
    @Published private(set) var previewMeter: SIMD3<Float>?
    @Published var errorMessage: String?
    @Published var cameraDenied = false

    private var started = false

    init() {
        let d = UserDefaults.standard
        selectedSimulationID = d.string(forKey: "selectedSimulationID") ?? Simulation.neutralID
        flashMode = d.object(forKey: "flashMode") == nil ? .auto : AVCaptureDevice.FlashMode(rawValue: d.integer(forKey: "flashMode")) ?? .auto
        previewAnchorEV = d.double(forKey: "previewAnchorEV")
        stillAnchorEV = d.object(forKey: "stillAnchorEV") == nil ? Self.defaultStillAnchorEV : d.double(forKey: "stillAnchorEV")
        exportFormat = ExportFormat(rawValue: d.string(forKey: "exportFormat") ?? "") ?? .heif
        if let ctx = MetalContext.shared {
            renderer = PreviewRenderer(context: ctx)
            developer = RAWDeveloper(context: ctx)
        } else {
            renderer = nil
            developer = nil
        }
        camera.renderer = renderer
        renderer?.onStats = { [weak self] s in self?.previewStats = s }
        renderer?.onMeter = { [weak self] m in self?.previewMeter = m }
        lastCapture = store.latest()
        if let rec = lastCapture, let file = rec.renderedFile {
            lastImage = UIImage(contentsOfFile: store.folder(rec.id).appendingPathComponent(file).path)
        }
        let installed = library.installBundledLUTsIfNeeded()
        if selectedSimulationID == Simulation.neutralID,
           let start = installed.first(where: { $0.displayName == "Classic Chrome" }) ?? installed.first {
            selectedSimulationID = start.id
            d.set(start.id, forKey: "selectedSimulationID") // didSet does not fire inside init
        }
    }

    var selectedSimulation: Simulation { library.simulation(id: selectedSimulationID) }

    // MARK: Camera lifecycle

    func startCamera() async {
        guard await CameraController.requestAccess() else { cameraDenied = true; return }
        cameraDenied = false
        let saved = UserDefaults.standard.string(forKey: "lensID")
        await configure(lensID: saved)
        if !started {
            started = true
            lenses = CameraController.physicalBackLenses().map {
                LensInfo(id: $0.uniqueID, name: CameraController.lensName($0), deviceType: $0.deviceType.rawValue,
                         supportsBayerRAW: UserDefaults.standard.object(forKey: "bayer.\($0.uniqueID)") as? Bool)
            }
            markLens(cameraStatus)
        }
        updatePreview()
    }

    func stopCamera() { camera.stop() }

    /// Empty when the current lens has no flash. Refreshed with the camera status.
    var supportedFlashModes: [AVCaptureDevice.FlashMode] { cameraStatus.rawAvailable ? camera.supportedFlashModes : [] }

    /// Auto -> on -> off -> auto.
    func cycleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        default: flashMode = .auto
        }
    }

    func selectLens(_ lens: LensInfo) async {
        UserDefaults.standard.set(lens.id, forKey: "lensID")
        zoom = 1
        await configure(lensID: lens.id)
        markLens(cameraStatus)
        updatePreview()
    }

    private func configure(lensID: String?) async {
        do {
            cameraStatus = try await camera.start(lensID: lensID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markLens(_ status: CameraStatus) {
        guard let id = status.lensID, let i = lenses.firstIndex(where: { $0.id == id }) else { return }
        lenses[i].supportsBayerRAW = status.rawAvailable
        UserDefaults.standard.set(status.rawAvailable, forKey: "bayer.\(id)")
    }

    /// Lenses shown in the picker: physical lenses known (or not yet known) to support Bayer RAW.
    var pickerLenses: [LensInfo] { lenses.filter { $0.supportsBayerRAW != false } }

    func updatePreview() {
        let lut = try? library.lutTexture(for: selectedSimulation)
        renderer?.update(lut: lut, exposureStops: ev + previewAnchorEV, inputMode: cameraStatus.previewMode, zoom: zoom)
    }

    /// `viewPoint` normalized to the viewfinder (0..1). Converts through the aspect-fill crop and the
    /// 90° portrait rotation to device (sensor) coordinates.
    func focus(atViewPoint p: CGPoint, viewSize: CGSize) {
        guard let dims = cameraStatus.videoDimensions else { return }
        // Buffers are rotated to portrait, so width/height swap relative to the format dimensions.
        let src = CGSize(width: CGFloat(dims.height), height: CGFloat(dims.width))
        let t = PreviewRenderer.aspectFill(src: src, dst: viewSize)
        let z = PreviewRenderer.centerZoom(t, by: Float(zoom))
        let u = p.x * CGFloat(z.x) + CGFloat(z.z)
        let v = p.y * CGFloat(z.y) + CGFloat(z.w)
        camera.focusAndExpose(at: CGPoint(x: v, y: 1 - u))
    }

    // MARK: Capture and render

    func capture() async {
        guard !isCapturing else { return }
        guard cameraStatus.rawAvailable else { errorMessage = CameraError.rawUnavailable.localizedDescription; return }
        isCapturing = true
        defer { isCapturing = false }
        let shotZoom = zoom
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            let result = try await camera.capture(flash: flashMode)
            var record = try store.save(result)
            lastCapture = record
            let (image, data, format) = try await render(dng: result.dngData, record: &record, simulation: selectedSimulation, ev: ev, zoom: shotZoom)
            lastImage = image
            try await PhotoLibrarySaver.save(rendered: data, format: format, baseName: record.baseName)
            lastCapture = record
        } catch {
            Log.error("Capture/save failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Renders a DNG with a simulation and stores the result in the capture folder.
    func render(dng: Data, record: inout CaptureRecord, simulation: Simulation, ev: Double, zoom: Double) async throws -> (UIImage, Data, ExportFormat) {
        guard let developer else { throw FilmEngineError.noMetalDevice }
        let lut = try library.lutTexture(for: simulation)
        let out = try await developer.render(dng: dng, lut: lut, exposureStops: ev + stillAnchorEV)
        let meta = RenderMetadata(simulationName: simulation.displayName, lutFileName: simulation.lutFileName,
                                  exposureEV: ev, anchorEV: stillAnchorEV, appVersion: RenderMetadata.currentAppVersion, zoom: zoom)
        let image = ImageExporter.centerCrop(out.image, zoom: zoom)
        let (data, format) = try ImageExporter.encode(image, format: exportFormat, dng: dng, metadata: meta)
        record.baselineExposure = out.baselineExposure
        record.lastRender = meta
        try store.saveRendered(data, format: format, record: &record)
        lastStillMeter = out.linearCenter
        return (UIImage(cgImage: image), data, format)
    }

    @Published private(set) var lastStillMeter: SIMD3<Float>?

    func rerender(_ record: CaptureRecord, simulation: Simulation, ev: Double) async throws -> (UIImage, Data, ExportFormat) {
        var rec = record
        let dng = try store.loadDNG(record.id)
        let result = try await render(dng: dng, record: &rec, simulation: simulation, ev: ev, zoom: record.lastRender?.zoom ?? 1)
        lastCapture = rec
        lastImage = result.0
        return result
    }

    func saveToPhotos(_ record: CaptureRecord, rendered: Data, format: ExportFormat) async {
        do {
            try await PhotoLibrarySaver.save(rendered: rendered, format: format, baseName: record.baseName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestMeter() { renderer?.requestMeter() }
}
