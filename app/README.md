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

On a first launch the app shows a short introduction and seeds five sample sankalpas — one per
lifecycle state and one per action type — so every screen has something in it. **Clear all data**
at the foot of the Sankalpas list removes them.

## Layout

```text
app/
  SankalpaCore/          Swift package: domain + application. Foundation only, no UI.
    Sources/SankalpaCore/
      Domain/            Sankalpa, Session, Commitment, LifecycleTimeline, PeriodOutcomeCalculator
      Application/       Ports, use cases, queries, read models
    Tests/               60 tests over the commitment arithmetic and lifecycle rules
  Sankalpa/              The iOS app
    Adapters/            Clock, JSON store, sample data — the driven side
    UI/                  SwiftUI screens and the design system — the driving side
  SankalpaUITests/       A tour that drives every screen and captures it
  scripts/               screen-tour.sh, make-app-icon.py
```

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
screenshots to `app/build/screens` — in Light Mode, Dark Mode, and at an accessibility text size.
It is a smoke test as much as a review tool: each step asserts the element it is about to use.

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
| Domain objects mapped to persistence rows | Domain types are `Codable`, stored in a versioned JSON envelope | For a local file store, hand-written DTO mapping would be ceremony. The envelope carries a schema version so the shape can change later. |
| HTTP controllers | SwiftUI views and `AppModel` | The driving adapter for this app is the UI. |
| `SessionRepository.findForSankalpa` | Plus `sessions(from:until:)` across all sankalpas | The Journal reads performed sessions across sankalpas. Still day-range bounded, per DD-17. |
| No session delete use case | `SessionRepository.delete` plus `undoLoggedSession` | Logging is one tap on the largest control in the app. Taking back the tap you just made is a different thing from amending history, so the capability is deliberately narrow: only the id returned by `logSession`, only while the confirmation is still on screen. Editing an older session is still out of scope (Q3). |

Two debug-only launch arguments exist, compiled out of release builds, both for the screen tour:
`-forceDarkMode`, because the simulator's own appearance switch does not reliably repaint this
runtime, and `-resetIntroduction`, which clears the first-run flag so the introduction card can be
captured and then dismissed normally.

## Interpretations

Two things the requirements do not settle, decided here so the behaviour is at least explicit:

- **Periods that closed before the sankalpa was begun are evaluated as missed.** "When a period ends,
  each session not logged as performed counts as missed" has no carve-out for them, and a backdated
  Begin is exactly the tool for covering them. The alternative — exempting them — would let a
  sankalpa started late look better than one started on time.
- **A future start date is allowed.** The requirements bound only how far in the past a start date
  may be. A sankalpa declared with a start date still to come simply waits in Not started, and
  Begin is refused until that date.

Both are worth confirming before this is taken further; they belong with the questions in
[09-open-questions](../docs/architecture/ddd/09-open-questions.md).
