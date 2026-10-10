package ph.appbuilders.bantay_app

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.sqrt

/** Sensor-time fall cascade. Input axes are g; no Android dependency. */
data class FallImpact(
    val impactTMs: Double,
    val detectedTMs: Double,
    val peakG: Double,
    val beforeImpact: String,
    val stillnessSeconds: Int,
)

data class DetectorDiagnostics(
    val lastPeakG: Double = 0.0,
    val impactThresholdCrossed: Boolean = false,
    val rotationDegrees: Double = 0.0,
    val stillnessMs: Double = 0.0,
    val rejectReason: String = "none",
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "lastPeakG" to lastPeakG,
        "impactThresholdCrossed" to impactThresholdCrossed,
        "rotationDegrees" to rotationDegrees,
        "stillnessMs" to stillnessMs,
        "rejectReason" to rejectReason,
    )
}

class CascadeDetector(
    private val movementBaseline: MovementBaseline = MovementBaseline(),
) {
    companion object {
        const val IMPACT_THRESHOLD_G = 5.0
        private const val ROTATION_THRESHOLD_DEGREES = 60.0
        private const val ROTATION_WINDOW_MS = 500.0
        private const val STILLNESS_WINDOW_MS = 2000.0
        private const val STILLNESS_TOLERANCE_G = 0.15
    }

    private data class Vec3(val x: Double, val y: Double, val z: Double) {
        val norm get() = sqrt(x * x + y * y + z * z)
        operator fun minus(other: Vec3) = Vec3(x - other.x, y - other.y, z - other.z)
        fun lerp(other: Vec3, alpha: Double) = Vec3(
            x + (other.x - x) * alpha,
            y + (other.y - y) * alpha,
            z + (other.z - z) * alpha,
        )
        fun angleDegrees(other: Vec3): Double {
            val denominator = norm * other.norm
            if (denominator < 0.01) return 0.0
            val cosine = ((x * other.x + y * other.y + z * other.z) / denominator).coerceIn(-1.0, 1.0)
            return acos(cosine) * 180.0 / Math.PI
        }
    }

    private data class Candidate(
        val impactTMs: Double,
        var peakG: Double,
        val priorGravity: Vec3,
        val beforeImpact: String,
        var rotated: Boolean = false,
        var stillStartTMs: Double? = null,
        var stillReference: Vec3? = null,
    )

    private var gravity: Vec3? = null
    private var candidate: Candidate? = null
    private var lastTMs: Double? = null
    private var suppressedUntilMs = Double.NEGATIVE_INFINITY
    private var cooldownUntilMs = Double.NEGATIVE_INFINITY
    private var trainingAfterMs = Double.NEGATIVE_INFINITY
    private var samplesSinceTrainingWindow = 0
    private val recentMagnitudes = ArrayDeque<Double>()
    var diagnostics = DetectorDiagnostics()
        private set

    fun suppressFor(durationMs: Double, nowMs: Double) {
        suppressedUntilMs = max(suppressedUntilMs, nowMs + durationMs)
        candidate = null
    }

    fun reset() {
        gravity = null
        candidate = null
        lastTMs = null
        cooldownUntilMs = Double.NEGATIVE_INFINITY
        recentMagnitudes.clear()
    }

    fun add(tMs: Double, xG: Double, yG: Double, zG: Double): FallImpact? {
        val vector = Vec3(xG, yG, zG)
        val magnitude = vector.norm
        if (!tMs.isFinite() || !magnitude.isFinite()) return null
        val previousTime = lastTMs
        if (previousTime != null && (tMs <= previousTime || tMs - previousTime > 500.0)) reset()
        lastTMs = tMs
        val priorGravity = gravity

        if (candidate == null && magnitude > IMPACT_THRESHOLD_G &&
            tMs >= suppressedUntilMs && tMs >= cooldownUntilMs &&
            priorGravity != null && priorGravity.norm > 0.5) {
            trainingAfterMs = max(trainingAfterMs, tMs + 10_000.0)
            candidate = Candidate(tMs, magnitude, priorGravity, classifyBeforeImpact())
            diagnostics = DetectorDiagnostics(magnitude, true, 0.0, 0.0, "candidate")
            return null
        }

        if (magnitude < 2.0) gravity = priorGravity?.lerp(vector, 0.2) ?: vector
        val current = candidate
        if (current != null) {
            if (tMs < suppressedUntilMs) {
                candidate = null
                diagnostics = diagnostics.copy(rejectReason = "suppressed")
                return null
            }
            if (magnitude > current.peakG) current.peakG = magnitude
            diagnostics = diagnostics.copy(lastPeakG = current.peakG)
            if (!current.rotated) {
                if (tMs - current.impactTMs > ROTATION_WINDOW_MS) {
                    candidate = null
                    diagnostics = diagnostics.copy(rejectReason = "rotation_timeout")
                    return null
                }
                val angle = gravity?.let { current.priorGravity.angleDegrees(it) } ?: 0.0
                diagnostics = diagnostics.copy(rotationDegrees = max(diagnostics.rotationDegrees, angle))
                if (angle > ROTATION_THRESHOLD_DEGREES) {
                    current.rotated = true
                    current.stillStartTMs = tMs
                    current.stillReference = vector
                    diagnostics = diagnostics.copy(rejectReason = "waiting_for_stillness")
                }
            } else {
                val reference = current.stillReference!!
                if ((vector - reference).norm > STILLNESS_TOLERANCE_G ||
                    abs(magnitude - 1.0) > STILLNESS_TOLERANCE_G) {
                    current.stillStartTMs = tMs
                    current.stillReference = vector
                    diagnostics = diagnostics.copy(rejectReason = "movement_after_rotation", stillnessMs = 0.0)
                }
                val stillnessMs = tMs - current.stillStartTMs!!
                diagnostics = diagnostics.copy(stillnessMs = stillnessMs)
                if (stillnessMs >= STILLNESS_WINDOW_MS) {
                    candidate = null
                    cooldownUntilMs = tMs + 10_000.0
                    diagnostics = diagnostics.copy(rejectReason = "confirmed")
                    return FallImpact(current.impactTMs, tMs, current.peakG,
                        current.beforeImpact, (stillnessMs / 1000.0).toInt())
                }
            }
        }

        if (candidate == null) {
            recentMagnitudes.addLast(magnitude)
            if (recentMagnitudes.size > 100) recentMagnitudes.removeFirst()
            if (magnitude <= 2.0 && tMs >= suppressedUntilMs &&
                tMs >= cooldownUntilMs && tMs >= trainingAfterMs &&
                recentMagnitudes.size == 100
            ) {
                samplesSinceTrainingWindow += 1
                if (samplesSinceTrainingWindow >= 25) {
                    samplesSinceTrainingWindow = 0
                    movementBaseline.observe(windowVariance())
                }
            }
        }
        return null
    }

    private fun classifyBeforeImpact(): String {
        if (recentMagnitudes.size < 25) return "unknown"
        val variance = windowVariance()
        val ordinaryActivity = when {
            variance < 0.01 -> "still"
            variance > 0.25 -> "running"
            else -> "walking"
        }
        return movementBaseline.classify(variance, ordinaryActivity)
    }

    private fun windowVariance(): Double {
        val mean = recentMagnitudes.average()
        return recentMagnitudes.sumOf { (it - mean) * (it - mean) } / recentMagnitudes.size
    }
}
