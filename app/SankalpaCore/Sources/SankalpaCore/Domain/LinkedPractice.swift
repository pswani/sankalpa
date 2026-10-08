import Foundation

public enum ExtensionError: DomainError {
    case sourceNotExtendable, durationNotGreater, endsInPast, invalidIdentity, clockMovedBackwards
    public var message: String {
        switch self {
        case .sourceNotExtendable: "Only an ongoing finite sankalpa can be extended."
        case .durationNotGreater: "Choose a greater total duration from the original start."
        case .endsInPast: "The extended end date must be today or later."
        case .invalidIdentity: "The extension must have its own identity."
        case .clockMovedBackwards: "Check the device date and time before extending this sankalpa."
        }
    }
}

public enum SessionContributions {
    public static func contributes(_ fact: Session, to target: Sankalpa, members: [Sankalpa]) -> Bool {
        guard let owner = members.first(where: { $0.id == fact.sankalpaId }) else { return false }
        return owner.seriesId == target.seriesId && target.acceptsPerformedAt(fact.occurredAt)
    }
    public static func contributors(_ fact: Session, members: [Sankalpa]) -> [Sankalpa] {
        members.filter { contributes(fact, to: $0, members: members) }
            .sorted { ($0.commitment.periodCount?.value ?? 0) < ($1.commitment.periodCount?.value ?? 0) }
    }
}

/// Reject malformed remote/cached collections before publishing a partial practice.
public enum PracticeValidation {
    public enum Invalid: Error { case collection }
    public static func validate(_ vows: [Sankalpa], sessions: [Session]) throws {
        guard Set(vows.map(\.id)).count == vows.count, Set(sessions.map(\.id)).count == sessions.count else { throw Invalid.collection }
        let owners = Dictionary(uniqueKeysWithValues: vows.map { ($0.id, $0) })
        var sources = Set<SankalpaId>()
        for vow in vows {
            guard (1...TimesPerPeriod.maxValue).contains(vow.commitment.timesPerPeriod.value),
                  vow.commitment.periodCount.map({ (1...PeriodCount.maxValue).contains($0.value) && vow.endDate != nil }) ?? true
            else { throw Invalid.collection }
            guard let root = owners[vow.seriesId], root.id == root.seriesId, root.extensionOf == nil else { throw Invalid.collection }
            var state = LifecycleState.notStarted
            var last: LifecycleTransition?
            for entry in vow.lifecycle.transitions {
                guard entry.from == state, state.canTransition(to: entry.to), entry.effectiveAt <= entry.recordedAt,
                      entry.effectiveAt == entry.recordedAt || (state == .notStarted && entry.to == .inProgress),
                      last == nil || (entry.effectiveAt >= last!.effectiveAt && entry.recordedAt >= last!.recordedAt),
                      entry.originSankalpaId.flatMap({ owners[$0] }) != nil else { throw Invalid.collection }
                if entry.to == .inProgress && entry.from == .notStarted && entry.effectiveAt.day < vow.startDate { throw Invalid.collection }
                state = entry.to; last = entry
            }
            guard state == vow.state else { throw Invalid.collection }
            guard let source = vow.extensionOf else {
                guard vow.id == vow.seriesId, vow.lifecycle.transitions.allSatisfy({ $0.originSankalpaId == vow.id }) else { throw Invalid.collection }
                continue
            }
            guard sources.insert(source).inserted, let parent = owners[source], parent.seriesId == vow.seriesId,
                  parent.title == vow.title, parent.description == vow.description, parent.actionType == vow.actionType,
                  parent.startDate == vow.startDate, parent.commitment.periodUnit == vow.commitment.periodUnit,
                  parent.commitment.timesPerPeriod == vow.commitment.timesPerPeriod,
                  let count = vow.commitment.periodCount, let previous = parent.commitment.periodCount, count.value > previous.value,
                  vow.declaredAt >= parent.declaredAt, vow.endDate.map({ $0 >= vow.declaredAt.day }) == true else { throw Invalid.collection }
            var ancestors = Set<SankalpaId>(); var cursor: Sankalpa? = parent
            while let member = cursor {
                guard member.id != vow.id, ancestors.insert(member.id).inserted else { throw Invalid.collection }
                if let id = member.extensionOf { guard let ancestor = owners[id] else { throw Invalid.collection }; cursor = ancestor }
                else { cursor = nil }
            }
            guard ancestors.contains(root.id) else { throw Invalid.collection }
            let history = vow.lifecycle.transitions
            let prefix = history.prefix { $0.originSankalpaId != vow.id }
            guard !prefix.isEmpty, Array(parent.lifecycle.transitions.prefix(prefix.count)) == Array(prefix),
                  prefix.last?.to == .inProgress || prefix.last?.to == .paused,
                  prefix.allSatisfy({ ancestors.contains($0.originSankalpaId!) && $0.recordedAt <= vow.declaredAt }),
                  history.dropFirst(prefix.count).allSatisfy({ $0.originSankalpaId == vow.id && $0.recordedAt >= vow.declaredAt }),
                  parent.lifecycle.transitions.filter({ $0.recordedAt < vow.declaredAt }).count <= prefix.count else { throw Invalid.collection }
        }
        for fact in sessions {
            guard let owner = owners[fact.sankalpaId], owner.acceptsPerformedAt(fact.occurredAt), fact.occurredAt <= fact.loggedAt else { throw Invalid.collection }
        }
    }
}
