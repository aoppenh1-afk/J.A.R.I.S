import Darwin
import Foundation

/// The PID alone is insufficient: macOS can reuse it after a gateway exits.
struct HermesManagedProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let parentPID: Int32
    let userID: UInt32
    let startTime: UInt64
}

/// Verify the profile record against the live process and the actual TCP listener.
/// Capability responses establish API compatibility, but do not identify a profile.
struct HermesManagedProcessInspector: Sendable {
    let profileDirectory: URL
    var processIdentity: @Sendable (Int32) -> HermesManagedProcessIdentity? = { Self.readProcessIdentity($0) }
    var listenerPIDs: @Sendable (URL) -> Set<Int32> = { Self.readListenerPIDs($0) }
    var sendSignal: @Sendable (Int32, Int32) -> Bool = { Darwin.kill($0, $1) == 0 }

    init(
        profileDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".hermes/profiles/jarvis")
    ) {
        self.profileDirectory = profileDirectory
    }

    func verifiedListener(at endpoint: URL) -> HermesManagedProcessIdentity? {
        struct Record: Decodable {
            let pid: Int32
            let kind: String
            let argv: [String]
            let start_time: UInt64
            let hermes_home: String
        }
        let recordURL = profileDirectory.appending(path: "gateway.pid")
        guard let size = try? recordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size < 65_536,
              let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.kind == "hermes-gateway", record.pid > 1,
              URL(fileURLWithPath: record.hermes_home).standardizedFileURL.resolvingSymlinksInPath()
                == profileDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              record.argv.contains("--external-supervisor"),
              record.argv.indices.dropLast().contains(where: {
                  record.argv[$0] == "gateway" && record.argv[$0 + 1] == "run"
              }),
              let identity = processIdentity(record.pid),
              identity.userID == getuid(), identity.startTime == record.start_time,
              listenerPIDs(endpoint) == [identity.pid],
              processIdentity(record.pid) == identity else {
            return nil
        }
        return identity
    }

    func isSameProcess(_ identity: HermesManagedProcessIdentity) -> Bool {
        guard let current = processIdentity(identity.pid) else { return false }
        return current.pid == identity.pid && current.userID == identity.userID
            && current.startTime == identity.startTime
    }

    func isSameListener(_ identity: HermesManagedProcessIdentity, at endpoint: URL) -> Bool {
        isSameProcess(identity) && verifiedListener(at: endpoint) == identity
    }

    /// Recover only an orphan from a previous app instance, never another live owner's gateway.
    func signalOrphan(_ identity: HermesManagedProcessIdentity, signal: Int32) -> Bool {
        guard identity.parentPID == 1, identity.userID == getuid(),
              processIdentity(identity.pid) == identity else { return false }
        return sendSignal(identity.pid, signal)
    }

    static func readProcessIdentity(_ pid: Int32) -> HermesManagedProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // Hermes records round(psutil.Process(pid).create_time() * 100) on macOS.
        let centiseconds = UInt64((Double(info.pbi_start_tvsec)
            + Double(info.pbi_start_tvusec) / 1_000_000) * 100 + 0.5)
        return HermesManagedProcessIdentity(
            pid: pid, parentPID: Int32(info.pbi_ppid), userID: info.pbi_uid, startTime: centiseconds
        )
    }

    static func readListenerPIDs(_ endpoint: URL) -> Set<Int32> {
        guard let port = endpoint.port else { return [] }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        command.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        let output = Pipe()
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        do { try command.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            line.first == "p" ? Int32(line.dropFirst()) : nil
        })
    }
}
