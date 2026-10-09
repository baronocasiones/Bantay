package ph.appbuilders.bantay_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Path 1, slice 1: the watcher.
 *
 * A foreground service that samples the accelerometer on a [HandlerThread],
 * keeps a 4-second [AccelRingBuffer], and pushes batches to Dart over
 * [SensorChannel] at 20 Hz. It does not decide anything yet; the detector
 * arrives in a later slice and consumes this stream from a background isolate.
 *
 * Design constraints (architecture.md §§2-3 and SPEC.md §5):
 * - The service thread never touches the UI; batching at 20 Hz replaces what
 *   would otherwise be 50-100 platform traversals per second.
 * - The foreground service type is declared in the manifest AND passed to
 *   `startForeground`. Android 14+ throws on a mismatch, which is the classic
 *   way to crash the demo on stage.
 * - Android 12+ forbids starting a foreground service from the background, so
 *   this is only ever started from the visible activity's method handler.
 */
class FallWatchService : Service(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var serviceThread: HandlerThread? = null
    private var serviceHandler: Handler? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val ring = AccelRingBuffer(RING_SAMPLES)
    private var sampling = false

    /** Drains new samples into [SensorChannel] every 50 ms. Runs on the service thread. */
    private val emitter = object : Runnable {
        override fun run() {
            emitBatch()
            serviceHandler?.postDelayed(this, EMIT_PERIOD_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(SensorManager::class.java)
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSampling("stopped by user")
                stopSelf()
                return START_NOT_STICKY
            }
            else -> startSampling()
        }
        return START_STICKY
    }

    private fun startSampling() {
        if (sampling) return
        promoteToForeground()
        acquireWakeLock()

        val thread = HandlerThread(THREAD_NAME).also { it.start() }
        val handler = Handler(thread.looper)
        serviceThread = thread
        serviceHandler = handler

        val manager = sensorManager
        val sensor = accelerometer
        if (manager == null || sensor == null) {
            stopSampling("accelerometer unavailable")
            stopSelf()
            return
        }
        val registered = manager.registerListener(this, sensor, SAMPLE_PERIOD_US, handler)
        if (!registered) {
            stopSampling("sensor registration failed")
            stopSelf()
            return
        }

        sampling = true
        Log.i(TAG, "sampling started at ${REQUESTED_HZ}Hz requested (${sensor.name})")
        updateSnapshot(running = true, sensorName = sensor.name, requestedHz = REQUESTED_HZ)
        handler.postDelayed(emitter, EMIT_PERIOD_MS)
        pushState(
            running = true,
            error = null,
            sensorName = sensor.name,
            requestedHz = REQUESTED_HZ,
        )
    }

    private fun stopSampling(reason: String) {
        sampling = false
        serviceHandler?.removeCallbacks(emitter)
        serviceHandler = null
        accelerometer?.let { sensorManager?.unregisterListener(this, it) }
        serviceThread?.quitSafely()
        serviceThread = null
        releaseWakeLock()
        updateSnapshot(running = false, sensorName = null, requestedHz = null)
        pushState(running = false, error = reason)
    }

    private fun promoteToForeground() {
        createNotificationChannel()
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(getString(R.string.notification_text))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openMainActivity())
            .build()
        // minSdk is 30; the 3-argument startForeground (type declared) is the
        // form Android 14+ requires and must match the manifest value.
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = getString(R.string.channel_description) }
        manager.createNotificationChannel(channel)
    }

    private fun openMainActivity(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val power = getSystemService(PowerManager::class.java) ?: return
        wakeLock = power
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    override fun onDestroy() {
        stopSampling("service destroyed")
        super.onDestroy()
    }

    // SensorEventListener -- called on the service HandlerThread only.

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor?.type != Sensor.TYPE_ACCELEROMETER) return
        val values = event.values
        if (values.size < 3) return
        // event.timestamp is SystemClock.elapsedRealtimeNanos; napkin check:
        // full-precision millis keeps the 20 ms period intact through float32.
        ring.append(event.timestamp / NS_PER_MS.toDouble(), values[0], values[1], values[2])
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun emitBatch() {
        if (!isConsumerAttached()) return
        val drain = ring.drainFrom(consumerSeqValue())
        if (drain.samples.isEmpty()) return

        val payload = DoubleArray(drain.samples.size * 4)
        for ((index, sample) in drain.samples.withIndex()) {
            val base = index * 4
            payload[base] = sample.timestampMs
            payload[base + 1] = sample.x.toDouble()
            payload[base + 2] = sample.y.toDouble()
            payload[base + 3] = sample.z.toDouble()
        }
        // Advance the sequence only on delivery. The push is queued on the
        // main thread by SensorChannel (Flutter requires @UiThread for
        // channel invocations); with the activity gone the batch stays in the
        // ring (until the 4 s overwrite window) and the next tick retries it,
        // so the debug panel sees "dropped 0" after a rotation instead of
        // silently missing samples.
        // Capture the batch's own sequence before the push: the delivery
        // callback runs later on the main thread, by which point the ring
        // may have advanced and advancing to that newer value would skip
        // samples the consumer never received.
        val batchSeq = ring.lastSeq
        SensorChannel.postBatch(
            payload = payload,
            count = drain.samples.size,
            dropped = drain.dropped,
            seq = batchSeq,
            onDelivered = { delivered ->
                if (delivered) updateConsumerSeq(batchSeq)
            },
        )
    }

    private fun pushState(
        running: Boolean,
        error: String?,
        sensorName: String? = null,
        requestedHz: Int? = null,
    ) {
        SensorChannel.postState(
            mapOf(
                "running" to running,
                "error" to error,
                "sensorName" to sensorName,
                "requestedHz" to requestedHz,
            )
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_START = "ph.appbuilders.bantay_app.action.START_SAMPLING"
        const val ACTION_STOP = "ph.appbuilders.bantay_app.action.STOP_SAMPLING"

        /** 50 Hz; Android will not honour 100 Hz requests (SPEC §6). */
        const val REQUESTED_HZ = 50
        private const val SAMPLE_PERIOD_US = 1_000_000 / REQUESTED_HZ

        /** Batching cadence, architecture.md §3. */
        private const val EMIT_PERIOD_MS = 50L

        /** 4-second history at the requested rate; power-of-ten keeps the math readable. */
        private val RING_SAMPLES = REQUESTED_HZ * 4

        private const val THREAD_NAME = "fall-watch-sensor"
        private const val TAG = "FallWatchService"
        private const val CHANNEL_ID = "fall_watch_channel"
        private const val NOTIFICATION_ID = 0x46414C4C // "FALL"
        private const val WAKE_LOCK_TAG = "bantay:fall-watch"
        private const val NS_PER_MS = 1_000_000

        /**
         * Consumer bookkeeping shared with [MainActivity]. The service holds
         * its own copy of "who we last sent to" so an emitter running with no
         * visible engine sends nothing.
         */
        @Volatile
        private var attached = false

        /**
         * Live-state snapshot for a consumer that attaches while the service
         * is already running. Without it a cold-attached panel has no way to
         * learn the service is sampling and shows a stale "stopped".
         */
        @Volatile
        private var snapshotRunning = false

        @Volatile
        private var snapshotSensorName: String? = null

        @Volatile
        private var snapshotRequestedHz: Int? = null

        @Volatile
        private var consumerSeq = 0L

        fun attachConsumer() {
            attached = true
            // Re-draining from 0 deliberately reports every sample that was
            // overwritten while the panel was closed rather than pretending
            // the stream was continuous.
            consumerSeq = 0L
            // Snapshot the live state onto the attaching engine's main thread.
            SensorChannel.postState(
                mapOf(
                    "running" to snapshotRunning,
                    "error" to null,
                    "sensorName" to snapshotSensorName,
                    "requestedHz" to snapshotRequestedHz,
                )
            )
        }

        private fun updateSnapshot(running: Boolean, sensorName: String?, requestedHz: Int?) {
            snapshotRunning = running
            snapshotSensorName = sensorName
            snapshotRequestedHz = requestedHz
        }

        fun detachConsumer() {
            attached = false
        }

        private fun isConsumerAttached() = attached

        private fun consumerSeqValue() = consumerSeq

        private fun updateConsumerSeq(seq: Long) {
            consumerSeq = seq
        }
    }
}
