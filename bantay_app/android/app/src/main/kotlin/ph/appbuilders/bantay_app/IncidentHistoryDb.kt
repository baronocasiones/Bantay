package ph.appbuilders.bantay_app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.concurrent.Executors

data class IncidentTimelineEvent(
    val label: String,
    val atEpochMs: Long,
    val detail: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "label" to label,
        "atEpochMs" to atEpochMs,
        "detail" to detail,
    )
}

data class IncidentHistoryRecord(
    val incidentId: String,
    val occurredAtEpochMs: Long?,
    val source: String,
    val peakG: Double?,
    val beforeImpact: String?,
    val stillnessSeconds: Int?,
    val contactName: String?,
    val number: String?,
    val stage: String,
    val smsText: String?,
    val error: String?,
    val timeline: List<IncidentTimelineEvent>,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "incidentId" to incidentId,
        "occurredAtEpochMs" to occurredAtEpochMs,
        "source" to source,
        "peakG" to peakG,
        "beforeImpact" to beforeImpact,
        "stillnessSeconds" to stillnessSeconds,
        "contactName" to contactName,
        "number" to number,
        "stage" to stage,
        "smsText" to smsText,
        "error" to error,
        "timeline" to timeline.map(IncidentTimelineEvent::toMap),
    )
}

interface IncidentJournal {
    fun upsert(state: GuardianState)
    fun appendEvent(incidentId: String, label: String, atEpochMs: Long, detail: String? = null)
}

object NoOpIncidentJournal : IncidentJournal {
    override fun upsert(state: GuardianState) = Unit
    override fun appendEvent(incidentId: String, label: String, atEpochMs: Long, detail: String?) = Unit
}

/** Serializes disk writes away from the detector/SMS thread. */
class AsyncIncidentJournal(private val database: IncidentHistoryDb) : IncidentJournal {
    private val writer = Executors.newSingleThreadExecutor { task ->
        Thread(task, "bantay-incident-history").apply { isDaemon = true }
    }

    override fun upsert(state: GuardianState) {
        writer.execute { runCatching { database.upsert(state) } }
    }

    override fun appendEvent(incidentId: String, label: String, atEpochMs: Long, detail: String?) {
        writer.execute { runCatching { database.appendEvent(incidentId, label, atEpochMs, detail) } }
    }

    fun snapshot(): List<IncidentHistoryRecord> = writer.submit<List<IncidentHistoryRecord>> {
        database.all()
    }.get()
}

