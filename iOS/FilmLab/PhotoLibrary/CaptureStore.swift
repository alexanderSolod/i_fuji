import Foundation

struct CaptureRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var rawPixelFormat: String
    var rawWidth: Int32
    var rawHeight: Int32
    var locked: LockedCaptureSettings
    var baselineExposure: Float?
    var lastRender: RenderMetadata?
    var renderedFile: String?

    var baseName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "FL_\(f.string(from: date))"
    }
}

/// App-local copies of every capture: `Captures/<id>/original.dng` (bytes as delivered), `info.json`
/// and the latest render.
struct CaptureStore {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func dngURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("original.dng") }

    func save(_ result: CaptureResult) throws -> CaptureRecord {
        try FileManager.default.createDirectory(at: folder(result.id), withIntermediateDirectories: true)
        try result.dngData.write(to: dngURL(result.id), options: .atomic)
        let record = CaptureRecord(id: result.id, date: result.locked.timestamp, rawPixelFormat: result.rawPixelFormat,
                                   rawWidth: result.resolvedRAWDimensions.width, rawHeight: result.resolvedRAWDimensions.height,
                                   locked: result.locked)
        try update(record)
        return record
    }

    func update(_ record: CaptureRecord) throws {
        try JSONEncoder.iso.encode(record).write(to: folder(record.id).appendingPathComponent("info.json"), options: .atomic)
    }

    func saveRendered(_ data: Data, format: ExportFormat, record: inout CaptureRecord) throws {
        let name = "rendered.\(format.fileExtension)"
        try data.write(to: folder(record.id).appendingPathComponent(name), options: .atomic)
        record.renderedFile = name
        try update(record)
    }

    func loadDNG(_ id: UUID) throws -> Data { try Data(contentsOf: dngURL(id)) }

    func latest() -> CaptureRecord? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> CaptureRecord? in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("info.json")) else { return nil }
            return try? JSONDecoder.iso.decode(CaptureRecord.self, from: d)
        }.max { $0.date < $1.date }
    }
}
