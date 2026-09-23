# Testing

```bash
./app/scripts/test.sh
```

That is the whole thing. It runs every suite, leaves a report in
`app/build/test-runs/<timestamp>/`, and points `app/build/test-runs/latest` at it. The exit
status is the worst result, so it can gate anything that cares.

It also starts and stops the backend services the UI suites need, so nothing has to be running
first. It needs Maven and a working `backend/` checkout for that.

```bash
./app/scripts/test.sh --core     # domain, application and adapters only — seconds, no simulator
./app/scripts/test.sh --ui       # the simulator suites only
./app/scripts/test.sh --quick    # everything except the Release build
./app/scripts/test.sh --only testPauseAndResume
./app/scripts/uitest.sh          # just the UI suites, without the report
```

## What runs

| Suite | What it covers | Where it runs |
|---|---|---|
| Core | The domain rules, application service, service adapter, and deterministic voice layer — including reducer transitions, title resolution, transcript accumulation, draft durability, and accepted-versus-pending results. Network behavior uses a stub transport; voice tests inject interpreted turns | macOS toolchain, no simulator |
| UI | The journeys a person takes, the screens they see, and the states that are hard to reach by hand | iPhone simulator |
| Release | That the app still compiles with every debug-only test hook removed | Unsigned, generic iOS device |

The UI suites are in two files because they answer two different questions.
`SankalpaUITests/JourneyTests.swift` asks whether the app *does* what its screens offer —
declaring, beginning, logging, pausing, resuming, completing, stopping, filtering — each one
built from an empty practice through the interface, which is the state a real first run is in.
`SankalpaUITests/ScreenTour.swift` asks what every screen *looks like*, in Light Mode, Dark Mode
and at an accessibility text size, and captures it.

The UI journey also verifies that the app-level voice entry point opens from an empty practice and
offers an explicit listening control. It deliberately does not automate real audio or Foundation
Models output: the simulator has no usable on-device language model, and prompt quality is not a
stable UI assertion. Run the physical-device checklist in
[`docs/design/voice/README.md`](../docs/design/voice/README.md#ui-and-device-checks) for microphone,
asset installation, locale, prompt-fixture and interruption coverage.

Both inherit `SankalpaUITests/UITestCase.swift`, which is where the launching, scrolling and
capturing live. Three rules there are worth knowing before adding a test:

- **Each test class gets its own service.** Isolation used to be a store file per test; the
  practice now lives in the backend, so it is a backend per class instead — its own port, its own
  SQLite database, thrown away afterwards (`scripts/service.sh`). `ScreenTour` gets the demo
  fixture seeded into it by `scripts/seed-demo.py`; `JourneyTests` gets an empty one, which is
  what its empty-state assertions need. Tests within a class still share, so two tests in the
  same class must not expect the practice to be empty.
- **There is no default service.** `UITestCase.serviceURL()` fails the test when
  `SANKALPA_API_BASE_URL` is missing rather than falling back to `localhost:8080`. A fallback
  would point the suite at whatever is running on the machine — possibly a real practice, which
  these tests would declare into and which the API has no delete to undo — and the run would
  report ordinary test failures instead of saying it was misconfigured.
- **Every launch starts from an empty phone.** The cache and the outbox are built to survive, so
  without `-resetCache` a run would inherit the last one's practice — the same trap the old store
  file had. Pass `keepCache: true` when the point of the test is that something survived, and
  `relaunchOffline()` when it is that the practice is still readable with the service away.
- **A helper that cannot do what it was asked fails the test.** `tap` and `expect` take a
  sentence saying what the absence would mean. A tap that silently misses is the one thing that
  turns a UI suite into decoration.

Driving the offline screens needs one test hook the app carries: `-offline` makes every request
fail. Nothing inside the simulator can stop the service the test is running against, and the
alternative — trusting that the banner and the cached render work because the unit tests pass — is
exactly the gap a UI suite exists to close. It is compiled out of release builds like every other
hook here.

`UITestCase.timeout` is 30 seconds rather than 10 because first paint is now a round trip: a list
request plus a lifecycle and a session read per sankalpa. `reveal` waits for an element to exist
before it starts scrolling, so a screen whose content arrives a moment after the screen does is
not swiped straight past.

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

Alongside them, `app/build/screens` always points at the newest run's gallery. Design review
means opening the same path twice and seeing what moved, which a timestamped directory cannot
offer. Only a run that actually captured screens moves the link, so `--core` leaves the last
gallery where it was.

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
