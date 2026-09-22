# Testing

```bash
./app/scripts/test.sh
```

That is the whole thing. It runs every suite, leaves a report in
`app/build/test-runs/<timestamp>/`, and points `app/build/test-runs/latest` at it. The exit
status is the worst result, so it can gate anything that cares.

```bash
./app/scripts/test.sh --core     # domain, application and storage only — seconds, no simulator
./app/scripts/test.sh --ui       # the simulator suites only
./app/scripts/test.sh --quick    # everything except the Release build
./app/scripts/test.sh --only testPauseAndResume
```

## What runs

| Suite | What it covers | Where it runs |
|---|---|---|
| Core | The domain rules, the application service, and the file store — including the failure paths that could lose someone's practice | macOS toolchain, no simulator |
| UI | The journeys a person takes, the screens they see, and the states that are hard to reach by hand | iPhone simulator |
| Release | That the app still compiles with every debug-only test hook removed | Unsigned, generic iOS device |

The UI suites are in two files because they answer two different questions.
`SankalpaUITests/JourneyTests.swift` asks whether the app *does* what its screens offer —
declaring, beginning, logging, pausing, resuming, completing, stopping, filtering, clearing —
each one built from an empty store through the interface, which is the state a real first run is
in. `SankalpaUITests/ScreenTour.swift` asks what every screen *looks like*, in Light Mode, Dark
Mode and at an accessibility text size, and captures it.

Both inherit `SankalpaUITests/UITestCase.swift`, which is where the launching, scrolling and
capturing live. Two rules there are worth knowing before adding a test:

- **Every test gets its own store file.** `SANKALPA_TEST_STORE` is a fresh UUID per launch, so a
  test can never read another test's data, never depend on the order they run in, and never
  touch a real practice history that happens to be on the simulator.
- **A helper that cannot do what it was asked fails the test.** `tap` and `expect` take a
  sentence saying what the absence would mean. A tap that silently misses is the one thing that
  turns a UI suite into decoration.

## Reading the report

Each run directory holds:

```text
report.md         the run as prose — failures first, then everything that ran
results.json      the same thing structured, for anything that would rather parse than read
summary.txt       one line per suite
screens/          every screenshot the UI tests captured, under stable names
logs/             raw console output from each step
raw/              the result bundle, the swift-testing event stream, build output
```

`report.md` is written to be read by a language model as much as by a person: every failure
carries its suite, the test's own sentence-long name, the source location, the message, and the
screens that test had captured before it failed — so a failure can be understood without opening
a raw log.

Two things it deliberately does *not* do. A suite that produced no tests is reported as **did not
run**, with its compiler errors, rather than as zero failures — "0 failed" about a suite that
never built is the most misleading line a test report can contain. And a run that was stopped
part-way says so at the top, because tests that never reported are unknown, not passing.

## When a run does not come back

`xcodebuild` can hang after its tests have already finished. Every step therefore runs under a
time limit (`UI_TIMEOUT`, `CORE_TIMEOUT`, `RELEASE_TIMEOUT` — seconds), and a step that exceeds
it is killed and reported as a failure. Because a killed `xcodebuild` never finishes writing its
result bundle, the report falls back to the console log, and says that it did.

## The simulator

The UI suites use a simulator of their own, created on first run and reused after that:

```bash
DEVICE_NAME="iPhone 17 Pro" ./app/scripts/test.sh   # use an existing one instead
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16 ./app/scripts/test.sh
```

Nothing in a run installs to, uninstalls from, or clears a simulator the user set up themselves.

## What the suite found, and left standing

Two things came out of writing these journeys and are worth knowing before reading a failure.

**A session logged after the Journal tab has been opened once did not appear in it.** The Journal
asks the application layer a question rather than reading a stored property, so nothing told
SwiftUI the answer had changed — and a tab stays alive after the first visit. `AppModel.revision`
now changes on every refresh and the Journal reads it. `testTheJournalShowsASessionJustLogged`
is the test that catches a regression: it visits the Journal *before* logging, which is the only
order in which the bug appears.

**The Stop and Complete confirmations draw no Cancel button on this runtime.** The app declares
`Button("Cancel", role: .cancel)`, but iOS renders these as a compact centred dialog containing
only the destructive action, so the only way to back out is a tap outside it. The tests drive
that tap, because it is what a user has to do. Whether a confirmation with no visible way out is
acceptable is a design question, not a test one, so nothing here asserts either way.

## Adding a test

Put behaviour in `JourneyTests.swift` and appearance in `ScreenTour.swift`. Name the test for
the thing that would be wrong if it failed, and give every assertion a reason in the same
voice — the report prints those sentences, and they are what makes a failure legible to someone
who was not there when it was written.

For a rule that does not need a screen, prefer the core suites: they run in under a second and
say exactly which rule broke. `SankalpaCore/Tests/` is organised by what is being decided —
calendar arithmetic, commitments, lifecycle, period outcomes, session logging, declaration
bounds, the query surface, and the regressions that came out of review.
