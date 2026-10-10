package ph.appbuilders.bantay_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Single native-to-Dart SMS state event endpoint. Flutter calls stay on main thread. */
object AlertChannel {
    const val NAME = "ph.appbuilders.bantay_app/alerts"
    @Volatile var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    fun post(record: SmsOutboxRecord) {
        val event = record.toEvent()
        main.post { channel?.invokeMethod("smsState", event) }
    }

    /**
     * Pushes an incident snapshot to whatever engine is attached. A detached
     * engine simply receives nothing: the countdown keeps running in the
     * service and the next attach reads the persisted snapshot.
     */
    fun postState(state: GuardianState) {
        val event = state.toMap()
        main.post { channel?.invokeMethod("incidentState", event) }
    }

    fun postDiagnostics(diagnostics: DetectorDiagnostics) {
        val event = diagnostics.toMap()
        main.post { channel?.invokeMethod("detectorDiagnostics", event) }
    }
}

fun SmsOutboxRecord.toEvent(): Map<String, Any?> = mapOf(
    "incidentId" to incidentId,
    "state" to state,
    "error" to error,
)
