import SwiftUI

/// Diagnostics, anchor tuning (spec 4.10), simulation management and the log.
struct DebugScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SimulationLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Simulation?
    @State private var newName = ""
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    row("RAW", model.cameraStatus.rawLabel)
                    row("Preview", model.cameraStatus.previewMode == .appleLog ? "Apple Log (exact)" : "Approx. Rec.709")
                    row("Video format", model.cameraStatus.videoPixelFormat ?? "-")
                    row("Reconfigure", String(format: "%.0f ms", model.cameraStatus.reconfigureMs))
                    if let s = model.previewStats {
                        row("Preview FPS", String(format: "%.0f", s.fps))
                        row("GPU / frame", String(format: "%.2f ms", s.gpuMs))
                        row("Buffer", "\(Int(s.bufferSize.width))x\(Int(s.bufferSize.height)) \(s.pixelFormat)")
                    }
                }
                Section {
                    Button("Meter preview center (gray card)") { model.requestMeter() }
                    if let m = model.previewMeter { row("Preview linear", fmt(m)) }
                    if let m = model.lastStillMeter { row("Last still linear", fmt(m)) }
                    if let m = model.previewMeter, let s = model.lastStillMeter {
                        let p = (m.x + m.y + m.z) / 3, q = (s.x + s.y + s.z) / 3
                        if p > 0, q > 0 {
                            row("Suggested preview anchor", String(format: "%+.2f EV", log2(0.18 / Double(p))))
                            row("Suggested still anchor", String(format: "%+.2f EV", log2(0.18 / Double(q))))
                        }
                    }
                    Stepper(String(format: "Preview anchor %+.2f EV", model.previewAnchorEV), value: $model.previewAnchorEV, in: -4...4, step: 0.05)
                    Stepper(String(format: "Still anchor %+.2f EV", model.stillAnchorEV), value: $model.stillAnchorEV, in: -4...4, step: 0.05)
                } header: { Text("Exposure anchor") } footer: {
                    Text("Fill the center with an 18% gray card, meter it, then capture it. The anchor makes the card land at scene-linear 0.18.")
                }
                Section("Output") {
                    Picker("Format", selection: $model.exportFormat) {
                        Text("HEIF").tag(ExportFormat.heif)
                        Text("JPEG").tag(ExportFormat.jpeg)
                    }
                }
                Section("Simulations") {
                    ForEach(library.simulations) { sim in
                        HStack {
                            Text(sim.displayName)
                            Spacer()
                            Text(sim.lutFileName.map { String($0.drop(while: { $0 != "_" }).dropFirst()) } ?? "built-in")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .swipeActions {
                            if !sim.isBuiltIn {
                                Button("Delete", role: .destructive) { library.delete(sim.id) }
                                Button("Rename") { renaming = sim; newName = sim.displayName }
                            }
                        }
                    }
                }
                Section("Log") {
                    ShareLink(item: logText.isEmpty ? Log.lines.joined(separator: "\n") : logText) { Text("Share log") }
                    Text(Log.lines.suffix(80).joined(separator: "\n")).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { logText = Log.lines.joined(separator: "\n") }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let r = renaming { library.rename(r.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).font(.callout.monospaced()) }
    }

    private func fmt(_ v: SIMD3<Float>) -> String { String(format: "%.4f %.4f %.4f", v.x, v.y, v.z) }
}
