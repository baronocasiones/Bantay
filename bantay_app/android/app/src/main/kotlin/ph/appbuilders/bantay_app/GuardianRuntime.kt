package ph.appbuilders.bantay_app

import java.util.concurrent.atomic.AtomicBoolean

/** Durable incident state, so a countdown survives service and process death. */
interface IncidentStore {
    fun load(): GuardianState?
    fun save(state: GuardianState)
    fun clear()
}

/** In-memory store. Production uses [SharedPrefsIncidentStore]. */
class MemoryIncidentStore : IncidentStore {
    private var saved: GuardianState? = null
    override fun load(): GuardianState? = saved
    override fun save(state: GuardianState) { saved = state }
    override fun clear() { saved = null }
}

/**
 * The Path 1 incident chain, owned by the service rather than by Flutter.
 *
 * Why it lives here: [FallWatchService] used to hand every accelerometer batch
 * to Dart and return early when no Flutter engine was attached. The Flutter
 * engine dies with the Activity, so rotating the screen or leaving the app
 * stopped detection mid-incident and silently dropped a pending countdown. The
 * cascade now runs on the service's own HandlerThread and the countdown is
 * driven by a [android.os.Handler] on that same thread, so a confirmed fall
 * still sends its SMS with the Activity gone.
 *
 * Flutter is a viewer and a source of user intent (arm, cancel, send now,
 * override wording). It is never in the path between an impact and the SMS.
 *
 * All state changes funnel through [commit], which is the only place the state
 * is persisted, pushed to Dart, and acted on. Every public method that changes
 * state is safe to call from any thread: the transitions are pure functions on
 * [GuardianStateMachine] and [commit] is synchronized.
 *
 * @param store durable incident state.
 * @param sendSms blocking send; returns the outbox state string.
 * @param emit pushes snapshots to Dart; called on the caller's thread.
 * @param now wall clock in epoch millis.
 * @param zoneOffsetMs fixed offset used to render the incident time.
 * @param elapsedRealtimeMs monotonic clock matching [CascadeDetector]'s input;
 *   injectable so the cascade-to-incident path is testable off-device.
 * @param countdownMs override for tests; production uses
 *   [GuardianStateMachine.COUNTDOWN_MS].
 */
