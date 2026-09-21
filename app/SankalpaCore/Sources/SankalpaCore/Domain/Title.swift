import Foundation

/// S1 — a title is present and not blank.
public struct Title: Hashable, Codable, Sendable {
    public static let maxLength = 80

    public let value: String

    public init(_ raw: String) throws(DeclarationError) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidTitle(.blank) }
        guard trimmed.count <= Title.maxLength else { throw .invalidTitle(.tooLong(max: Title.maxLength)) }
        self.value = trimmed
    }
}

/// Free text. Optional, so the only rule is normalisation.
public struct SankalpaDescription: Hashable, Codable, Sendable {
    public let value: String

    public init(_ raw: String) {
        self.value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { value.isEmpty }
}
