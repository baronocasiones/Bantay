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
| `SPEC.md` | Authoritative spec: cascade, alert prompt, gates. |
| `architecture.md` | Data flow, module ownership, session lifecycle. |
| `ui-flow.md` | Screen flow. |
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
