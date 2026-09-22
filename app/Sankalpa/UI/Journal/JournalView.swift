import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Everything performed, across every sankalpa, newest first. It answers "what have I actually
/// done" without going through each sankalpa in turn.
struct JournalView: View {
    @Environment(AppModel.self) private var model

    private var grouped: [(day: CalendarDay, entries: [JournalEntry])] {
        // The journal is a query, not a stored property, so nothing here would otherwise tell
        // SwiftUI that the answer has changed — and this is a tab, so the view outlives the
        // visit that built it. Reading the revision is what makes a session logged on another
        // tab show up on the next visit to this one.
        _ = model.revision
        return Dictionary(grouping: model.journal(), by: { $0.occurredAt.day })
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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Same rule as every other row in the app: at accessibility sizes the title gets the
        // width instead of sharing it with an icon and a timestamp.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            ActionChip(actionType: entry.actionType, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sankalpaTitle)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.actionType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }

            Text(AppTime.timeText(entry.occurredAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
