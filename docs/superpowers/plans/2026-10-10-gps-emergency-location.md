# GPS Emergency Location Implementation Plan

> **For agentic workers:** Execute inline in the current checkout. Keep edits local; do not commit or push.

**Goal:** Include a fresh phone location in fall-alert SMS when available, without delaying the existing 15-second SMS deadline; keep manual SOS immediate and use only a recent cached location there.

**Architecture:** Request coarse or precise location permission during visible setup. Start the existing watcher as a health+location foreground service only when permission is granted. On a confirmed fall, request a bounded current fix asynchronously; `GuardianRuntime` accepts it only while that incident is counting and adds a deterministic coordinate/Maps suffix at send time, after any optional model wording. If location is missing, SMS still sends on its existing schedule with a location-unavailable suffix.

**Tech Stack:** Kotlin `LocationManager` API 30+, Android runtime permissions and foreground service types, Flutter MethodChannel, JUnit, Flutter tests.

---

## Files and ownership

- `bantay_app/android/app/src/main/AndroidManifest.xml`: declare coarse/fine location permissions, location FGS permission, and `health|location` service types.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/EmergencyLocation.kt`: pure coordinate validation and message formatting.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/EmergencyLocationProvider.kt`: Android current-fix and recent-last-known lookup, bounded and cancellable.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/GuardianAlertText.kt`: append deterministic location suffix to final SMS body.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/GuardianRuntime.kt`: retain fix for the active incident, reject late callbacks, use recent cached location for manual SOS, append location only at send time.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/Guardian.kt`: provide location source to runtime.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/FallWatchService.kt`: promote with location FGS type when permission is granted; request a current fix after a confirmed fall.
- `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/MainActivity.kt`: request coarse/fine permission while visible and report grant result over alert MethodChannel.
- `bantay_app/lib/alerts/native_incident_gateway.dart`: expose location-permission request.
- `bantay_app/lib/ui/product_app.dart`: explain permission and that refusal does not block SMS; request permission during setup.
- `bantay_app/android/app/src/test/kotlin/ph/appbuilders/bantay_app/EmergencyLocationTest.kt`: test formatting, validity, and location fallbacks.
- `bantay_app/android/app/src/test/kotlin/ph/appbuilders/bantay_app/GuardianRuntimeTest.kt`: test fresh fix inclusion, late-fix rejection, and unchanged send deadline.
- `bantay_app/test/native_incident_gateway_test.dart`: test permission request bridge.
- `docs/path1-module.md` and `docs/SPEC.md`: document permission, location behavior, and no-delay fallback.

## Task 1: Define safe location value and SMS formatting

- [x] Write Kotlin tests first: valid coordinates format into latitude/longitude and accuracy; absent/invalid fix produces `Location unavailable`; accuracy and age boundaries reject unusable fixes.
- [x] Run the location formatter tests and confirm the new tests fail for the missing type/formatter.
- [x] Add pure `EmergencyLocation` value/formatter and `GuardianAlertText.withLocation(body, location)`; round coordinates to five decimal places. Maps URL was later removed during SMS failure diagnosis.
- [x] Re-run the targeted Kotlin tests and confirm they pass.

## Task 2: Keep location asynchronous and deadline-safe

- [x] Add `GuardianRuntimeTest` cases proving a fix received during countdown appears in the final SMS; a fix after the deadline is rejected; no fix still sends once at the original deadline; manual SOS sends immediately with a recent cached fix.
- [x] Run the runtime tests and confirm they fail before the location behavior is implemented.
- [x] Add an incident-scoped location setter that accepts only the current `counting` incident before its deadline. Capture the chosen fix when the SMS send begins; append the location suffix after any model-provided text so Path 2 cannot remove coordinates.
- [x] Inject a recent-last-known lookup for manual SOS. Accept only fixes no older than two minutes and no worse than 5 km accuracy; never wait for a fix on manual SOS.
- [x] Re-run the Kotlin tests and confirm the countdown and exactly-once SMS tests pass.

## Task 3: Add bounded Android location lookup and service permissions

- [x] Add `EmergencyLocationProvider` using `LocationManager.getCurrentLocation` on GPS and network providers, whichever yields the first usable fix. Cancel outstanding requests after 10 seconds; validate that a returned fix is at most 30 seconds old and within the accepted accuracy bound.
- [x] Add coarse/fine location and `FOREGROUND_SERVICE_LOCATION` manifest permissions; declare the existing watcher service `health|location`.
- [x] In `FallWatchService`, pass `FOREGROUND_SERVICE_TYPE_HEALTH` plus `FOREGROUND_SERVICE_TYPE_LOCATION` to `startForeground` only when coarse or fine location is granted; otherwise keep health-only sampling.
- [x] Request a fix asynchronously for each confirmed counting incident; a null/error/late result does not change the timer.
- [x] In `Guardian`, inject `EmergencyLocationProvider` and expose its recent-last-known lookup to manual SOS. Catch permission/provider errors and return no location.
- [x] Run the full Kotlin unit suite and check that no tests depend on Android service state.

## Task 4: Request permission in setup without blocking SMS

- [x] Add Flutter MethodChannel coverage proving `requestLocationPermission` invokes the native method and returns its boolean result.
- [x] Add a separate native location-permission request/result path in `MainActivity`, requesting coarse and fine together. Treat either grant as permission; do not request background location.
- [x] Add the Dart gateway method and request permission in `_beginCalibration` after required SMS permission. If location is declined, continue calibration so SMS remains usable without coordinates.
- [x] Add setup copy explaining automatic alert-time location and SMS fallback.
- [x] Run full Flutter tests and analyzer.

## Task 5: Document and verify on the phone

- [x] Update the Path 1 module guide and spec with the user-visible permission, automatic fall-time fix, manual-SOS cached-fix behavior, and fail-open SMS contract.
- [x] Build arm64 debug APK with the workstation SDK and Java 21.
- [ ] Install locally on SM-A127F. Grant location permission, confirm Guardian Active and the ongoing service, then use the user's padded-drop test to verify the SMS contains coordinates and accuracy after the normal countdown, with no Maps URL.
- [ ] With user approval for a real outgoing test SMS, verify location permission, Guardian Active, padded-drop alert content, denied-permission fallback, screen-off operation, and the unchanged 15-second deadline.
- [x] Inspect `git status --short --branch`; leave every change uncommitted and do not push.

## Platform references

- Android requires the location FGS type and `FOREGROUND_SERVICE_LOCATION`; a location FGS relying on while-in-use permission must be started while the activity is visible. See [foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types?hl=en) and [background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start?authuser=111).
- Repository contract: `docs/SPEC.md` calls for coordinates only, no reverse geocoding; `docs/path1-module.md` keeps SMS independent of the optional model.
