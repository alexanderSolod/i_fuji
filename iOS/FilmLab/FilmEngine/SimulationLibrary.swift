import Foundation
import Metal

struct Simulation: Codable, Identifiable, Hashable {
    static let neutralID = "builtin.neutral"

    var id: String
    var displayName: String
    /// File name inside the LUT folder; nil for the built-in Neutral simulation.
    var lutFileName: String?
    var expectedInput: String = "F-Log2 / F-Gamut"
    var output: String = "Rec.709"
    var dateImported: Date

    var isBuiltIn: Bool { lutFileName == nil }

    static let neutral = Simulation(id: neutralID, displayName: "Neutral", lutFileName: nil,
                                    dateImported: Date(timeIntervalSince1970: 0))
}

/// Imported Fujifilm LUTs: copies in Application Support, metadata JSON, parsed 3D texture cache.
@MainActor
final class SimulationLibrary: ObservableObject {
    @Published private(set) var simulations: [Simulation] = [.neutral]

    let directory: URL
    private var metadataURL: URL { directory.appendingPathComponent("simulations.json") }
    private var textureCache: [String: LUTTexture] = [:]
    private let device: MTLDevice?

    var importedCount: Int { simulations.filter { !$0.isBuiltIn }.count }

    init(directory: URL? = nil, device: MTLDevice? = MetalContext.shared?.device) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LUTs", isDirectory: true)
        self.directory = base
        self.device = device
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let stored = try? JSONDecoder.iso.decode([Simulation].self, from: data) else { return }
        simulations = [.neutral] + stored.filter { !$0.isBuiltIn }
    }

    private func save() throws {
        let data = try JSONEncoder.iso.encode(simulations.filter { !$0.isBuiltIn })
        try data.write(to: metadataURL, options: .atomic)
    }

    /// Imports `.cube` files picked in Files. Returns per-file errors (empty on full success).
    @discardableResult
    func importLUTs(from urls: [URL]) -> [(file: String, error: Error)] {
        var failures: [(String, Error)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let lut = try CubeLUT.parse(contentsOf: url)
                let id = UUID().uuidString
                let fileName = "\(id)_\(url.lastPathComponent)"
                try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(fileName))
                let sim = Simulation(id: id, displayName: Self.displayName(forFileName: url.lastPathComponent),
                                     lutFileName: fileName, dateImported: Date())
                simulations.append(sim)
                if let device { textureCache[id] = try LUTTexture(lut: lut, device: device) }
                Log.info("Imported LUT \(url.lastPathComponent) as \(sim.displayName) (\(lut.size)^3)")
            } catch {
                Log.error("LUT import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                failures.append((url.lastPathComponent, error))
            }
        }
        try? save()
        return failures
    }

    func rename(_ id: String, to name: String) {
        guard let i = simulations.firstIndex(where: { $0.id == id }), !simulations[i].isBuiltIn else { return }
        simulations[i].displayName = name
        try? save()
    }

    func delete(_ id: String) {
        guard let i = simulations.firstIndex(where: { $0.id == id }), let file = simulations[i].lutFileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        simulations.remove(at: i)
        textureCache[id] = nil
        try? save()
    }

    func simulation(id: String?) -> Simulation {
        simulations.first { $0.id == id } ?? .neutral
    }

    func cubeLUT(for sim: Simulation) throws -> CubeLUT {
        guard let file = sim.lutFileName else { return NeutralLUT.make() }
        return try CubeLUT.parse(contentsOf: directory.appendingPathComponent(file))
    }

    func lutTexture(for sim: Simulation) throws -> LUTTexture {
        if let cached = textureCache[sim.id] { return cached }
        guard let device else { throw FilmEngineError.noMetalDevice }
        let tex = try LUTTexture(lut: cubeLUT(for: sim), device: device)
        textureCache[sim.id] = tex
        return tex
    }

    // MARK: Names

    nonisolated private static let knownNames: [(keys: [String], name: String)] = [
        (["eternableachbypass", "bleachbypass"], "Eterna Bleach Bypass"),
        (["classicchrome"], "Classic Chrome"),
        (["classicneg"], "Classic Neg."),
        (["pronegstd", "pronegstandard"], "PRO Neg. Std"),
        (["realaace"], "Reala Ace"),
        (["eterna"], "Eterna"),
        (["provia"], "Provia"),
        (["velvia"], "Velvia"),
        (["astia"], "Astia"),
        (["acros"], "Acros"),
    ]

    nonisolated static func displayName(forFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let key = stem.lowercased().filter { $0.isLetter || $0.isNumber }
        for entry in knownNames where entry.keys.contains(where: key.contains) {
            return entry.name
        }
        return stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
