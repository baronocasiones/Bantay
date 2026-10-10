package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Off-device tests for the service-owned incident chain.
 *
 * The point of these is the property the old code got wrong: the chain must run
 * to completion without any Flutter engine. Nothing here constructs an
 * Activity, a Context, or a Handler, because none of those are allowed to be in
 * the path between an impact and the SMS.
 */
class GuardianRuntimeTest {
    private var clock = 10_000L
    private val sent = mutableListOf<Triple<String, String, String>>()
    private val emitted = mutableListOf<GuardianState>()
    private val store = MemoryIncidentStore()
    private class FakeLocationSource : EmergencyLocationSource {
        var callback: ((EmergencyLocation?) -> Unit)? = null
        var recent: EmergencyLocation? = null
        override fun requestCurrent(onLocation: (EmergencyLocation?) -> Unit) { callback = onLocation }
        override fun recentLocation(): EmergencyLocation? = recent
    }

    private fun runtime(
        sendResult: String = "sent",
        countdownMs: Long = GuardianStateMachine.COUNTDOWN_MS,
        locationSource: EmergencyLocationSource? = null,
    ) = GuardianRuntime(
        store = store,
        sendSms = { id, number, text ->
            sent += Triple(id, number, text)
            sendResult
        },
        emit = { emitted += it },
        now = { clock },
        zoneOffsetMs = { 0L },
        elapsedRealtimeMs = { 1_000L },
        countdownMs = countdownMs,
        locationSource = locationSource,
    ).also { it.arm("Maria Santos", "+639991234567") }

    private fun impact(
        peakG: Double = 7.2,
        atMs: Double = 5_000.0,
        before: String = "walking",
        stillness: Int = 8,
    ) = FallImpact(atMs, atMs + 2_000.0, peakG, before, stillness)

