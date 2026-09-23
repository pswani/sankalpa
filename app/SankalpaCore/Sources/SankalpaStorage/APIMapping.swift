import Foundation
import SankalpaCore

/// The service returned something this version of the app cannot turn into a domain value.
///
/// It is reported rather than absorbed: rendering a sankalpa whose commitment was quietly guessed
/// at would be worse than saying the two ends disagree.
struct WireDecodingError: Error, Equatable, Sendable {
    let field: String
    let value: String

    var message: String {
        "The service sent a \(field) this version of the app does not understand (\(value))."
    }
}

/// DTO → domain. The service is the authority on the rules, so nothing here re-validates: these
/// build values that the service has already accepted, the same way rehydrating from storage does.
enum APIMapping {

    static func sankalpa(
        _ dto: API.SankalpaResponse,
        transitions: [API.LifecycleTransitionResponse]
    ) throws -> Sankalpa {
        guard let actionType = APIEnum.actionType(dto.actionType) else {
            throw WireDecodingError(field: "action type", value: dto.actionType)
        }
        guard let periodUnit = APIEnum.periodUnit(dto.periodUnit) else {
            throw WireDecodingError(field: "period", value: dto.periodUnit)
        }
        guard let state = APIEnum.lifecycleState(dto.lifecycleState) else {
            throw WireDecodingError(field: "lifecycle state", value: dto.lifecycleState)
        }
        guard let startDate = WireFormat.day(from: dto.startDate) else {
            throw WireDecodingError(field: "start date", value: dto.startDate)
        }
        guard let declaredAt = WireFormat.moment(from: dto.declaredAt) else {
            throw WireDecodingError(field: "declaration time", value: dto.declaredAt)
        }

        let timesPerPeriod: TimesPerPeriod
        do {
            timesPerPeriod = try TimesPerPeriod(dto.timesPerPeriod)
        } catch {
            throw WireDecodingError(field: "times per period", value: "\(dto.timesPerPeriod)")
        }

        var periodCount: PeriodCount?
        if let declared = dto.periodCount {
            do {
                periodCount = try PeriodCount(declared)
            } catch {
                throw WireDecodingError(field: "duration", value: "\(declared)")
            }
        }

        return Sankalpa.rehydrate(
            id: SankalpaId(dto.id),
            declaredAt: declaredAt,
            title: try title(dto.title),
            description: SankalpaDescription(dto.description),
            actionType: actionType,
            commitment: Commitment(
                startDate: startDate,
                periodUnit: periodUnit,
                timesPerPeriod: timesPerPeriod,
                periodCount: periodCount
            ),
            lifecycle: LifecycleTimeline(
                current: state,
                transitions: try transitions.map(transition)
            )
        )
    }

    /// The service allows a longer title than this app's own limit, which is a deliberate
    /// asymmetry: a stricter client is compatible with a laxer service. This app is the only
    /// writer, so it cannot produce one — but if some other client ever does, showing a shortened
    /// title beats refusing to show the sankalpa at all.
    private static func title(_ raw: String) throws -> Title {
        if let title = try? Title(raw) { return title }
        // `Title` refuses only blank or over-long text. Shortening fixes the second and the
        // ellipsis fixes the first, so in practice this always succeeds.
        let shortened = String(raw.prefix(Title.maxLength - 1)) + "…"
        guard let title = try? Title(shortened) else {
            throw WireDecodingError(field: "title", value: raw)
        }
        return title
    }

    static func transition(_ dto: API.LifecycleTransitionResponse) throws -> LifecycleTransition {
        guard let from = APIEnum.lifecycleState(dto.from) else {
            throw WireDecodingError(field: "lifecycle state", value: dto.from)
        }
        guard let to = APIEnum.lifecycleState(dto.to) else {
            throw WireDecodingError(field: "lifecycle state", value: dto.to)
        }
        guard let effectiveAt = WireFormat.moment(from: dto.effectiveAt) else {
            throw WireDecodingError(field: "transition time", value: dto.effectiveAt)
        }
        guard let recordedAt = WireFormat.moment(from: dto.recordedAt) else {
            throw WireDecodingError(field: "transition time", value: dto.recordedAt)
        }
        return LifecycleTransition(from: from, to: to, effectiveAt: effectiveAt, recordedAt: recordedAt)
    }

    static func session(_ dto: API.SessionResponse) throws -> Session {
        guard let occurredAt = WireFormat.moment(from: dto.occurredAt) else {
            throw WireDecodingError(field: "session time", value: dto.occurredAt)
        }
        guard let loggedAt = WireFormat.moment(from: dto.loggedAt) else {
            throw WireDecodingError(field: "session time", value: dto.loggedAt)
        }
        return Session.rehydrate(
            id: SessionId(dto.id),
            sankalpaId: SankalpaId(dto.sankalpaId),
            occurredAt: occurredAt,
            loggedAt: loggedAt
        )
    }

    // MARK: - Domain → DTO

    static func declareRequest(_ declaration: Declaration, id: SankalpaId) -> API.DeclareRequest {
        API.DeclareRequest(
            id: id.value,
            title: declaration.title,
            description: declaration.description,
            actionType: APIEnum.wire(declaration.actionType),
            startDate: WireFormat.text(declaration.startDate),
            periodUnit: APIEnum.wire(declaration.periodUnit),
            timesPerPeriod: declaration.timesPerPeriod,
            periodCount: declaration.periodCount
        )
    }
}
