package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsOutboxStateTest {
    @Test fun duplicateIncidentKeepsOriginalBody() {
        val first = SmsOutboxState.enqueue(null, "fall-1", "+639990000000", "Original")
        val duplicate = SmsOutboxState.enqueue(first, "fall-1", "+639991111111", "Changed")
        assertEquals(first, duplicate)
    }

    @Test fun multipartIsSentOnlyAfterAllSentCallbacks() {
        var record = SmsOutboxState.enqueue(null, "fall-2", "+639990000000", "Help")
        record = SmsOutboxState.dispatch(record, 2)
        record = SmsOutboxState.sentPart(record, 0)
        assertEquals("sending", record.state)
        record = SmsOutboxState.sentPart(record, 1)
        assertEquals("sent", record.state)
        assertFalse(record.deliveredParts.contains(0))
    }

    @Test fun deliveryRequiresEveryPartReceipt() {
        var record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-3", "+639990000000", "Help"), 2
        )
        record = SmsOutboxState.sentPart(SmsOutboxState.sentPart(record, 0), 1)
        record = SmsOutboxState.deliveredPart(record, 0)
        assertEquals("sent", record.state)
        record = SmsOutboxState.deliveredPart(record, 1)
        assertEquals("delivered", record.state)
    }

    @Test fun failedPartDoesNotClaimSent() {
        var record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-4", "+639990000000", "Help"), 2
        )
        record = SmsOutboxState.sentPart(record, 0)
        record = SmsOutboxState.failedPart(record, "radio_off")
        assertEquals("failed", record.state)
        assertTrue(record.sentParts.contains(0))
    }

    @Test fun terminalErrorNeverRetriesAutomatically() {
        val record = SmsOutboxState.fail(
            SmsOutboxState.enqueue(null, "fall-5", "+639990000000", "Help"),
            "invalid_number"
        )
        assertEquals("failed", record.state)
        assertFalse(SmsOutboxState.shouldRetry(record))
    }
}
