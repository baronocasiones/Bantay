package ph.appbuilders.bantay_app

/**
 * Fixed alert wording for the native incident chain.
 *
 * Path 2 (LiteRT-LM) may replace this text before the message leaves the
 * device — see `BantayPath2` in `bantay_llm`. It never gates sending. This
 * builder is the text that goes out when no model is loaded, when the model
 * times out, or when its wording fails the fact check, which is the normal
 * case on the demo phone.
 *
 * Pure by design: no Android types, no clock, no locale lookup. The runtime is
 * unit-testable without a device, and the wording matches the message preview
 * shown on Emergency Alert Sent in the Figma design.
 */
object GuardianAlertText {
    const val BANTAY_ALERT = "BANTAY ALERT"

    fun fall(peakG: Double, timeText: String, stillnessSeconds: Int): String =
        "$BANTAY_ALERT: A possible fall was detected at $timeText. " +
            "A sudden ${formatG(peakG)} impact was recorded, followed by " +
            "$stillnessSeconds seconds of limited movement. " +
            "Please check on me immediately."

    fun sos(timeText: String): String =
        "$BANTAY_ALERT: I need help at $timeText. " +
            "Location unavailable. Please check on me."

    /** One decimal, always, so the fact check can compare it against `peakG`. */
    fun formatG(peakG: Double): String = String.format("%.1fg", peakG)

    /**
     * 12-hour clock with a space before the meridiem, matching
     * `ImpactFacts.timeText` on the Dart side. Keeping the two in sync is what
     * lets the Dart fact check accept this text unmodified.
     *
     * Uses [Math.floorMod] rather than `%`, which for negative epoch or a
     * negative zone offset would yield a negative hour and print `-5:00 AM`.
     *
     * @param zoneOffsetMs offset added to epoch millis, as a Long so callers can
     *   pass a computed offset without losing a cast.
     */
    fun timeText(epochMs: Long, zoneOffsetMs: Long): String {
        val local = epochMs + zoneOffsetMs
        val minutes = Math.floorMod(local / 60_000L, 60L).toInt()
        val hours24 = Math.floorMod(local / 3_600_000L, 24L).toInt()
        val hour12 = if (hours24 % 12 == 0) 12 else hours24 % 12
        val meridiem = if (hours24 < 12) "AM" else "PM"
        return "$hour12:${minutes.toString().padStart(2, '0')} $meridiem"
    }
}
