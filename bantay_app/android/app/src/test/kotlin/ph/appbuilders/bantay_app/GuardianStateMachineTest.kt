package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GuardianStateMachineTest {
    @Test fun countdownIsFifteenSecondsAndCannotSendEarly() {
        val armed = GuardianStateMachine.arm(GuardianState(), "Ana", "+639990000000")
        val counting = GuardianStateMachine.begin(
            armed, "incident-1", 1_000L, 5.0, "walking", 2, false, "Help"
        )
        assertEquals("counting", counting.stage)
        assertEquals(16_000L, counting.deadlineEpochMs)
        assertFalse(GuardianStateMachine.isDue(counting, 15_999L))
        assertTrue(GuardianStateMachine.isDue(counting, 16_000L))
    }

    @Test fun cancelWinsBeforeDeadlineAndSurvivesDuplicateTimeout() {
        val armed = GuardianStateMachine.arm(GuardianState(), "Ana", "+639990000000")
        val counting = GuardianStateMachine.begin(
            armed, "incident-2", 1_000L, 5.0, "walking", 2, false, "Help"
        )
        val canceled = GuardianStateMachine.cancel(counting, "incident-2")
        assertEquals("canceled", canceled.stage)
        assertFalse(GuardianStateMachine.isDue(canceled, 20_000L))
        assertEquals(canceled, GuardianStateMachine.send(canceled, "incident-2"))
    }

    @Test fun receiverStatusUpdatesLatestIncidentOnly() {
        val armed = GuardianStateMachine.arm(GuardianState(), "Ana", "+639990000000")
        val counting = GuardianStateMachine.begin(
            armed, "incident-3", 1_000L, 5.0, "walking", 2, false, "Help"
        )
        val sending = GuardianStateMachine.send(counting, "incident-3")
        assertEquals("sending", sending.stage)
        assertEquals(sending, GuardianStateMachine.sms(sending, "other", "sent", null))
        assertEquals("sent", GuardianStateMachine.sms(sending, "incident-3", "sent", null).stage)
    }
}
