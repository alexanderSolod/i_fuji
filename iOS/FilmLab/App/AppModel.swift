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
        previewAnchorEV = d.double(forKey: "previewAnchorEV")
        stillAnchorEV = d.double(forKey: "stillAnchorEV")
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

    func selectLens(_ lens: LensInfo) async {
        UserDefaults.standard.set(lens.id, forKey: "lensID")
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
        renderer?.update(lut: lut, exposureStops: ev + previewAnchorEV, inputMode: cameraStatus.previewMode)
    }

    /// `viewPoint` normalized to the viewfinder (0..1). Converts through the aspect-fill crop and the
    /// 90° portrait rotation to device (sensor) coordinates.
    func focus(atViewPoint p: CGPoint, viewSize: CGSize) {
        guard let dims = cameraStatus.videoDimensions else { return }
        // Buffers are rotated to portrait, so width/height swap relative to the format dimensions.
        let src = CGSize(width: CGFloat(dims.height), height: CGFloat(dims.width))
        let t = PreviewRenderer.aspectFill(src: src, dst: viewSize)
        let u = p.x * CGFloat(t.x) + CGFloat(t.z)
        let v = p.y * CGFloat(t.y) + CGFloat(t.w)
        camera.focusAndExpose(at: CGPoint(x: v, y: 1 - u))
    }

    // MARK: Capture and render

    func capture() async {
        guard !isCapturing else { return }
        guard cameraStatus.rawAvailable else { errorMessage = CameraError.rawUnavailable.localizedDescription; return }
        isCapturing = true
        defer { isCapturing = false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            let result = try await camera.capture()
            var record = try store.save(result)
            lastCapture = record
            let (image, data, format) = try await render(dng: result.dngData, record: &record, simulation: selectedSimulation, ev: ev)
            lastImage = image
            try await PhotoLibrarySaver.savePair(rendered: data, format: format, dng: result.dngData, baseName: record.baseName)
            lastCapture = record
        } catch {
            Log.error("Capture/save failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Renders a DNG with a simulation and stores the result in the capture folder.
    func render(dng: Data, record: inout CaptureRecord, simulation: Simulation, ev: Double) async throws -> (UIImage, Data, ExportFormat) {
        guard let developer else { throw FilmEngineError.noMetalDevice }
        let lut = try library.lutTexture(for: simulation)
        let out = try await developer.render(dng: dng, lut: lut, exposureStops: ev + stillAnchorEV)
        let meta = RenderMetadata(simulationName: simulation.displayName, lutFileName: simulation.lutFileName,
                                  exposureEV: ev, anchorEV: stillAnchorEV, appVersion: RenderMetadata.currentAppVersion)
        let (data, format) = try ImageExporter.encode(out.image, format: exportFormat, dng: dng, metadata: meta)
        record.baselineExposure = out.baselineExposure
        record.lastRender = meta
        try store.saveRendered(data, format: format, record: &record)
        lastStillMeter = out.linearCenter
        return (UIImage(cgImage: out.image), data, format)
    }

    @Published private(set) var lastStillMeter: SIMD3<Float>?

    func rerender(_ record: CaptureRecord, simulation: Simulation, ev: Double) async throws -> (UIImage, Data, ExportFormat) {
        var rec = record
        let dng = try store.loadDNG(record.id)
        let result = try await render(dng: dng, record: &rec, simulation: simulation, ev: ev)
        lastCapture = rec
        lastImage = result.0
        return result
    }

    func saveToPhotos(_ record: CaptureRecord, rendered: Data, format: ExportFormat) async {
        do {
            try await PhotoLibrarySaver.savePair(rendered: rendered, format: format, dng: try store.loadDNG(record.id),
                                                 baseName: record.baseName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestMeter() { renderer?.requestMeter() }
}
