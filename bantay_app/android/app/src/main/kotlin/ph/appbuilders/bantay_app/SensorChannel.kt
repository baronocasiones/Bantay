package ph.appbuilders.bantay_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between the Kotlin sensor layer and Dart.
 *
 * Dart -> Kotlin calls are [MethodChannel] invocations handled by MainActivity;
 * Kotlin -> Dart pushes ("batch", "state") go through the channel the activity
 * installs. [channel] is set in MainActivity.configureFlutterEngine and
 * cleared on teardown, so a running service with no visible engine simply
 * drops batches instead of crashing.
 */
object SensorChannel {
    /** Single endpoint; method names are part of the contract, mirrored in Dart. */
    const val NAME = "ph.appbuilders.bantay_app/sensors"

    // Dart -> Kotlin
    const val METHOD_START = "start"
    const val METHOD_STOP = "stop"
    const val METHOD_ATTACH = "attach"
    const val METHOD_DETACH = "detach"

    // Kotlin -> Dart
    const val METHOD_BATCH = "batch"
    const val METHOD_STATE = "state"

    @Volatile
    var channel: MethodChannel? = null

    /**
     * Flutter requires every channel invocation on the main thread:
     * `FlutterJNI.dispatchPlatformMessage` throws "Methods marked with
     * @UiThread must be executed on the main thread" otherwise. Batch emits
     * originate on the FallWatchService handler thread, so pushes are queued
     * here and executed on the main looper in FIFO order.
     */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Queues one batch push on the main thread: [count] quads of
     * [t_ms, x, y, z] in [payload]. [seq] is the stream sequence number now
     * reached; [dropped] counts samples overwritten since the previous batch.
     *
     * [onDelivered] runs on the main thread once the send has been attempted,
     * reporting whether an engine was still listening at that point. The
     * caller advances its consumer sequence only on `true`, so a detach
     * between queue and delivery still leaves the batch to be retried (see
     * FallWatchService.emitBatch). Returns false immediately when no Dart
     * engine was listening when queued; in that case no callback is invoked.
     */
    fun postBatch(
        payload: DoubleArray,
        count: Int,
        dropped: Int,
        seq: Long,
        onDelivered: (Boolean) -> Unit,
    ): Boolean {
        channel ?: return false
        val arguments = mapOf(
            "samples" to payload,
            "count" to count,
            "dropped" to dropped,
            "seq" to seq,
        )
        mainHandler.post {
            val live = channel
            if (live == null) {
                onDelivered(false)
            } else {
                live.invokeMethod(METHOD_BATCH, arguments)
                onDelivered(true)
            }
        }
        return true
    }

    /**
     * Queues a state push on the main thread. Fire-and-forget: if no engine is
     * listening the state is simply not updated anywhere.
     */
    fun postState(state: Map<String, Any?>) {
        channel ?: return
        mainHandler.post {
            channel?.invokeMethod(METHOD_STATE, state)
        }
    }
}
