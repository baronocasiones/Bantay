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
    }

    override fun onDestroy() {
        smsPermissionResult?.success(false)
        smsPermissionResult = null
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

    private fun handleAlertCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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
            else -> result.notImplemented()
        }
    }

    private fun hasSmsPermission() = ContextCompat.checkSelfPermission(
        this, Manifest.permission.SEND_SMS,
    ) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_SMS) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            smsPermissionResult?.success(granted)
            smsPermissionResult = null
            if (granted) runCatching { SmsGateway.retryQueued(this) }
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
    }
}
