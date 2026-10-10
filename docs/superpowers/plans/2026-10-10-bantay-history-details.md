# Bantay History and Incident Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add truthful, persistent local incident History and Incident Details screens for real fall and manual SOS incidents.

**Architecture:** Native `GuardianRuntime` remains the owner of incident transitions and writes each real incident to an app-private SQLite journal. `MainActivity` exposes journal snapshots through the existing alerts MethodChannel, and the current `NativeIncidentGateway` reads them. Flutter owns display, local search/filter state, and navigation; no cloud sync or fabricated rows.

**Tech Stack:** Kotlin, Android SQLiteOpenHelper, existing Flutter MethodChannel, Dart, Material 3.

---

## File map

- Create `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/IncidentHistoryDb.kt`: schema, upsert incident facts/status, append real timeline events off the detector thread, and return records in newest-first order.
- Modify `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/GuardianRuntime.kt`: write journal rows and timeline events at the same real state transitions that already persist the active incident.
- Modify `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/Guardian.kt`: construct the journal with the application context and inject it into the runtime.
- Modify `bantay_app/android/app/src/main/kotlin/ph/appbuilders/bantay_app/MainActivity.kt`: add `incidentHistorySnapshot` to the existing alert channel; do not add a second Dart method-call handler.
- Create `bantay_app/lib/alerts/incident_history.dart`: immutable record/timeline data types and tolerant native-map parsing.
- Modify `bantay_app/lib/alerts/native_incident_gateway.dart`: expose `historySnapshot()` over the already registered channel.
- Create `bantay_app/lib/ui/history_screens.dart`: History list, filters/search, honest empty state, and Incident Details presentation.
- Modify `bantay_app/lib/ui/product_app.dart`: add History/Details page state, preserve filter/search when opening/backing from details, refresh records on native state changes, add Guardian/History bottom navigation, and add the top-bar Settings gear beside Live linking to existing setup.
- Update `docs/path1-module.md` and `docs/ui-flow.md`: describe journal ownership, local-only data, screens, and supported incident facts.

## Task 1: Add durable native incident journal

**Files:** Create `IncidentHistoryDb.kt`.

- [x] Add an SQLite database with an `incidents` table keyed by incident ID. Store occurrence time, source (`fall` or `manual_sos`), impact, pre-impact movement label, limited-movement seconds, contact name/number, current stage, and current error. Read exact SMS text from the existing outbox so canceled countdown previews are never stored as sent messages.
- [x] Add an `incident_timeline` table with auto-increment order, incident ID, event label, event timestamp, and optional outcome detail. Index incident ID and descending occurrence time.
- [x] Provide synchronized operations `upsert(state: GuardianState)`, `appendEvent(incidentId: String, label: String, atEpochMs: Long, detail: String? = null)`, and `all(): List<IncidentHistoryRecord>`.
- [x] Make reads return each incident with its timeline ordered by insertion/time. Use nullable columns for unknown facts; do not turn absent movement facts into zero.
- [x] Keep database app-private. App-data reset naturally removes it. No network or account storage.

## Task 2: Journal native transitions

**Files:** Modify `GuardianRuntime.kt` and `Guardian.kt`.

- [x] Add an `IncidentJournal` dependency to `GuardianRuntime`, with a no-op default only for existing pure runtime callers that do not provide a store. Production injects `IncidentHistoryDb`.
- [x] Extend `commit` to persist the active snapshot and upsert its incident row whenever `incidentId` is non-null. Append an event only when caller supplies an event for a genuine transition; ordinary same-stage text updates only refresh row data.
- [x] On automatic fall confirmation, record the new incident and a `Fall detected` / `Countdown started` timeline event.
- [x] On manual SOS, record the new incident with source `manual_sos`, no fall-only values, and a `Manual SOS started` event; then record send start before dispatch.
- [x] On user cancellation, append `Countdown cancelled` only if the state actually changes from counting to canceled.
- [x] Distinguish send origin in `beginSend`: `Countdown expired` for `tick()` and `Send requested` for the user's early-send action. Record send start once.
- [x] On carrier/outbox state transition, append the actual new SMS state and error detail only when stage changes. Enrich screen snapshots with exact SMS body/status from the durable outbox.
- [x] In `Guardian.build`, create one `IncidentHistoryDb(app)` and pass it into the single process-wide runtime.

## Task 3: Expose real journal records to Flutter

