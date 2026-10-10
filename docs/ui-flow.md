# BANTAY — UI Flow

Demo scope only. No auth, no accounts, seven screens.

![UI flow](assets/bantay-ui-flow.jpg)

Source: `docs/assets/bantay-ui-flow.jpg`

---

## Screens

### 1 · Setup (one-time)

Pick emergency contact → calibrate baseline ("walk normally ~20 s") → arm.
Single primary button: **Arm Guardian**.

### 2 · Guardian Active

Status badge `◉ LIVE`. Centered "watching for you" with a calm breathing pulse.

- Stat rows: baseline (your gait) · last incident · sensitivity
- Live accel waveform strip (real-time, not decorative)
- Primary action: **I need help**. Bottom navigation switches Guardian/History;
  Settings gear beside Live opens the existing contact setup flow.

### 3 · Incident

Badge `⚠ COUNTDOWN 15s`. Heading "Detected a 7.2g impact".

Fact card, three lines:
- you were walking
- you haven't moved for 8 seconds
- it's 2:14 AM

Countdown progress bar. Buttons: **I'M OK (cancels)** · **SEND HELP**

`SEND HELP` expands a preview of the exact message before sending.

### 4 · Alert Sent

Confirmation with recipient and timestamp, plus the verbatim message sent
(Tagalog in the demo). Note beneath: the app keeps watching. This is not a
session.

### 5 · History (local, offline)

List of saved real incidents only: date, source, measured impact when
available, contact, and actual SMS/countdown outcome. Filters: All, Sent, and
Cancelled. Search is a local text match over incident ID, type, date, and
contact name; it does not answer conversational questions. No sample incidents
are inserted. A History card opens the matching details record.

### 6 · Incident Details

Shows saved detection facts, incident ID/type, real timeline events, emergency
contact and SMS outcome, technical details, and exact SMS text only when an
outbox record exists. Cancelled incidents have no SMS preview. Unknown facts
stay unavailable; manual SOS omits fall-only details. Back returns to History
with its prior search and filter.

### 7 · Eval

Precision 94% · Recall 91% · F1 92.5%, with proportional bars.
Footer: UCI HAR + synthetic · n=12,400 windows.

This screen exists to win the **Technical Execution** score. Numbers on screen,
not just in the deck.

---

## Flow

```
1 --arm--> 2
2 --IMPACT (emphasized)----------> 3
2 --MANUAL DETECTED--------------> 3
3 --15s expires-----------------> 4
3 --user OKs---------------------> 2
4 --tap History (navigation)-----> 5
5 --tap incident card------------> 6
6 --Back to Incident History-----> 5
5 --tap Eval (navigation)--------> 7
```

Two arrow types in the diagram:

- **Trigger arrow** (red) — a state change the system initiates on its own
- **Navigation arrow** (slate, dashed) — the user tapping through

The distinction matters on stage. The red arrow is the product working. The
grey one is you clicking.

---

## The three demo moments

1. **Screen 3 countdown → "I'M OK"**
   The fear is real and dischargeable. Judges feel it in the room.

2. **Airplane mode on screen 2**
   Turn it on. Nothing changes. Say nothing. Let them notice on their own.

3. **Screen 5 local search and filters**
   Find saved incidents by ID, type, date, or contact without a network.

---

## Deliberate omissions

No login, no signup, no sync, no account recovery, no settings screen beyond
the three setup choices. Anything that isn't load-bearing for the demo is
cut. 24 hours does not buy polish on screens nobody opens on stage.
