import Foundation

public struct ResponseSource: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let line: Int?
    public let label: String?

    public var id: String {
        "\(path):\(line ?? 0):\(label ?? "")"
    }

    public init(path: String, line: Int? = nil, label: String? = nil) {
        self.path = path
        self.line = line
        self.label = label
    }
}

struct HermesResponsePresentation: Equatable {
    let text: String
    let sources: [ResponseSource]
    let followUpPrompts: [String]
}

struct HermesResponseStreamFilter {
    private var pending = ""
    private var isCapturingMetadata = false

    mutating func append(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        pending += delta

        if isCapturingMetadata {
            return ""
        }

        if let markerRange = pending.range(of: HermesResponsePresentationParser.openingMarker) {
            let visible = String(pending[..<markerRange.lowerBound])
            pending = String(pending[markerRange.lowerBound...])
            isCapturingMetadata = true
            return visible
        }

        let retainedCount = min(
            pending.count,
            max(0, HermesResponsePresentationParser.openingMarker.count - 1)
        )
        guard pending.count > retainedCount else { return "" }

        let splitIndex = pending.index(pending.endIndex, offsetBy: -retainedCount)
        let visible = String(pending[..<splitIndex])
        pending = String(pending[splitIndex...])
        return visible
    }

    mutating func finish() -> String {
        defer { pending = "" }
        return isCapturingMetadata ? "" : pending
    }
}

enum HermesResponsePresentationParser {
    static let openingMarker = "<jarvis_ui>"
    private static let closingMarker = "</jarvis_ui>"

    private struct Metadata: Decodable {
        let followUpPrompts: [String]?
        let sources: [ResponseSource]?

        enum CodingKeys: String, CodingKey {
            case followUpPrompts = "follow_up_prompts"
            case sources
        }
    }

    static func parse(_ rawResponse: String) -> HermesResponsePresentation {
        guard let openingRange = rawResponse.range(of: openingMarker) else {
            return HermesResponsePresentation(
                text: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
                sources: [],
                followUpPrompts: []
            )
        }

        let visibleText = rawResponse[..<openingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let closingRange = rawResponse.range(
            of: closingMarker,
            range: openingRange.upperBound..<rawResponse.endIndex
        ) else {
            return HermesResponsePresentation(text: visibleText, sources: [], followUpPrompts: [])
        }

        let json = String(rawResponse[openingRange.upperBound..<closingRange.lowerBound])
        guard let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return HermesResponsePresentation(text: visibleText, sources: [], followUpPrompts: [])
        }

        var seenPrompts = Set<String>()
        let followUps = (metadata.followUpPrompts ?? []).compactMap { prompt -> String? in
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenPrompts.insert(trimmed).inserted else { return nil }
            return trimmed
        }.prefix(3)

        var seenSources = Set<String>()
        let sources = (metadata.sources ?? []).compactMap { source -> ResponseSource? in
            let path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let normalizedLine = source.line.flatMap { $0 > 0 ? $0 : nil }
            let label = source.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = ResponseSource(
                path: path,
                line: normalizedLine,
                label: label?.isEmpty == false ? label : nil
            )
            guard seenSources.insert(normalized.id).inserted else { return nil }
            return normalized
        }

        return HermesResponsePresentation(
            text: visibleText,
            sources: sources,
            followUpPrompts: Array(followUps)
        )
    }
}
