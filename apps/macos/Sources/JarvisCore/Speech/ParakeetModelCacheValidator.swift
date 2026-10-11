import Foundation

public enum ParakeetModelCacheValidator {
    public static let requiredRelativePaths = [
        "encoder.mlpackage/Manifest.json",
        "encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "decoder.mlpackage/Manifest.json",
        "decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "joint.mlpackage/Manifest.json",
        "joint.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "joint.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "tokenizer.json",
    ]

    public static func validate(at rootURL: URL, fileManager: FileManager = .default) throws {
        let missingPaths = requiredRelativePaths.filter { relativePath in
            let url = rootURL.appending(path: relativePath).resolvingSymlinksInPath()
            guard fileManager.isReadableFile(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return true }
            return false
        }
        guard missingPaths.isEmpty else {
            throw ParakeetModelCacheError.incomplete(
                rootPath: rootURL.path,
                missingRelativePaths: missingPaths
            )
        }
    }
}

public enum ParakeetModelCacheError: Error, Equatable, LocalizedError {
    case incomplete(rootPath: String, missingRelativePaths: [String])

    public var errorDescription: String? {
        switch self {
        case .incomplete(let rootPath, let missingRelativePaths):
            return "The Parakeet model cache at \(rootPath) is incomplete. Missing: \(missingRelativePaths.joined(separator: ", "))."
        }
    }
}
