import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SimulationLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReview = false
    @State private var showDebug = false
    @State private var showImport = false
    @State private var focusPoint: CGPoint?
    @State private var dragStartEV: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.cameraDenied {
                permissionView
            } else {
                viewfinder
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                evBadge
                SimulationPicker(selection: $model.selectedSimulationID, onImport: { showImport = true })
                bottomBar
            }
            .padding(.bottom, 8)
        }
        .task { await model.startCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.startCamera() } } else if phase == .background { model.stopCamera() }
        }
        .onChange(of: library.simulations) { _, _ in model.updatePreview() }
        .sheet(isPresented: $showReview) { ReviewScreen() }
        .sheet(isPresented: $showDebug) { DebugScreen() }
        .sheet(isPresented: $showImport) { NavigationStack { ImportLUTsScreen(isSheet: true) } }
        .alert("FilmLab", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ViewfinderView(renderer: model.renderer)
                .overlay {
                    if let p = focusPoint {
                        RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 1.5)
                            .frame(width: 70, height: 70).position(p).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    focusPoint = value.location
                    model.focus(atViewPoint: CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height),
                                viewSize: geo.size)
                    Task { try? await Task.sleep(for: .seconds(1.5)); focusPoint = nil }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
                    if dragStartEV == nil { dragStartEV = model.ev }
                    let delta = -Double(value.translation.height) / 120
                    model.ev = min(2, max(-2, ((dragStartEV ?? 0) + delta) * 3).rounded() / 3)
                }.onEnded { _ in dragStartEV = nil })
        }
        .ignoresSafeArea()
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Text("FilmLab needs camera access.").font(.headline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var topBar: some View {
        HStack {
            StatusChip(status: model.cameraStatus)
            Spacer()
            Button { showDebug = true } label: {
                Image(systemName: "slider.horizontal.3").padding(10).background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
    }

    private var evBadge: some View {
        HStack(spacing: 14) {
            Button { model.ev = max(-2, model.ev - 1.0 / 3) } label: { Image(systemName: "minus") }
            Text(String(format: "%+.1f EV", model.ev)).monospacedDigit().onTapGesture { model.ev = 0 }
            Button { model.ev = min(2, model.ev + 1.0 / 3) } label: { Image(systemName: "plus") }
        }
        .font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var bottomBar: some View {
        HStack {
            Button { showReview = model.lastCapture != nil } label: {
                Group {
                    if let image = model.lastImage {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            Button { Task { await model.capture() } } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(model.isCapturing ? .gray : .white).frame(width: 64, height: 64)
                    if model.isCapturing { ProgressView().tint(.black) }
                }
            }
            .disabled(model.isCapturing || !model.cameraStatus.rawAvailable)
            Spacer()
            LensPicker()
                .frame(width: 56)
        }
        .padding(.horizontal, 24)
    }
}

struct StatusChip: View {
    let status: CameraStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.rawLabel)
            Text(status.previewLabel).foregroundStyle(status.previewMode == .appleLog ? Color.primary : Color.orange)
        }
        .font(.caption2.monospaced())
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LensPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let lenses = model.pickerLenses
        if lenses.count > 1 {
            VStack(spacing: 6) {
                ForEach(lenses) { lens in
                    Button(lens.name) { Task { await model.selectLens(lens) } }
                        .font(.caption.bold())
                        .frame(width: 44, height: 28)
                        .background(lens.id == model.cameraStatus.lensID ? Color.yellow.opacity(0.85) : Color.black.opacity(0.4),
                                    in: Capsule())
                        .foregroundStyle(lens.id == model.cameraStatus.lensID ? .black : .white)
                }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

struct SimulationPicker: View {
    @EnvironmentObject var library: SimulationLibrary
    @Binding var selection: String
    var onImport: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(library.simulations) { sim in
                        Text(sim.displayName)
                            .font(.footnote.weight(sim.id == selection ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(sim.id == selection ? Color.white : Color.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(sim.id == selection ? .black : .white)
                            .id(sim.id)
                            .onTapGesture { selection = sim.id }
                    }
                    Button(action: onImport) {
                        Image(systemName: "plus").padding(8).background(Color.black.opacity(0.45), in: Circle())
                    }
                }
                .padding(.horizontal)
            }
            .sensoryFeedback(.selection, trigger: selection)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}
