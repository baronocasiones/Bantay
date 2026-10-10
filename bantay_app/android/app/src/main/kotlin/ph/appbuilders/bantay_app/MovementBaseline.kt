package ph.appbuilders.bantay_app

import kotlin.math.sqrt

/**
 * Local, online profile of ordinary accelerometer-magnitude variability.
 * It personalizes only the activity context attached to an event; it never
 * changes any fall-cascade threshold.
 */
data class MovementBaselineSnapshot(
    val windows: Long = 0,
    val meanVariance: Double = 0.0,
    val squaredDeviationTotal: Double = 0.0,
)

class MovementBaseline(
    initial: MovementBaselineSnapshot = MovementBaselineSnapshot(),
    private val onPersist: (MovementBaselineSnapshot) -> Unit = {},
) {
    private var windows = initial.windows.coerceAtLeast(0)
    private var meanVariance = initial.meanVariance.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
    private var squaredDeviationTotal = initial.squaredDeviationTotal
        .takeIf { it.isFinite() && it >= 0.0 } ?: 0.0

    fun snapshot() = MovementBaselineSnapshot(windows, meanVariance, squaredDeviationTotal)

    fun observe(variance: Double) {
        if (!variance.isFinite() || variance < 0.0) return
        windows += 1
        val delta = variance - meanVariance
        meanVariance += delta / windows
        squaredDeviationTotal += delta * (variance - meanVariance)
        // Persist in batches to avoid writing preferences on every sensor window.
        if (windows % PERSIST_EVERY_WINDOWS == 0L) onPersist(snapshot())
    }

    fun classify(variance: Double, fallback: String): String {
        if (!variance.isFinite() || windows < MIN_WINDOWS) return fallback
        val standardDeviation = if (windows > 1) sqrt(squaredDeviationTotal / (windows - 1)) else 0.0
        val stillLimit = (meanVariance * STILL_FRACTION).coerceIn(MIN_STILL_VARIANCE, MAX_STILL_VARIANCE)
        val runningLimit = (meanVariance + RUNNING_SIGMAS * standardDeviation)
            .coerceIn(MIN_RUNNING_VARIANCE, MAX_RUNNING_VARIANCE)
        return when {
            variance < stillLimit -> "still"
            variance > runningLimit -> "running"
            else -> "walking"
        }
    }

    private companion object {
        const val MIN_WINDOWS = 20L
        const val PERSIST_EVERY_WINDOWS = 20L
        const val STILL_FRACTION = 0.2
        const val MIN_STILL_VARIANCE = 0.005
        const val MAX_STILL_VARIANCE = 0.05
        const val RUNNING_SIGMAS = 2.0
        const val MIN_RUNNING_VARIANCE = 0.12
        const val MAX_RUNNING_VARIANCE = 0.5
    }
}
