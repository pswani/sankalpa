# Clients and Journeys

## Shared client model

Both apps use explicit `seriesId`/source links and the domain performed-time predicate. Their
session collections hold one fact per `SessionId`. A session row's displayed vow is independent
of its immutable logging owner. Do not clone a Swift `Session` with another parent ID to make it
appear in that vow's history.

Adapt both application query services, remote-store `totalCount`, and local FileStore `counts`:
filter series candidates using `SessionContributions`. Today, detail, collection, journal, and
outcome history must all use that projection. Preserve the existing calendar/timezone interpretation.

In `app/`, `RemoteSankalpaService.refresh()` currently concatenates sessions fetched for each vow
and rejects duplicate identities. Replace that refresh strategy with unique-fact paging from
`GET /api/v1/sessions`. Do not weaken the duplicate check: canonical fact pages must still contain
unique IDs. Per-vow contributed pages are for history display, not reconstruction of the cache.

## Extension interaction

From an In progress or Paused finite vow without a direct child, offer Extend. If it already has
a child, offer navigation to that child and its own Extend action when eligible. Completed,
Stopped, Not started, and indefinite vows cannot initiate extension. The backend remains the
authority if the displayed state has changed.

The form asks for **total duration**, in the existing period unit. A 40-day source extended to
90 days means a total of 90 days, not another 90 days. Derive the preview end date from the
original start and count. Show original/proposed durations and end dates, copied current state,
and that past and future eligible sessions will count toward both vows. Activity and frequency
are inherited rather than editable. Cancel before submission changes nothing.

The source keeps its own title and period count; distinguish identical titles using duration and
end date in linked navigation and selection. After success, navigate to the extension and retain
the source as a separate vow. There is no automatic completion, stop, or pause of the source.

## Durable remote extension attempt

`app/` adds one small attempt record per service, separate from the session journal:

```text
schemaVersion = 1
serviceInstanceId, sourceId, seriesId, extensionId, totalPeriodCount
revision                       immutable local operation revision
submittedAt
state                          unresolved | acceptedAwaitingCache | resolvedNotice | blockedConflict
acceptedResponse?              validated result plus resolution kind: exactCreation | existingChild
failureNotice?                 user-facing resolution/recovery evidence
```

Allow one unresolved extension attempt per service in this release. This does not block ordinary
eligible session logging on the series; it blocks submitting another extension. Persist the
stable identity/input/binding successfully immediately before the first network request. If the
write fails, send nothing. From that point, treat the command as submitted even if a crash occurs
before the network starts; resolve it by replay rather than guessing whether it was sent.

| Event | Durable state and visible behavior |
|---|---|
| Submit | Unresolved record exists; disable duplicate Extend submission; show processing. |
| Offline before Submit | Keep editable form; explain that extension creation requires connection; create no attempt/vow. |
| Timeout, lost response, 5xx | Retain unresolved record; show that the extension result is pending; retry same ID/input. |
| `201` or exact `200` | Validate ID/source/count/binding; retain accepted result until cached; then navigate to the child. |
| Cache write failure | Keep accepted result/attempt; retry local cache application or exact server replay; no new ID. |
| Existing-child conflict | Fetch/cache the named child/series, verify its source link, and explain its actual duration; do not claim the requested extension was created. |
| Definitive source/duration refusal | Move to resolvedNotice with no automatic resend; acknowledge the notice before correcting input as a new action. |
| Identity conflict/malformed result | Preserve attempt and evidence; block automatic retries; require recovery rather than a new guessed ID. |
| Upgrade-required | Retain attempt; rediscover same-service capability and retry when supported. |
| Relaunch | Load/validate attempt and resume unresolved delivery or accepted-result caching. |

Only an explicit existing-child conflict may resolve to a child ID different from the attempt ID.
Preserve the attempted identity/input while recording that separate resolution; a mismatched
`201`/`200` success is still a protocol failure. Clear the conflict attempt only after the named
child is cached and its resolution is shown.

Do not offer cancellation of an uncertain submitted command: an extension may already exist.
A definitive refusal is never retried automatically, even if the source later resumes.
An accepted result must reach the durable base cache before the attempt is removed. Reject service
relocation while a session operation or extension attempt remains unresolved. Every response
checks service binding and exact attempt revision before applying/removing it. A capability/header
upgrade changes transport context, not persisted source/count/identity.

Apply the response's complete series metadata/timelines together. Keep unique cached facts; do
not replace them with per-vow contributed rows. Mark this as an accepted local cache patch, not
as a complete refresh at the response revision. Invalidate earlier refresh publication before
applying it, then run a staged canonical-fact refresh. Never regress newer cached metadata with
an older result: keep the attempt until a current replay/refresh supplies a valid merge.

The local-file app needs no network attempt record. It calls the extension application command,
commits a complete candidate snapshot atomically, and navigates only after success. The existing
transactional file error surface reports a failed creation without changing the visible source.

