import SwiftUI
import UniformTypeIdentifiers
import SankalpaCore
import SankalpaStorage

struct RootView: View {
    @Environment(PracticeModel.self) private var model
    @State private var declaring = false
    @State private var settings = false
    var body: some View {
        @Bindable var model = model
        Group {
            if let problem = model.storageProblem {
                RecoveryView(message: problem)
            } else {
                TabView {
                    Tab("Today", systemImage: "sun.horizon") { TodayView(onDeclare: { declaring = true }, onSettings: { settings = true }) }
                    Tab("Collection", systemImage: "square.stack") { CollectionView(onDeclare: { declaring = true }) }
                    Tab("Journal", systemImage: "book.closed") { JournalView() }
                }
            }
        }
        .sheet(isPresented: $declaring) { DeclarationView() }
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("Unable to make this change", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    Text(notice.text).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    if notice.canUndo { Button("Undo") { model.undo() }.fontWeight(.bold).accessibilityIdentifier("undo-session") }
                    Button { model.dismissNotice() } label: { Image(systemName: "xmark").frame(width: 32, height: 44) }.accessibilityLabel("Dismiss confirmation")
                }
                .foregroundStyle(Ink.onAccent).padding(.horizontal, 16)
                .background(Ink.accent, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20).padding(.bottom, 80)
                .task(id: notice.id) {
                    do { try await Task.sleep(for: .seconds(notice.canUndo ? 8 : 3)) } catch { return }
                    if model.notice?.id == notice.id { model.dismissNotice() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: model.notice?.id)
    }
}
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsView: View {
    @Environment(PracticeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var document = BackupDocument(data: Data())
    @State private var importing = false
    @State private var restoring = false
    @State private var importData = Data()
    @State private var importSummary: FileStore.BackupSummary?
    @State private var clearing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your practice, on your device") {
                    Text("Your intentions and sessions are stored locally. There is no account, advertising, or automatic cloud sync.")
                    Button("Export a backup", systemImage: "square.and.arrow.up") {
                        do { document = BackupDocument(data: try model.exportData()); exporting = true }
                        catch { self.error = "Could not prepare your backup. Please try again." }
                    }
                }
                Section {
                    Button("Restore a backup", systemImage: "square.and.arrow.down") { importing = true }
                } footer: { Text("Restore replaces the current collection with a validated Sankalpa 2 backup.") }
                Section {
                    Button("Clear all practice data", role: .destructive) { clearing = true }.accessibilityIdentifier("clear-data")
                } footer: { Text("This permanently removes your intentions, sessions, and transition history from this app. Export a backup first if you want to keep a copy.") }
                if let error { Section { Text(error).foregroundStyle(Ink.danger) } }
                Section("About") { Text("Sankalpa 2").font(.headline); Text("Declare your intention. Return to your practice.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Your data").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Permanently clear all practice data?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) { model.clearAll(); if let failure = model.alert { error = failure; model.alert = nil } else { dismiss() } }
            } message: { Text("This cannot be undone. Exported backups are kept.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    importSummary = try model.inspectBackup(data)
                    importData = data
                    restoring = true
                } catch { self.error = "This file could not be read as a valid Sankalpa 2 backup. Nothing has changed." }
            }
            .confirmationDialog("Replace your current collection?", isPresented: $restoring, titleVisibility: .visible) {
                Button("Restore backup", role: .destructive) { error = model.restoreBackup(importData) }
            } message: {
                if let summary = importSummary { Text("This backup contains \(summary.intentions) intentions and \(summary.sessions) sessions. It will replace all current practice data. This cannot be undone unless you export your current data first.") }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Sankalpa-backup") { result in
                if case .failure = result { error = "The backup could not be exported. Your original data is safe." }
            }
        }
    }
}
struct RecoveryView: View {
    @Environment(PracticeModel.self) private var model
    let message: String
    @State private var exporting = false
    @State private var document = BackupDocument(data: Data())
    @State private var error: String?
    @State private var importing = false
    @State private var restoring = false
    @State private var backup = Data()
    @State private var summary: FileStore.BackupSummary?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    EmptyPractice(title: "Your data needs attention", message: message, symbol: "externaldrive.badge.exclamationmark")
                    Button("Try opening again") { model.retryLoading() }.buttonStyle(FilledButton())
                    Button("Export original file") {
                        do { document = BackupDocument(data: try model.exportData()); exporting = true }
                        catch { self.error = "The original file could not be read. Please try again after restarting your device." }
                    }.buttonStyle(OutlineButton())
                    Button("Recover from a backup") { importing = true }.buttonStyle(OutlineButton())
                    if let error { Text(error).foregroundStyle(Ink.danger) }
                }.padding(24)
            }.background(Ink.paper).navigationTitle("Sankalpa")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        summary = try model.inspectBackup(data)
                        backup = data
                        restoring = true
                    } catch { self.error = "This is not a readable Sankalpa 2 backup. The original file is unchanged." }
                }
                .confirmationDialog("Recover using this backup?", isPresented: $restoring, titleVisibility: .visible) {
                    Button("Recover practice") { error = model.restoreBackup(backup, recovering: true) }
                } message: {
                    if let summary { Text("Restore \(summary.intentions) intentions and \(summary.sessions) sessions. A separate copy of the unreadable original will be preserved first.") }
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Sankalpa-recovery") { result in
                    if case .failure = result { error = "Could not export the original file." }
                }
        }
    }
}
