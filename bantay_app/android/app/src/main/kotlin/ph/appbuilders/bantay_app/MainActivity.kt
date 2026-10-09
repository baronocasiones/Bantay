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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SensorChannel.NAME,
        )
        channel.setMethodCallHandler { call, result -> handleSensorCall(call, result) }
        SensorChannel.channel = channel
        sensorsChannel = channel
    }

    override fun onDestroy() {
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
    }
}
