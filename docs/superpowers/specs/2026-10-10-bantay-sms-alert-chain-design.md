# Bantay SMS Alert Chain Design

## Scope

Build working Flutter screens from PNG references in the original checkout's `figma-ui-for-frontend/raw`: Setup, Calibration, Guardian Dashboard, Incident Detected, and Emergency Alert Sent. Native widgets carry real state; screenshots are references, not screen backgrounds. Automatic calling and remaining History, Settings, Incident Details, and Detection Performance pages follow only after real SMS chain passes on demo phone.

## Behavior

Setup stores user-entered contact name and phone number locally and requests permissions before arming. Calibration samples actual accelerometer data for 20 seconds. Guardian displays live motion, monitoring state, and manual SOS. Threshold cascade consumes same native batches through a background Dart isolate. Detected impact or manual SOS creates one incident. Detection starts alarm, vibration, and a 15-second countdown. `I'M OK` cancels; `SEND HELP NOW` or expiry sends once. Monitoring resumes after response.

Fixed bilingual alert is prepared immediately from incident facts. Path 2 may replace it only if it finishes and passes fact checks before send decision; sending never awaits generation. No model or location produces an honest fallback. Real SMS sender records queued, sent, failed, and delivered states from Android callbacks, persists exact message text, and retries queued message when cellular service returns. UI reports actual state; it never says sent merely because a send was requested. Recipient may receive real SMS during device tests.

## Boundaries

`SensorChannel` remains native input. Shared Dart bridge decodes batches and feeds live UI and pure-Dart detector isolate. Detector emits immutable incident facts, never renders UI or sends SMS. One incident coordinator owns countdown and send-once state. Native SMS gateway owns permission, SIM selection, carrier callbacks, and durable outbox. Local app storage owns contact and incident history. Path 2 remains optional and cannot block Path 1.

## Acceptance

Automated tests cover cascade accept/reject and suppression, countdown cancel/send-once, fallback priority, queued retry, and truthful UI states. Fresh arm64 APK must build, install, and run on SM-A127F. Device checks cover calibration, live 50 Hz stream, manual SOS cancellation, immediate send, countdown expiry, actual recipient SMS receipt, screen-off monitoring, model timeout, missing model, and no-service queue/retry. Controlled padded drop comes only after safe manual chain and recipient setup work. Record exact message, recipient confirmation, timestamps, `llmUsed`, and SMS state. Do not infer real-human-fall accuracy from a phone drop.

## Deferred pages

After full SMS acceptance, implement remaining Figma pages with real records and verified metrics only. Hide Figma call action until later automatic-call phase; never show sample names, timestamps, incidents, or evaluation scores as real.
