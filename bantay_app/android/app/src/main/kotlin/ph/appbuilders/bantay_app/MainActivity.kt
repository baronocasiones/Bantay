package ph.appbuilders.bantay_app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Wires the sensor MethodChannel and owns the transition from "visible
 * activity" to "foreground service", which is the only legal way to start a
 * health FGS on Android 12+.
 */
class MainActivity : FlutterActivity() {
    private var sensorsChannel: MethodChannel? = null
    private var alertsChannel: MethodChannel? = null
    private var smsPermissionResult: MethodChannel.Result? = null
    private var locationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SensorChannel.NAME,
        )
        channel.setMethodCallHandler { call, result -> handleSensorCall(call, result) }
        SensorChannel.channel = channel
        sensorsChannel = channel
        val alerts = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AlertChannel.NAME)
        alerts.setMethodCallHandler { call, result -> handleAlertCall(call, result) }
        AlertChannel.channel = alerts
        alertsChannel = alerts
        runCatching { SmsGateway.retryQueued(this) }
        runCatching { Guardian.reconcile(this) }
    }

    override fun onDestroy() {
        smsPermissionResult?.success(false)
        smsPermissionResult = null
        locationPermissionResult?.success(false)
        locationPermissionResult = null
        AlertChannel.channel = null
        alertsChannel?.setMethodCallHandler(null)
        alertsChannel = null
        SensorChannel.channel = null
        sensorsChannel?.setMethodCallHandler(null)
        sensorsChannel = null
        super.onDestroy()
    }

    private fun handleSensorCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            SensorChannel.METHOD_START -> {
                // Best effort: without the notification permission the service
                // still runs, the persistent notification is just invisible.
                // Never block sampling on a runtime dialog.
                ensureNotificationVisibility()
                ContextCompat.startForegroundService(
                    this,
                    Intent(this, FallWatchService::class.java)
                        .setAction(FallWatchService.ACTION_START),
                )
                result.success(null)
            }
            SensorChannel.METHOD_STOP -> {
                startService(
                    Intent(this, FallWatchService::class.java)
                        .setAction(FallWatchService.ACTION_STOP)
                )
                result.success(null)
            }
            SensorChannel.METHOD_ATTACH -> {
                FallWatchService.attachConsumer()
                result.success(null)
            }
            SensorChannel.METHOD_DETACH -> {
                FallWatchService.detachConsumer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Flutter-facing contract for the native incident chain.
     *
     * Flutter is a viewer and a source of intent here. Every method either
     * reads state out of [Guardian] or asks it to transition; none of them
     * decides anything about detection, and none of them can block the chain.
     * The activity that forwards these calls may be destroyed mid-incident and
     * the service keeps counting down regardless — which is the whole point of
     * [GuardianRuntime] living in the service.
     */
    private fun handleAlertCall(call: MethodCall, result: MethodChannel.Result) {
        val guardian = runCatching { Guardian.runtime(this) }.getOrNull()
        when (call.method) {
            "armGuardian" -> {
                if (guardian == null) return result.resultUnavailable()
                val name = call.argument<String>("contactName")?.trim().orEmpty()
                val number = call.argument<String>("number")?.trim().orEmpty()
                if (name.isEmpty() || number.isEmpty()) {
                    return result.resultUnavailable()
                }
                result.success(guardian.arm(name, number).toMap())
            }
            "disarmGuardian" -> {
                if (guardian == null) return result.resultUnavailable()
                result.success(guardian.disarm().toMap())
            }
            "incidentSnapshot" -> {
                if (guardian == null) return result.resultUnavailable()
                result.success(Guardian.reconcile(this).toMap())
            }
            "detectorDiagnostics" -> {
                if (guardian == null) return result.resultUnavailable()
                result.success(guardian.diagnostics.toMap())
            }
            "startManualSos" -> {
                if (guardian == null) return result.resultUnavailable()
                result.success(guardian.startManualSos().toMap())
            }
            "cancelIncident" -> {
                if (guardian == null) return result.resultUnavailable()
                val id = call.argument<String>("incidentId")?.trim().orEmpty()
                if (id.isEmpty()) return result.resultUnavailable()
                result.success(guardian.cancel(id).toMap())
            }
            "sendHelpNow" -> {
                if (guardian == null) return result.resultUnavailable()
                val id = call.argument<String>("incidentId")?.trim().orEmpty()
                if (id.isEmpty()) return result.resultUnavailable()
                result.success(guardian.sendNow(id).toMap())
            }
            "setIncidentText" -> {
                if (guardian == null) return result.resultUnavailable()
                val id = call.argument<String>("incidentId")?.trim().orEmpty()
                val text = call.argument<String>("text").orEmpty()
                if (id.isEmpty()) return result.resultUnavailable()
                result.success(guardian.setIncidentText(id, text))
            }
            "smsPermissionStatus" -> result.success(hasSmsPermission())
            "requestSmsPermission" -> {
                if (hasSmsPermission()) {
                    runCatching { SmsGateway.retryQueued(this) }
                    result.success(true)
                } else if (smsPermissionResult != null) {
                    result.success(false)
                } else {
                    smsPermissionResult = result
                    requestPermissions(arrayOf(Manifest.permission.SEND_SMS), REQUEST_SMS)
                }
            }
            "requestLocationPermission" -> {
                if (hasLocationPermission()) {
                    result.success(true)
                } else if (locationPermissionResult != null) {
                    result.success(false)
                } else {
                    locationPermissionResult = result
                    requestPermissions(LOCATION_PERMISSIONS, REQUEST_LOCATION)
                }
            }
            "sendSms" -> {
                val id = call.argument<String>("incidentId")?.trim().orEmpty()
                val number = call.argument<String>("number")?.trim().orEmpty()
                val body = call.argument<String>("text").orEmpty()
                if (id.isEmpty() || number.isEmpty() || body.isBlank()) {
                    result.success(mapOf("incidentId" to id, "state" to "failed", "error" to "invalid_sms_request"))
                } else {
                    try {
                        result.success(SmsGateway.enqueue(this, id, number, body).toEvent())
                    } catch (_: RuntimeException) {
                        result.success(mapOf("incidentId" to id, "state" to "failed", "error" to "outbox_unavailable"))
                    }
                }
            }
            "outboxSnapshot" -> {
                try {
                    result.success(SmsGateway.snapshot(this))
                } catch (_: RuntimeException) {
                    result.success(emptyList<Map<String, Any?>>())
                }
            }
            "incidentHistorySnapshot" -> {
                try {
                    val outboxById = SmsGateway.snapshot(this).associateBy { it["incidentId"] }
                    val records = Guardian.historySnapshot(applicationContext).map { record ->
                        val outbox = outboxById[record.incidentId]
                        record.copy(
                            stage = outbox?.get("state") as? String ?: record.stage,
                            smsText = outbox?.get("text") as? String,
                            error = outbox?.get("error") as? String ?: record.error,
                        ).toMap()
                    }
                    result.success(mapOf("records" to records))
                } catch (_: Exception) {
                    result.success(mapOf("error" to "history_unavailable"))
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Answers a call that could not be served with the chain unavailable. Sends
     * the app's own "unavailable" state rather than throwing, so Flutter
     * degrades to the fixed alert instead of crashing.
     */
    private fun MethodChannel.Result.resultUnavailable() {
        success(mapOf("stage" to "unavailable", "error" to "incident_chain_unavailable"))
    }

    private fun hasSmsPermission() = ContextCompat.checkSelfPermission(
        this, Manifest.permission.SEND_SMS,
    ) == PackageManager.PERMISSION_GRANTED

    private fun hasLocationPermission() = LOCATION_PERMISSIONS.any {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_SMS) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            smsPermissionResult?.success(granted)
            smsPermissionResult = null
            if (granted) runCatching { SmsGateway.retryQueued(this) }
        } else if (requestCode == REQUEST_LOCATION) {
            val granted = permissions.indices.any { index ->
                permissions[index] in LOCATION_PERMISSIONS &&
                    grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            }
            locationPermissionResult?.success(granted)
            locationPermissionResult = null
        }
    }

    private fun ensureNotificationVisibility() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS,
            )
        }
    }

    private companion object {
        const val REQUEST_NOTIFICATIONS = 6301
        const val REQUEST_SMS = 6302
        const val REQUEST_LOCATION = 6303
        val LOCATION_PERMISSIONS = arrayOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
    }
}
