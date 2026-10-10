# Live Local Model Alert Design

**Status:** Design approved in conversation; implementation not started.

## Goal

Use the on-device Qwen model to compose wording for a real fall-alert SMS. On
the Samsung SM-A127F, at least one grounded model result must reach the SMS
before the existing 15-second deadline before this work is considered working.

## Constraints

- Native Path 1 remains the source of truth for confirmed incidents, countdown,
  cancellation, location, and SMS delivery.
- Model generation starts only after native Path 1 confirms a fall.
- Generation runs asynchronously inside the existing countdown. It never
  extends the deadline or blocks a send.
- Kotlin accepts model wording only for the matching incident while it is still
  counting and before its deadline. Existing fixed text remains ready as
  fallback.
- Kotlin appends available GPS coordinates after the wording at send time.
- Manual SOS continues to send immediately and does not wait for the model.
- The model may use only incident facts already supplied by Path 1. It cannot
  diagnose injury, claim the person is safe, or change alert decisions.
- Diagnostic prompt tools remain outside the production alert flow.

## Proposed data flow

1. `GuardianRuntime` confirms a fall and emits the counting incident snapshot
   to Flutter, as it does today.
2. One app-level local-model coordinator maps the snapshot into `ImpactFacts`
   and calls `BantayPath2.compose` without awaiting it in Path 1. It uses the
   device language (`fil`/`tl` -> Tagalog, otherwise English), and no location
   facts because native Kotlin appends the eventual fix at send time.
3. The coordinator passes only the remaining countdown time, minus a 500 ms
   bridge reserve, as the model candidate timeout. It sends text through
   `setIncidentText(incidentId, text)` only when `AlertResult.llmUsed` is true.
4. `GuardianRuntime` stores it only if that incident is still counting and the
   deadline has not passed.
5. At the original deadline, native Path 1 sends the accepted text plus the
   location suffix, or its fixed fallback if no acceptable model result arrived.

One app-level coordinator owns one `BantayPath2` instance and its lifecycle. It
prepares the model once during startup; failure keeps monitoring available in
template mode. App UI does not call the raw generator. The diagnostic harness
keeps its separate diagnostic-only path.

## Performance approach

The current alert prompt is too long for the measured hardware. Shorten the
production prompt and generated response while preserving required facts and
the existing fact-check. Use the already selected GPU backend. Measure cold and
warm generation on the SM-A127F. Let production `compose` accept a caller
timeout so it can use the remaining countdown window; keep the diagnostic
timeout separate. The 15-second SMS deadline never changes.

## Verification

- Unit tests: snapshot-to-facts mapping, matching incident ID, cancellation,
  late/ungrounded candidate rejection, and unchanged SMS deadline.
- Device check: record model readiness, elapsed generation time, `llmUsed`, and
  final SMS text for a padded-drop run.
- Success requires the device SMS to contain model-generated wording with
  `llmUsed: true`; a template-only fallback proves safety behavior but does not
  satisfy the sprint's local-model success criterion.
- Any real SMS test is performed only after the user authorizes that send.

## Scope exclusions

No model-driven fall detection, contact choice, location lookup, cancel/send
decision, or general-purpose chat. No SMS delay, model requirement, or removal
of the fixed fallback.
