package ph.appbuilders.bantay_app

/**
 * One accelerometer sample. [seq] is the 1-based index of the sample in the
 * stream, assigned by [AccelRingBuffer] as samples land; it is what lets the
 * Dart consumer measure drops instead of guessing.
 */
data class AccelSample(
    val seq: Long,
    val timestampMs: Double,
    val x: Float,
    val y: Float,
    val z: Float,
)

/** Result of [AccelRingBuffer.drainFrom]. */
class AccelDrain(
    /** Samples since [AccelRingBuffer.drainFrom]'s afterSeq, oldest first. */
    val samples: List<AccelSample>,
    /** Samples that were overwritten before the consumer caught up. */
    val dropped: Int,
)

/**
 * Fixed-capacity circular buffer for the accelerometer stream.
 *
 * Capacity covers the detection window plus history: at 50 Hz, 4 seconds is
 * 200 samples of x/y/z, a few KB of floats. Memory cost is irrelevant;
 * the point is that history exists when the detector asks for it.
 *
 * Sequence numbers are total appends, not buffer indices: when the consumer
 * stalls, [drainFrom] reports how many samples were overwritten and hands
 * back the most recent [capacity] samples, so a stalled demo panel shows
 * "dropped N" instead of silently losing time.
 *
 * Pure Kotlin (no Android imports) so it can run under plain JVM unit tests.
 */
internal class AccelRingBuffer(val capacity: Int) {
    private val timestamps = DoubleArray(capacity)
    private val xs = FloatArray(capacity)
    private val ys = FloatArray(capacity)
    private val zs = FloatArray(capacity)
    private var appended = 0L

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    /** Total samples appended so far; equals the newest sample's [AccelSample.seq]. */
    val lastSeq: Long
        get() = synchronized(this) { appended }

    /** Writes one sample. Returns the new [AccelSample.seq]. */
    fun append(timestampMs: Double, x: Float, y: Float, z: Float): Long =
        synchronized(this) {
            val index = (appended % capacity).toInt()
            timestamps[index] = timestampMs
            xs[index] = x
            ys[index] = y
            zs[index] = z
            appended++
            appended
        }

    /**
     * Returns samples appended after [afterSeq], oldest first, capped at the
     * [capacity] most recent. [AccelDrain.dropped] counts overwritten samples.
     * A negative [afterSeq] is treated as "consumer not attached yet" and
     * returns the whole buffer.
     */
    fun drainFrom(afterSeq: Long): AccelDrain = synchronized(this) {
        val floor = if (afterSeq < 0) 0L else afterSeq
        val available = appended - floor
        if (available <= 0) return AccelDrain(emptyList(), 0)

        val count = minOf(available, capacity.toLong()).toInt()
        val dropped = (available - count).toInt()
        val startSeq = appended - count
        val out = ArrayList<AccelSample>(count)
        for (i in 0 until count) {
            val index = ((startSeq + i) % capacity).toInt()
            out.add(
                AccelSample(
                    seq = startSeq + i + 1,
                    timestampMs = timestamps[index],
                    x = xs[index],
                    y = ys[index],
                    z = zs[index],
                )
            )
        }
        AccelDrain(out, dropped)
    }
}