The local app also exposes permanent session deletion from contributing histories and persists
recent-log guards in the same FileStore snapshot as logging/deletion. Its processing gate is
scoped to the logical local store and root, with no service-binding or network pending state.


## Consistent remote refresh

1. Capture existing service-binding and publication revisions; verify linked capability.
2. Load feature-aware collection rows and capture their server practice revision.
3. Fetch lifecycle rows and all canonical fact pages with that required server revision.
4. Require matching service/revision on every response; restart on `READ_SNAPSHOT_CHANGED`.
5. Resolve all sources, roots, owners, and transition origins; validate the complete collection.
6. Persist the complete staged base cache only while captured publication/binding still match.
7. Replace the visible store and reapply unresolved session overlays from their current revisions.

Try at most two complete passes per refresh invocation. An incomplete or repeatedly changing
collection retains the last valid cache and overlays. A response is not authoritative for the
whole collection merely because a single page succeeded. Reject conflicting duplicate facts,
owner aliases, unknown members, or partial histories; no silent repair by title/time.

If linked capability is absent, retain the existing one-member refresh/session path and disable
Extend. If the cached collection already contains links but the connected service advertises an
older contract, keep it readable with stale/offline status and block incompatible mutations.
Capability verification never retargets pending work to a new persistent service instance.

## Pending session projection and repeat guards

```text
active facts = unique base facts + pending creates by SessionId
visible facts = active facts minus all pending-delete SessionIds
vow view = visible facts filtered by same series and target performed-time eligibility
journal = unique visible facts; selected-vow totals use a union of contributions
```

Deletion suppression is global, even when initiated from a linked history whose displayed vow
is not the owner. A pending session may count toward several eligible vows; a rejection removes
it everywhere with the existing durable notice. Deletion rejection restores the original fact
everywhere it remains eligible. Own completed states and achievements are unchanged.

Use `(serviceInstanceId, seriesId)` for the processing gate and newest recent-log lookup. Retain
individual session ID, immutable owner, and pending/completed time for Undo, expiry, and deletion.
Confirming a rapid repeat allocates another identity; cancelling it creates nothing. Entries
expire after the existing 60-second elapsed-time rule, not after a change in performed time.
Switching linked vows cannot bypass either gate. Unrelated roots stay independent.

Migrate recent guards by resolving their retained owners to cached roots. Unknown scope means
logging is temporarily unavailable for that unresolved context until membership refresh succeeds;
it is not an empty guard. An extension leaves the root unchanged, so existing guards still apply.
Suppress guards for pending deletion and remove them after accepted deletion as before.

Starting linked offline logging requires validated cached members/timelines and verified cached
linked capability. Delivery of an already journaled command requires its existing identity/owner/
binding, not a currently complete contribution cache. Upgrade-required retains that operation and
its overlay until negotiation succeeds; only a definitive session refusal corrects it as rejected.

## Session deletion and completion

Deletion confirmation names the affected vows and explains that history and totals change across
them. Submit to the selected fact's logging owner; immediate Undo uses the accepted/pending
receipt's owner. Show pending suppression consistently in every view and retain existing recovery.
If contributors change before delivery, the effect is still removal of the one session fact.

On a successful Complete action, acknowledge the selected vow, its duration, and successful
outcome. Use the existing action result, not an observer that fires whenever a refreshed row has
a completed state. Persistent wins are the series members in Completed - Successfully with their
own terminal completion timestamps. Distinguish them by duration even when titles match.
Lost completion responses use the existing lifecycle refresh/recovery flow: the terminal vow
remains a visible win after refresh without inventing a new lifecycle replay protocol.

Completion before a duration's end remains the user's existing choice. A completed shorter vow
does not block eligible practice on the extension or force other vows to complete. Later backfill
or deletion updates counts while retaining the user-declared win. Badges, points, streaks, and
celebration asset creation are outside this implementation.

## Acceptance journeys

| Journey | Expected observable outcome |
|---|---|
| 40 → 90 days after 30 days | Original unchanged; child has the same start/history; 30 facts appear in each eligible history and once in journal. |
| Log through either member before day 40 ends | One fact; both eligible counts increase. |
| Complete original after day 40; log on day 41 through extension | Original win remains; only eligible longer vows receive that later contribution. |
| Pause only the extension; log through active original | Original accepts; extension excludes sessions performed during its own pause. |
| Log through paused extension at a paused performed time | Refused even if original would accept; no shared fact is created. |
| Delete an inherited session from the extension history | Owner-routed deletion removes its contribution everywhere; original win remains. |
| Extend 90 → 180 after original completes | Immediate source's history is copied; completed root remains linked and celebrated. |
| Switch vows during unresolved log or within 60 seconds | Processing blocks resubmission; a later rapid log requires confirmation. |
| Source completes while extension response is lost | Retry returns the existing child if committed; otherwise source-state refusal creates none. |
