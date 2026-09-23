import Foundation

public enum SankalpaReferenceResolution: Equatable, Sendable {
    case none
    case one(VoiceSankalpaReference)
    case ambiguous([VoiceSankalpaReference])
}

public struct SankalpaReferenceResolver: Sendable {
    public init() {}

    public func resolve(
        _ spokenReference: String,
        among sankalpas: [VoiceSankalpaReference]
    ) -> SankalpaReferenceResolution {
        let reference = Self.normalized(spokenReference)
        guard !reference.isEmpty else { return .none }

        let exact = sankalpas.filter { Self.normalized($0.title) == reference }
        if !exact.isEmpty { return resolution(for: exact) }

        let contained = sankalpas.filter {
            let title = Self.normalized($0.title)
            return Self.containsWholeWords(title, in: reference) ||
                Self.containsWholeWords(reference, in: title)
        }
        return resolution(for: contained)
    }

    private func resolution(
        for matches: [VoiceSankalpaReference]
    ) -> SankalpaReferenceResolution {
        switch matches.count {
        case 0: return .none
        case 1: return .one(matches[0])
        default: return .ambiguous(matches)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { result, character in
                if character == " " && result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsWholeWords(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let paddedHaystack = " \(haystack) "
        return paddedHaystack.contains(" \(needle) ")
    }
}