    @Test
    fun confirmedImpactStartsCountdownAndEmitsToDart() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())

        assertEquals("counting", state.stage)
        assertEquals(7.2, state.peakG!!, 0.001)
        assertEquals("walking", state.beforeImpact)
        assertTrue(state.text!!.contains("7.2g"))
        assertTrue(emitted.isNotEmpty())
        assertTrue(guardian.isCounting())
    }

    @Test
    fun deadlineExpirySendsExactlyOneSmsWithTheFixedText() {
        val guardian = runtime()
        guardian.beginFromImpact(impact())

        // Nothing is sent early.
        guardian.tick()
        assertTrue(sent.isEmpty())

        clock = 25_000L // past the 15s deadline
        guardian.tick()

        assertEquals(1, sent.size)
        val (id, number, text) = sent.single()
        assertEquals("+639991234567", number)
        assertEquals(state_id_of(guardian), id)
        assertTrue(text.startsWith("BANTAY ALERT:"))
        assertTrue(text.contains("7.2g"))
    }

    @Test
    fun freshFixDuringCountdownAppearsInSmsWithoutMovingDeadline() {
        val source = FakeLocationSource()
        val guardian = runtime(locationSource = source)
        val state = guardian.beginFromImpact(impact())
        assertEquals(25_000L, state.deadlineEpochMs)

        clock = 20_000L
        source.callback!!(EmergencyLocation(14.6, 121.0, 20_000L, 20f))
        clock = 25_000L
        guardian.tick()

        assertEquals(1, sent.size)
        assertTrue(sent.single().third.contains("GPS: 14.60000,121.00000"))
        assertFalse(sent.single().third.contains("maps.google.com"))
        assertEquals(25_000L, state.deadlineEpochMs)
    }

    @Test
    fun fixArrivingAtDeadlineIsRejectedAndFallbackSmsStillSends() {
        val source = FakeLocationSource()
        val guardian = runtime(locationSource = source)
        val state = guardian.beginFromImpact(impact())
        clock = state.deadlineEpochMs!!
        source.callback!!(EmergencyLocation(14.6, 121.0, clock, 20f))
        guardian.tick()

        assertEquals(1, sent.size)
        assertTrue(sent.single().third.contains("GPS unavailable."))
        assertTrue(!sent.single().third.contains("maps.google.com"))
    }

    private fun state_id_of(guardian: GuardianRuntime) = guardian.snapshot().incidentId!!

    @Test
    fun repeatedTicksAfterSendingDoNotSendAgain() {
        val guardian = runtime()
        guardian.beginFromImpact(impact())
        clock = 25_000L

        repeat(5) { guardian.tick() }

        assertEquals(1, sent.size)
    }

    @Test
    fun cancelBeforeDeadlineSendsNothing() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())

        guardian.cancel(state.incidentId!!)
        clock = 25_000L
        guardian.tick()

        assertTrue("cancelled incident must not send", sent.isEmpty())
        assertEquals("canceled", guardian.snapshot().stage)
    }

    @Test
    fun cancelOfUnknownIncidentIsIgnored() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())

        guardian.cancel("some-other-incident")
        clock = 25_000L
        guardian.tick()

        assertEquals(1, sent.size)
        assertEquals(state.incidentId, sent.single().first)
    }

    @Test
    fun sendHelpNowSendsImmediatelyBeforeDeadline() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())

        guardian.sendNow(state.incidentId!!)

        assertEquals(1, sent.size)
        // No longer counting: the message is out, so the countdown is finished.
        assertTrue(guardian.snapshot().stage != "counting")
        // The outbox reported success, so the stage tracks it rather than
        // staying optimistically on "sending".
        assertEquals("sent", guardian.snapshot().stage)
    }

    @Test
    fun pathTwoWordingReplacesTextOnlyWhileCounting() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())

        guardian.setIncidentText(state.incidentId!!, "BANTAY ALERT: custom wording")
        assertEquals("BANTAY ALERT: custom wording", guardian.snapshot().text)

        // After it has left the device, late model output must never rewrite it.
        guardian.sendNow(state.incidentId!!)
        guardian.setIncidentText(state.incidentId!!, "too late")
        assertEquals(
            "BANTAY ALERT: custom wording GPS unavailable.",
            guardian.snapshot().text,
        )
    }

    @Test
    fun carrierCallbackUpdatesPersistedIncidentState() {
        val guardian = runtime(sendResult = "sending")
        val state = guardian.beginFromImpact(impact())
        guardian.sendNow(state.incidentId!!)
        guardian.onSmsState(state.incidentId!!, "sent", null)
        assertEquals("sent", guardian.snapshot().stage)
        assertEquals("sent", store.load()!!.stage)
    }

    @Test
    fun pathTwoTextAfterDeadlineIsRejectedEvenBeforeTickRuns() {
        val guardian = runtime()
        val state = guardian.beginFromImpact(impact())
        clock = state.deadlineEpochMs!!
        val accepted = guardian.setIncidentText(state.incidentId!!, "late model text")
        assertEquals(false, accepted)
        assertTrue(guardian.snapshot().text != "late model text")
    }

    @Test
    fun manualSosSendsWithoutAnyImpact() {
        val source = FakeLocationSource().apply {
            recent = EmergencyLocation(14.6, 121.0, clock, 20f)
        }
        val guardian = runtime(locationSource = source)

        guardian.startManualSos()

        assertEquals(1, sent.size)
        assertTrue(sent.single().third.contains("I need help"))
        assertTrue(sent.single().third.contains("GPS: 14.60000,121.00000"))
        assertFalse(sent.single().third.contains("maps.google.com"))
    }

    @Test
    fun unarmedGuardianNeverStartsAnIncident() {
        val guardian = GuardianRuntime(
            store = MemoryIncidentStore(),
            sendSms = { id, n, t -> sent += Triple(id, n, t); "sent" },
            emit = { emitted += it },
            now = { clock },
            zoneOffsetMs = { 0L },
            elapsedRealtimeMs = { 1_000L },
        )

        guardian.beginFromImpact(impact())
        clock = 30_000L
        guardian.tick()

        assertTrue(sent.isEmpty())
        assertNull(guardian.snapshot().incidentId)
    }

    @Test
    fun pendingCountdownRestoredFromStoreStillSends() {
        // Simulates process death mid-countdown: the store holds a state that
        // was counting, and enough wall clock has passed that the deadline is
        // now due when the process comes back.
        store.save(
            GuardianState().copy(
                armed = true, contactName = "Maria Santos",
                number = "+639991234567", stage = "counting",
                incidentId = "INC-restored", occurredAtEpochMs = 0L,
                deadlineEpochMs = 12_000L, peakG = 5.0,
                beforeImpact = "walking", stillnessSeconds = 3,
                text = "BANTAY ALERT: restored",
            ),
        )
        val guardian = runtime()

        // Still counting on the way back up, before the deadline.
        clock = 5_000L
        assertTrue("restored state must still be counting", guardian.isCounting())
        guardian.tick()
        assertTrue("must not send before its deadline", sent.isEmpty())

        // Deadline passes while nothing is looking at the app.
        clock = 30_000L
        guardian.tick()

        assertEquals(1, sent.size)
        assertEquals("INC-restored", sent.single().first)
    }

    @Test
    fun incidentTimeIsRenderedInLocalTime() {
        val guardian = runtime()
        // 01:00 UTC on day 0 with a +8h zone must read 09:00.
        val text = GuardianAlertText.timeText(3_600_000L, 8 * 3_600_000L)
        assertEquals("9:00 AM", text)
        val midnight = GuardianAlertText.timeText(0L, -5 * 3_600_000L)
        assertEquals("7:00 PM", midnight)
    }
}
