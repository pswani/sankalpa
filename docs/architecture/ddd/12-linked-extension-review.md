# 12 — Linked Extension Architecture Review

Reviewed on October 7, 2026 against
[Linked Sankalpa Extensions](../../requirements/linked-sankalpa-extensions.md),
[Sankalpa](../../requirements/sankalpa.md), and the existing
[session reliability design](../../design/session-reliability/README.md).
This records the update, self-review, and fix loop for the documentation. It does not certify an
implementation or report tests that have not been run.

## Pass 1 — Model and requirement coverage

Updated the domain, vocabulary, commands, queries, persistence, decisions, and testing strategy.
Added [Linked extensions](11-linked-extensions.md) as the detailed cross-layer design.

| Finding | Fix |
|---|---|
| Earlier documents treat the logging owner as the only vow whose history/count can include a session. | Keep the immutable owner for identity commands; derive contributions from explicit series membership and each target's performed-time eligibility. Update histories, lifetime counts, outcomes, and combined totals. |
| Fresh lifecycle creation would reject inherited sessions or lose paused-period behavior. | Copy the source timeline as a value and retain transition origins/timestamps. Extension creation is separate audit metadata, not Begin. |
| Existing one-year start validation would reject legitimate long-running extensions. | Use a dedicated extension factory; retain declaration limits for unrelated vows. |
| Deletion from a contributing view could name the wrong identity owner. | Expose the immutable logging owner on session rows and route deletion/Undo to it. Keep cross-owner identity conflicts. |
| Extension creation could branch or capture a stale source timeline. | Atomic creation, unique direct child, shared series-root write ordering, and command time captured after the guard. |
| Pending overlays and repeat guards were scoped to a single displayed vow. | Suppress sessions globally by ID; derive all contributions after overlay; scope processing/repeat guards to the series root. |

## Pass 2 — Restore, compatibility, and operational consistency

Reviewed the changed contracts and command sequences after the first fixes.

| Finding | Fix |
|---|---|
| Restore cannot require a child timeline to equal its source's entire current history. | Validate the inherited prefix with ancestor origins and original values; validate the child's own suffix separately. Preserve sequence for equal-time transitions. |
| Detail/list sketches still allowed owner-only aggregate counts and filtered candidate pages could truncate history. | Assemble counts with the contribution helper; paginate after eligibility filtering; use complete traversal for lifetime counts. |
| Root-first locking was not explicit in the Begin example or absent-session deletion path. | Show root acquisition before reloading the vow and capturing time; apply the same order to deletion. |
| A partial refresh could publish facts without the owner/membership needed to calculate contributions. | Require consistent contribution read snapshots and stage client refresh publication; incomplete results retain the last valid snapshot and overlays. |
| Renaming the owner field would unnecessarily break existing consumers. | Retain `sankalpaId` as an alias and add the explicit `loggingSankalpaId`. |
| Capability advertising alone would let older clients mutate or misread linked vows. | Define the linked contract header, gate linked writes/reads, and keep ordinary one-member compatibility. |
| A pending old-contract log could be rejected after its owner became linked. | Treat upgrade-required as unresolved, preserve the command identity/binding, and negotiate the header before retry. Exact accepted/deleted identities remain replayable. |
| Lost extension responses could create uncertainty or a second request identity. | Persist one small extension attempt and retry the same child ID/input; publish only authoritative creation and resolve existing-child conflicts. |

## Pass 3 — Final requirement and scope review

Walked through these scenarios against the revised model:

- Create a 90-day extension from an ongoing 40-day vow, including inherited paused intervals.
- Extend an already extended vow while the original root is completed.
- Log through either vow; reject an ineligible logging owner while independently filtering
  contributions to paused, shorter, or terminal members.
- Complete the shorter vow, continue the longer vow, and retain two separate successful wins.
- Backfill eligible past sessions after completion; delete a shared session without reopening vows.
- Retry creation/logging after uncertain delivery; race extension with lifecycle change or deletion.
- Restore a series whose timelines have diverged; retain guards and pending commands during upgrade.

Each requirement group maps to a responsibility in the coverage table in
[Linked extensions](11-linked-extensions.md), with implementation acceptance checks in
[Testing strategy](08-testing-strategy.md). Reviewed the existing chapter sketches and decision
records for consistency with those responsibilities.

Result: no unresolved feature architecture blockers found. The design retains one bounded
context, independent vow aggregates, one fact per session, and derived outcomes. It introduces
no session-copy process, contribution projection, series aggregate, event infrastructure,
activity catalogue, or achievement subsystem. Existing general timezone and sankalpa edit/delete
questions remain outside this feature.

Documentation checks cover local link targets, code-fence balance, and diff whitespace. The race,
migration, client, and journey checks are specified for implementation; they must pass before
shipping the feature.

## Detailed-design refinements

The subsequent [design review](../../design/linked-sankalpa-extensions/design-review.md) makes
read consistency concrete with a practice revision in existing service metadata and required
revision/cursor headers. It also resolves the legacy collection restriction as an upgrade-required
refusal, preserving the existing array shape. These refinements are reflected in chapter 11;
they add no retained snapshots, event stream, or contribution projections.
