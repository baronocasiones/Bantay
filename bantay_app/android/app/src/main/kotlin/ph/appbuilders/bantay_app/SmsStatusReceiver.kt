package ph.appbuilders.bantay_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** System PendingIntent callback. Receiver is not exported to other apps. */
class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        runCatching { SmsGateway.onStatus(context, intent, resultCode) }
    }
}
