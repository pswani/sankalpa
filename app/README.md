# Sankalpa — iOS app

A single-user iPhone app for [docs/requirements/sankalpa.md](../docs/requirements/sankalpa.md),
implementing the model in [docs/architecture/ddd](../docs/architecture/ddd).

Declare an intent with a commitment ("twice a day for 180 days"), begin it, log the sessions you
perform, and see how each period turned out once it closes.

**The [backend service](../backend/README.md) owns the practice; the phone keeps a copy.** Every
command goes to the service, which decides what is allowed. What it returns is cached on the phone,
so the practice is still readable when that computer is not reachable — and a session logged while
it is away is held and sent as soon as it answers.

## Running it

Requires Xcode 27, an iOS 27 simulator runtime, and the service running.

```bash
cd backend && SANKALPA_TIMEZONE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||') mvn spring-boot:run
```

`SANKALPA_TIMEZONE` must be the zone the phone is in. Both ends exchange offset-free wall-clock
times, so if they disagree the service will reject sessions as being in the future and judge
periods against the wrong day.

```bash
open app/Sankalpa.xcodeproj
```

Pick the **Sankalpa** scheme and an iPhone 17 Pro simulator. From the command line:

```bash
xcodebuild -project app/Sankalpa.xcodeproj -scheme Sankalpa -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The app looks for the service on `localhost` by default, which is where a **simulator** reaches one
running on the same Mac. On a **real phone** that never works — `localhost` is the phone — so the
name of the Mac has to be set: **Sankalpas → Sankalpa service**, then type something like
`studio.local` (add `:port` if it is not 8080). The same screen is reachable from the recovery
screen, which is where someone with nothing on screen yet will be. `SANKALPA_API_BASE_URL` in the
scheme's environment overrides the setting without disturbing it, which is how a UI run points the
app at its own service.

When the service advertises the `ag-ui-sankalpa/1` capability, an Assistant tab appears. It can
answer questions and prepare session or declaration proposals, but nothing is saved until the
proposal card is confirmed. Cancel and Edit cancel the server proposal first. Dictation uses
on-device speech recognition to fill the same editable composer and never sends automatically.

For a protected service, enter its bearer credential under **Sankalpas → Sankalpa service →
Authentication**. The credential is stored in the iOS Keychain and is sent to both the ordinary
REST API and assistant endpoint. A physical-device deployment must use an `https://` service
address backed by a certificate the device trusts; the app does not weaken platform TLS checks.
Enabling the assistant sends transcript text and bounded practice context to the model provider
configured on the service, but microphone audio stays on the device.

**A normal launch shows whatever the service holds.** There is no demo seed inside the app any
more: with a shared service there is no per-launch sandbox to seed and no delete endpoint to undo
it with. [`scripts/seed-demo.py`](scripts/seed-demo.py) builds the same five-sankalpa fixture
through the API instead — point it at a throwaway service, never at your own.

```bash
./app/scripts/seed-demo.py --base-url http://localhost:8080
```

## Layout

```text
app/
  SankalpaCore/          Swift package, domain, storage, and conversation library targets
    Sources/SankalpaCore/
      Domain/            Sankalpa, Session, Commitment, LifecycleTimeline, PeriodOutcomeCalculator
      Application/       Ports, use cases, queries, read models
    Sources/SankalpaStorage/
      SankalpaAPIClient.swift     HTTP against the service, and nothing else
      RemoteSankalpaService.swift Commands out, a snapshot back, the read side over it
      PracticeCache.swift         The phone's copy, and the outbox of what it still owes
      ServiceLocation.swift       Which computer the service is on, and where that is stored
      APIModels/APIMapping        The wire shapes and their translation to domain values
      ServerRefusal.swift         Problem codes back into the app's own domain errors
      WireFormat.swift            Zone-free dates and times, without going through `Date`
      AppTime.swift               The one place instants become dates
    Tests/               90 core tests + 64 adapter tests
  Sankalpa/              The iOS app
    UI/                  SwiftUI screens and the design system — the driving side
  SankalpaUITests/       Journeys through the app, and a tour that captures every screen
  scripts/               test.sh, uitest.sh, seed-demo.py, report.py, run.sh, make-app-icon.py
```

