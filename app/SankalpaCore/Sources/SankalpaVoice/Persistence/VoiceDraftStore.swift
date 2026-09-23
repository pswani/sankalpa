import Foundation

public enum VoiceDraftStoreError: Error, Equatable, Sendable {
    case writeFailed
    case unreadableDraft(String)
    case unsupportedVersion(Int)
}

public struct VoiceDraftLoadResult: Equatable, Sendable {
    public let draft: VoiceDeclarationDraft?
    public let warning: String?

    public init(draft: VoiceDeclarationDraft?, warning: String? = nil) {
        self.draft = draft
        self.warning = warning
    }
}

public protocol VoiceDraftStoring: Sendable {
    func load() -> VoiceDraftLoadResult
    func save(_ draft: VoiceDeclarationDraft) throws
    func discard() throws
}

/// Stores exactly one structured draft. Atomic replacement ensures a crash cannot leave half JSON.
public final class VoiceDraftStore: VoiceDraftStoring, @unchecked Sendable {
    private let directory: URL
    private let writer: @Sendable (Data, URL) throws -> Void
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL = VoiceDraftStore.defaultDirectory(),
        fileManager: FileManager = .default,
        writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.writer = writer
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var draftURL: URL { directory.appendingPathComponent("sankalpa-voice-draft.json") }

    public static func removeEverything(
        in directory: URL = VoiceDraftStore.defaultDirectory()
    ) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("sankalpa-voice-draft.json")
        )
    }

    /// A non-mutating presence check for UI indicators. Recovery remains `load()`'s responsibility
    /// so an unreadable draft warning cannot be consumed before the assistant is presented.
    public func hasDraft() -> Bool {
        lock.withLock { fileManager.fileExists(atPath: draftURL.path) }
    }

    public func load() -> VoiceDraftLoadResult {
        lock.withLock {
            guard fileManager.fileExists(atPath: draftURL.path) else {
                return VoiceDraftLoadResult(draft: nil)
            }
            do {
                let data = try Data(contentsOf: draftURL)
                let draft = try JSONDecoder().decode(VoiceDeclarationDraft.self, from: data)
                guard draft.schemaVersion <= VoiceDeclarationDraft.currentSchemaVersion else {
                    return setAside(
                        warning: "A saved voice draft was created by a newer app version and could not be restored."
                    )
                }
                return VoiceDraftLoadResult(draft: draft)
            } catch {
                return setAside(
                    warning: "A saved voice draft could not be restored. The original file was kept."
                )
            }
        }
    }

    public func save(_ draft: VoiceDeclarationDraft) throws {
        try lock.withLock {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try writer(JSONEncoder().encode(draft), draftURL)
            } catch {
                throw VoiceDraftStoreError.writeFailed
            }
        }
    }

    public func discard() throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: draftURL.path) else { return }
            do { try fileManager.removeItem(at: draftURL) }
            catch { throw VoiceDraftStoreError.writeFailed }
        }
    }

    private func setAside(warning: String) -> VoiceDraftLoadResult {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent("sankalpa-voice-draft-damaged-\(stamp).json")
        try? fileManager.moveItem(at: draftURL, to: destination)
        return VoiceDraftLoadResult(draft: nil, warning: warning)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
