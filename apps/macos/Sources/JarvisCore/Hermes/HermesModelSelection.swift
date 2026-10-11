import Foundation

/// Empty fields follow the Hermes profile's defaults. Overrides belong to Jarvis only.
public struct HermesModelSelection: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String

    public init(provider: String = "", model: String = "") {
        self.provider = provider
        self.model = model
    }
}

public struct HermesModelCatalog: Decodable, Sendable {
    public let providers: [Provider]
    public let model: String?
    public let provider: String?

    public struct Provider: Decodable, Sendable, Identifiable {
        public let slug: String
        public let name: String
        public let models: [String]
        public let authenticated: Bool?
        public let isCurrent: Bool?
        public let unavailableModels: [String]?
        public var id: String { slug }
        public var availableModels: [String] {
            let unavailable = Set(unavailableModels ?? [])
            return models.filter { !unavailable.contains($0) }
        }
        public var isSelectable: Bool { authenticated == true || isCurrent == true }

        private enum CodingKeys: String, CodingKey {
            case slug, name, models, authenticated
            case isCurrent = "is_current"
            case unavailableModels = "unavailable_models"
        }
    }
}