/** Private, durable record of real incident transitions. */
class IncidentHistoryDb(context: Context) : SQLiteOpenHelper(
    context.applicationContext,
    "bantay_incident_history.db",
    null,
    DATABASE_VERSION,
), IncidentJournal {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE incidents (
                incident_id TEXT PRIMARY KEY NOT NULL,
                occurred_at INTEGER,
                source TEXT NOT NULL,
                peak_g REAL,
                before_impact TEXT,
                stillness_seconds INTEGER,
                contact_name TEXT,
                number TEXT,
                stage TEXT NOT NULL,
                sms_text TEXT,
                error TEXT
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE incident_timeline (
                event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                incident_id TEXT NOT NULL,
                label TEXT NOT NULL,
                at_epoch_ms INTEGER NOT NULL,
                detail TEXT,
                FOREIGN KEY(incident_id) REFERENCES incidents(incident_id) ON DELETE CASCADE
            )
            """.trimIndent(),
        )
        db.execSQL(
            "CREATE INDEX incident_timeline_incident_idx " +
                "ON incident_timeline(incident_id, event_id)",
        )
        db.execSQL("CREATE INDEX incidents_occurred_idx ON incidents(occurred_at DESC)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        require(oldVersion == newVersion) { "Unsupported incident history database upgrade" }
    }

    @Synchronized
    override fun upsert(state: GuardianState) {
        val id = state.incidentId ?: return
        val values = ContentValues().apply {
            put("incident_id", id)
            putNullable("occurred_at", state.occurredAtEpochMs)
            put("source", if (state.manual) "manual_sos" else "fall")
            putNullable("peak_g", if (state.manual) null else state.peakG)
            putNullable("before_impact", if (state.manual) null else state.beforeImpact)
            putNullable("stillness_seconds", if (state.manual) null else state.stillnessSeconds)
            putNullable("contact_name", state.contactName.takeIf(String::isNotBlank))
            putNullable("number", state.number.takeIf(String::isNotBlank))
            put("stage", state.stage)
            // Exact text is read from the durable SMS outbox, never from a
            // countdown preview that may have been cancelled before sending.
            putNull("sms_text")
            putNullable("error", state.error?.takeIf(String::isNotBlank))
        }
        val db = writableDatabase
        if (db.update("incidents", values, "incident_id = ?", arrayOf(id)) == 0) {
            db.insert("incidents", null, values)
        }
    }

    @Synchronized
    override fun appendEvent(incidentId: String, label: String, atEpochMs: Long, detail: String?) {
        val values = ContentValues().apply {
            put("incident_id", incidentId)
            put("label", label)
            put("at_epoch_ms", atEpochMs)
            putNullable("detail", detail?.takeIf(String::isNotBlank))
        }
        writableDatabase.insert("incident_timeline", null, values)
    }

    @Synchronized
    fun all(): List<IncidentHistoryRecord> {
        val db = readableDatabase
        val records = mutableListOf<IncidentHistoryRecord>()
        db.query("incidents", null, null, null, null, null, "occurred_at DESC, incident_id DESC")
            .use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(cursor.getColumnIndexOrThrow("incident_id"))
                    records += IncidentHistoryRecord(
                        incidentId = id,
                        occurredAtEpochMs = cursor.longOrNull("occurred_at"),
                        source = cursor.getString(cursor.getColumnIndexOrThrow("source")),
                        peakG = cursor.doubleOrNull("peak_g"),
                        beforeImpact = cursor.stringOrNull("before_impact"),
                        stillnessSeconds = cursor.intOrNull("stillness_seconds"),
                        contactName = cursor.stringOrNull("contact_name"),
                        number = cursor.stringOrNull("number"),
                        stage = cursor.getString(cursor.getColumnIndexOrThrow("stage")),
                        smsText = cursor.stringOrNull("sms_text"),
                        error = cursor.stringOrNull("error"),
                        timeline = eventsFor(db, id),
                    )
                }
            }
        return records
    }

    private fun eventsFor(db: SQLiteDatabase, incidentId: String): List<IncidentTimelineEvent> {
        val events = mutableListOf<IncidentTimelineEvent>()
        db.query(
            "incident_timeline", null, "incident_id = ?", arrayOf(incidentId),
            null, null, "event_id ASC",
        ).use { cursor ->
            while (cursor.moveToNext()) {
                events += IncidentTimelineEvent(
                    label = cursor.getString(cursor.getColumnIndexOrThrow("label")),
                    atEpochMs = cursor.getLong(cursor.getColumnIndexOrThrow("at_epoch_ms")),
                    detail = cursor.stringOrNull("detail"),
                )
            }
        }
        return events
    }

    private fun ContentValues.putNullable(key: String, value: String?) {
        if (value == null) putNull(key) else put(key, value)
    }

    private fun ContentValues.putNullable(key: String, value: Long?) {
        if (value == null) putNull(key) else put(key, value)
    }

    private fun ContentValues.putNullable(key: String, value: Int?) {
        if (value == null) putNull(key) else put(key, value)
    }

    private fun ContentValues.putNullable(key: String, value: Double?) {
        if (value == null) putNull(key) else put(key, value)
    }

    private fun android.database.Cursor.stringOrNull(column: String): String? =
        getColumnIndexOrThrow(column).let { index -> if (isNull(index)) null else getString(index) }

    private fun android.database.Cursor.longOrNull(column: String): Long? =
        getColumnIndexOrThrow(column).let { index -> if (isNull(index)) null else getLong(index) }

    private fun android.database.Cursor.intOrNull(column: String): Int? =
        getColumnIndexOrThrow(column).let { index -> if (isNull(index)) null else getInt(index) }

    private fun android.database.Cursor.doubleOrNull(column: String): Double? =
        getColumnIndexOrThrow(column).let { index -> if (isNull(index)) null else getDouble(index) }

    private companion object {
        const val DATABASE_VERSION = 1
    }
}
