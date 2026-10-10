package ph.appbuilders.bantay_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/** Bounded Android location lookup; SMS never waits for this provider. */
class EmergencyLocationProvider(context: Context) : EmergencyLocationSource {
    private val app = context.applicationContext
    private val manager = app.getSystemService(LocationManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun requestCurrent(onLocation: (EmergencyLocation?) -> Unit) {
        if (!hasLocationPermission() || manager == null) {
            onLocation(null)
            return
        }

        val done = AtomicBoolean(false)
        val cancellations = mutableListOf<CancellationSignal>()
        val timeout = Runnable {
            if (done.compareAndSet(false, true)) {
                cancellations.forEach(CancellationSignal::cancel)
                onLocation(null)
            }
        }
        mainHandler.postDelayed(timeout, REQUEST_TIMEOUT_MS)

        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { provider -> runCatching { manager.isProviderEnabled(provider) }.getOrDefault(false) }
        if (providers.isEmpty()) {
            mainHandler.removeCallbacks(timeout)
            if (done.compareAndSet(false, true)) onLocation(null)
            return
        }
        providers.forEach { provider ->
            val cancellation = CancellationSignal()
            cancellations += cancellation
            runCatching {
                manager.getCurrentLocation(provider, cancellation, app.mainExecutor) { location ->
                    if (location != null) {
                        val fix = location.toEmergencyLocation()
                        if (fix.isUsable(System.currentTimeMillis(), FALL_MAX_AGE_MS) &&
                            done.compareAndSet(false, true)
                        ) {
                            mainHandler.removeCallbacks(timeout)
                            cancellations.forEach(CancellationSignal::cancel)
                            onLocation(fix)
                        }
                    }
                }
            }.onFailure { cancellation.cancel() }
        }
    }

    override fun recentLocation(): EmergencyLocation? {
        if (!hasLocationPermission() || manager == null) return null
        val now = System.currentTimeMillis()
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .mapNotNull { provider -> runCatching { manager.getLastKnownLocation(provider) }.getOrNull() }
            .map { it.toEmergencyLocation() }
            .filter { it.isUsable(now, MANUAL_MAX_AGE_MS) }
            .minByOrNull { it.accuracyMeters }
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(app, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun Location.toEmergencyLocation() = EmergencyLocation(
        latitude = latitude,
        longitude = longitude,
        capturedAtEpochMs = time,
        accuracyMeters = if (hasAccuracy()) accuracy else Float.MAX_VALUE,
    )

    private companion object {
        const val REQUEST_TIMEOUT_MS = 10_000L
        const val FALL_MAX_AGE_MS = 30_000L
        const val MANUAL_MAX_AGE_MS = 120_000L
    }
}
