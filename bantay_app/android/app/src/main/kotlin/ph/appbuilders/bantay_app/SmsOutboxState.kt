package ph.appbuilders.bantay_app

/** Pure transition rules. Body and destination never change after the first insert. */
data class SmsOutboxRecord(
    val incidentId: String,
    val number: String,
    val body: String,
    val state: String = "queued",
    val attempts: Int = 0,
    val partCount: Int = 0,
    val sentParts: Set<Int> = emptySet(),
    val failedParts: Set<Int> = emptySet(),
    val deliveredParts: Set<Int> = emptySet(),
    val error: String? = null,
)

object SmsOutboxState {
    fun enqueue(existing: SmsOutboxRecord?, incidentId: String, number: String, body: String) =
        existing ?: SmsOutboxRecord(incidentId, number, body)

    fun dispatch(record: SmsOutboxRecord, partCount: Int): SmsOutboxRecord {
        require(record.state == "queued" && partCount > 0)
        return record.copy(
            state = "sending", attempts = record.attempts + 1,
            partCount = partCount, sentParts = emptySet(), failedParts = emptySet(),
            deliveredParts = emptySet(), error = null,
        )
    }

    fun sentPart(record: SmsOutboxRecord, part: Int): SmsOutboxRecord {
        if (record.state != "sending" && record.state != "sent") return record
        if (part !in 0 until record.partCount) return record
        val sent = record.sentParts + part
        val state = when {
            record.failedParts.isNotEmpty() -> "failed"
            sent.size < record.partCount -> "sending"
            record.deliveredParts.size == record.partCount -> "delivered"
            else -> "sent"
        }
        return record.copy(state = state, sentParts = sent)
    }

    fun deliveredPart(record: SmsOutboxRecord, part: Int): SmsOutboxRecord {
        if (record.state != "sending" && record.state != "sent") return record
        if (part !in 0 until record.partCount) return record
        val delivered = record.deliveredParts + part
        val state = if (delivered.size == record.partCount &&
            record.sentParts.size == record.partCount) "delivered" else record.state
        return record.copy(state = state, deliveredParts = delivered)
    }

    fun failedPart(record: SmsOutboxRecord, part: Int, error: String): SmsOutboxRecord {
        if (record.state != "sending" || part !in 0 until record.partCount) return record
        val failed = record.failedParts + part
        val retryable = error == "radio_off" || error == "no_service"
        val state = when {
            record.sentParts.isNotEmpty() || !retryable -> "failed"
            failed.size == record.partCount -> "queued"
            else -> "sending" // Other parts may still reach the network.
        }
        return record.copy(state = state, failedParts = failed, error = error)
    }

    fun fail(record: SmsOutboxRecord, error: String) = record.copy(state = "failed", error = error)
    fun shouldRetry(record: SmsOutboxRecord) = record.state == "queued"
}
