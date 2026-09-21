import SwiftUI
import SankalpaCore
import SankalpaStorage

struct TodayView: View {
    @Environment(PracticeModel.self) private var model
    var onDeclare: () -> Void
    var onSettings: () -> Void
    private var practicing: [SankalpaSummary] { model.active.filter { $0.state == .inProgress } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: AppTime.date(from: model.today).formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        Text(model.active.isEmpty ? "Make space for\nwhat matters." : "Practice, gently.")
                            .font(.largeTitle.weight(.medium)).fontDesign(.serif).fixedSize(horizontal: false, vertical: true)
                        Text(model.active.isEmpty ? "A small commitment. A practice of your own." : todaySummary)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    if model.active.isEmpty {
                        Surface {
                            VStack(alignment: .leading, spacing: 20) {
                                Image(systemName: "leaf").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Ink.accent).accessibilityHidden(true)
                                Text(model.summaries.isEmpty ? "Your first sankalpa" : "A new chapter").font(.title2).fontDesign(.serif)
                                Text(model.summaries.isEmpty ? "Name an intention and choose how often you’ll return to it. You decide when to begin." : "Your finished intentions are safe in Collection. Begin another whenever you are ready.")
                                    .foregroundStyle(.secondary)
                                Button("Declare an intention", action: onDeclare).buttonStyle(FilledButton())
                            }
                        }
                    } else {
                        if !practicing.isEmpty { practiceSection("In practice", items: practicing) }
                        let paused = model.active.filter { $0.state == .paused }
                        if !paused.isEmpty { practiceSection("On pause", items: paused) }
                        let waiting = model.active.filter { $0.state == .notStarted }
                        if !waiting.isEmpty { practiceSection("Ready when you are", items: waiting) }
                    }
                    Text("Intent becomes practice, one session at a time.")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 8)
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(Ink.paper).navigationTitle("Today").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Your data", systemImage: "slider.horizontal.3", action: onSettings) }
                ToolbarItem(placement: .topBarTrailing) { Button("Declare an intention", systemImage: "plus", action: onDeclare).accessibilityIdentifier("declare-intention") }
            }
            .navigationDestination(for: SankalpaId.self) { DetailView(id: $0) }
        }
    }
    private var todaySummary: String {
        let open = practicing.filter { $0.currentPeriod?.isSatisfied == false }.count
        if open == 0 && practicing.contains(where: { $0.currentPeriod != nil }) { return "Your current commitments are met. There is room to pause." }
        if !practicing.isEmpty && practicing.allSatisfy({ $0.currentPeriod == nil }) { return "Your completed schedules are ready to review." }
        if open == 1 { return "One intention to return to. Make a little room for it." }
        if open > 1 { return "\(open) intentions to return to, at your own pace." }
        return "A little space for the things you choose."
    }
    private func practiceSection(_ title: String, items: [SankalpaSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            ForEach(items) { item in
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(item.actionType.displayName.uppercased(), systemImage: item.actionType.symbol)
                                        .font(.caption.weight(.medium)).tracking(1).foregroundStyle(Ink.accent)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                }.accessibilityHidden(true)
                                Text(item.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                Text(item.commitment.fullPhrase).font(.subheadline).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("open-\(item.title)")
                        if item.state == .inProgress, let progress = item.currentPeriod {
                            PracticeProgress(progress: progress)
                            if progress.isSatisfied {
                                Button("Record another session") { model.logNow(item.id) }
                                    .buttonStyle(OutlineButton()).accessibilityIdentifier("record-\(item.title)")
                            } else {
                                Button("Record session") { model.logNow(item.id) }
                                    .buttonStyle(FilledButton()).accessibilityIdentifier("record-\(item.title)")
                            }
                        } else {
                            Status(state: item.state)
                            if item.state == .inProgress { Text("The commitment has ended. Review it when you are ready.").font(.footnote).foregroundStyle(.secondary) }
                            if item.state == .paused { Text("Your history is here whenever you return.").font(.footnote).foregroundStyle(.secondary) }
                            if item.state == .notStarted { Text("Starts \(item.commitment.startDate.longDisplayText)").font(.footnote).foregroundStyle(.secondary) }
                            NavigationLink(value: item.id) { Text(item.state == .notStarted ? "Review and begin" : "Open practice").frame(maxWidth: .infinity) }.buttonStyle(OutlineButton())
                        }
                    }
                }
            }
        }
    }
}
struct CollectionView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(PracticeModel.self) private var model
    var onDeclare: () -> Void
    @State private var search = ""
    @State private var filter = "Active"
    private var items: [SankalpaSummary] {
        model.summaries.filter {
            (filter == "All" || (filter == "Finished" ? $0.state.isTerminal : !$0.state.isTerminal)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.sankalpa.description.value.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The intentions you keep.").font(.title2).fontDesign(.serif)
                    Picker("Show intentions", selection: $filter) { ForEach(["Active", "Finished", "All"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    if items.isEmpty {
                        EmptyPractice(title: search.isEmpty ? "Nothing here yet" : "No matching intentions", message: search.isEmpty ? "Choose another filter, or declare an intention of your own." : "Try a different title or description.", symbol: "square.stack")
                    }
                    ForEach(items) { item in
                        NavigationLink(value: item.id) {
                            Surface {
                                VStack(alignment: .leading, spacing: 12) {
                                    if typeSize.isAccessibilitySize {
                                        Image(systemName: item.actionType.symbol).font(.title2).foregroundStyle(Ink.accent).accessibilityHidden(true)
                                        Text(item.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: item.actionType.symbol).font(.title2).foregroundStyle(Ink.accent).accessibilityHidden(true)
                                            Text(item.title).font(.headline).foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                                        }
                                    }
                                    Text(item.commitment.fullPhrase).font(.subheadline).foregroundStyle(.secondary)
                                    Status(state: item.state)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("collection-\(item.title)")
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(Ink.paper).navigationTitle("Collection")
                .searchable(text: $search, prompt: "Find an intention")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Declare an intention", systemImage: "plus", action: onDeclare) } }
                .navigationDestination(for: SankalpaId.self) { DetailView(id: $0) }
        }
    }
}
