import SwiftUI

@main
struct FilmLabApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.library)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SimulationLibrary

    var body: some View {
        if library.importedCount == 0 && !model.skippedImport {
            ImportLUTsScreen()
        } else {
            CameraScreen()
        }
    }
}
