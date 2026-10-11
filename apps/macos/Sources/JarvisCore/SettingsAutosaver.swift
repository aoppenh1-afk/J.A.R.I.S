import Foundation

public enum SettingsSaveState: Equatable, Sendable {
    case saved, pending, applying
    case failed(String)
}

/// Debounces edits and serializes applications. New edits never cancel a save in progress.
@MainActor
public final class SettingsAutosaver<Value: Equatable & Sendable> {
    private let delay: Duration
    private let apply: @MainActor (Value) async throws -> Void
    private let onState: @MainActor (SettingsSaveState) -> Void
    private var pending: Value?
    private var deadline = ContinuousClock.now
    private var worker: Task<Void, Never>?

    public init(
        delay: Duration = .milliseconds(500),
        apply: @escaping @MainActor (Value) async throws -> Void,
        onState: @escaping @MainActor (SettingsSaveState) -> Void = { _ in }
    ) {
        self.delay = delay
        self.apply = apply
        self.onState = onState
    }

    public func schedule(_ value: Value) {
        pending = value
        deadline = .now.advanced(by: delay)
        onState(.pending)
        startWorker()
    }

    public func flush() {
        deadline = .now
        startWorker()
    }

    public func waitUntilIdle() async {
        await worker?.value
    }

    private func startWorker() {
        guard worker == nil, pending != nil else { return }
        worker = Task {
            while pending != nil {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    continue
                }
                guard let value = pending else { break }
                pending = nil
                onState(.applying)
                do {
                    try await apply(value)
                    onState(pending == nil ? .saved : .pending)
                } catch {
                    onState(pending == nil ? .failed(error.localizedDescription) : .pending)
                }
            }
            worker = nil
        }
    }
}
