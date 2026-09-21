# Sankalpa 2 — review and verification

Reviewed on September 21, 2026. The original app was retained. App2 is a separate app with its own bundle identifier and data store.

## What changed

The new interface uses warm paper, forest green, serif headings, generous spacing, and a consistent card system. Today prioritizes current practice and quick recording. Collection makes paused and finished intentions searchable. Journal and practice history make the time range explicit and let the user reach older records. Resume and historical recording remain easy to reach in the relevant states.

The existing domain model was worth retaining. App2 hardens its lifecycle rules and replaces the persistence adapter and interface. A successful action now means the data was saved; unreadable files have a recovery path instead of being replaced with examples.

## Build → review → fix → test cycles

| Cycle | Review findings and fixes | Verification |
| --- | --- | --- |
| 1 | Rebuilt the screens and transactional storage. Reviewed light/dark screenshots and large text. Fixed narrow Collection titles at accessibility sizes, shortened the past-session navigation title, and corrected the session-count accessibility container. | Core and storage tests passed. Three of five initial UI tests passed; the two failures exposed the count-selector issue. |
| 2 | Added validated backup restore and explicit corrupt-file recovery. Corrected date-picker bounds for the oldest month. Stabilized screenshot capture after transitions. | Four of six UI tests passed. Two failures were duplicate accessibility matches in native confirmation dialogs; selectors were corrected. |
| 3 | Shortened the Today introduction, improved form labels, and stacked Collection content at accessibility sizes. Reviewed the resulting screenshots. | All six iPhone UI tests passed, including first use, Undo, relaunch, historical logging, clearing data, future-start stopping, and large text. |
| 4 | Moved Resume to the main action card and added a persistent historical-recording toolbar action. Added landscape and corrupt-store UI tests, explicit iPad orientations, and device-independent tab selectors. | Both iPad tests and the release build passed. Four of eight iPhone tests passed; the added orientation test exposed test-state leakage after failure, a cropped capture, and an offscreen status assertion. |
| 5 | Capture the full display, reset portrait before each test, use the persistent recording action in landscape, and reveal the final status before asserting it. | All eight iPhone UI tests passed. The final large-text, light/dark, landscape, and recovery captures were inspected. |

The first iPad attempt found a test assumption: iPad presents native tabs as top buttons rather than the iPhone tab-bar hierarchy. The tests now select the same accessible tab labels on both devices.

## Automated coverage

- **66 domain/application tests:** calendar arithmetic, anchored periods, duration, lifecycle, session eligibility, tallies, command behavior, and review regressions.
- **12 storage/model tests:** atomic-write failure, no false success, persistence round-trip, duplicate identities, malformed dates/files, backup validation, original-file preservation during recovery, failed recovery, timestamp precision, historical eligibility, and access across 600 days of history.
- **iPhone UI journeys:** declare → begin earlier today → record → undo → record → relaunch; historical logging while paused and after stopping; old-history access and clear/relaunch; stop before a future start; light/dark screens; largest Dynamic Type; landscape; unreadable-file recovery.
- **iPad UI journeys:** light/dark navigation and landscape detail/session forms.
- **Release configuration:** build for a generic physical iOS device without signing.

## Final results

| Check | Result |
| --- | --- |
| Domain and application | 66 tests passed |
| Storage and observable model | 12 tests passed |
| iPhone UI suite, final run | 8 tests passed, 0 failures |
| iPad UI suite | 2 tests passed, 0 failures |
| iPad full-display landscape recapture | 1 repeated test passed |
| Unsigned physical-device Release build | Build succeeded |
| Run and verification scripts | Shell syntax checks passed |

Final result bundles: `/tmp/sankalpa2-cycle5.xcresult` and `/tmp/sankalpa2-ipad2.xcresult`; the corrected iPad landscape captures are from `/tmp/sankalpa2-ipad-landscape.xcresult`. Final core and release logs are `/tmp/sankalpa2-core.log` and `/tmp/sankalpa2-release-final.log`. Selected screenshots are retained in `Preview/`. Temporary result bundles are local verification evidence; rerun the verification script to regenerate them.

## Scope and remaining validation

Tests ran with Xcode 27 and the iOS 27 simulator runtime on iPhone 17 Pro and iPad mini (A17 Pro). The deployment target is iOS 18; an iOS 18 runtime and physical-device run were not available in this session. Release compilation is not App Store submission or signed-device validation.

The simulator runtime is available, but its desktop GUI application is absent from this Xcode installation. The Debug demo was installed and launched on the dedicated `Sankalpa2-Quality` simulator with the isolated preview store. The launch script handles a missing GUI and still installs/runs the app.

Large Dynamic Type was exercised and screenshots were inspected. Full manual VoiceOver, Switch Control, localization, and device-specific accessibility audits remain before a public release. Backup validation/replacement/recovery is covered at the storage layer; the system Files picker export/import interaction was not automated end to end.

The application is local-only. It does not migrate original-app data or synchronize across devices. Timezone travel and repeated daylight-saving hours need an explicit product policy. The supported lifecycle and historical-editing choices are documented in the README.

## Reproduce

Open `Sankalpa.xcodeproj` and run the Sankalpa scheme, or use `scripts/run.sh`. Run `scripts/verify.sh` to repeat core tests, the iPhone UI suite, screenshot export, and the unsigned release build on an isolated simulator. The script returns a failure if a required check fails.
