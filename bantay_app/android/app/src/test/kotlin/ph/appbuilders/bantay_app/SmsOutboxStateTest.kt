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
        record = SmsOutboxState.failedPart(record, 1, "radio_off")
        assertEquals("failed", record.state)
        assertTrue(record.sentParts.contains(0))
    }

    @Test fun multipartNoServiceQueuesOnlyAfterEveryPartFails() {
        var record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-6", "+639990000000", "Help"), 2
        )
        record = SmsOutboxState.failedPart(record, 0, "no_service")
        assertEquals("sending", record.state)
        record = SmsOutboxState.failedPart(record, 1, "no_service")
        assertEquals("queued", record.state)
    }

    @Test fun successfulPartAfterFailureNeverRetries() {
        var record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-7", "+639990000000", "Help"), 2
        )
        record = SmsOutboxState.failedPart(record, 0, "no_service")
        record = SmsOutboxState.sentPart(record, 1)
        assertEquals("failed", record.state)
    }

    @Test fun staleSendingBecomesUnknownWithoutAutomaticRetry() {
        var record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-8", "+639990000000", "Help"), 1,
            1_000L
        )
        record = SmsOutboxState.markUnknown(record)
        assertEquals("unknown", record.state)
        assertFalse(SmsOutboxState.shouldRetry(record))
        record = SmsOutboxState.sentPart(record, 0)
        assertEquals("sent", record.state)
    }

    @Test fun staleSendingReconcilesToUnknownButFreshSendingStaysInFlight() {
        val record = SmsOutboxState.dispatch(
            SmsOutboxState.enqueue(null, "fall-9", "+639990000000", "Help"), 1,
            1_000L
        )
        assertEquals("sending", SmsOutboxState.reconcile(record, 60_999L).state)
        val unknown = SmsOutboxState.reconcile(record, 61_000L)
        assertEquals("unknown", unknown.state)
        assertFalse(SmsOutboxState.shouldRetry(unknown))
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
