# Module: Path 1 — sensor foundation (`bantay_app`)

First slice of the safety-critical path. Path 1 owns impact detection, the
countdown, and SMS; Path 2 (`bantay_llm`) only rewrites alert text. The judge
answer and the build gates live in `SPEC.md`; this module is where Path 1
code accrues, one slice at a time.

This slice: **the watcher's eyes.** An accelerometer stream, sampled on a
service thread and delivered to Dart at 20 Hz, observable in a fenced debug
panel. No detection logic yet — that is slice 2.

## Files

| File | Role |
|---|---|
| `android/app/src/main/kotlin/ph/appbuilders/bantay_app/FallWatchService.kt` | FGS `health`, wake lock, HandlerThread, listener, 20 Hz emitter |
| `.../AccelRingBuffer.kt` | 4 s circular buffer, seq-numbered drain, drop accounting (pure Kotlin) |
| `.../SensorChannel.kt` | MethodChannel bridge: start/stop/attach/detach in, batch/state out |
| `.../MainActivity.kt` | Registers the channel, starts the service from the visible activity |
| `android/app/src/main/res/values/strings.xml` | FGS notification strings |
| `lib/sensor_payload.dart` | Wire-format decode, status parse, RateTracker (pure Dart, no Flutter) |
| `lib/sensor_debug.dart` | Fenced debug panel: live strip, measured rates, drop accounting |
| `test/sensor_payload_test.dart` | Decode, malformed-shape rejection, rate math |
| `test/sensor_debug_test.dart` | Panel wiring through the real Kotlin→Dart codec envelope |

## Wire format

Single endpoint `ph.appbuilders.bantay_app/sensors`. The names are mirrored as
constants in `sensor_payload.dart` and `SensorChannel.kt`; `sensor_payload_test.dart`
asserts the Dart half.

```
Dart → Kotlin : start, stop, attach, detach
Kotlin → Dart : batch = { samples: Float64List [t_ms,x,y,z]*n,
                          count: n, dropped: k, seq: s }
                state  = { running: bool, error: String?,
                           sensorName: String?, requestedHz: int? }
```

Timestamps go over the wire as a `double[]` (Float64List), not a `float[]`:
`event.timestamp` is elapsedRealtime nanos, and float32 would smear the 20 ms
period once device uptime passes ~18 hours — the detector needs real spacing,
and the payload is 2 KB per batch anyway.

Accelerometer components go over the wire as **m/s²** (raw
`SensorEvent.values`) and are converted to **g** exactly once, at the Dart
decode boundary (`ms2PerG = 9.80665` in `sensor_payload.dart`). Found on
device: without the conversion a resting phone reads "9.8" and every
threshold downstream of the cascade (SPEC §6: peak > 3.5 g) misfires.

## Conventions established

### The FGS type is declared twice, on purpose

`android:foregroundServiceType="health"` in the manifest **and**
`ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH` passed to `startForeground`.
Android 14+ throws on a mismatch. The permission set (`FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_HEALTH`, `HIGH_SAMPLING_RATE_SENSORS`, `POST_NOTIFICATIONS`,
`WAKE_LOCK`) is the sensor-side slice; `SEND_SMS` and `ACCESS_COARSE_LOCATION`
arrive with the SMS slice.

### SEQ bookkeeping: deliver before advancing

`emitBatch` advances `consumerSeq` only after `SensorChannel.postBatch`
reports the channel exists. If the activity rotates, batches stay in the ring
for the 4-second overwrite window and the next tick retries them. The panel
then shows `dropped: 0` after rotation instead of silent gaps.

### Drop accounting, not dropped data

`AccelRingBuffer` numbers samples by total appends. A detach/attach cycle or
a stalled receiver reports how many samples were overwritten (`dropped`) and
hands the consumer the newest `capacity` samples. Never pretend the stream was
continuous when it wasn't — the eval screen (screen 6) depends on this honesty.

### Register the listener on the service thread

`registerListener(..., handler)` pins `onSensorChanged` and the emitter to one
`HandlerThread`; the UI thread sees nothing. Batching at 20 Hz replaces 50-100
platform traversals per second (architecture.md §3).

