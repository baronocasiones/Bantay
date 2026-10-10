# AGENTS.md

Project context for agents working in `/home/adrian/codes/appbuilder-stufff`.

## What this is

**Bantay**, a Filipino fall-detection app. Two paths:

- **Path 1 (safety-critical):** threshold cascade on accelerometer features →
  alarm, countdown, haptic, SMS. Kotlin service + Flutter shell.
- **Path 2 (optional):** on-device LLM wording for the alert text. Degrades to a
  hardcoded bilingual template. Must never block or delay an SMS.

The demo phone currently decides Path 2's fate: prefill is ~1.3s per prompt token
on an Exynos 850, so the 2-second budget is not reachable. **Present Path 1 as
the product.** See `docs/path2-llm-module.md`.

## Layout

| Path | What |
|---|---|
| `bantay_llm/` | Dart-only Path 2 module. No platform code. |
| `bantay_app/` | Flutter harness to exercise Path 2 on a phone. Not the product shell. |
| `models/` | `.litertlm` files, gitignored. Do not commit. |
| `docs/SPEC.md` | Authoritative spec: cascade, alert prompt, gates. |
| `docs/architecture.md` | Data flow, module ownership, session lifecycle. |
| `docs/ui-flow.md` | Screen flow. |
| `docs/` | Per-module archive, appended by the End protocol. |

## Environment

This workstation has non-default tool locations. Use them, not PATH:

- Flutter: `/home/adrian/flutter/bin/flutter` (not on PATH).
- Writable Android SDK: `/home/adrian/codes/appbuilder-stufff/.android-sdk`
  (the system SDK is read-only; the NDK lives in this copy).
- Java 21 from `/opt/android-studio/jbr`.
- Demo phone: Samsung SM-A127F, Android 13 (API 33), arm64, Exynos 850.
  `adb devices -l` must list it as `device`.

```sh
export ANDROID_HOME=/home/adrian/codes/appbuilder-stufff/.android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

## Conventions

### Model files

Use `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`, md5
`0c63f12e688bc91d1bd4577c9858d262`. Do **not** use `qwen3_0_6b_mixed_int4.litertlm`
— verified broken: it ignores its input and returns the same generic greeting for
every prompt, on-device and under Google's CLI. Always checksum the sideloaded
copy with `run-as md5sum`; a truncated file appears to load and then fails
exactly like the broken one.

Model files stay out of source control: `models/` is gitignored and the file is
too large for git anyway (329 MiB, and GitHub rejects anything over 100 MiB).
The one file we use is published as a release attachment, tag
`model-qwen3-0.6b-wi4b32-v1`; download it from there rather than fetching it
from a link in someone's note. sha256
`03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856`.

### Never let Path 2 block the alert

`BantayPath2` never throws. `prepareFromFile` returns `false` on failure.
`compose` computes the template first and returns it on any model failure,
timeout, or fact-check rejection. Any change that makes the alert wait on the
model is a regression.

### Fact-check and prompt change together

`alert_composer.dart` owns the prompt, the template, and `_isGrounded`. Edit them
together; the checker is what catches a prompt regression.

### `maxTokens` is the KV cache

`maxTokens` (2048) is the context window on `getActiveModel`. `maxOutputTokens:
40` caps generation on `createSession`. Conflating them is a package trap.

### Build for one platform

`flutter build apk --target-platform android-arm64`. Omitting it bundles 32-bit
and x86_64 plugin libs that cannot run on the target.

### Confirm on the device, never assume

Passing `flutter test` is not evidence the model loads or generates on the phone.
The package's native runtime can only be verified by installing and observing.
Record `llmUsed`, elapsed time, and the actual wording.

## Commands

```sh
# Module
cd bantay_llm && /home/adrian/flutter/bin/flutter test && /home/adrian/flutter/bin/flutter analyze

# Harness
cd bantay_app && /home/adrian/flutter/bin/flutter test && /home/adrian/flutter/bin/flutter analyze

