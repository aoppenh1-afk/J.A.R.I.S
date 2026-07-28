import Foundation

public struct SentenceBuffer: Sendable {
    private var buffered = ""

    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        buffered += delta
        var sentences: [String] = []

        while let boundary = buffered.firstIndex(where: { ".!?\n".contains($0) }) {
            let end = buffered.index(after: boundary)
            let sentence = String(buffered[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffered.removeSubrange(..<end)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    public mutating func flush() -> String? {
        let remaining = buffered.trimmingCharacters(in: .whitespacesAndNewlines)
        buffered = ""
        return remaining.isEmpty ? nil : remaining
    }
}
