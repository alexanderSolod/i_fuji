import Photos
import UniformTypeIdentifiers

enum PhotoLibrarySaver {
    enum SaveError: Error, LocalizedError {
        case notAuthorized
        var errorDescription: String? { "Photos access is off. Enable \"Add Photos Only\" in Settings > FilmLab." }
    }

    /// Saves only the rendered image, at the owner's request (differs from spec 4.8, see DEVELOPMENT_LOG.md).
    /// The DNG stays in the app's capture folder for re-rendering.
    static func save(rendered: Data, format: ExportFormat, baseName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }
        // Passed by file URL because in-memory Data failed with PHPhotosErrorDomain 3300 on iOS 27.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderedURL = dir.appendingPathComponent("\(baseName).\(format.fileExtension)")
        try rendered.write(to: renderedURL)
        try await PHPhotoLibrary.shared().performChanges {
            let photo = PHAssetResourceCreationOptions()
            photo.uniformTypeIdentifier = format.uti.identifier
            photo.originalFilename = "\(baseName).\(format.fileExtension.uppercased())"
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: renderedURL, options: photo)
        }
        Log.info("Saved \(baseName) (\(format.rawValue)) to Photos")
    }
}
