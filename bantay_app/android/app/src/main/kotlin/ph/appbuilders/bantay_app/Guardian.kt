package ph.appbuilders.bantay_app

import android.content.Context

/**
 * Process-wide owner of the one [GuardianRuntime].
 *
 * Both [FallWatchService] and [MainActivity] must reach the *same* runtime:
 * the service detects and counts down, the activity forwards user intent
 * (arm, cancel, send help, Path 2 wording). Two runtimes would mean two
 * detectors and a countdown that survives the Activity but ignores the cancel
 * button, which is the bug this seam exists to prevent.
 *
 * Created lazily from an application context, so it survives Activity
 * recreation. The SMS send is a thin lambda over [SmsGateway], which keeps the
 * runtime free of Android imports and unit-testable.
 */
object Guardian {
    @Volatile
    private var runtime: GuardianRuntime? = null

    fun runtime(context: Context): GuardianRuntime =
        runtime ?: synchronized(this) {
            runtime ?: build(context.applicationContext).also { runtime = it }
        }

    private fun build(app: Context): GuardianRuntime = GuardianRuntime(
        store = SharedPrefsIncidentStore(app),
        sendSms = { id, number, text ->
            SmsGateway.enqueue(app, id, number, text).state
        },
        emit = { AlertChannel.postState(it) },
    )

    /** Reattach/restart recovery: outbox is authoritative for any staged send. */
    fun reconcile(context: Context): GuardianState {
        val app = context.applicationContext
        val current = runtime(app)
        if (current.isCounting()) current.tick()
        val id = current.snapshot().incidentId
        if (id != null) {
            val outbox = SmsGateway.recordForIncident(app, id)
            if (outbox != null) {
                current.onSmsState(id, outbox.state, outbox.error)
            } else if (current.snapshot().stage == "sending") {
                // Outbox insert is durable-before-dispatch. No row means no SMS
                // entered the modem, so resuming this exact incident is safe.
                current.resumeSending()
            }
        }
        return current.snapshot()
    }

    /** Test seam: drops the cached runtime so a fresh one builds on next use. */
    fun resetForTest() {
        synchronized(this) { runtime = null }
    }
}
