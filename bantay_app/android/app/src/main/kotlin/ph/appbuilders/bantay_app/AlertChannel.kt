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
}

fun SmsOutboxRecord.toEvent(): Map<String, Any?> = mapOf(
    "incidentId" to incidentId,
    "state" to state,
    "error" to error,
)