### How the two halves divide

The service owns every rule. The app sends a command, the service accepts or refuses it, and the
app maps the refusal's stable `code` back into the domain error the screens were already written
around — so a refusal reads in the app's own voice rather than as an API `detail` string.

Reads work the other way. `GET /sankalpas` returns declarations only: no current period, no session
count, no transitions. Everything the screens actually show — the Today board's progress rings, the
period strip, the satisfied/missed tally, the journal, the list ordering — is derived on the device
from the sankalpas, sessions and lifecycle transitions a refresh pulls down, using the same
`PeriodOutcomeCalculator` and query surface as before. That is why a refresh is `1 + 2N` requests,
and why `SankalpaCore` still holds a full domain model rather than a set of view structs.

`SankalpaStorage` is a library target rather than app code specifically so this seam can be tested
without a simulator: the wire format, the mapping, the refusal translation and the refresh fan-out
all have tests that answer from a stub transport.

### Away from the service

Three rules decide what happens when the Mac is not reachable, and they are easier to keep straight
as a set than one at a time:

1. **The service owns the rules.** Every command goes to it, and it is the only thing that can say
   yes.
2. **The service wins.** A refresh replaces the phone's copy outright rather than merging into it.
   Nothing cached can contradict what the service says about a sankalpa.
3. **Except what the service has not seen.** A session logged while it was away is held in an
   outbox, counts towards the period straight away, and is sent at the first opportunity. If the
   service then refuses it — the sankalpa was paused elsewhere in the meantime — rule 2 applies: it
   is dropped and the person is told why, in the service's own words rather than a sentence rebuilt
   from the copy that was wrong.

Two files hold this, and the split is the point. The **cache** is a copy of what the service last
said; losing it costs a round trip, so one that cannot be read is simply discarded. The **outbox**
holds sessions that exist nowhere else; losing it loses someone's practice, so one that cannot be
read is renamed and kept rather than written over, and a session is reported as logged only once it
has reached the disk. A corrupt cache must not be able to take the outbox with it.

**Only session logging and deletion work offline.** Lifecycle transitions are refused with a clear
reason: queuing them would need ordering and backdating rules the requirements do not settle, and
"the service wins" cannot reconcile a queued Pause against a service that has moved on. Offline
session changes still apply the rules known to the phone. They remain visibly pending until the
service accepts or rejects them; a rejected change is corrected locally and explained to the user.

The recovery screen now appears only when the phone has nothing cached either. Once there is a
copy, a failure becomes a strip across the top saying the practice may be behind and how many
session changes are pending — a state, not an event, so not an alert that keeps coming back.

**There is no export.** The practice is in the service, which is where a copy would come from.

The dependency rule from
[06-hexagonal-architecture](../docs/architecture/ddd/06-hexagonal-architecture.md) holds: the
package has no SwiftUI or UIKit import, and nothing in `Domain/` knows about persistence or the
system clock.

## Screens

| Screen | Purpose |
|---|---|
| Today | What is still open in the current period, and one tap to log a session |
| Sankalpas | Every sankalpa, filtered by Active / Finished / All; declaring a new one |
| Sankalpa detail | State, commitment, current period, period outcomes, sessions, lifecycle actions |
| Periods | Every judged period with the arithmetic behind each standing |
| Sessions | Everything logged for one sankalpa, grouped by day |
| Transition history | The lifecycle audit trail, with effective and recorded times |
| Journal | Every performed session across every sankalpa, newest first |

## Testing

```bash
./app/scripts/test.sh
```

One command runs everything — the domain, application and storage suites, the simulator suites,
and a Release build — and writes a report to `app/build/test-runs/latest/`. The exit status is
the worst result. [TESTING.md](TESTING.md) covers the options, the report layout, and how to add
a test.

