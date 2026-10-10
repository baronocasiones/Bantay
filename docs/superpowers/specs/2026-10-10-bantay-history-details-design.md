# Bantay History and Incident Details

**Status:** Approved; implemented locally  
**Scope:** Local incident history and the two supplied Flutter screens.

## Goal

Add the Incident History and Incident Details screens shown in the supplied
Figma exports. Render real on-device incident data only. Never seed screenshot
names, dates, impact values, or delivery states as app records.

## Data and lifecycle

The current app persists only the active guardian state and SMS outbox. It does
not retain cancelled incidents or the complete detection facts needed by these
screens. Add a private, local incident journal owned by the native Path 1
incident chain. Record automatic falls and manual SOS incidents, including:

- incident ID, occurrence time, automatic/manual source, impact strength, and
  limited-movement duration when available;
- contact used and incident facts captured at detection;
- real timeline transitions: detected/countdown started, cancelled or countdown
  expired/send started, and the resulting SMS state;
- the exact outgoing SMS text when an outbox entry exists.

Append timeline entries only when their corresponding state transition occurs.
Keep records on-device; app data reset clears them. Existing data that lacks
complete facts must not be presented as if those facts were known. History may
start empty and fill as new incidents occur.

## History screen

- Match the supplied pale background, BANTAY header, Live indicator, search
  field, rounded filter chips, incident cards, and bottom navigation.
- Place the Settings gear beside Live in the top app bar, per user direction.
  Route it to the existing setup/contact flow; do not add a separate Settings
  screen in this scope.
- Filters: All, Sent, and Cancelled. Sent includes carrier-accepted/delivered
  alerts. Failed, queued, sending, and unknown outcomes remain visible under
  All with their actual labels.
- Search locally by incident ID, incident type, date, or contact name. It is a
  text filter, not conversational or semantic recall.
- Show an honest empty state when no records match. Do not insert demo rows.
- Guardian and History are the bottom navigation destinations. A History card
  opens its detail; Guardian returns to the dashboard.

## Incident Details screen

- Match the supplied section hierarchy: incident heading and date; detection
  information; incident ID and detection type; timeline; emergency response;
  technical details; and Back to Incident History.
- Populate every value from the saved record. Show unavailable for absent facts;
  omit fields that do not apply to manual SOS.
- Timeline wording and times must follow recorded transitions. Cancellation,
  countdown expiry, and SMS outcome must not be inferred from one another.
- Show exact SMS preview only when an outbox entry exists. Cancelled incidents
  have no SMS preview. Failed or uncertain outcomes must remain truthful.
- Back returns to the prior History query/filter state.

## Architecture and boundaries

Keep sensor detection and SMS sending native and independent of Flutter UI
lifecycle. The native journal records state transitions; a narrow MethodChannel
API exposes history snapshots/details to Flutter. Flutter owns presentation,
search, filters, and navigation only. No network sync or account system.

## Acceptance criteria

1. Empty state appears with no saved incidents; no fabricated screenshot data
   appears.
2. A real manual SOS and automatic fall each create one history item with
   truthful facts and SMS state.
3. A cancelled countdown appears as Cancelled and has no SMS preview.
4. Search and all three filters return only matching saved records.
5. Opening a card shows its stored facts and actual timeline; Back restores the
   prior History state.
6. Gear appears beside Live and opens the existing setup/contact flow.
7. Records survive app process restart and remain local; clearing app data
   clears the journal.