class GuardianRuntime(
    private val store: IncidentStore,
    private val sendSms: (incidentId: String, number: String, text: String) -> String,
    private val emit: (GuardianState) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
    private val zoneOffsetMs: () -> Long = { java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong() },
    private val elapsedRealtimeMs: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val countdownMs: Long = GuardianStateMachine.COUNTDOWN_MS,
) {
    private val detector = CascadeDetector()
    private val lock = Any()
    private var state: GuardianState = store.load() ?: GuardianState()

    /** Guards [maybeAutoSend] so a retry cannot race a manual SEND HELP. */
    private val sending = AtomicBoolean(false)

    /** Diagnostics are debug-only and never gate an alert. */
    val diagnostics: DetectorDiagnostics get() = detector.diagnostics

    fun snapshot(): GuardianState = synchronized(lock) { state }

    // ---- intent from Flutter -------------------------------------------------

    /** Arms monitoring with a validated contact. Idempotent. */
    fun arm(contactName: String, number: String): GuardianState = synchronized(lock) {
        commit(GuardianStateMachine.arm(state, contactName.trim(), number.trim()))
        state
    }

    fun disarm(): GuardianState = synchronized(lock) {
        commit(GuardianStateMachine.disarm(state))
        state
    }

    /**
     * Path 2 wording, arriving while the countdown runs. Accepted only before
     * the deadline; after it the fixed text has already left the device.
     */
    fun setIncidentText(incidentId: String, text: String): Boolean = synchronized(lock) {
        if (state.incidentId != incidentId || state.stage != "counting") return false
        if (now() >= (state.deadlineEpochMs ?: 0L)) return false
        if (text.isBlank() || text.length > 320 || text.any { it == '\n' || it == '\r' }) return false
        commit(state.copy(text = text))
        true
    }

    fun cancel(incidentId: String): GuardianState = synchronized(lock) {
        commit(GuardianStateMachine.cancel(state, incidentId))
        state
    }

    /** User pressed SEND HELP, or the deadline expired. Sends once. */
    fun sendNow(incidentId: String): GuardianState = synchronized(lock) {
        beginSend(incidentId)
        snapshot()
    }

    fun startManualSos(): GuardianState = synchronized(lock) {
        if (!state.armed) return state
        val occurredAt = now()
        val text = GuardianAlertText.sos(
            GuardianAlertText.timeText(occurredAt, zoneOffsetMs()),
        )
        val began = GuardianStateMachine.begin(
            state, nextIncidentId(occurredAt), occurredAt,
            peakG = 0.0, beforeImpact = "manual", stillnessSeconds = 0,
            manual = true, text = text,
        )
        commit(began)
        beginSend(began.incidentId ?: return snapshot())
        snapshot()
    }

    // ---- sensor intake, service thread only ----------------------------------

    /** Feeds the cascade. Returns non-null when a fall was confirmed. */
    fun feedSample(tMs: Double, xG: Double, yG: Double, zG: Double): FallImpact? =
        detector.add(tMs, xG, yG, zG)

    /** Called with the confirmed impact; begins the countdown if armed. */
    fun beginFromImpact(impact: FallImpact): GuardianState = synchronized(lock) {
        val contactName = state.contactName
        val number = state.number
        if (!state.armed) return state
        val timeText = GuardianAlertText.timeText(
            impact.detectedTMs.toLong() + bootEpochOffsetMs(),
            zoneOffsetMs(),
        )
        val text = GuardianAlertText.fall(
            impact.peakG, timeText, impact.stillnessSeconds,
        )
        val began = GuardianStateMachine.begin(
            state, nextIncidentId(impact.detectedTMs.toLong()), now(),
            impact.peakG, impact.beforeImpact, impact.stillnessSeconds,
            manual = false, text = text,
        )
        commit(began)
        return began
    }

    /**
     * Countdown tick. Call from the service thread on a fixed period; a
     * restart with a pending countdown calls this once on attach and sends
     * immediately if the deadline already passed.
     */
    fun tick(): GuardianState = synchronized(lock) {
        val current = state
        if (!GuardianStateMachine.isDue(current, now())) return current
        beginSend(current.incidentId ?: return current)
        return snapshot()
    }

    /** Carrier callbacks update both persisted incident state and Flutter snapshot. */
    fun onSmsState(incidentId: String, smsState: String, error: String?): GuardianState =
        synchronized(lock) {
            val next = GuardianStateMachine.sms(state, incidentId, smsState, error)
            if (next != state) commit(next)
            state
        }

    /** Complete crash window after persisted "sending" but before outbox insert. */
    fun resumeSending(): GuardianState = synchronized(lock) {
        if (state.stage != "sending") return state
        val id = state.incidentId ?: return state
        val number = state.number
        val text = state.text ?: return state
        if (number.isBlank()) return state
        val outboxState = runCatching { sendSms(id, number, text) }.getOrElse { "failed" }
        val next = GuardianStateMachine.sms(state, id, outboxState, null)
        if (next != state) commit(next)
        state
    }

    /** True while a countdown is running, so the service can schedule its tick. */
    fun isCounting(): Boolean = synchronized(lock) { state.stage == "counting" }

    fun deadlineRemainingMs(): Long = synchronized(lock) {
        val deadline = state.deadlineEpochMs ?: return -1L
        (deadline - now()).coerceAtLeast(0L)
    }

    // ---- internals ----------------------------------------------------------

    /**
     * The only path to an SMS.
     *
     * [GuardianStateMachine.send] already refuses to leave "counting", so
     * calling this twice, or after a cancel, or after a previous send, is a
     * no-op. That is what makes "exactly one SMS per incident" a property of
     * the state machine rather than something each caller has to remember.
     */
    private fun beginSend(incidentId: String?) {
        if (incidentId == null) return
        val staged = GuardianStateMachine.send(state, incidentId)
        if (staged.stage != "sending") return
        commit(staged)
        val number = staged.number
        val text = staged.text
        if (number.isBlank() || text.isNullOrBlank()) return
        // One send at a time per runtime; a retry cannot race a manual send.
        if (!sending.compareAndSet(false, true)) return
        try {
            val stateString = runCatching { sendSms(incidentId, number, text) }
                .getOrElse { "failed" }
            commit(GuardianStateMachine.sms(state, incidentId, stateString, null))
        } finally {
            sending.set(false)
        }
    }

    private fun commit(next: GuardianState) {
        state = next
        store.save(next)
        emit(next)
    }

    private fun nextIncidentId(atMs: Long): String = "INC-" + atMs + "-" + java.util.UUID.randomUUID()

    /**
     * CascadeDetector works in SystemClock.elapsedRealtime millis; the incident
     * record and SMS need epoch millis. The offset between them is stable for
     * the life of the process (elapsedRealtime counts since boot), so it is
     * measured once rather than per sample.
     */
    private var bootOffset: Long? = null
    private fun bootEpochOffsetMs(): Long =
        bootOffset ?: (now() - elapsedRealtimeMs()).also { bootOffset = it }

    fun resetDetector() = detector.reset()

    fun suppressFor(durationMs: Double, nowMs: Double) = detector.suppressFor(durationMs, nowMs)
}