# Phone install
$ANDROID_HOME/platform-tools/adb install -r bantay_app/build/app/outputs/flutter-apk/app-debug.apk
$ANDROID_HOME/platform-tools/adb shell am start -n ph.appbuilders.bantay_app/.MainActivity
$ANDROID_HOME/platform-tools/adb shell screencap -p /sdcard/s.png
```

Log filter for timing: `adb logcat -d -v brief | grep FfiInferenceModelSession`
reports prefill, decode, and chunks per second.

## Session History

### 2026-10-09 — Path 2 integration and on-device verification (`bantay_llm`, `bantay_app`)

Picked up from a Codex session that died mid-build on a usage limit.

**Implemented**

- Installed and ran the comparison APK that Codex had built but not deployed.
- Diagnosed the persistent "model ignores its prompt" failure: the shipped
  `qwen3_0_6b_mixed_int4.litertlm` is itself broken. Replaced it with the
  publisher's `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`, which answers the
  "capital of France" probe correctly on both the desktop CLI and the phone.
- Measured prefill vs. decode and found prefill is the bottleneck, not decode:
  ~1.3s per prompt token on CPU. That is why the 2-second budget failed, which
  the previous session had misread as a general "slow model" symptom.
- Made the LiteRT-LM backend selectable. The GPU OpenCL accelerator was
  registering successfully on the device while the code hardcoded
  `PreferredBackend.cpu`; GPU cuts prefill 2.6x and decode 1.5x.
- Verified the production 2-second path on both backends: both correctly select
  the template, with correct `llmUsed: false` and complete SMS text.
- Updated `bantay_llm/README.md` with the measurement table and hardware
  conclusion, corrected the model reference in `bantay_app/README.md`, and
  replaced the projected timing note in `SPEC.md` with measured numbers.

**Conventions established**

- Backends are selectable via `--dart-define=BANTAY_BACKEND=gpu`, resolved in one
  place (`resolveBackend`), and printed in the harness UI so a screenshot is
  self-describing.
- `prepareFromFile` takes an optional `backend`, defaulting to CPU.
- Model integrity is verified by checksum on the device before testing, because
  a truncated sideload looks identical to a broken model.
- Test-only diagnostics are fenced in the UI and use a 30-second budget distinct
  from the production path.
- Hardware measurements are recorded in module docs before recommending
  changes, rather than estimated from published decode rates.

**Not done, deliberately** — moving generation into the Path 1 countdown window
and shortening the prompt. Both are the fixes that would work and both live
outside Path 2's 2-second contract. SPEC.md's Hour-16 gate says ship
template-only and present Path 1 as the product; prompt tuning on demo eve is
explicitly discouraged.

### 2026-10-09 — Path 1 slice 1: sensor foundation (`bantay_app`)

First slice of the safety-critical path. The watcher's eyes: accelerometer
stream from a Kotlin foreground service into Dart, observable in a fenced debug
panel. Picked up from the Hour-16 gate decision to present Path 1 as the
product.

**Implemented**

- `FallWatchService`: FGS `health`, wake lock scoped to sampling, HandlerThread
  with the listener and emitter pinned to it, sample rate requested at 50 Hz,
  batches emitted at 20 Hz.
- `AccelRingBuffer`: 4 s circular buffer with total-append sequence numbers;
  drain reports how many samples were overwritten instead of hiding stalls.
  Pure Kotlin, no Android imports.
- `SensorChannel` bridge + `MainActivity` wiring: start/stop/attach/detach in,
  `batch`/`state` out; the service is started only from the visible activity
  (Android 12+ rule) and `POST_NOTIFICATIONS` is requested best-effort, never
  blocking the start.
- Dart side: `sensor_payload.dart` (pure decode contract, seq math, windowed
  RateTracker) and `sensor_debug.dart` (fenced panel: measured vs requested
  rate, seq, dropped, rejected, peak g, live magnitude strip). `main.dart` now
  hosts both panels under a two-destination NavigationBar.
- Manifest: sensor-side permission set + service declaration; `SEND_SMS` and
  location deferred to the SMS slice.
- `docs/path1-module.md` created (API surface, wire format, conventions,
  device checklist).

**Verified on the authoring box** — 13/13 payload-contract tests under
`dart test`; `dart format` clean on all new files. **Not verified** — no
Android SDK or Flutter SDK on that machine: Kotlin compile, `flutter test`,
`flutter analyze`, and the device checklist all wait for the dev machine.

**Conventions established**

- FGS type declared in manifest **and** `startForeground` — Android 14+ throws
  on mismatch.
- Sequence advance only on delivery: a missing Dart channel retries from the
  ring instead of silently skipping samples.
- Timestamps cross the channel as a `double[]` (Float64List), never `float[]`:
  elapsedRealtime nanos through float32 would smear the 20 ms period at uptime.
- Measured rate is reported separately from the requested rate; the request is
  never evidence.
- Kotlin seams (buffer) and Dart seams (decode) are kept dependency-free so
  they are unit-testable without a device; device behaviour is pinned to a
  checklist, not assumed.
- Debug UI carries the same "Test only; never use for an emergency alert."
  fence as the Path 2 diagnostics.

**Not done, deliberately** — detection logic, SMS, gyroscope, backfill reads of
pre-impact history, and the six product screens. Those are slice 2+ per
`docs/path1-module.md`; the stale `_modelFileName` default in `main.dart`
(broken model filename, flagged in `docs/phone-harness.md`) is a Path 2 concern
and was left untouched.

### 2026-10-10 — Path 1 first device verification (`bantay_app`)

First compile and run of the Kotlin side, on the demo phone (SM-A127F).
Toolchain had to be built on the dev box from scratch: Flutter 3.47.7,
Android platform 36 + build-tools + NDK 28.2.13676358, Gradle 9.3.1 wrapper
generated (the checkout has none), Temurin JDK 21 (system JDK 27 is too new
for AGP 9.1's jlink transform; `java-17-openjdk` here is a JRE without
`javac`).

**Implemented** — three device-only bugs found and fixed, all invisible to
the laptop tests:

- `SensorChannel.postBatch` invoked the MethodChannel from the service
  HandlerThread; `FlutterJNI` requires @UiThread and the app crash-looped.
  Channel invocations now queue on `Handler(Looper.getMainLooper())`, and
  `postBatch` reports delivery through a main-thread callback that advances
  the consumer sequence — to the batch's captured seq, not to a
  `ring.lastSeq` re-read at callback time (that race would skip samples).
- The wire carries m/s²; decode converts to g exactly once (`ms2PerG` in
  `sensor_payload.dart`). A resting phone had read "10.36 g".
- Stop/start left stale stream numbers (the panel's seq de-dup swallowed the
  restarted service's fresh sequence); a `running=false` state push clears
  live indicators, and `attachConsumer` pushes a state snapshot.

**Verified** — full device checklist filled in `docs/path1-module.md`:
measured 41.8–49.8 Hz, cadence 19.3–19.9 Hz, carpet drop × 2 at **11.09 g**
vs the 3.5 g cascade threshold, 65 s screen-off with sampling intact, cold
attach re-drains with honest dropped count (147661), notification lifecycle
correct. The signal path works; the detector itself is still slice 2.

**Conventions established**

- Channel invocations to Dart are main-thread-only; the service thread
  touches the ring, never the channel.
- One unit conversion, at the decode boundary; everything downstream sees g.
- Device evidence comes from `screencap`; `uiautomator` dumps lag this panel's
  live semantics and are not a record.
- Laptop-green is not device-green: every bug above existed only because the
  Kotlin side had never run anywhere.

**Housekeeping (same session)** — removed the duplicate root copies of
`SPEC.md`, `architecture.md`, `ui-flow.md` and the two architecture images;
`docs/` holds the single newer canonical set (commit `a3c7057` superseded the
root originals), and the AGENTS.md layout table now points at `docs/`.
