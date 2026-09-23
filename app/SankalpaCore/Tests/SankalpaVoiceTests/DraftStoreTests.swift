import Foundation
import Testing
@testable import SankalpaVoice

@Suite("Voice draft store")
struct DraftStoreTests {
    @Test("One structured draft survives a relaunch and can be discarded")
    func roundTripAndDiscard() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = VoiceDeclarationDraft(title: "Vipassana", timesPerPeriod: 2)

        try VoiceDraftStore(directory: directory).save(draft)
        #expect(VoiceDraftStore(directory: directory).load().draft == draft)

        try VoiceDraftStore(directory: directory).discard()
        #expect(VoiceDraftStore(directory: directory).load().draft == nil)
    }

    @Test("A failed atomic write is reported and does not replace the old draft")
    func failedWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = VoiceDeclarationDraft(title: "Original")
        try VoiceDraftStore(directory: directory).save(original)
        let failing = VoiceDraftStore(directory: directory) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }

        #expect(throws: VoiceDraftStoreError.writeFailed) {
            try failing.save(VoiceDeclarationDraft(title: "Replacement"))
        }
        #expect(VoiceDraftStore(directory: directory).load().draft == original)
    }

    @Test("Unreadable bytes are kept aside rather than overwritten")
    func unreadableDraft() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sankalpa-voice-draft.json")
        try Data("not json".utf8).write(to: url)

        let result = VoiceDraftStore(directory: directory).load()

        #expect(result.draft == nil)
        #expect(result.warning != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("sankalpa-voice-draft-damaged-") })
    }

    @Test("Checking for a draft does not consume an unreadable draft warning")
    func presenceCheckIsNonMutating() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sankalpa-voice-draft.json")
        try Data("not json".utf8).write(to: url)
        let store = VoiceDraftStore(directory: directory)

        #expect(store.hasDraft())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.load().warning != nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-draft-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
