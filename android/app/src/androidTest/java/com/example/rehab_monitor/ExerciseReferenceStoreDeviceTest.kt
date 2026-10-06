package com.example.rehab_monitor

import android.test.AndroidTestCase
import org.json.JSONObject

@Suppress("DEPRECATION")
class ExerciseReferenceStoreDeviceTest : AndroidTestCase() {
    fun testSettingsMigrationAndReopenPreserveExistingReference() {
        val name = "settings_migration_device_test.db"
        context.deleteDatabase(name)
        val reference = mapOf("exercise_id" to "squat", "measurement_version" to "thigh_tilt_v1",
            "reference_peak_deg" to 70, "bend_threshold_deg" to 42, "upright_band_deg" to 10,
            "placement" to "front_thigh", "recorded_at" to "2026-10-06T06:00:00Z")
        val zero = mapOf("version" to 1, "adc_max" to 1023,
            "left" to mapOf("baseline" to 12.0, "deadband" to 5.0),
            "right" to mapOf("baseline" to 11.0, "deadband" to 6.0))
        try {
            context.openOrCreateDatabase(name, 0, null).use { old ->
                old.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                old.execSQL("INSERT INTO exercise_references VALUES (?, ?)", arrayOf("squat", JSONObject(reference).toString()))
                old.version = 1
            }
            ExerciseReferenceStore(context, name).use { migrated ->
                assertEquals(70.0, migrated.load().single()["reference_peak_deg"])
                assertNull(migrated.loadSettings()["injured_leg"])
                migrated.saveSettings(mapOf("injured_leg" to "right", "heel_zero" to zero))
                try {
                    migrated.saveSettings(mapOf("injured_leg" to "other", "heel_zero" to null))
                    fail("Invalid settings accepted")
                } catch (_: IllegalArgumentException) { }
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                assertEquals("right", reopened.loadSettings()["injured_leg"])
                assertEquals(zero, reopened.loadSettings()["heel_zero"])
                assertEquals(1, reopened.load().size)
                reopened.saveSettings(mapOf("injured_leg" to "left", "heel_zero" to zero))
                assertEquals("left", reopened.loadSettings()["injured_leg"])
            }
        } finally { context.deleteDatabase(name) }
    }
    fun testReferencesSurviveReopenAndInvalidReplacement() {
        val name = "exercise_references_device_test.db"
        context.deleteDatabase(name)
        val reference = mapOf<String, Any>(
            "exercise_id" to "squat", "measurement_version" to "thigh_tilt_v1",
            "reference_peak_deg" to 70.0, "bend_threshold_deg" to 42.0,
            "upright_band_deg" to 10.0, "placement" to "front_thigh",
            "recorded_at" to "2026-10-06T06:00:00.123456Z",
        )
        try {
            ExerciseReferenceStore(context, name).use { store ->
                assertTrue(store.load().isEmpty())
                store.save(reference)
                store.save(reference + ("exercise_id" to "sit_to_stand"))
                try {
                    store.save(reference + ("reference_peak_deg" to Double.NaN))
                    fail("Invalid replacement accepted")
                } catch (_: IllegalArgumentException) { }
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                val records = reopened.load()
                assertEquals(2, records.size)
                assertEquals(70.0, records.single { it["exercise_id"] == "squat" }["reference_peak_deg"])
                reopened.save(reference + ("reference_peak_deg" to 80.0))
                assertEquals(80.0, reopened.load().single { it["exercise_id"] == "squat" }["reference_peak_deg"])
                assertEquals(70.0, reopened.load().single { it["exercise_id"] == "sit_to_stand" }["reference_peak_deg"])
            }
        } finally { context.deleteDatabase(name) }
    }
}
