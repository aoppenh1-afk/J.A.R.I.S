import Foundation

public struct DeepgramVoice: Identifiable, Hashable, Sendable {
    public let modelID: String
    public let name: String
    public let language: String

    public var id: String { modelID }
    public var detail: String { "\(language) · Aura-2" }

    public init(modelID: String, name: String, language: String = "English") {
        self.modelID = modelID
        self.name = name
        self.language = language
    }

    public static let englishAura2: [DeepgramVoice] = [
        .init(modelID: "aura-2-amalthea-en", name: "Amalthea"),
        .init(modelID: "aura-2-andromeda-en", name: "Andromeda"),
        .init(modelID: "aura-2-apollo-en", name: "Apollo"),
        .init(modelID: "aura-2-arcas-en", name: "Arcas"),
        .init(modelID: "aura-2-aries-en", name: "Aries"),
        .init(modelID: "aura-2-asteria-en", name: "Asteria"),
        .init(modelID: "aura-2-athena-en", name: "Athena"),
        .init(modelID: "aura-2-atlas-en", name: "Atlas"),
        .init(modelID: "aura-2-aurora-en", name: "Aurora"),
        .init(modelID: "aura-2-callista-en", name: "Callista"),
        .init(modelID: "aura-2-cora-en", name: "Cora"),
        .init(modelID: "aura-2-cordelia-en", name: "Cordelia"),
        .init(modelID: "aura-2-delia-en", name: "Delia"),
        .init(modelID: "aura-2-draco-en", name: "Draco"),
        .init(modelID: "aura-2-electra-en", name: "Electra"),
        .init(modelID: "aura-2-harmonia-en", name: "Harmonia"),
        .init(modelID: "aura-2-helena-en", name: "Helena"),
        .init(modelID: "aura-2-hera-en", name: "Hera"),
        .init(modelID: "aura-2-hermes-en", name: "Hermes"),
        .init(modelID: "aura-2-hyperion-en", name: "Hyperion"),
        .init(modelID: "aura-2-iris-en", name: "Iris"),
        .init(modelID: "aura-2-janus-en", name: "Janus"),
        .init(modelID: "aura-2-juno-en", name: "Juno"),
        .init(modelID: "aura-2-jupiter-en", name: "Jupiter"),
        .init(modelID: "aura-2-luna-en", name: "Luna"),
        .init(modelID: "aura-2-mars-en", name: "Mars"),
        .init(modelID: "aura-2-minerva-en", name: "Minerva"),
        .init(modelID: "aura-2-neptune-en", name: "Neptune"),
        .init(modelID: "aura-2-odysseus-en", name: "Odysseus"),
        .init(modelID: "aura-2-ophelia-en", name: "Ophelia"),
        .init(modelID: "aura-2-orion-en", name: "Orion"),
        .init(modelID: "aura-2-orpheus-en", name: "Orpheus"),
        .init(modelID: "aura-2-pandora-en", name: "Pandora"),
        .init(modelID: "aura-2-phoebe-en", name: "Phoebe"),
        .init(modelID: "aura-2-pluto-en", name: "Pluto"),
        .init(modelID: "aura-2-saturn-en", name: "Saturn"),
        .init(modelID: "aura-2-selene-en", name: "Selene"),
        .init(modelID: "aura-2-thalia-en", name: "Thalia"),
        .init(modelID: "aura-2-theia-en", name: "Theia"),
        .init(modelID: "aura-2-vesta-en", name: "Vesta"),
        .init(modelID: "aura-2-zeus-en", name: "Zeus")
    ]

    public static func voice(for modelID: String) -> DeepgramVoice? {
        englishAura2.first { $0.modelID == modelID }
    }
}
