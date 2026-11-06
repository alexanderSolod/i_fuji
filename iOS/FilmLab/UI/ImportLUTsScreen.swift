import SwiftUI
import UniformTypeIdentifiers

struct ImportLUTsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SimulationLibrary
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    @State private var showPicker = false
    @State private var failures: [String] = []

    static let cubeType = UTType(filenameExtension: "cube") ?? .data

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import Fujifilm LUTs").font(.largeTitle.bold())
            Text("""
            FilmLab uses Fujifilm's official F-Log2 to Rec.709 film simulation LUTs. Any built into this copy of the app are already installed; to add more:

            1. On fujifilm-x.com, download the F-Log2 LUT package for your camera (for example the X-T5 or X-H2).
            2. Unzip it in the Files app.
            3. Tap Import and select the .cube files you want ("F-Log2 to …" for each film simulation, not the WDR or F-Log ones).
            """)
            .font(.callout)
            if library.importedCount > 0 {
                Text("\(library.importedCount) simulation(s) imported.").foregroundStyle(.green)
            }
            ForEach(failures, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
            Spacer()
            Button { showPicker = true } label: {
                Text("Import .cube files").frame(maxWidth: .infinity).padding().background(.white, in: Capsule()).foregroundStyle(.black)
            }
            Button(library.importedCount > 0 || isSheet ? "Done" : "Continue with Neutral only") {
                model.skippedImport = true
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [Self.cubeType, .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                failures = library.importLUTs(from: urls).map { "\($0.file): \($0.error.localizedDescription)" }
                if let first = library.simulations.last(where: { !$0.isBuiltIn }), model.selectedSimulationID == Simulation.neutralID {
                    model.selectedSimulationID = first.id
                }
            case .failure(let error):
                failures = [error.localizedDescription]
            }
        }
    }
}