The core suites run on the macOS toolchain with no simulator, in about a second. They cover the
requirement's own examples (Vipassana twice a day for six months, gym four times a week with no
duration) plus the boundary rules: January 31 monthly anchoring, February 29 yearly anchoring,
inclusive end dates, the transition table, backdated Begin, session eligibility, partial versus
full pauses, the terminal-transition cutoff, and the limits the declare form shows the user.

The simulator suites are in two halves. `JourneyTests` drives the app from an empty store the way
a person would — declare, begin, log, pause, resume, complete, stop, filter, clear — and checks
that what the screens offer actually happens, including that a period moves when a session is
logged and that a stopped sankalpa leaves the active list. `ScreenTour` walks every screen
in Light Mode, Dark Mode and at an accessibility text size and captures it; every step asserts the
element it is about to use rather than skipping quietly when a screen fails to appear.

Between them they drive the things that would lose or misreport someone's practice: a service that
has never answered raises recovery instead of looking like a first run, and a retry that fails says
so and names the address it tried; a logged session is still there after a relaunch; a forgotten
session can still be recorded from Paused and from a finished sankalpa; and a duration can be typed
rather than stepped to. The Release build at the end is where an optimiser difference or a
`#if DEBUG` mistake would show up, since every test hook is debug-only.

Run them with [`scripts/uitest.sh`](scripts/uitest.sh), not `xcodebuild test` directly. Isolation
used to come from giving each test its own store file; with the practice in a service it comes from
giving each test *class* its own service — the script starts a backend per class on a throwaway
database, seeds the demo fixture into the one `ScreenTour` uses, and leaves the one `JourneyTests`
uses empty. Run against a service that already holds sankalpas and the empty-state assertions will
fail, and nothing in the suite can put it back: the API has no delete.

For design review, every run leaves its numbered gallery at the stable path
`app/build/screens`, pointing at the newest run — so reviewing a change means opening the same
path again and seeing what moved.

## How much history is reported

Every read is day-range bounded (DD-17), so the screens name their ranges rather than implying
they show everything:

| Screen | Range |
|---|---|
| Periods, and the tally above it | The most recent 3,650 periods — one number for both, so the count can never describe rows the list does not contain. The footer says so only when something was actually cut off. |
| Sessions | Complete session history, loaded through all service pages |
| Recent sessions, on detail | The last 120 days. When there is older history the card says so and still links to the full list. |
| Journal | The last 3,650 days |

3,650 is also the longest duration a commitment can declare, so it is sufficient for period and
journal reporting. Session history is deliberately not bounded by that range: it is also the place
where a user can find and permanently delete any recorded session, including one older than the
current commitment window. The worst bounded reporting case — ten years of daily practice, 3,650
sessions, every period rebuilt — takes about 7 ms in a Debug build, which is why the Periods screen
computes its list directly rather than caching it.

## Responsiveness

A command is cheap. Measured on an iPhone 17 Pro simulator with the sample data (5 sankalpas,
172 sessions), a lifecycle transition takes **about 5 ms end to end** — roughly 4.6 ms of that is
writing the store file, and the query layer that rebuilds every summary afterwards is around
0.2 ms.

Two things follow from that, and both are already done:

- Period outcomes for the card strips are computed once per refresh and cached on `AppModel`,
  rather than being fetched from inside a view's `body`. The work was small, but calling into the
  application layer during rendering is how small work stops being small.
- The store writes compact JSON. Pretty-printing an app data file that nobody reads roughly doubled
  both the encode time and the file size.

If the app ever does feel slow, check first whether the control is actually disabled — a tap that
does nothing is indistinguishable from a tap that is slow, and that is a far more likely cause here
than the arithmetic.

## Where this departs from the design documents

The DDD documents describe a server with HTTP controllers and a relational store. The same model on
a local single-user iPhone app leads to a few deliberate differences.

