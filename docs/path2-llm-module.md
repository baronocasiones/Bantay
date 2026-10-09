# Module: bantay_llm (Path 2)

Dart-only Flutter module for optional on-device alert text. Path 1 owns impact detection, countdown, and SMS. Path 2 returns a short grounded alert or the fixed template.

## API surface

`lib/bantay_llm.dart` exports:

| Symbol | Kind | Notes |
|---|---|---|
| `PreferredBackend` | enum, re-export from `flutter_edge_ai` | `cpu` (default), `gpu`, `npu` |
| `ImpactFacts` | class | Path 1 output; validated in the constructor |
| `AlertLanguage` | enum | `english`, `tagalog` |
| `BeforeImpact`, `AfterImpact` | enum | pre/post impact state |
| `AlertResult` | class | `text`, `llmUsed` |
| `AlertComposer` | class | prompt + fact check + timeout |
| `AlertGenerator` | abstract interface | `generate`, `stop` |
| `LitertAlertGenerator` | class | LiteRT-LM adapter |
| `BantayPath2` | class | the entry point |

### Entry points

```dart
class BantayPath2 {
  bool get modelReady;

  AlertResult fallback(ImpactFacts facts, AlertLanguage language);

  Future<bool> prepareFromFile(
    String modelPath, {
    PreferredBackend backend = PreferredBackend.cpu,
  });

  Future<AlertResult> compose(ImpactFacts facts, AlertLanguage language);

  Future<AlertResult> composeDiagnostic(
    ImpactFacts facts,
    AlertLanguage language, {
    required void Function(String text) onCandidate,
  });

  Future<String> probePrompt(String prompt);

  Future<void> dispose();
}
```

`prepareFromFile` returns `false` on any failure and never throws, so the caller
can show "offline text mode" and continue. `compose` returns the fallback on any
model failure, timeout, or fact-check rejection.

`LitertAlertGenerator.initializeFromFile(String modelPath, {PreferredBackend backend})`
mirrors the same parameter.

## Dependencies

Pinned exactly, no ranges:

- `flutter_edge_ai: 2.1.1`
- `flutter_edge_ai_litertlm: 1.10.0`
- `flutter_test` (dev)

## Conventions established

### The fallback is the primary alert, not the failure path

`compose` computes the template first and returns it whenever the model is
absent, fails, times out, or produces ungrounded text. `Path2Harness` shows the
template and the Path 2 result separately so `llmUsed` is observable in a demo.
Nothing in this module may block, throw, or delay the SMS.

### Prompt construction and fact checking live in one file

`alert_composer.dart` owns the prompt string, the template string, and
`_isGrounded`. Prompt edits and the checker that would catch their regression
change together. The fact check is a format and numeric check: exact prefix,
sentence count, length cap, allowed numbers, required before/after terms, and a
denylist of reassurance words. It is not a semantic proof.

### `maxTokens` is the context window, not the reply length

`maxTokens` (2048) sets the KV cache on `getActiveModel`. `maxOutputTokens: 40`
on `createSession` caps generation. Conflating them is a documented package trap
the module avoids.

### Timeout is enforced in Dart, not left to native

`compose` wraps `generate` in `.timeout(...)` and calls `generator.stop()` on
timeout. Native decode is cancelled rather than abandoned, because silently
dropping a subscription lets the accelerator keep decoding to completion.

### Diagnostic paths are test-only and clearly fenced

`composeDiagnostic` and `probePrompt` exist so raw model behaviour can be
observed on hardware. Their output never becomes an alert, and the phone harness
labels them "never use for an emergency alert". `_diagnosticElapsed`, the 30s
diagnostic timeout, and `_diagnosticProbe`/`_diagnosticLanguage` state keep them
distinct from the production 2-second path.

## Patterns used

- **Dart-only module, no plugin.** The bindings come from `flutter_edge_ai`,
  which bundles the native runtime. No custom MethodChannel, no Gradle dependency.
- **Build-time environment injection.** Flutter app uses
  `String.fromEnvironment(BANTAY_MODEL_PATH)` instead of hardcoding the model
  path, so the harness can be built for different paths without code edits and
  the file stays out of source control.
- **Verified sideload with checksum.** Debug build stage with
  `run-as cp`, then `adb shell run-as ... md5sum` compared against the host
  before testing. A truncated copy appears to load and then returns generic
  output, so checksum verification is mandatory rather than optional.
- **Build targeting the only supported platform combination**:
  `flutter build apk --target-platform android-arm64`. Without it the APK
  bundles 32-bit and x86_64 plugin libs that cannot run on the target phone.
- **Test hook forwarded, not duplicated.** `Path2HarnessState.prepareNow()`, the
  `modelPathOverride`/`backendOverride` constructor args, and
  `BantayApp.autoPrepare` exist so widget tests can drive state without platform
  channels or fake-async hangs; `main.dart` reads the define once in
  `resolveBackend()`.

## Verified behaviour (Samsung SM-A127F, Android 13, Exynos 850)

Model: `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`

| | CPU | GPU |
|---|---|---|
| Cold load | 20.8 s | 51.7 s |
| Prefill, short prompt (~15 tok) | 19.9 s | 7.5 s |
| Prefill, alert prompt (~130 tok) | >30 s, no output | 10.2 s |
| Decode | 2.7 chunks/s | 4.1 chunks/s |
| 2-second alert path | fallback | fallback |

Prefill dominates at roughly 1.3 s per prompt token on CPU. Decode is not the
binding constraint. The 2-second budget is not achievable on this hardware with
either backend.

## Known state

- `compose` on the 2-second path always selects the template on the demo phone.
  This is correct behaviour, not a defect.
- GPU diagnostic output is close to correct but incomplete: `BANTAY alert:
  Possible fall at 14.59950, 120.98420 – 7.2g impact, 7:` — right prefix, right
  coordinates, right hedging, missing timestamp, stray `7`. Correctly rejected by
  `_isGrounded`.
- Tagalog diagnostic not yet measured on GPU.

## Next steps (not done, deliberately)

- Move generation into the Path 1 countdown window so prefill overlaps the
  countdown instead of the send deadline. Requires Path 1 change.
- Shorten the prompt. The static instruction block is ~330 of 508 characters;
  moving it to a system role or trimming it cuts prefill proportionally.
- Per SPEC.md Hour-16 gate: present Path 1 as the product.
