# Live Local Model Alert Implementation Plan

## Goal

Use the on-device Qwen model to produce grounded wording for a confirmed fall SMS during the existing countdown. Keep detection, the 15-second deadline, cancellation, GPS, and SMS under native Path 1 control. All changes stay local; no commit or push.

## Tasks

1. Add failing composer tests for short prompt, caller-provided timeout, and location-excluded production wording.
2. Add failing coordinator tests for fact mapping, language selection, countdown budget reserve, duplicate/manual/late suppression, and submitting only accepted model text.
3. Implement prompt/checker and configurable output cap; run `bantay_llm` tests and analyze.
4. Implement one production `LocalModelAlertCoordinator`, integrate it with the native incident stream, and record readiness/timing/acceptance for device evidence.
5. Run app tests and analyze; build arm64 APK; install and verify on the SM-A127F. Do not cause a real SMS without renewed consent.

## Safety checks

- Generation is fire-and-forget from UI and gets only remaining countdown time minus bridge reserve.
- Native `setIncidentText` remains the final gate and accepts only a matching live incident before deadline.
- Manual SOS never invokes Path 2.
- Never claim production model success until a grounded result is accepted during the real app countdown. A real outgoing SMS test requires explicit user consent.
