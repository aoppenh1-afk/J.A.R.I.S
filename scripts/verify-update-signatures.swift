import CryptoKit
import Foundation

// All arguments are public verification material. Private signing keys never enter this tool.
let arguments = CommandLine.arguments
guard arguments.count == 6,
      let publicKeyData = Data(base64Encoded: arguments[1]),
      let archiveSignature = Data(base64Encoded: arguments[2]),
      let feedSignature = Data(base64Encoded: arguments[4]) else {
    fputs("Expected public key, archive signature/path, and feed signature/path.\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
    let feed = try Data(contentsOf: URL(fileURLWithPath: arguments[5]), options: .mappedIfSafe)
    guard key.isValidSignature(archiveSignature, for: archive),
          key.isValidSignature(feedSignature, for: feed) else {
        fputs("Update signatures do not match the public key embedded in the app.\n", stderr)
        exit(1)
    }
    print("Verified archive and feed signatures against the app's public key.")
} catch {
    fputs("Could not verify update signatures: \(error.localizedDescription)\n", stderr)
    exit(1)
}
