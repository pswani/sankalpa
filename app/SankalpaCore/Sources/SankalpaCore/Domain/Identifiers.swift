import Foundation

public struct SankalpaId: Hashable, Codable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public struct SessionId: Hashable, Codable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}
