package ph.appbuilders.bantay_app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Durable alert text and send progress. No message body or phone number enters logs. */
class SmsOutboxDb(context: Context) : SQLiteOpenHelper(context, "bantay_sms_outbox.db", null, 2) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE sms_outbox (
                incident_id TEXT PRIMARY KEY, number TEXT NOT NULL, body TEXT NOT NULL,
                state TEXT NOT NULL, attempts INTEGER NOT NULL, part_count INTEGER NOT NULL,
                sent_parts TEXT NOT NULL, failed_parts TEXT NOT NULL,
                delivered_parts TEXT NOT NULL, error TEXT
            )
        """.trimIndent())
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion == 1 && newVersion == 2) {
            db.execSQL("ALTER TABLE sms_outbox ADD COLUMN failed_parts TEXT NOT NULL DEFAULT ''")
            return
        }
        error("Unsupported outbox migration: $oldVersion -> $newVersion")
    }

    @Synchronized fun get(id: String): SmsOutboxRecord? {
        readableDatabase.query("sms_outbox", null, "incident_id = ?", arrayOf(id),
            null, null, null).use { cursor ->
            return if (cursor.moveToFirst()) fromCursor(cursor) else null
        }
    }

    @Synchronized fun all(): List<SmsOutboxRecord> {
        readableDatabase.query("sms_outbox", null, null, null, null, null,
            "rowid DESC").use { cursor ->
            val rows = mutableListOf<SmsOutboxRecord>()
            while (cursor.moveToNext()) rows += fromCursor(cursor)
            return rows
        }
    }

    @Synchronized fun put(record: SmsOutboxRecord) {
        val values = ContentValues().apply {
            put("incident_id", record.incidentId)
            put("number", record.number)
            put("body", record.body)
            put("state", record.state)
            put("attempts", record.attempts)
            put("part_count", record.partCount)
            put("sent_parts", record.sentParts.sorted().joinToString(","))
            put("failed_parts", record.failedParts.sorted().joinToString(","))
            put("delivered_parts", record.deliveredParts.sorted().joinToString(","))
            put("error", record.error)
        }
        writableDatabase.insertWithOnConflict("sms_outbox", null, values,
            SQLiteDatabase.CONFLICT_REPLACE)
    }

    private fun fromCursor(c: android.database.Cursor): SmsOutboxRecord = SmsOutboxRecord(
        incidentId = c.getString(c.getColumnIndexOrThrow("incident_id")),
        number = c.getString(c.getColumnIndexOrThrow("number")),
        body = c.getString(c.getColumnIndexOrThrow("body")),
        state = c.getString(c.getColumnIndexOrThrow("state")),
        attempts = c.getInt(c.getColumnIndexOrThrow("attempts")),
        partCount = c.getInt(c.getColumnIndexOrThrow("part_count")),
        sentParts = parseParts(c.getString(c.getColumnIndexOrThrow("sent_parts"))),
        failedParts = parseParts(c.getString(c.getColumnIndexOrThrow("failed_parts"))),
        deliveredParts = parseParts(c.getString(c.getColumnIndexOrThrow("delivered_parts"))),
        error = c.getString(c.getColumnIndexOrThrow("error")),
    )

    private fun parseParts(raw: String): Set<Int> = raw.split(',').mapNotNull { it.toIntOrNull() }.toSet()
}
