import SwiftUI
import SankalpaCore

/// Everything performed, across every sankalpa, newest first. It answers "what have I actually
/// done" without going through each sankalpa in turn.
struct JournalView: View {
    @Environment(AppModel.self) private var model

    private var grouped: [(day: CalendarDay, entries: [JournalEntry])] {
        Dictionary(grouping: model.journal(days: 365), by: { $0.occurredAt.day })
            .map { (day: $0.key, entries: $0.value.sorted { $0.occurredAt > $1.occurredAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if grouped.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing logged yet", systemImage: "book.closed")
                    } description: {
                        Text("Sessions you log against any sankalpa appear here, newest first.")
                    }
                } else {
                    List {
                        ForEach(grouped, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    JournalRow(entry: entry)
                                }
                            } header: {
                                HStack {
                                    Text(AppTime.relativeDayText(group.day, today: model.today))
                                    Spacer()
                                    Text("\(group.entries.count)")
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Journal")
        }
    }
}

private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack(spacing: 12) {
            ActionChip(actionType: entry.actionType, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sankalpaTitle)
                    .font(.subheadline.weight(.medium))
                Text(entry.actionType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(AppTime.timeText(entry.occurredAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
