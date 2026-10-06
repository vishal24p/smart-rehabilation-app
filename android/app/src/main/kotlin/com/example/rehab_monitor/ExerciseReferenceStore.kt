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
import java.util.Date
import java.util.GregorianCalendar

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

object GaitReferencePayload {
    private val metricKeys = setOf("cadence_spm", "right_step_time_s", "left_step_time_s",
        "right_stride_time_s", "left_stride_time_s")

    fun validate(value: Any?): Map<String, Any> {
        require(value is Map<*, *>) { "Gait reference must be a map." }
        require(value.keys == setOf("measurement_version", "placement", "recorded_at", "right_strides", "left_strides", "metrics")) {
            "Gait reference must contain exactly the required fields."
        }
        require(value["measurement_version"] == "gait_forefoot_timing_v1" &&
            value["placement"] == "right_thigh_shin_bilateral_forefeet") {
            "Unsupported gait reference. Record it again."
        }
        val counts = listOf("right_strides", "left_strides").associateWith { key ->
            val count = value[key]
            require((count is Int || count is Long) && (count as Number).toLong() >= 10) {
                "A reference needs at least 10 complete strides per foot."
            }
            count as Number
        }
        val metrics = value["metrics"]
        require(metrics is Map<*, *> && metrics.keys == metricKeys) { "Reference must contain the five gait timing metrics." }
        val validatedMetrics = metricKeys.associateWith { key ->
            val number = metrics[key]
            require(number is Number && number.toDouble().isFinite() && number.toDouble() > 0) { "Invalid $key." }
            number.toDouble()
        }
        val date = value["recorded_at"]
        require(date is String && Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,6})?Z").matches(date)) {
            "Invalid gait reference timestamp."
        }
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT).apply {
            calendar = GregorianCalendar(TimeZone.getTimeZone("UTC"), Locale.ROOT).apply {
                gregorianChange = Date(Long.MIN_VALUE)
            }
            isLenient = false
        }
        val position = ParsePosition(0)
        require(format.parse(date.take(19), position) != null && position.index == 19) { "Invalid gait reference date." }
        return mapOf("measurement_version" to "gait_forefoot_timing_v1", "placement" to "right_thigh_shin_bilateral_forefeet",
            "recorded_at" to date, "right_strides" to counts.getValue("right_strides"),
            "left_strides" to counts.getValue("left_strides"), "metrics" to validatedMetrics)
    }
}

class ExerciseReferenceStore(context: Context, name: String = "exercise_references.db") : SQLiteOpenHelper(context, name, null, 2) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        createGaitTable(db)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2) { "Unsupported reference database version." }
        createGaitTable(db)
    }
    private fun createGaitTable(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE gait_reference (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)")
    }
    fun loadGait(): Map<String, Any>? = readableDatabase.query(
        "gait_reference", arrayOf("payload"), "id = ?", arrayOf("1"), null, null, null,
    ).use { cursor ->
        if (!cursor.moveToFirst()) null else {
            val json = JSONObject(cursor.getString(0))
            val metrics = json.getJSONObject("metrics")
            val values = json.keys().asSequence().associateWith { key ->
                if (key == "metrics") metrics.keys().asSequence().associateWith { metrics.get(it) } else json.get(key)
            }
            if (values["measurement_version"] == "gait_heel_timing_v1" &&
                values["placement"] == "right_thigh_shin_bilateral_heels") {
                // Validate the stored record before ignoring its incompatible sensor placement.
                GaitReferencePayload.validate(values + mapOf(
                    "measurement_version" to "gait_forefoot_timing_v1",
                    "placement" to "right_thigh_shin_bilateral_forefeet",
                ))
                null
            } else GaitReferencePayload.validate(values)
        }
    }
    fun saveGait(value: Any?): Map<String, Any> {
        val reference = GaitReferencePayload.validate(value)
        val values = ContentValues().apply {
            put("id", 1)
            put("payload", JSONObject(reference).toString())
        }
        val db = writableDatabase
        db.beginTransaction()
        try {
            check(db.insertWithOnConflict("gait_reference", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L) {
                "Could not save the gait reference."
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        return reference
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