### Measure the rate; don't trust the request

Requested is 50 Hz (`SAMPLE_PERIOD_US = 1_000_000/50`); the measured rate in
the panel comes from event timestamps (`RateTracker`), never from what was
requested. SPEC §6 already notes Android will not honour a 100 Hz request.

### Wake lock is scoped to sampling

Acquired in `startSampling`, released in `stopSampling`/destroy. Demo runs
screen-on foregrounded; screen-off operation is a stretch, and the checklist
below measures what actually happens.

### POST_NOTIFICATIONS never blocks sampling

Requested best-effort when Dart calls `start`; without it the service runs with
an invisible notification rather than refusing to start.

### Debug UI is fenced

`SensorDebugPanel` carries the same "Test only; never use for an emergency
alert." banner as the Path 2 diagnostics. Path 1's real screens (Setup,
Guardian Active, Incident) land in later slices.

### Kotlin/Dart seams are pure on purpose

`AccelRingBuffer` has no Android imports and `sensor_payload.dart` no Flutter
imports, so the buffer logic and the decode contract are unit-testable on a
laptop. The parts that are *not* testable here are the parts the checklist
below pins to the phone.

## Build and run

```sh
cd bantay_app
export ANDROID_HOME=<writable sdk>
$ANDROID_HOME/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
# open the app, Sensors tab, "Start sampling"
```

Build with `flutter build apk --target-platform android-arm64` — the LiteRT-LM
runtime is arm64-only, and a fat APK installs and then fails at model load.

## Device verification (record numbers here after running)

NOTE: this slice was authored on a machine with no Android SDK — the Kotlin
side has **not** been compiled by anything yet. These steps are the first
compile plus the first measurement; fill them in on the dev machine before
slice 2 starts.

**Recorded 2026-10-10 on SM-A127F (Android 13, LIS2DLC12 accelerometer).**

- [x] `flutter pub get`, `flutter test`, `flutter analyze` all clean
      — 67/67 tests, no analyzer issues. Two stale test expectations fixed
      on the way (combined-format peak row; lazy-ListView banner visibility)
      plus a new stop-reset test.
- [x] Debug build installs; app opens on **Sensors** tab without a crash
      — opens on the Path 2 tab by design; navigating to Sensors is clean.
- [x] POST_NOTIFICATIONS dialog appears once; notification shows while sampling
      — dialog appeared once (granted); `fall_watch_channel` notification
      confirmed via `dumpsys notification` while running, gone after stop.
- [x] `Measured sample rate` ≈ 50.0 Hz (record the actual number)
      — 47.3, 41.8, 48.3, and **49.8 Hz** across runs on battery+USB; the
      sensor delivers slightly under the 50 Hz request. Measured from
      timestamps, not from `requestedHz` (that field reads 50 by construction).
- [x] `Batch cadence` ≈ 20.0 Hz — 19.3, 19.7, 19.8, 19.9 Hz across runs.
- [x] Rotate the app away and back: `Dropped (ring overwrote)` does not spike
      — Flutter absorbs the config change without recreating the activity
      (same State id before/after rotation), so the panel never detaches.
- [x] Screen off 60 s, resume: samples continued arriving — 65 s screen-off:
      sampling continued, seq advanced at the measured ~50 Hz, `Dropped` 0.
      (Partial wake lock held; battery-kill still untested.)
- [x] "Stop sampling" → notification gone; "Start" works again — stop shows
      `service destroyed`, rates freeze, notification dismisses; restart
      re-streams end to end.
- [x] Drop the phone on carpet: `Peak magnitude` clearly exceeds 3.5 g
      — two carpet drops registered **11.09 g** (3.2× threshold). A desk
      handling event during the screen-off test read 4.65 g. At rest the
      peak reads ~1.0 g (post-units-fix).
- [x] Cold start with service running (reboot-less): attach re-drains
      history and reports dropped count honestly — task swiped away while
      the service kept running, relaunched: fresh panel attached, re-drained,
      and reported `Dropped 147661` (everything overwritten since the last
      attach, per the documented convention).

