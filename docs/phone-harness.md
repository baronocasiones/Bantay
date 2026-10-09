# Module: bantay_app (Path 2 phone harness)

Single-screen Flutter app used to exercise `bantay_llm` on a real Android phone.
It does not implement Path 1, the sensor service, or SMS. Its job is to produce
the numbers a demo needs: cold load time, whether the model's wording passes the
fact check, and how the 2-second timeout behaves.

## Structure

`lib/main.dart` (single file, ~460 lines):

| Component | Responsibility |
|---|---|
| `resolveModelPath` | `BANTAY_MODEL_PATH` define, else app documents dir + default filename |
| `resolveBackend` | `BANTAY_BACKEND` define → `PreferredBackend`, default `cpu` |
| `sampleFacts` | Synthetic incident, values mirrored from `bantay_llm` test fixtures |
| `BantayApp` | `MaterialApp` shell; forwards test hooks to the harness |
| `Path2Harness` | StatefulWidget |
| `Path2HarnessState` | Model card, per-language run cards, raw diagnostic card |
| `_RunRecord` | Fallback vs. result, `llmUsed`, elapsed time for one language |

## Build-time environment injection

Two defines, read via `String.fromEnvironment`:

- `BANTAY_MODEL_PATH` — absolute path to the `.litertlm` file, for debug builds
  where the model is sideloaded rather than placed in the documents directory.
- `BANTAY_BACKEND` — `cpu` or `gpu`. Compare prefill on real hardware.

`resolveBackend` is the single decision point, so the define is read in exactly
one place and tests can inject a `PreferredBackend` directly. The active backend
is rendered next to cold load time so a screenshot is self-describing.

Typical debug build:

```sh
/home/adrian/flutter/bin/flutter build apk --debug --target-platform android-arm64 \
  --dart-define=BANTAY_MODEL_PATH=/data/user/0/ph.appbuilders.bantay_app/app_flutter/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm \
  --dart-define=BANTAY_BACKEND=gpu
```

## Conventions established

### UI shows the fallback and the model result as separate facts

Each language card renders "Fixed alert (Path 1, always ready)" above
"Path 2 result", plus `llmUsed` and elapsed time. The demo needs to prove the
fallback path was exercised (`incidents.llm_used`), so the harness never
collapses them into one string.

### Diagnostics are explicitly fenced in the UI

The diagnostic card is labelled "Raw model diagnostic" and repeated as
"Test only; never use for an emergency alert", with a 30-second budget that is
visibly distinct from the production 2-second path. Diagnostic state
(`_diagnosing`, `_diagnosticProbe`, `_diagnosticLanguage`, `_diagnosticCandidate`)
is kept separate from `_runs` so a diagnostic cannot be mistaken for an alert.

### Failure is rendered, not hidden

`_prepare` catches everything and sets `modelReady = false`, showing
"Model unavailable - offline text mode only". A failed model load is a supported
state the UI is expected to display during a demo.

### Widget tests must not depend on platform channels

`autoPrepare: false` and the `prepareNow()` test hook exist because widget tests
run under fake-async, where the real `File.exists()` probe inside
`prepareFromFile` never completes. Tests drive preparation explicitly inside
`runAsync`.

## Build configuration

- `minSdk 30`, `targetSdk 36`, arm64-v8a only, per the LiteRT-LM runtime.
- Application id `ph.appbuilders.bantay_app`.
- The app expects the model in its app-private `app_flutter/` directory for
  debug builds; sideload with `run-as` and verify md5 before testing.

## Known issues

- The default model filename constant `_modelFileName` still points at the broken
  `qwen3_0_6b_mixed_int4.litertlm`. Any build that omits `BANTAY_MODEL_PATH`
  loads the wrong model. Suspect as a leftover; correct before the next use.

## Related

- [Path 2 module](path2-llm-module.md)
- Project spec: `SPEC.md`, `architecture.md`, `ui-flow.md`

## Update — 2026-10-09: the harness gained a second destination

Path 1 slice 1 landed in this app, so several statements above are superseded
(added additively per the archive rule):

- The app is **no longer single-screen**. `lib/main.dart` now wraps both panels
  in `_ShellScaffold` (`NavigationBar` with Path 2 / Sensors destinations,
  `IndexedStack` children). `Path2Harness` is unchanged; `BantayApp` forwards
  its hooks as before. Structure lines above stay true for the Path 2 half.
- "It does not implement Path 1" is now false in the streaming sense: a
  `FallWatchService` samples the accelerometer and the **Sensors** tab shows
  the live stream. Impact detection, countdown, and SMS remain Path 1 work.
- New Android sources under
  `android/app/src/main/kotlin/ph/appbuilders/bantay_app/`: `FallWatchService`,
  `AccelRingBuffer`, `SensorChannel`, and the extended `MainActivity`.
  `AndroidManifest.xml` gained the sensor-side permissions and the
  `foregroundServiceType="health"` service declaration; `values/strings.xml`
  is new.
- New Dart files: `lib/sensor_payload.dart` (pure decode contract),
  `lib/sensor_debug.dart` (fenced debug panel). New tests:
  `test/sensor_payload_test.dart`, `test/sensor_debug_test.dart`.

Full detail, conventions, and the device checklist: [Path 1 module](path1-module.md).
