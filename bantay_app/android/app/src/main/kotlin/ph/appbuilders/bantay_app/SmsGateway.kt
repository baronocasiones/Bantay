package ph.appbuilders.bantay_app

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat

/** Saves exact SMS body before dispatch, then tracks system sent/delivery callbacks. */
object SmsGateway {
    private const val ACTION_SENT = "ph.appbuilders.bantay_app.SMS_SENT"
    private const val ACTION_DELIVERED = "ph.appbuilders.bantay_app.SMS_DELIVERED"
    private const val EXTRA_ID = "incidentId"
    private const val EXTRA_ATTEMPT = "attempt"
    private const val EXTRA_PART = "part"
    private var store: SmsOutboxDb? = null
    private val main = Handler(Looper.getMainLooper())
    private val scheduledReconciles = mutableSetOf<String>()
    private fun database(context: Context): SmsOutboxDb =
        store ?: SmsOutboxDb(context.applicationContext).also { store = it }

    @Synchronized fun enqueue(context: Context, id: String, number: String, body: String): SmsOutboxRecord {
        val db = database(context)
        val existing = db.get(id)
        if (existing != null) return existing // Duplicate id can never change recipient or text.
        val record = SmsOutboxState.enqueue(null, id, number, body)
        persist(context, db, record)
        return dispatch(context, record)
    }

    @Synchronized fun snapshot(context: Context): List<Map<String, Any?>> {
        reconcileInFlight(context)
        return database(context).all().map {
            it.toEvent() + mapOf("number" to it.number, "text" to it.body, "attempts" to it.attempts)
        }
    }

    @Synchronized fun retryQueued(context: Context) {
        reconcileInFlight(context)
        database(context).all().filter(SmsOutboxState::shouldRetry).forEach {
            dispatch(context, it)
        }
    }

    @Synchronized fun recordForIncident(context: Context, id: String): SmsOutboxRecord? {
        reconcileInFlight(context)
        return database(context).get(id)
    }

    /** Missing sent callbacks leave outcome unknown; never resend that record. */
    @Synchronized fun reconcileInFlight(context: Context) {
        val db = database(context)
        val now = System.currentTimeMillis()
        db.all().filter { it.state == "sending" }.forEach { current ->
            val next = SmsOutboxState.reconcile(current, now)
            if (next != current) {
                persist(context, db, next)
            } else if (scheduledReconciles.add(current.incidentId)) {
                val remaining = (current.attemptStartedAtEpochMs + 60_000L - now)
                    .coerceAtLeast(1L)
                val app = context.applicationContext
                main.postDelayed({
                    synchronized(this) { scheduledReconciles.remove(current.incidentId) }
                    runCatching { reconcileInFlight(app) }
                }, remaining)
            }
        }
    }

    private fun hasPermission(context: Context) = ContextCompat.checkSelfPermission(
        context, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    @Synchronized private fun dispatch(context: Context, record: SmsOutboxRecord): SmsOutboxRecord {
        if (record.state != "queued") return record
        val db = database(context)
        if (!hasPermission(context)) {
            val queued = record.copy(error = "sms_permission_required")
            return persist(context, db, queued)
        }
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_MESSAGING)) {
            return persist(context, db, SmsOutboxState.fail(record, "sms_not_supported"))
        }
        val subscriptionId = try {
            SubscriptionManager.getDefaultSmsSubscriptionId()
        } catch (_: RuntimeException) {
            SubscriptionManager.INVALID_SUBSCRIPTION_ID
        }
        if (subscriptionId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
            val queued = record.copy(error = "no_default_sms_sim")
            return persist(context, db, queued)
        }

        return try {
            @Suppress("DEPRECATION")
            val sms = SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            val parts = sms.divideMessage(record.body)
            if (parts.isEmpty()) return persist(context, db, SmsOutboxState.fail(record, "empty_sms"))
            val sending = persist(context, db, SmsOutboxState.dispatch(record, parts.size, System.currentTimeMillis()))
            val sent = ArrayList<PendingIntent>(parts.size)
            val delivered = ArrayList<PendingIntent>(parts.size)
            parts.indices.forEach { part ->
                sent += pending(context, ACTION_SENT, sending, part)
                delivered += pending(context, ACTION_DELIVERED, sending, part)
            }
            reconcileInFlight(context)
            if (parts.size == 1) {
                sms.sendTextMessage(record.number, null, parts[0], sent[0], delivered[0])
            } else {
                sms.sendMultipartTextMessage(record.number, null, parts, sent, delivered)
            }
            sending
        } catch (_: SecurityException) {
            persist(context, db, record.copy(state = "queued", error = "sms_permission_required"))
        } catch (_: IllegalArgumentException) {
            persist(context, db, SmsOutboxState.fail(record, "invalid_sms"))
        } catch (_: UnsupportedOperationException) {
            persist(context, db, SmsOutboxState.fail(record, "sms_not_supported"))
        } catch (_: RuntimeException) {
            // We cannot prove whether the modem accepted some parts. Never
            // auto-retry an ambiguous dispatch: duplicate SMS is worse.
            persist(context, db, SmsOutboxState.fail(record, "sms_dispatch_error"))
        }
    }

    private fun pending(context: Context, action: String, record: SmsOutboxRecord, part: Int): PendingIntent {
        val uri = Uri.Builder().scheme("bantay-sms").authority("status")
            .appendPath(record.incidentId).appendPath(record.attempts.toString())
            .appendPath(part.toString()).appendPath(action).build()
        val intent = Intent(context, SmsStatusReceiver::class.java).apply {
            this.action = action
            data = uri
            putExtra(EXTRA_ID, record.incidentId)
            putExtra(EXTRA_ATTEMPT, record.attempts)
            putExtra(EXTRA_PART, part)
        }
        return PendingIntent.getBroadcast(context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    @Synchronized fun onStatus(context: Context, intent: Intent, resultCode: Int) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val attempt = intent.getIntExtra(EXTRA_ATTEMPT, -1)
        val part = intent.getIntExtra(EXTRA_PART, -1)
        val db = database(context)
        val current = db.get(id) ?: return
        if (current.attempts != attempt || part !in 0 until current.partCount) return
        val next = when (intent.action) {
            ACTION_SENT -> if (resultCode == Activity.RESULT_OK) {
                SmsOutboxState.sentPart(current, part)
            } else {
                val error = when (resultCode) {
                    SmsManager.RESULT_ERROR_RADIO_OFF -> "radio_off"
                    SmsManager.RESULT_ERROR_NO_SERVICE -> "no_service"
                    else -> "sms_error_$resultCode"
                }
                SmsOutboxState.failedPart(current, part, error)
            }
            ACTION_DELIVERED -> if (resultCode == Activity.RESULT_OK) {
                SmsOutboxState.deliveredPart(current, part)
            } else {
                // SMS was sent but network delivery failed/unknown. Preserve
                // 'sent'; never claim 'delivered' or blindly send duplicate.
                current.copy(error = "delivery_unconfirmed")
            }
            else -> return
        }
        if (next != current) persist(context, db, next)
    }

    private fun persist(context: Context, db: SmsOutboxDb, record: SmsOutboxRecord): SmsOutboxRecord {
        db.put(record)
        AlertChannel.post(record)
        val app = context.applicationContext
        main.post { runCatching { Guardian.reconcile(app) } }
        return record
    }
}
