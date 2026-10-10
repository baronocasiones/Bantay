package ph.appbuilders.bantay_app

/** Pure incident/countdown transitions; persistence and timer live in GuardianRuntime. */
data class GuardianState(
    val armed: Boolean = false,
    val contactName: String = "",
    val number: String = "",
    val stage: String = "idle",
    val incidentId: String? = null,
    val occurredAtEpochMs: Long? = null,
    val deadlineEpochMs: Long? = null,
    val peakG: Double? = null,
    val beforeImpact: String? = null,
    val stillnessSeconds: Int? = null,
    val manual: Boolean = false,
    val text: String? = null,
    val error: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "armed" to armed,
        "stage" to stage,
        "incidentId" to incidentId,
        "occurredAtEpochMs" to occurredAtEpochMs,
        "deadlineEpochMs" to deadlineEpochMs,
        "peakG" to peakG,
        "beforeImpact" to beforeImpact,
        "stillnessSeconds" to stillnessSeconds,
        "manual" to manual,
        "text" to text,
        "number" to number,
        "error" to error,
    )
}

object GuardianStateMachine {
    const val COUNTDOWN_MS = 15_000L

    fun arm(state: GuardianState, contactName: String, number: String) = state.copy(
        armed = true, contactName = contactName, number = number,
    )

    fun disarm(state: GuardianState) = state.copy(armed = false)

    fun begin(state: GuardianState, id: String, now: Long, peakG: Double,
              beforeImpact: String, stillnessSeconds: Int, manual: Boolean,
              text: String): GuardianState {
        if (!state.armed || state.stage == "counting" || state.stage == "sending") return state
        return state.copy(stage = "counting", incidentId = id,
            occurredAtEpochMs = now, deadlineEpochMs = now + COUNTDOWN_MS,
            peakG = peakG, beforeImpact = beforeImpact,
            stillnessSeconds = stillnessSeconds, manual = manual,
            text = text, error = null)
    }

    fun cancel(state: GuardianState, id: String) =
        if (state.incidentId == id && state.stage == "counting")
            state.copy(stage = "canceled") else state

    fun send(state: GuardianState, id: String) =
        if (state.incidentId == id && state.stage == "counting")
            state.copy(stage = "sending") else state

    fun sms(state: GuardianState, id: String, smsState: String, error: String?) =
        if (state.incidentId == id && state.stage != "canceled")
            state.copy(stage = smsState, error = error) else state

    fun isDue(state: GuardianState, now: Long) =
        state.stage == "counting" && (state.deadlineEpochMs ?: Long.MAX_VALUE) <= now
}
