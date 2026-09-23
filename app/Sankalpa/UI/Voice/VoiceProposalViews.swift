import SankalpaCore
import SankalpaStorage
import SankalpaVoice
import SwiftUI

struct VoiceSessionProposalView: View {
    let proposal: VoiceSessionProposal

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label(proposal.title, systemImage: "checkmark.circle")
                    .font(.headline)
                LabeledContent("Date", value: proposal.occurredAt.day.longDisplayText)
                LabeledContent("Time", value: AppTime.timeText(proposal.occurredAt))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct VoiceDeclarationProposalView: View {
    let proposal: VoiceDeclarationProposal

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(proposal.declaration.title).font(.headline)
                if !proposal.declaration.description.isEmpty {
                    Text(proposal.declaration.description).foregroundStyle(.secondary)
                }
                LabeledContent("Action", value: proposal.declaration.actionType.displayName)
                LabeledContent("Starts", value: proposal.declaration.startDate.longDisplayText)
                LabeledContent(
                    "Commitment",
                    value: "\(proposal.declaration.timesPerPeriod) times \(proposal.declaration.periodUnit.perPhrase)"
                )
                if let count = proposal.declaration.periodCount {
                    LabeledContent(
                        "Duration",
                        value: "\(count) \(proposal.declaration.periodUnit.pluralName(count))"
                    )
                }
                if let endDate = proposal.endDate {
                    LabeledContent("Ends", value: endDate.longDisplayText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct VoiceDraftView: View {
    let draft: VoiceDeclarationDraft

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title ?? "Untitled Sankalpa").font(.headline)
                if let actionType = draft.actionType {
                    Label(actionType.displayName, systemImage: actionType.symbolName)
                }
                if let start = draft.startDate {
                    LabeledContent("Starts", value: start.longDisplayText)
                }
                if let count = draft.timesPerPeriod, let period = draft.periodUnit {
                    LabeledContent("Commitment", value: "\(count) times \(period.perPhrase)")
                }
            }
        }
    }
}
