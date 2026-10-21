import Foundation
import CryptoKit

/// Sole writer for conversation files. All encoding and file I/O runs on this actor.
public actor AssistantConversationStore {
    public struct Library: Sendable {
        public var summaries: [AssistantConversationSummary]
        public var selected: AssistantConversationRecord?
        public var damagedFiles: [String]
        public var problem: String?
    }
    private struct Version: Decodable { let schemaVersion: Int }
    private struct ImportReceipt: Codable { let threadId: UUID; let digest: String }
    private struct Selection: Codable {
        var schemaVersion = 1
        let serviceInstanceId: UUID
        var selectedId: UUID
        var legacyImport: ImportReceipt?
    }
    private struct Legacy: Decodable {
        let threadId: UUID
        let transcript: [AGUI.Message]
        let proposal: AssistantProposal?
        let confirmationId: UUID?
        let input: AGUI.RunAgentInput?
    }
    public let root: URL
    public let serviceInstanceId: UUID
    private let legacyURL: URL
    private let beforeWrite: @Sendable (URL) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(serviceInstanceId: UUID, assistantDirectory: URL = URL.applicationSupportDirectory.appending(path: "Assistant"),
                beforeWrite: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.serviceInstanceId = serviceInstanceId
        root = assistantDirectory.appending(path: "Conversations/v1/\(serviceInstanceId.uuidString)")
        legacyURL = assistantDirectory.appending(path: "\(serviceInstanceId.uuidString)-linked-v1.json")
        self.beforeWrite = beforeWrite
        encoder.outputFormatting = [.sortedKeys]
    }
    private func recordURL(_ id: UUID) -> URL { root.appending(path: "\(id.uuidString).json") }
    private var selectionURL: URL { root.appending(path: "selection.json") }

    public func open(now: Date = Date()) -> Library {
        var problem: String?
        do { try migrate() } catch { problem = AssistantStorageError.invalidHistory.localizedDescription }
        var summaries: [AssistantConversationSummary] = [], damaged: [String] = []
        do {
            let files = FileManager.default.fileExists(atPath: root.path)
                ? try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) : []
            for file in files where file.pathExtension == "json" && file.lastPathComponent != "selection.json" {
                do {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw AssistantStorageError.invalidHistory }
                    summaries.append(AssistantConversationSummary(try load(id)))
                } catch { damaged.append(file.lastPathComponent) }
            }
        } catch { problem = AssistantStorageError.invalidHistory.localizedDescription }
        summaries.sort(by: Self.order)
        var selection: Selection?
        if FileManager.default.fileExists(atPath: selectionURL.path) {
            // A bad pointer is recoverable only when it cannot conceal migration ownership.
            do { selection = try readSelection() }
            catch {
                let version = (try? Data(contentsOf: selectionURL)).flatMap { try? decoder.decode(Version.self, from: $0) }
                if version?.schemaVersion != nil && version?.schemaVersion != 1 || FileManager.default.fileExists(atPath: legacyURL.path) {
                    problem = AssistantStorageError.invalidHistory.localizedDescription
                }
            }
        }
        var selected = selection.flatMap { value in summaries.first(where: { $0.id == value.selectedId })?.id }
        if selected == nil { selected = summaries.first?.id }
        if summaries.isEmpty && damaged.isEmpty && problem == nil {
            do {
                let created = try create(now: now)
                summaries = [AssistantConversationSummary(created)]; selected = created.id
            } catch { problem = AssistantStorageError.writeFailed.localizedDescription }
        }
        if !damaged.isEmpty { problem = AssistantStorageError.invalidHistory.localizedDescription }
        return Library(summaries: summaries, selected: selected.flatMap { try? load($0) },
                       damagedFiles: damaged.sorted(), problem: problem)
    }
    private static func order(_ lhs: AssistantConversationSummary, _ rhs: AssistantConversationSummary) -> Bool {
        if lhs.activityAt != rhs.activityAt { return lhs.activityAt > rhs.activityAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    public func load(_ id: UUID) throws -> AssistantConversationRecord {
        let value = try decoder.decode(AssistantConversationRecord.self, from: Data(contentsOf: recordURL(id)))
        guard value.id == id, value.serviceInstanceId == serviceInstanceId else { throw AssistantStorageError.invalidHistory }
        try value.validate()
        return value
    }
    public func create(now: Date = Date()) throws -> AssistantConversationRecord {
        let value = AssistantConversationRecord(serviceInstanceId: serviceInstanceId, now: now)
        try write(value, to: recordURL(value.id))
        try select(value.id)
        return value
    }
    public func select(_ id: UUID) throws {
        _ = try load(id)
        if let bytes = try? Data(contentsOf: selectionURL),
           let version = try? decoder.decode(Version.self, from: bytes), version.schemaVersion != 1 {
            throw AssistantStorageError.invalidHistory
        }
        var selection = (try? readSelection()) ?? Selection(serviceInstanceId: serviceInstanceId, selectedId: id)
        // Never destroy a damaged migration receipt to recover selection.
        if FileManager.default.fileExists(atPath: selectionURL.path),
           FileManager.default.fileExists(atPath: legacyURL.path) { selection = try readSelection() }
        selection.selectedId = id
        try write(selection, to: selectionURL)
    }
    public func save(_ record: AssistantConversationRecord) throws -> AssistantConversationRecord {
        let current = try load(record.id)
        guard current.revision == record.revision else { throw AssistantStorageError.staleWrite }
        guard record.serviceInstanceId == serviceInstanceId else { throw AssistantStorageError.invalidHistory }
        try record.validate()
        var next = record; next.revision += 1
        try write(next, to: recordURL(next.id))
        return next
    }
    /// Load/merge/write is one actor turn, so a result cannot race a draft patch between awaits.
    func update(_ id: UUID, _ change: @Sendable (inout AssistantConversationRecord) throws -> Void) throws -> AssistantConversationRecord {
        var current = try load(id)
        try change(&current)
        return try save(current)
    }
    /// Draft patches merge with current request/result state, rather than replacing stale records.
    public func saveDraft(_ draft: String, id: UUID, now: Date) throws -> AssistantConversationRecord {
        var record = try load(id)
        if record.draft == draft { return record }
        record.draft = draft; record.activityAt = now
        return try save(record)
    }
    private func readSelection() throws -> Selection {
        let value = try decoder.decode(Selection.self, from: Data(contentsOf: selectionURL))
        guard value.schemaVersion == 1, value.serviceInstanceId == serviceInstanceId else { throw AssistantStorageError.invalidHistory }
        if let receipt = value.legacyImport {
            guard receipt.digest.count == 64, receipt.digest.allSatisfy({ $0.isHexDigit }),
                  FileManager.default.fileExists(atPath: recordURL(receipt.threadId).path) else { throw AssistantStorageError.invalidHistory }
        }
        return value
    }
    private func migrate() throws {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        if FileManager.default.fileExists(atPath: selectionURL.path), let receipt = try readSelection().legacyImport {
            _ = try load(receipt.threadId)
            let digest = SHA256.hash(data: try Data(contentsOf: legacyURL)).map { String(format: "%02x", $0) }.joined()
            guard digest == receipt.digest else { throw AssistantStorageError.invalidHistory }
            try protect(legacyURL)
            return
        }
        let bytes = try Data(contentsOf: legacyURL)
        let old = try decoder.decode(Legacy.self, from: bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        let date = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        var record = AssistantConversationRecord(serviceInstanceId: serviceInstanceId, id: old.threadId, now: date)
        record.transcript = old.transcript; record.proposal = old.proposal
        record.confirmationId = old.confirmationId; record.imported = true
        if let input = old.input {
            let resume = input.resume?.first
            let kind: AssistantRequest.Kind = resume == nil ? .ordinary : resume?.status == "cancelled" ? .cancel : .confirm
            // Keep staged imports deterministic even if the app reconnects between crash/retry.
            // Actual headers are unknown; explicit recovery freezes verified current support later.
            var recoveredNegotiation = AssistantNegotiation()
            if old.proposal?.kind == .logSessions {
                recoveredNegotiation.linked = true; recoveredNegotiation.batchSessions = true
                if old.proposal?.metadata["proposalVersion"] == .number(3) { recoveredNegotiation.beginCorrection = true }
            }
            record.request = AssistantRequest(kind: kind, input: input, negotiation: recoveredNegotiation, negotiationInferred: true)
        }
        try record.validate()
        let files = FileManager.default.fileExists(atPath: root.path)
            ? try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) : []
        guard files.filter({ $0.pathExtension == "json" && $0.lastPathComponent != "selection.json" })
            .allSatisfy({ $0.lastPathComponent == recordURL(record.id).lastPathComponent }) else { throw AssistantStorageError.invalidHistory }
        if FileManager.default.fileExists(atPath: recordURL(record.id).path) {
            guard try load(record.id) == record else { throw AssistantStorageError.invalidHistory }
        } else { try write(record, to: recordURL(record.id)) }
        _ = try load(record.id)
        let receipt = ImportReceipt(threadId: record.id, digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try write(Selection(serviceInstanceId: serviceInstanceId, selectedId: record.id, legacyImport: receipt), to: selectionURL)
        try protect(legacyURL)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try protect(root)
            try beforeWrite(url)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try protect(url)
        } catch { throw AssistantStorageError.writeFailed }
    }
    private func protect(_ url: URL) throws {
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