**Files:** Modify `MainActivity.kt`, create `incident_history.dart`, modify `native_incident_gateway.dart`.

- [x] Add alert-channel method `incidentHistorySnapshot` that returns journal records merged with matching SMS outbox body/status. Keep the current single MethodChannel handler in `NativeIncidentGateway`.
- [x] Define immutable Dart `IncidentHistoryRecord` and `IncidentTimelineEvent` types. Parse nullable impact, movement, error, and SMS text without inventing defaults.
- [x] Map native timestamps from epoch milliseconds to `DateTime`; retain raw status and source fields so UI labels reflect actual data.
- [x] Add `Future<List<IncidentHistoryRecord>> historySnapshot()` to `NativeIncidentGateway`. If native call fails or returns malformed data, surface an empty/error state without breaking guardian monitoring.

## Task 4: Build History and Details screens

**Files:** Create `history_screens.dart`.

- [x] Implement `IncidentHistoryScreen` matching supplied reference: pale canvas, BANTAY heading, Live status supplied by parent, search field, All/Sent/Cancelled chips, recent incident cards, and no-record/no-match empty states.
- [x] Search locally over incident ID, source/type, formatted date, and contact name. Do not treat free text as a semantic query.
- [x] `All` shows all records. `Sent` includes only carrier-accepted (`sent`) or delivered (`delivered`) outcomes. `Cancelled` includes only canceled countdowns. Failed, queued, sending, and unknown remain visible in All with their true labels.
- [x] Each card shows actual source, date/time, measured impact only when present, and actual outcome. Tap opens matching record details.
- [x] Implement `IncidentDetailsScreen` following reference section order: heading/date, detection information, ID/type, ordered timeline, emergency contact/response, technical facts, exact SMS preview only when stored, and Back to Incident History.
- [x] For manual SOS, omit fall-only detection fields. For missing facts, show `Unavailable`. Never infer countdown expiry from a send state or an SMS outcome from countdown expiry.
- [x] Keep presentation components driven only by passed records and callbacks; do not create demo fixtures.

## Task 5: Wire navigation and refresh behavior

**Files:** Modify `product_app.dart`.

- [x] Add `history` and `incidentDetails` page states, selected-record ID, history records, search query, and filter state to `_ProductHomeState`.
- [x] Load journal records after initialization and refresh after native incident/SMS state events, including cancellation and terminal status.
- [x] Add Guardian and History destinations in a bottom navigation bar on the corresponding screens. Preserve search/filter values while a Details page is open.
- [x] On detail Back, return to History without clearing the prior filter/query; on a missing selected record, return safely to History after refresh.
- [x] Add a Settings gear beside the existing Live pill in Guardian's top app bar. It opens the existing setup/contact screen. When a saved contact already exists, expose a way back to Guardian without requiring a new incident or clearing journal data.
- [x] Keep countdown rendering and incident/SMS send behavior unchanged; the journal and screens must not gate detection or SMS.

## Task 6: Update module documentation

**Files:** Update `docs/path1-module.md` and `docs/ui-flow.md`.

- [x] Document native SQLite journal ownership, fields, event source, and app-private retention/reset behavior.
- [x] Document History/Details navigation and that search/filter work only on saved real incidents.
- [x] Remove stale claims that imply semantic/conversational History search or fabricated evaluation rows are part of this UI.

## Execution constraints

- The user authorized implementation and explicitly prohibited commits/pushes. Keep every change local; do not run Git commit or push.
- Do not add or run tests for this task. No automated-test claim should be made.
- Preserve all pre-existing working-tree changes; only edit files listed above.

## Self-review

- Spec coverage: real-only local records and honest empty state (Tasks 1–4); actual timeline/status and nullable facts (Tasks 1–4); search and all three filters (Task 4); Back restores query/filter (Task 5); gear beside Live and existing setup flow (Task 5); process-restart persistence and app-data reset (Task 1); local-only storage and no alert blocking (Tasks 1–2, 5); docs (Task 6).
- Placeholder scan: no TBD/TODO implementation steps; schema columns, native transition points, channel name, UI responsibilities, and navigation state are specified above.
- Type consistency: native history returns record maps through the existing alert channel; Dart parser owns `IncidentHistoryRecord` and `IncidentTimelineEvent`; UI receives parsed records and callbacks. Runtime persists `GuardianState` snapshots through `IncidentJournal`.
