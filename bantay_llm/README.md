# Bantay Path 2: on-device alert text

Importable Flutter module for the optional LiteRT-LM path. Path 1 owns impact detection, countdown, and sending. In the product app, Qwen composes wording asynchronously during the confirmed-fall countdown; native Path 1 uses it only if it passes fact checks and arrives before the unchanged deadline. Otherwise native sends its fixed English or Tagalog alert.

## Host app setup

Add this package to the Flutter app:

```yaml
dependencies:
  bantay_llm:
    path: ../bantay_llm
```

Set Android `minSdk` to **30** and build for `arm64-v8a`. The current `flutter_edge_ai_litertlm` Android runtime requires both. This package pins `flutter_edge_ai` 2.1.1 and `flutter_edge_ai_litertlm` 1.10.0. It fetches its verified native library during build; do not add a separate `litertlm-android:latest.release` Gradle dependency.

Obtain a Qwen3-0.6B `.litertlm` file ahead of the demo and pass its absolute path to `prepareFromFile`. Use `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` (329 MiB, md5 `0c63f12e688bc91d1bd4577c9858d262`). Do **not** use `qwen3_0_6b_mixed_int4.litertlm`: verified on the demo phone, that file ignores its input and answers every prompt with the same generic English greeting, on-device and under Google's LiteRT-LM CLI alike. Model transfer is setup work; incident handling makes no network request. Keep model files out of source control; download the one file we use from the [`model-qwen3-0.6b-wi4b32-v1` release](../../releases/tag/model-qwen3-0.6b-wi4b32-v1).

`prepareFromFile` takes a `backend` argument. It defaults to `PreferredBackend.cpu`. Prefer GPU on any phone whose OpenCL accelerator loads, because prefill is the bottleneck (see below).

Call `WidgetsFlutterBinding.ensureInitialized()` before preparing the model. Preparation may take time; run it during setup, not after impact:

```dart
final path2 = BantayPath2();
final modelReady = await path2.prepareFromFile(modelPath);
// Show "offline text mode" when modelReady is false.
```

`BantayPath2` registers the LiteRT-LM engine during preparation. Register it once; do not also call `FlutterEdgeAi.initialize` for this engine in the host app. Preparation loads the model and opens a session before monitoring starts.

## Connect at impact

Start the Path 1 countdown immediately. Keep its SMS text available before asking the model for wording:

```dart
final facts = ImpactFacts(
  occurredAt: detectedAtLocal,
  peakG: peakG,
  beforeImpact: BeforeImpact.walking,
  afterImpact: AfterImpact.noMovement,
  stillnessSeconds: 8,
  latitude: latitude,
  longitude: longitude,
  contactName: contactName,
);

var alert = path2.fallback(facts, AlertLanguage.tagalog);
startCountdown(); // Path 1; never await Path 2 here.
unawaited(path2.compose(facts, AlertLanguage.tagalog).then((candidate) {
  if (!alertAlreadySent) alert = candidate;
}));

// On SEND HELP or countdown expiry:
await smsSender.send(alert.text);
await incidentStore.recordLlmUsed(alert.llmUsed);
```

The host app supplies `startCountdown`, `alertAlreadySent`, `smsSender`, and `incidentStore`. `AlertResult.llmUsed` maps to the `incidents.llm_used` field in `docs/architecture.md`. Preserve the exact `alert.text` in the SMS outbox and Alert Sent screen. Do not wait for `compose` when the user presses SEND HELP.

The harness keeps a 2-second wall-clock limit. The product coordinator supplies the remaining countdown time minus a 500 ms bridge reserve. Both ask the native session to stop on timeout, limit output to 32 tokens, and reject empty, long, or numerically inconsistent text. This is a format and numeric check, not a full semantic proof; review actual model wording on the demo phone. Only accepted model wording is offered to native Path 1. The fixed alert remains complete when no model is installed or generation is late.

## Measured on the demo phone

Samsung SM-A127F, Android 13 (API 33), arm64, Exynos 850, model
`Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`.

| | CPU (XNNPACK) | GPU (OpenCL) |
|---|---|---|
| Cold load | 20.8 s | 51.7 s |
| Prefill, short prompt | 19.9 s | 7.5 s |
| Prefill, alert prompt | >30 s, no output | 10.2 s |
| Decode | 2.7 chunks/s | 4.1 chunks/s |
| 2-second alert path | fallback | fallback |

**Prefill dominates, and it is the reason the 2-second budget cannot be met on
this hardware.** A 15-token prompt costs 19.9 s of prefill on CPU: roughly
1.3 s per prompt token. The alert prompt in `alert_composer.dart` is about 130
tokens, so it needs ~170 s of CPU prefill before the first token is decoded.
GPU cuts prefill 2.6x but 10.2 s is still 5x over budget.

Decode is not the problem. At 4.1 chunks/s the 40-token cap would need ~10 s,
so the 2-second limit would fail even with free prefill. The published 8–13
tokens/s figures on the [model card](https://huggingface.co/litert-community/Qwen3-0.6B)
refer to decode, not to the end-to-end alert, and do not change this conclusion.

**The 2-second path will always select the template on this phone.** `compose`
returns the fixed alert, `llmUsed` is `false`, and the SMS is correct and
complete. That is the designed behaviour, not a bug.

### What the model does produce, given time

Under the 30-second diagnostic, GPU returned real alert wording rather than a
greeting:

```
BANTAY alert: Possible fall at 14.59950, 120.98420 – 7.2g impact, 7:
```

Correct prefix, correct coordinates, correct impact force, correct hedging. It
was still rejected by `_isGrounded`, correctly: no timestamp, and a stray `7`
from the stillness clause. A 0.6B model reliably produces plausible framing and
unreliably produces complete, correct facts. That is precisely the failure mode
docs/SPEC.md §7 describes, and it is why the composer keeps a hard numeric check
rather than trusting the output.

### Current product integration

The product now composes wording during the native 15-second countdown using a
shorter prompt and a deadline-aware timeout. Native Kotlin appends any current
GPS fix and remains the final gate for incident ID and deadline. Model load was
observed on the SM-A127F at 11.4 seconds on GPU on 2026-10-10. A padded-drop
check must still establish that generation passes the grounding checks and is
accepted by native Path 1 before the deadline. Do not treat model readiness or
the older diagnostic output as proof of production `llmUsed: true`.

## Verification on a different phone

Run `flutter pub get`, `flutter test`, then an Android build in the host app. Test cold and warm model loads, Tagalog output, timeout, airplane mode, and immediate SEND HELP. Record elapsed generation time and `llmUsed`; performance varies by phone and by backend. Build with `--dart-define=BANTAY_BACKEND=gpu` to compare backends on the actual device. Faster hardware will move the prefill number, not the architecture of this problem.
