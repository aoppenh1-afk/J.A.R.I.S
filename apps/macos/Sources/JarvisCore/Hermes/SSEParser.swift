import Foundation

public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    public init() {}

    public mutating func consume(line: String) throws -> HermesEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let data = Data(dataLines.joined(separator: "\n").utf8)
            dataLines.removeAll(keepingCapacity: true)
            return try decoder.decode(HermesEvent.self, from: data)
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public mutating func finish() throws -> HermesEvent? {
        try consume(line: "")
    }
}