## Known state

- Detection: none. The stream is consumed by the debug panel only. The
  2026-10-10 device session proved the signal path (sensor → FGS → batching
  → Dart decode) and measured the drop signature at 11.09 g against the 3.5 g
  cascade threshold; the detector itself is still slice 2.
- Gyroscope: not registered; accelerometer-only, the documented degradation.
- The contended device-machine paths in the repo docs (`/home/adrian/...`) are
  stale on some checkouts; resolve tool paths locally.
- The debug panel streams at full rate even while the **Path 2** tab is
  visible — `IndexedStack` keeps both children attached by design.
- Units: the wire carries m/s², the panel and everything downstream see g
  (`ms2PerG` in `sensor_payload.dart`, one conversion, tested).
- Panel truth: `uiautomator dump` lags the live Flutter semantics on this
  panel (it kept reporting a stale "Watcher stopped" while batches flowed).
  Verified device numbers come from `screencap`, not from XML dumps.

## Next steps (slice 2 candidates, not committed)

1. `ThresholdDetector` + the `IDLE→ARMED→PRECURSOR→IMPACT` state machine
   (architecture.md §4) consuming this stream from a background isolate.
2. Pull-backfill for pre-impact history: the ring exists, the detector needs
   to read it at trigger time.
3. `FeatureExtractor` (gravity LPF, 24 features) + its unit fixtures.
4. A JVM unit test for `AccelRingBuffer` (junit dependency) if the team wants
   the buffer logic covered natively rather than through the panel.

## Session record — 2026-10-09 (slice 1 completion)

Authored on a machine with Dart 3.13.5 and pub network, but **no Android SDK
and no Flutter SDK**. What actually ran, and what did not:

**Ran and green**
- `dart test` over the payload contract (via a standalone copy, `flutter_test`
  unavailable): 13/13 pass — decode, per-sample seq recomputation, short-count
  handling, rejection of malformed shapes (NaN, infinity, short payload, wrong
  types), status parse, RateTracker window/stall/backwards-clock/reset.
- `dart format --set-exit-if-changed`: clean on all five new Dart files.

**Not run on this box — compile and device checks belong to the dev machine**
- Kotlin: never compiled (no Android SDK). AccelRingBuffer, FallWatchService,
  SensorChannel, MainActivity, and the manifest are written for `minSdk 30` and
  the AGP version already in `bantay_app`.
- `flutter test` / `flutter analyze` / APK build: not run. The two new test
  files are written against `flutter_test` and run on the phone-capable box.
- Device checklist (`## Device verification` above): untouched, still pending.

**Bugs caught while implementing (all fixed, logged for the pattern)**
- `parseAccelBatch` indexed `samples` inside a `List.generate` closure after a
  promotion that closures cannot see — compile error. Fixed by binding a
  concrete `Float64List` local before the closure.
- `Float64List` used without `import 'dart:typed_data'`; it only resolved in the
  Flutter test context through re-exports. Explicit import added everywhere.
- `static const MethodChannel` — the constructor is not const. Fixed to `final`
  in the panel and the widget test.
- `emitBatch` advanced `consumerSeq` before confirming delivery; with the
  activity gone, samples were silently skipped. Fixed: `postBatch` returns a
  Boolean and the sequence advances only on delivery, so the next tick retries
  from the ring.
- Foreground-service start path: the type constant is passed to
  `startForeground` and declared in the manifest; stop path goes through
  `ACTION_STOP` + `stopSelf` so teardown stays in `onDestroy`.

**Explicitly deferred, planned for later slices**
- `SensorChannel.METHOD_*` route table stays open for `state` pushes on
  wake-lock loss and sensor-accuracy changes; both are Kotlin-side calls that
  reuse the existing contract.
- The stale `_modelFileName` default in `lib/main.dart` still points at the
  broken `qwen3_0_6b_mixed_int4.litertlm` (already noted in
  [phone-harness.md](phone-harness.md) Known issues). Left untouched here
  because it is a Path 2 concern and outside this slice's diff.