| Document | This implementation | Why |
|---|---|---|
| `SankalpaReadPort` with flat read rows | Queries go through the two repository ports | The read port exists to keep SQL read models out of the aggregate. With one local JSON store there is no second query engine to isolate, so the port would wrap nothing. |
| Seven single-method use-case classes | One `SankalpaApplicationService`, one method per use case | The use-case names stay visible without seven files of constructor boilerplate. No rules moved into it. |
| `Result<T, E>` returns | Swift typed `throws(E)` | The same thing in Swift, and it reads better at the call site. Every domain error type is still explicit in the signature. |
| `LocalDate` / `LocalDateTime` | `CalendarDay` / `CalendarMoment` | Foundation has no zone-free date. These are integer-only value types, so a daylight-saving shift cannot move a period boundary. Conversion happens once, in `AppTime`. |
| HTTP controllers | SwiftUI views and `AppModel` | The driving adapter for this app is the UI. |
| `SessionRepository.findForSankalpa` | Plus `sessions(from:until:)` across all sankalpas | The Journal reads performed sessions across sankalpas. Still day-range bounded, per DD-17. |
| iPhone and iPad | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait only | The requirement is an iPhone app. Declaring iPad, or the landscape orientations the template turns on, would claim support for layouts that were never designed or tested. Every screen here is a single vertical column; landscape adds nothing it does not already do. |
| Domain objects mapped to persistence rows | Explicit DTOs and a hand-written mapping in `SankalpaStorage` | The service is a separate deployable with its own release cycle, so its wire shape is a contract rather than an internal detail. A field this version cannot read is reported instead of guessed at. |
| The repository port is the persistence seam | It is a read-through snapshot of the service, plus a durable operation journal | Commands never go through it — they go to the service, or to the journal — so its `save` methods refuse rather than pretend. The conformance exists so the query surface can run unchanged over server-sourced facts; reads overlay pending creates and deletions, so the visible practice immediately reflects a change whether or not the service has heard about it. |

Four launch arguments remain, all compiled out of release builds: `-forceDarkMode` forces the
appearance because the simulator's own switch does not reliably repaint this runtime,
`-resetIntroduction` clears the first-run flag so the introduction card can be captured and then
dismissed normally, `-resetCache` starts from an empty phone because the cache is built to survive
and a test that did not ask would inherit the last run's practice, and `-offline` makes every
request fail so the offline screens can be driven — nothing inside the simulator can stop the
service a test is running against. `SANKALPA_API_BASE_URL` points the app at a service, which is
how a UI run reaches its own throwaway one.

## Interpretations

Decisions the requirements do not settle, recorded so the behaviour is explicit rather than
accidental. Each is *decision → reason → what is still open*.

- **Periods that closed before the sankalpa was begun are evaluated as missed.** "When a period ends,
  each session not logged as performed counts as missed" has no carve-out for them, and a backdated
  Begin is exactly the tool for covering them. The alternative — exempting them — would let a
  sankalpa started late look better than one started on time.
- **A future start date is allowed.** The requirements bound only how far in the past a start date
  may be. A sankalpa declared with a start date still to come simply waits in Not started, and
  Begin is refused until that date.

- **A declared sankalpa cannot be edited**, because the requirements leave editing unresolved
  (Q2/A3). The detail screen says so rather than leaving the user hunting for a button. *Open:
  amendment A3 would allow changing Key Information while Not started, which is the natural way to
  move a start date.*
- **A logged session can be corrected.** The confirmation offers an immediate Undo, and complete
  session history supports permanent deletion later. A deleted session is excluded immediately and
  no longer contributes to totals or period outcomes; an unresolved deletion remains visibly
  pending and completes when the service is reachable.
- **Each logging action has a stable client-generated identity.** Retries use that identity, so a
  lost response cannot create another session. Equal performed-at times do not collapse distinct
  actions. A new action for the same sankalpa within one minute asks for confirmation; confirming it
  intentionally creates another session.
- **The time zone is captured once per launch**, so a day already recorded keeps its meaning if the
  device travels mid-session; a relaunch picks up the new zone. *Open: Q1 — no per-sankalpa zone is
  modelled, and repeated daylight-saving hours have no stated policy.*
- **A period is judged only once it closes**, so the current period is neither satisfied nor missed
  and is shown as open.

All of these are worth confirming before this is taken further; they belong with the questions in
[09-open-questions](../docs/architecture/ddd/09-open-questions.md).
