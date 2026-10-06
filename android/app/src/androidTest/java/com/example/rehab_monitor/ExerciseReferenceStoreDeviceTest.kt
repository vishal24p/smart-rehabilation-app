package com.example.rehab_monitor

import android.test.AndroidTestCase
import org.json.JSONObject

@Suppress("DEPRECATION")
class ExerciseReferenceStoreDeviceTest : AndroidTestCase() {
    private fun gaitReference() = mapOf<String, Any>(
        "measurement_version" to "gait_forefoot_timing_v1", "placement" to "right_thigh_shin_bilateral_forefeet",
        "recorded_at" to "2026-10-06T06:00:00Z", "right_strides" to 10, "left_strides" to 10,
        "metrics" to mapOf("cadence_spm" to 120.0, "right_step_time_s" to 0.5,
            "left_step_time_s" to 0.5, "right_stride_time_s" to 1.0, "left_stride_time_s" to 1.0),
    )

    fun testHeelGaitReferenceIsPreservedUntilExplicitForefootReplacement() {
        val name = "gait_forefoot_replacement_test.db"
        context.deleteDatabase(name)
        val legacy = gaitReference() + mapOf("measurement_version" to "gait_heel_timing_v1",
            "placement" to "right_thigh_shin_bilateral_heels")
        val payload = JSONObject(legacy).toString()
        try {
            ExerciseReferenceStore(context, name).use { store ->
                store.writableDatabase.execSQL("INSERT INTO gait_reference VALUES (1, ?)", arrayOf(payload))
                assertNull(store.loadGait())
                try {
                    store.saveGait(legacy)
                    fail("Heel baseline accepted")
                } catch (_: IllegalArgumentException) { }
                try {
                    store.saveGait(gaitReference() + ("right_strides" to 9))
                    fail("Invalid replacement accepted")
                } catch (_: IllegalArgumentException) { }
                store.readableDatabase.rawQuery("SELECT payload FROM gait_reference WHERE id = 1", null).use {
                    assertTrue(it.moveToFirst()); assertEquals(payload, it.getString(0))
                }
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                assertNull(reopened.loadGait())
                reopened.saveGait(gaitReference())
                assertEquals(gaitReference(), reopened.loadGait())
            }
        } finally { context.deleteDatabase(name) }
    }

    fun testMalformedAndUnsupportedStoredGaitReferencesFail() {
        val name = "gait_invalid_stored_reference_test.db"
        context.deleteDatabase(name)
        val legacy = gaitReference() + mapOf("measurement_version" to "gait_heel_timing_v1",
            "placement" to "right_thigh_shin_bilateral_heels")
        val invalid = listOf(
            legacy + ("right_strides" to 9), legacy + ("extra" to true),
            legacy + ("metrics" to mapOf("cadence_spm" to 120)),
            legacy - "recorded_at", legacy + ("placement" to "front_thigh"),
            gaitReference() + ("measurement_version" to "unknown"),
            gaitReference() + ("placement" to "right_thigh_shin_bilateral_heels"),
        )
        try {
            ExerciseReferenceStore(context, name).use { store ->
                for (reference in invalid) {
                    store.writableDatabase.execSQL("INSERT OR REPLACE INTO gait_reference VALUES (1, ?)",
                        arrayOf(JSONObject(reference).toString()))
                    try {
                        store.loadGait()
                        fail("Malformed or unsupported baseline ignored")
                    } catch (_: IllegalArgumentException) { }
                }
            }
        } finally { context.deleteDatabase(name) }
    }

    fun testVersionOneMigrationPreservesExerciseAndGaitSurvivesFailedReplacement() {
        val name = "gait_reference_migration_test.db"
        context.deleteDatabase(name)
        val exercise = mapOf<String, Any>(
            "exercise_id" to "squat", "measurement_version" to "thigh_tilt_v1",
            "reference_peak_deg" to 70.0, "bend_threshold_deg" to 42.0,
            "upright_band_deg" to 10.0, "placement" to "front_thigh", "recorded_at" to "2026-10-06T06:00:00Z",
        )
        try {
            context.openOrCreateDatabase(name, 0, null).use { db ->
                db.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                db.execSQL("INSERT INTO exercise_references VALUES (?, ?)", arrayOf("squat", JSONObject(exercise).toString()))
                db.version = 1
            }
            ExerciseReferenceStore(context, name).use { store ->
                assertEquals(2, store.readableDatabase.version)
                assertEquals(listOf(exercise), store.load())
                assertNull(store.loadGait())
                val gait = gaitReference()
                store.saveGait(gait)
                try {
                    store.saveGait(gait + ("right_strides" to 9))
                    fail("Invalid replacement accepted")
                } catch (_: IllegalArgumentException) { }
                assertEquals(gait, store.loadGait())
                store.writableDatabase.execSQL("CREATE TRIGGER fail_gait_save BEFORE INSERT ON gait_reference BEGIN SELECT RAISE(ABORT, 'test save failure'); END")
                try {
                    store.saveGait(gait + ("recorded_at" to "2026-10-06T07:00:00Z"))
                    fail("Failed write accepted")
                } catch (_: IllegalStateException) { }
                assertEquals(gait, store.loadGait())
                store.writableDatabase.execSQL("DROP TRIGGER fail_gait_save")
                store.saveGait(gait + ("recorded_at" to "2026-10-06T07:00:00Z"))
                store.readableDatabase.rawQuery("SELECT COUNT(*) FROM gait_reference", null).use {
                    assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0))
                }
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                assertEquals(listOf(exercise), reopened.load())
                assertEquals("2026-10-06T07:00:00Z", reopened.loadGait()!!["recorded_at"])
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
