# Sankalpa 2

A separate native SwiftUI app built against the Sankalpa requirements, with a new interface and a hardened version of the existing domain model. It lives entirely in `app2`; it neither reads nor changes the original app's data.

## Open and run

Open `app2/Sankalpa.xcodeproj`, select the **Sankalpa** scheme, and choose an iPhone simulator. This environment has Xcode 27 and an iOS 27 runtime. The app's deployment target is iOS 18. On a physical device, select your own signing team in Xcode.

This environment includes the simulator runtime but no Simulator desktop application. Automated UI runs work; use the saved screenshots here, or a full Xcode installation for an interactive simulator window.

Alternatively, from the project root:

```sh
./app2/scripts/run.sh
```

For an immediate visual tour with example intentions, run `./app2/scripts/run.sh --demo`. This uses a separate preview store; a normal launch uses your own collection. Captured screens are in [Preview](Preview/), and the build/review/test record is in [QUALITY.md](QUALITY.md).

The installed display name is **Sankalpa 2**, with bundle identifier `com.sankalpa.practice`, so it can coexist with the first app.

## The experience

- **Today:** a focused practice board, explicit date spans, quick session recording, and an eight-second undo opportunity.
- **Collection:** searchable intentions, including paused, planned, and finished practices.
- **Detail:** a clear commitment, current progress, historical logging in every eligible state, and user-controlled lifecycle actions.
- **History:** period pages of 30 windows with matching tallies, a month selector for sessions, and an audit trail with effective and recorded times. Older records remain reachable.
- **Journal:** search within any month across every intention.
- **Your data:** export and validated restore of complete JSON backups; explicit confirmation before replacing or clearing the collection.

Production starts empty. Examples are available only in a Debug build with `-demo`; the test suite uses isolated store names and creates its own fixtures. Demo data is never seeded by a normal launch or a release build.

## Data safety

A command reports success only after its atomic file write succeeds. Failed writes leave the previous in-memory and disk state intact. Unreadable, invalid, or unsupported-version files produce a recovery screen; they are never automatically replaced or seeded. The recovery screen can retry, export the original bytes, or restore a validated backup after explicit confirmation. Recovery preserves a separate copy of the damaged original before replacing it. Duplicate identities and malformed domain values are rejected on load and restore.

Backups use the app2 schema and are validated before a restore confirmation is offered. Restore replaces the entire collection; export a copy first if needed. This app does not provide cloud synchronization or an automatic migration from the original app.

## Structure

```text
Sankalpa/                      SwiftUI app and screens
SankalpaCore/Sources/
  SankalpaCore/                Domain, application ports, commands, queries
  SankalpaStorage/             Transactional file store, clock adapter, observable model
SankalpaCore/Tests/            Domain, service, storage, model, and backup regressions
SankalpaUITests/               Real UI journeys and visual/accessibility captures
scripts/verify.sh             Isolated core/UI/release verification; fails on failed tests
QUALITY.md                    Review cycles, results, and remaining limitations
```

The existing core was reused because its calendar and period rules were sound. Changes enforce persistence errors, distinguish Begin from Resume, and permit terminal transitions before a planned start. The SwiftUI interface and persistence/model adapters were rebuilt.

## Verify

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path app2/SankalpaCore
./app2/scripts/verify.sh
```

The verification script creates and removes its own simulator. It never uninstalls an app from your existing simulator. Results and screenshots are kept under `app2/build/verification-*`.

## Deliberate interpretations

- A session's performed time determines eligibility. Paused and finished practices accept backfilled sessions from their earlier In progress intervals.
- Same-day backdated Begin is allowed. Pause, Resume, Complete, and Stop take effect immediately.
- The inclusive last day and period boundaries remain anchored to the original start date. Partial pauses keep the full requirement; fully paused periods are exempt.
- Closed periods before an initial Begin count as missed, matching the first implementation's documented interpretation. This remains a product decision to confirm.
- Future start dates are allowed; Begin waits for that date, but the intention can be stopped beforehand.
- Times use the device timezone captured at app launch, preserving stored calendar dates. There is no per-intention timezone. Travel and repeated daylight-saving hours need a product policy before more sophisticated time modeling.
- There is no general editing/deletion of historical sessions or intentions because the requirements leave those operations unresolved. Immediate Undo is limited to the most recent successful log while its notice remains active.
- Title length (80), sessions per period (99), and duration periods (3,650) retain the first app's practical limits. A duration in days is shown as days, never assumed to be a precise number of calendar months.
