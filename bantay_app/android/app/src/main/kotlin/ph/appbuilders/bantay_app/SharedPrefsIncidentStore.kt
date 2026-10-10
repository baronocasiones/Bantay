package ph.appbuilders.bantay_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Durable incident state in app-private preferences.
 *
 * Survives process death and Activity loss. Stores only what is needed to
 * resume: the stage, the deadline, and the exact text already chosen. A message
 * that was mid-send when the process died is resumed by
 * [SmsGateway.retryQueued], which owns the durable record of what actually went
 * out; this store only decides *whether* a countdown is still owed.
 *
 * Deliberately hand-rolled rather than deriving from [GuardianState.toMap],
 * which drops `contactName` and would lose it across a restart.
 */
class SharedPrefsIncidentStore(context: Context) : IncidentStore {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun load(): GuardianState? {
        val raw = prefs.getString(KEY, null) ?: return null
        return runCatching { fromJson(JSONObject(raw)) }.getOrNull()
    }

    override fun save(state: GuardianState) {
        check(prefs.edit().putString(KEY, toJson(state)).commit()) { "incident state not persisted" }
    }

    override fun clear() {
        check(prefs.edit().remove(KEY).commit()) { "incident state not cleared" }
    }

    private fun toJson(state: GuardianState): String = JSONObject().apply {
        put("armed", state.armed)
        put("contactName", state.contactName)
        put("number", state.number)
        put("stage", state.stage)
        put("incidentId", state.incidentId ?: "")
        state.occurredAtEpochMs?.let { put("occurredAtEpochMs", it) }
        state.deadlineEpochMs?.let { put("deadlineEpochMs", it) }
        state.peakG?.let { put("peakG", it) }
        put("beforeImpact", state.beforeImpact ?: "")
        state.stillnessSeconds?.let { put("stillnessSeconds", it) }
        put("manual", state.manual)
        put("text", state.text ?: "")
        put("error", state.error ?: "")
    }.toString()

    private fun fromJson(json: JSONObject) = GuardianState(
        armed = json.optBoolean("armed"),
        contactName = json.optString("contactName", ""),
        number = json.optString("number", ""),
        stage = json.optString("stage", "idle"),
        incidentId = json.optString("incidentId").ifEmpty { null },
        occurredAtEpochMs = if (json.has("occurredAtEpochMs")) json.getLong("occurredAtEpochMs") else null,
        deadlineEpochMs = if (json.has("deadlineEpochMs")) json.getLong("deadlineEpochMs") else null,
        peakG = if (json.has("peakG")) json.getDouble("peakG") else null,
        beforeImpact = json.optString("beforeImpact").ifEmpty { null },
        stillnessSeconds = if (json.has("stillnessSeconds")) json.getInt("stillnessSeconds") else null,
        manual = json.optBoolean("manual"),
        text = json.optString("text").ifEmpty { null },
        error = json.optString("error").ifEmpty { null },
    )

    private companion object {
        const val PREFS = "bantay_guardian_state"
        const val KEY = "incident"
    }
}
