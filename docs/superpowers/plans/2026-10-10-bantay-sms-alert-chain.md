# Bantay SMS Alert Chain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver Figma-styled working Setup → Guardian → Incident → SMS result flow, prove real SMS receipt on SM-A127F, then unlock remaining Figma pages.

**Architecture:** Keep sensor service as source. A Dart bridge fans out decoded batches to live UI and a detector isolate. An incident controller owns cancel/countdown/send-once state and always holds a fixed alert. Kotlin owns SMS submission, callbacks, and durable outbox. Path 2 may replace wording before send, never gate it.

**Tech Stack:** Flutter/Dart, Kotlin Android, LiteRT-LM package already present, Android SmsManager, local preferences, Flutter widget tests, Kotlin unit tests, SM-A127F device checks.

---

## File map

- bantay_app/lib/domain/fall_detector.dart: pure cascade and impact event.
- bantay_app/lib/domain/detector_worker.dart: isolate message loop.
- bantay_app/lib/sensors/sensor_bridge.dart: one MethodChannel consumer and fan-out.
- bantay_app/lib/alerts/incident_controller.dart: countdown and one send decision.
- bantay_app/lib/alerts/alert_gateway.dart: Dart interface for SMS states and native adapter.
- bantay_app/lib/alerts/contact_store.dart: local setup data.
- bantay_app/lib/ui/: Figma-based product screens and shared theme/widgets.
- bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/: SMS bridge, durable outbox, status callbacks, alarm/haptic.
- bantay_app/test/: pure detector, incident controller, adapter, and widget tests.

## Task 1: Pure detector

- [ ] Write failing tests in bantay_app/test/fall_detector_test.dart for valid impact (>3.5 g, >60 degrees in 500 ms, 2 s stillness), same-orientation rejection, ongoing-motion rejection, and 8 s test suppression. Use synthetic AccelSample sequences.
- [ ] Run /home/adrian/flutter/bin/flutter test test/fall_detector_test.dart; confirm expected failures.
- [ ] Add fall_detector.dart with interface:
~~~dart
class ImpactEvent {
  final DateTime detectedAt;
  final double peakG;
  final BeforeImpact beforeImpact;
  final int stillnessSeconds;
}
class FallDetector {
  ImpactEvent? addSample(AccelSample sample);
  void suppressFor(Duration duration);
  void reset();
}
~~~
- [ ] Run targeted test, then full bantay_app tests.

## Task 2: Sensor fan-out and detector isolate

- [ ] Write failing bridge tests: one native batch reaches live stream and detector once; malformed batch is rejected; stop/restart resets detector state.
- [ ] Add sensor_bridge.dart as sole product MethodChannel handler. Keep debug panel test hook separate; product UI never registers another handler.
- [ ] Add detector_worker.dart with Isolate.spawn, SendPort/ReceivePort, immutable batch DTOs and event messages. No Flutter widgets or SMS calls inside isolate.
- [ ] Run bridge tests and full app tests.

## Task 3: Incident coordinator

- [ ] Write failing tests for synchronous fallback before generation, 15-second timer, cancel preventing SMS, SEND HELP sending once, expiry sending once, late model result ignored, and duplicate impact suppression.
- [ ] Add incident_controller.dart with:
~~~dart
abstract interface class AlertGateway {
  Future<SmsSubmission> send({required String incidentId, required String number, required String body});
}
class IncidentController {
  void start(ImpactFacts facts, String number);
  Future<void> sendHelp();
  void cancel();
}
~~~
- [ ] Use injected clock/timer and fake gateway in tests. Start Path 2 unawaited; snapshot current alert at send. Never await Path 2 in sendHelp.
- [ ] Run targeted and full tests.

## Task 4: Native SMS and outbox

- [ ] Write failing pure Kotlin tests for queued → sending → sent/delivered or failed transitions and idempotent retry by incident ID. Add fake carrier result seam.
- [ ] Add SEND_SMS to AndroidManifest.xml; request permission during Setup. Implement SmsManager with multipart handling, sent and delivery PendingIntents, and explicit SIM selection/default handling. Expose status over alert MethodChannel.
- [ ] Persist incident ID, destination, exact body, state, and attempts in app-private storage. Retry queued entries on cellular service return and app/service start; no duplicate submission while sending.
- [ ] Verify on device with a consenting recipient. Never log recipient or full SMS body to logcat.

## Task 5: Contact, location, and incident feedback

- [ ] Write failing tests for contact persistence and validation, denied SMS permission blocking Arm, optional location fallback, alarm/haptic start on incident and stop on cancel/send.
- [ ] Add contact_store.dart and Android feedback channel. Request coarse location separately; last known coordinates may enrich facts but cannot block alert.
- [ ] Run targeted and full tests.

## Task 6: Figma alert-chain UI

- [ ] Copy only logo asset from original checkout's figma-ui-for-frontend/raw into bantay_app/assets; declare in pubspec.yaml. Build theme from supplied palette (#013791, #99CCFF, #185C43, #F5F7FA, #F5A524, #C52222).
- [ ] Write failing widget tests for Setup validation, calibration timer with real sensor data, live Guardian state, Incident 15-second countdown and buttons, and truthful Sent/Queued/Failed result.
- [ ] Replace harness root with product flow. Keep Path 2 and sensor diagnostics behind test-only route or build flag. Build reusable header, cards, buttons, and nav as widgets, not screenshot images.
- [ ] Use user-entered contact and live incident facts only. Hide call action until later automatic-call phase. Hide History/Eval links until their real pages exist.
- [ ] Run widget tests, flutter analyze, and arm64 APK build.

## Task 7: Device acceptance

- [ ] Install fresh APK on SM-A127F, verify sensor rate and screen-off continuity.
- [ ] Configure consenting test contact through Setup. Test manual SOS → I'M OK (no SMS), manual SOS → SEND HELP (one SMS), and countdown expiry (one SMS). Compare exact recipient text with app preview and native callback.
- [ ] Test model unavailable/timeout, no signal queue then retry on service return, app restart, and duplicate triggers. Record llmUsed and send state.
- [ ] Only after manual chain passes, run controlled padded-drop test for automatic detector. Record trigger latency from detector emission, peak g, orientation, stillness, countdown, and actual SMS receipt. If drop fails, diagnose before calling chain complete.
- [ ] Confirm all tests/analyzers/build pass, remove debug instrumentation, and write device evidence to docs. Then implement remaining Figma pages in a separate plan, using real incident records and measured evaluation metrics.

## Commands

- /home/adrian/flutter/bin/flutter test (in bantay_app and bantay_llm)
- /home/adrian/flutter/bin/flutter analyze (in both modules)
- ANDROID_HOME=/home/adrian/codes/appbuilder-stufff/.android-sdk JAVA_HOME=/opt/android-studio/jbr /home/adrian/flutter/bin/flutter build apk --debug --target-platform android-arm64 (in bantay_app)
- /home/adrian/codes/appbuilder-stufff/.android-sdk/platform-tools/adb devices -l
