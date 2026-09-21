# Sankalpa — iOS app

A single-user iPhone app for [docs/requirements/sankalpa.md](../docs/requirements/sankalpa.md),
implementing the model in [docs/architecture/ddd](../docs/architecture/ddd).

Declare an intent with a commitment ("twice a day for 180 days"), begin it, log the sessions you
perform, and see how each period turned out once it closes.

## Running it

Requires Xcode 27 and an iOS 27 simulator runtime.

```bash
open app/Sankalpa.xcodeproj
```

Pick the **Sankalpa** scheme and an iPhone 17 Pro simulator. From the command line:

```bash
xcodebuild -project app/Sankalpa.xcodeproj -scheme Sankalpa -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**A normal launch starts empty.** Demo content — five sankalpas, one per lifecycle state and one
per action type — is seeded only in a Debug build launched with `-demo`, and only into a store that
is genuinely new. It is never seeded by a release build, and clearing the data keeps it cleared.

```bash
./app/scripts/run.sh          # your own practice, starts empty
DEMO=1 ./app/scripts/run.sh   # with the demo content
```

## Layout

```text
app/
  SankalpaCore/          Swift package, two library targets
    Sources/SankalpaCore/
      Domain/            Sankalpa, Session, Commitment, LifecycleTimeline, PeriodOutcomeCalculator
      Application/       Ports, use cases, queries, read models
    Sources/SankalpaStorage/
      FileStore.swift    The JSON store, with its load/write failure behaviour
      AppTime.swift      The one place instants become dates
    Tests/               75 core tests + 9 storage tests
  Sankalpa/              The iOS app
    Adapters/            Demo data — the driven side
    UI/                  SwiftUI screens and the design system — the driving side
  SankalpaUITests/       A tour that drives every screen and captures it
  scripts/               screen-tour.sh, run.sh, make-app-icon.py
```

`SankalpaStorage` is a library target rather than app code specifically so its failure paths can be
tested. A store that cannot be read, and a write that fails, are the two ways this app could lose
someone's practice history; both now have tests.

An unreadable store is reported, left exactly as it is, and can be retried — that is what stops
data being lost. But refusing to write over a file that will not parse is only half an answer: with
every write refused, the app would otherwise have no way forward at all, and deleting it would be
the only way back to a usable one — destroying the very file the recovery screen promises is still
there. So the recovery screen also offers to **save a copy** of the file, and to **start fresh**,
which renames the damaged file rather than removing it.

**Saving a copy is the whole of export.** The practice is one JSON file and nothing else points at
it, so handing it to the share sheet needs no format to design, and what it gives out is exactly
what the app reads. It is on the Sankalpas tab and on the recovery screen. There is no import:
reading a file back in means deciding what happens when it disagrees with what is already there,
and that is a question the requirements have not answered.

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
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path app/SankalpaCore
./app/scripts/screen-tour.sh
```

`swift test` runs the domain and application suites on the macOS toolchain — no simulator needed.
They cover the requirement's own examples (Vipassana twice a day for six months, gym four times a
week with no duration) plus the boundary rules: January 31 monthly anchoring, February 29 yearly
anchoring, inclusive end dates, the transition table, backdated Begin, session eligibility, partial
versus full pauses, and the terminal-transition cutoff.

`screen-tour.sh` builds the app, walks every screen in the simulator, and writes numbered
screenshots to `app/build/screens` — in Light Mode, Dark Mode, and at an accessibility text
size. It is a behaviour suite as much as a review tool: every step asserts the
element it is about to use rather than skipping quietly when a screen fails to appear, and the
script's exit status is the tests' own. It finishes with a Release build, which is where an
optimiser difference or a `#if DEBUG` mistake would show up.

Beyond the tour, it drives the things that would lose or misreport someone's practice: an
unreadable store raises recovery instead of looking like a fresh install *and can be escaped from*
— a failed retry says so, and starting fresh gives back a usable app with the damaged file renamed
rather than removed — a logged session survives a relaunch, undo is offered once and consumed, a
forgotten session can still be recorded from Paused and from a finished sankalpa, and a duration
can be typed rather than stepped to.

## How much history is reported

Every read is day-range bounded (DD-17), so the screens name their ranges rather than implying
they show everything:

| Screen | Range |
|---|---|
| Periods, and the tally above it | The most recent 3,650 periods — one number for both, so the count can never describe rows the list does not contain. The footer says so only when something was actually cut off. |
| Sessions | The last 3,650 days |
| Recent sessions, on detail | The last 120 days. When there is older history the card says so and still links to the full list. |
| Journal | The last 3,650 days |

3,650 is also the longest duration a commitment can declare, so in practice nothing a user has
recorded falls outside it. The worst case the app can reach — ten years of daily practice, 3,650
sessions, every period rebuilt — takes about 7 ms in a Debug build, which is why the Periods
screen computes its list directly rather than caching it.

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
| Domain objects mapped to persistence rows | Domain types are `Codable`, stored in a versioned JSON envelope | For a local file store, hand-written DTO mapping would be ceremony. The envelope carries a schema version, and a file written by a newer version is refused rather than replaced. |
| No session delete use case | `SessionRepository.delete` plus `undoLoggedSession` | Logging is one tap on the largest control in the app. Taking back the tap you just made is a different thing from amending history, so the capability is deliberately narrow: only the id returned by `logSession`, only while the confirmation is still on screen. Editing an older session is still out of scope (Q3). |

Several launch arguments exist for the screen tour, all compiled out of release builds: `-demo`
seeds the demo content, `-forceDarkMode` forces the appearance because the simulator's own switch
does not reliably repaint this runtime, `-resetIntroduction` clears the first-run flag so the
introduction card can be captured and then dismissed normally, and `-resetStore` / `-corruptStore`
prepare the store a UI test is about to open. `SANKALPA_TEST_STORE` gives each UI test its own
store file, so a test can never read or write a real practice history.

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
- **Undo is limited to the session just logged**, while its confirmation is still on screen. A
  recorded fact is not otherwise editable (Q3). *Open: whether older sessions should be
  correctable.*
- **The time zone is captured once per launch**, so a day already recorded keeps its meaning if the
  device travels mid-session; a relaunch picks up the new zone. *Open: Q1 — no per-sankalpa zone is
  modelled, and repeated daylight-saving hours have no stated policy.*
- **A period is judged only once it closes**, so the current period is neither satisfied nor missed
  and is shown as open.

All of these are worth confirming before this is taken further; they belong with the questions in
[09-open-questions](../docs/architecture/ddd/09-open-questions.md).
