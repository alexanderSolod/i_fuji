import SwiftUI

struct ReviewScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SimulationLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var simulationID = Simulation.neutralID
    @State private var ev = 0.0
    @State private var image: UIImage?
    @State private var rendered: (Data, ExportFormat)?
    @State private var busy = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    if let image = image ?? model.lastImage {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    if busy { ProgressView() }
                }
                .frame(maxHeight: .infinity)
                if let rec = model.lastCapture {
                    Text(info(rec)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                SimulationPicker(selection: $simulationID, onImport: {})
                HStack {
                    Text(String(format: "%+.1f EV", ev)).monospacedDigit().frame(width: 70)
                    Slider(value: $ev, in: -2...2, step: 1.0 / 3)
                }
                .padding(.horizontal)
                HStack {
                    Button("Re-render") { Task { await rerender() } }.disabled(busy)
                    Spacer()
                    Button(saved ? "Saved" : "Save to Photos") { Task { await save() } }
                        .disabled(busy || rendered == nil || saved)
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear {
            if let r = model.lastCapture?.lastRender {
                ev = r.exposureEV
                simulationID = library.simulations.first { $0.displayName == r.simulationName }?.id ?? model.selectedSimulationID
            } else {
                simulationID = model.selectedSimulationID
            }
        }
    }

    private func info(_ rec: CaptureRecord) -> String {
        let l = rec.locked
        return String(format: "%@ %dx%d  ISO %.0f  1/%.0fs  WB %.0fK  baseline %+.2f", rec.rawPixelFormat, rec.rawWidth, rec.rawHeight,
                      l.iso, 1 / max(l.exposureDurationSeconds, 1e-6), l.temperatureKelvin, rec.baselineExposure ?? 0)
    }

    private func rerender() async {
        guard let rec = model.lastCapture else { return }
        busy = true
        defer { busy = false }
        do {
            let (img, data, format) = try await model.rerender(rec, simulation: library.simulation(id: simulationID), ev: ev)
            image = img
            rendered = (data, format)
            saved = false
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let rec = model.lastCapture, let (data, format) = rendered else { return }
        busy = true
        await model.saveToPhotos(rec, rendered: data, format: format)
        busy = false
        saved = model.errorMessage == nil
    }
}
