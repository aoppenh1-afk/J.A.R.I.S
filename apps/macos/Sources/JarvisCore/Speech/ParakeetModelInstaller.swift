import Foundation
import ParakeetTDT

public enum ParakeetModelInstaller {
    public static let repository = "mweinbach1/parakeet-tdt-0.6b-v3-coreml"

    /// Called only from the user's Download button. This stages files without loading a model.
    public static func download(
        progress: @escaping @Sendable (Int64, Int64, String) -> Void
    ) async throws -> URL {
        let downloader = ModelDownloader()
        let root = downloader.cacheDirectory.appending(path: repository.replacingOccurrences(of: "/", with: "_"))
        if (try? ParakeetModelCacheValidator.validate(at: root)) != nil { return root }
        // Ignore a stale completion marker when repairing a partial cache.
        let downloaded = try await downloader.download(repoId: repository, skipIfPresent: false, progress: progress)
        try ParakeetModelCacheValidator.validate(at: downloaded)
        return downloaded
    }
}
