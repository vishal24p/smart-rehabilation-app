package com.example.rehab_monitor

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

object ExerciseReferencePayload {
    fun validate(value: Any?): Map<String, Any> {
        require(value is Map<*, *>) { "Exercise reference must be a map." }
        val id = value["exercise_id"]
        require(id in setOf("squat", "sit_to_stand")) { "Choose Squat or Sit-to-stand." }
        require(value["measurement_version"] == "thigh_tilt_v1" && value["placement"] == "front_thigh") {
            "Unsupported thigh reference. Record it again."
        }
        fun angle(key: String): Double {
            val number = value[key]
            require(number is Number && number.toDouble().isFinite() && number.toDouble() > 0 && number.toDouble() <= 180) {
                "Invalid $key."
            }
            return number.toDouble()
        }
        val peak = angle("reference_peak_deg")
        val bend = angle("bend_threshold_deg")
        val upright = angle("upright_band_deg")
        require(upright < bend && bend <= peak) { "Invalid movement bands." }
        val date = value["recorded_at"]
        require(date is String && Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,6})?Z").matches(date)) {
            "Invalid reference timestamp."
        }
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT).apply {
            isLenient = false; timeZone = TimeZone.getTimeZone("UTC")
        }
        val position = ParsePosition(0)
        require(format.parse(date.take(19), position) != null && position.index == 19) { "Invalid reference date." }
        return mapOf("exercise_id" to id as String, "measurement_version" to "thigh_tilt_v1",
            "reference_peak_deg" to peak, "bend_threshold_deg" to bend, "upright_band_deg" to upright,
            "placement" to "front_thigh", "recorded_at" to date)
    }
}

class ExerciseReferenceStore(context: Context, name: String = "exercise_references.db") : SQLiteOpenHelper(context, name, null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        throw IllegalStateException("Unsupported reference database version.")
    }
    fun load(): List<Map<String, Any>> = readableDatabase.query(
        "exercise_references", arrayOf("payload"), null, null, null, null, "exercise_id",
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                val json = JSONObject(cursor.getString(0))
                val values = json.keys().asSequence().associateWith { json.get(it) }
                add(ExerciseReferencePayload.validate(values))
            }
        }
    }
    fun save(value: Any?): Map<String, Any> {
        val reference = ExerciseReferencePayload.validate(value)
        val values = ContentValues().apply {
            put("exercise_id", reference["exercise_id"] as String)
            put("payload", JSONObject(reference).toString())
        }
        writableDatabase.beginTransaction()
        try {
            check(writableDatabase.insertWithOnConflict("exercise_references", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L) {
                "Could not save the exercise reference."
            }
            writableDatabase.setTransactionSuccessful()
        } finally { writableDatabase.endTransaction() }
        return reference
    }
}
