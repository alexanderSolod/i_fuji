import Photos
import UniformTypeIdentifiers

enum PhotoLibrarySaver {
    enum SaveError: Error, LocalizedError {
        case notAuthorized
        var errorDescription: String? { "Photos access is off. Enable \"Add Photos Only\" in Settings > FilmLab." }
    }

    /// Saves the rendered image as `.photo` and the untouched DNG as `.alternatePhoto` in one asset,
    /// so Photos treats them as a RAW + processed pair (spec 4.8).
    static func savePair(rendered: Data, format: ExportFormat, dng: Data, baseName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }
        // Passed by file URL: on iOS 27 (iPhone 17 Pro) the same request with in-memory Data fails with
        // PHPhotosErrorDomain 3300. These are copies, so the stored DNG stays in place.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderedURL = dir.appendingPathComponent("\(baseName).\(format.fileExtension)")
        let dngURL = dir.appendingPathComponent("\(baseName).dng")
        try rendered.write(to: renderedURL)
        try dng.write(to: dngURL)
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let photo = PHAssetResourceCreationOptions()
            photo.uniformTypeIdentifier = format.uti.identifier
            photo.originalFilename = "\(baseName).\(format.fileExtension.uppercased())"
            req.addResource(with: .photo, fileURL: renderedURL, options: photo)
            let raw = PHAssetResourceCreationOptions()
            raw.uniformTypeIdentifier = "com.adobe.raw-image"
            raw.originalFilename = "\(baseName).DNG"
            req.addResource(with: .alternatePhoto, fileURL: dngURL, options: raw)
        }
        Log.info("Saved \(baseName) (\(format.rawValue) + DNG) to Photos")
    }
}
