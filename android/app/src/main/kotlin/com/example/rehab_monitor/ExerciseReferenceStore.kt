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

object AppSettingsPayload {
    fun validateHeelZero(value: Any?): Map<String, Any> {
        require(value is Map<*, *> && value.keys == setOf("version", "adc_max", "left", "right")) { "Invalid heel baseline." }
        require(value["version"] == 1 && value["adc_max"] == 1023) { "Unsupported heel baseline." }
        fun side(key: String): Map<String, Double> {
            val values = value[key]
            require(values is Map<*, *> && values.keys == setOf("baseline", "deadband")) { "Invalid $key baseline." }
            fun number(field: String, range: ClosedFloatingPointRange<Double>): Double {
                val number = values[field]
                require(number is Number && number.toDouble().isFinite() && number.toDouble() in range) { "Invalid $key $field." }
                return number.toDouble()
            }
            return mapOf("baseline" to number("baseline", 0.0..1022.0), "deadband" to number("deadband", 5.0..1023.0))
        }
        return mapOf("version" to 1, "adc_max" to 1023, "left" to side("left"), "right" to side("right"))
    }

    fun validate(value: Any?): Map<String, Any?> {
        require(value is Map<*, *> && value.keys == setOf("injured_leg", "heel_zero")) { "Invalid settings." }
        val leg = value["injured_leg"]
        require(leg == null || leg in setOf("left", "right")) { "Choose the left or right injured leg." }
        return mapOf("injured_leg" to leg, "heel_zero" to value["heel_zero"]?.let { validateHeelZero(it) })
    }
}

class ExerciseReferenceStore(context: Context, name: String = "exercise_references.db") : SQLiteOpenHelper(context, name, null, 2) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        createSettings(db)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2) { "Unsupported reference database version." }
        createSettings(db)
    }
    private fun createSettings(db: SQLiteDatabase) = db.execSQL(
        "CREATE TABLE app_settings (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)",
    )

    fun loadSettings(): Map<String, Any?> = readableDatabase.query(
        "app_settings", arrayOf("payload"), "id = 1", null, null, null, null,
    ).use { cursor ->
        if (!cursor.moveToFirst()) mapOf("injured_leg" to null, "heel_zero" to null)
        else AppSettingsPayload.validate(jsonMap(JSONObject(cursor.getString(0))))
    }

    fun saveSettings(value: Any?): Map<String, Any?> {
        val settings = AppSettingsPayload.validate(value)
        val json = JSONObject().apply {
            put("injured_leg", settings["injured_leg"] ?: JSONObject.NULL)
            put("heel_zero", settings["heel_zero"]?.let { JSONObject(it as Map<*, *>) } ?: JSONObject.NULL)
        }
        val values = ContentValues().apply { put("id", 1); put("payload", json.toString()) }
        check(writableDatabase.insertWithOnConflict("app_settings", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L) {
            "Could not save settings."
        }
        return settings
    }

    private fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        when (val value = json.get(key)) {
            JSONObject.NULL -> null
            is JSONObject -> jsonMap(value)
            else -> value
        }
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