## Session record — 2026-10-10 (first device verification, SM-A127F)

First time the Kotlin side was ever compiled, installed, and run. The
session goal was to test whether detection works on a real phone; what it
actually established is that the **signal path** works and the detector
itself is still slice 2. Toolchain had to be built from scratch on the dev
box (no Flutter SDK, no Android SDK beyond bare adb, no JDK with a compiler):
Flutter 3.47.7, Android platform 36 + build-tools + NDK 28.2.13676358,
Gradle 9.3.1 wrapper generated, Temurin JDK 21 (system JDK 27 is too new
for AGP 9.1's jlink transform; `java-17-openjdk` here is a JRE).

**Three device-only bugs found and fixed** (all invisible to the laptop
tests — the Kotlin had never run anywhere):

1. **Crash-loop: MethodChannel invoked off the main thread.**
   `SensorChannel.postBatch` ran `invokeMethod` from the `fall-watch-sensor`
   HandlerThread; `FlutterJNI` threw "Methods marked with @UiThread must be
   executed on the main thread" and the app crash-looped ("bantay_app keeps
   stopping" system dialog). Fixed: `postBatch`/`postState` queue on
   `Handler(Looper.getMainLooper())`; `postBatch` reports delivery through
   a callback that runs on the main thread, preserving "advance the
   consumer sequence only on delivery". A follow-on race was caught in
   self-review and fixed the same day: the callback must advance to the
   *batch's* captured seq, not to `ring.lastSeq` read at callback time (the
   ring keeps appending on the service thread, and advancing to the newer
   value would silently skip samples).
2. **Units: m/s² mislabeled as g.** `AccelSample` passed raw
   `SensorEvent.values` through; the panel showed "Peak magnitude: 10.36 g"
   for a phone lying still. Any downstream consumer of the 3.5 g cascade
   threshold would misfire. Fixed at the decode boundary
   (`sensor_payload.dart`, `ms2PerG`), with a regression test (resting
   9.80665 m/s² decodes to 1.0 g) and the widget/payload tests updated.
3. **Stale stream after stop/start.** The panel's de-dup
   (`seq <= _recent.last.seq`) ignored the restarted service's fresh
   sequence (it restarts at 1), so the panel showed frozen pre-stop numbers.
   Fixed: a `running=false` state push clears the live indicators
   (`_recent`, rate trackers, peak) while cumulative counters stay.
   Also added: `attachConsumer()` pushes a state snapshot so a cold-attached
   panel learns the service is already running instead of showing a stale
   "Watcher stopped".

**Verified numbers (device screenshot is the record; XML dumps are stale)**

- Measured sample rate: 41.8–49.8 Hz across runs (requested 50).
- Batch cadence: 19.3–19.9 Hz (requested 20).
- Carpet drop × 2: **peak 11.09 g** vs 3.5 g cascade threshold. Desk
  handling during the screen-off test: 4.65 g. At rest: ~1.0 g.
- 65 s screen-off: sampling continued, no drops, rates healthy.
- Rotation: State survives (Flutter absorbs the config change), no detach,
  no drop spike.
- Cold attach: honest `Dropped 147661` re-drain report.
- Stop/start: state freeze, notification dismiss, clean restart.

**Conventions established this session**

- Channel invocations to Dart are main-thread-only; the service thread may
  touch the ring, never the channel. The delivery callback, not the post,
  is what advances the consumer sequence — and it advances to the batch's
  captured seq.
- One unit conversion, at the decode boundary; everything downstream of the
  wire sees g. Values and thresholds never get rescaled twice.
- Device evidence comes from `screencap`. `uiautomator` dumps lag this
  panel's live semantics and must not be used as the record.
- Laptop-green is not device-green: all three bugs above were invisible to
  `flutter test` and existed only because the Kotlin side had never run.

**Not done** — detector (slice 2), SMS, gyroscope, the six product screens.
The screen-off test used a 65 s window with a partial wake lock; battery-kill
behaviour remains untested, as flagged in the original checklist.
