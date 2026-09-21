import SwiftUI
import SankalpaCore

struct SankalpaListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case active = "Active"
        case finished = "Finished"
        case all = "All"

        var id: Self { self }

        func matches(_ summary: SankalpaSummary) -> Bool {
            switch self {
            case .active: return !summary.state.isTerminal
            case .finished: return summary.state.isTerminal
            case .all: return true
            }
        }
    }

    @Environment(AppModel.self) private var model
    var onDeclare: () -> Void

    @State private var filter: Filter = .active
    @State private var confirmingClear = false

    private var visible: [SankalpaSummary] {
        model.summaries.filter(filter.matches)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.summaries.isEmpty {
                    noSankalpasState
                } else if visible.isEmpty {
                    noMatchesState
                } else {
                    list
                }
            }
            .navigationTitle("Sankalpas")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Declare a sankalpa", systemImage: "plus", action: onDeclare)
                }
            }
            .navigationDestination(for: SankalpaId.self) { id in
                SankalpaDetailView(sankalpaId: id)
            }
            .alert("Clear every sankalpa and session?", isPresented: $confirmingClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear everything", role: .destructive) { model.clearAll() }
            } message: {
                Text("This removes the sample sankalpas and everything you have added. It cannot be undone.")
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(visible) { summary in
                    NavigationLink(value: summary.id) {
                        SankalpaRow(summary: summary)
                    }
                }
            } header: {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            Section {
                Button("Clear all data", role: .destructive) { confirmingClear = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Sankalpa starts with a few sample sankalpas so there is something to explore. Clearing removes them along with anything you have added.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var noSankalpasState: some View {
        ContentUnavailableView {
            Label("No sankalpas yet", systemImage: "seal")
        } description: {
            Text("Declare your intent, commit to how often you will act, and track each period.")
        } actions: {
            Button("Declare a sankalpa", action: onDeclare)
                .buttonStyle(.primary)
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label(
                filter == .finished ? "Nothing finished yet" : "Nothing active",
                systemImage: filter == .finished ? "checkmark.seal" : "figure.walk.motion"
            )
        } description: {
            Text(
                filter == .finished
                    ? "Sankalpas you complete or stop will be collected here."
                    : "Every sankalpa has been completed or stopped."
            )
        } actions: {
            Button("Show all") { filter = .all }
        }
    }
}

struct SankalpaRow: View {
    @Environment(AppModel.self) private var model
    let summary: SankalpaSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActionChip(actionType: summary.actionType, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Text(summary.commitment.fullPhrase)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    StateBadge(state: summary.state)
                    if let period = summary.currentPeriod, summary.state == .inProgress {
                        Text(period.progressPhrase)
                            .font(.caption)
                            .foregroundStyle(period.isSatisfied ? Palette.satisfied : .secondary)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
