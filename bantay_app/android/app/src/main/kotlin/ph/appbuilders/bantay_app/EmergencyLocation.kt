package ph.appbuilders.bantay_app

import java.util.Locale
import kotlin.math.ceil

/** A location captured for an emergency alert. */
data class EmergencyLocation(
    val latitude: Double,
    val longitude: Double,
    val capturedAtEpochMs: Long,
    val accuracyMeters: Float,
) {
    fun isUsable(nowEpochMs: Long, maxAgeMs: Long): Boolean =
        latitude.isFinite() && longitude.isFinite() &&
            latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            accuracyMeters.isFinite() && accuracyMeters >= 0f &&
            accuracyMeters <= 5_000f &&
            capturedAtEpochMs <= nowEpochMs && nowEpochMs - capturedAtEpochMs <= maxAgeMs

    fun toSmsSuffix(): String = String.format(
        Locale.US,
        "GPS: %.5f,%.5f +/- %dm",
        latitude, longitude, ceil(accuracyMeters).toInt(),
    )
}

/** Android-free seam so the countdown remains testable without a device. */
interface EmergencyLocationSource {
    fun requestCurrent(onLocation: (EmergencyLocation?) -> Unit)
    fun recentLocation(): EmergencyLocation?
}
