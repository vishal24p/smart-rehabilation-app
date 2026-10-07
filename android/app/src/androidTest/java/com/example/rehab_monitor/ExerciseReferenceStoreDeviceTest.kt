package com.example.rehab_monitor

import android.test.AndroidTestCase
import org.json.JSONObject

@Suppress("DEPRECATION")
class ExerciseReferenceStoreDeviceTest : AndroidTestCase() {
    fun testAllLegacySchemasUpgradeWithoutLosingRecords() {
        val exercise = mapOf<String, Any>(
            "exercise_id" to "squat", "measurement_version" to "thigh_tilt_v1",
            "reference_peak_deg" to 70.0, "bend_threshold_deg" to 42.0,
            "upright_band_deg" to 10.0, "placement" to "front_thigh", "recorded_at" to "2026-10-06T06:00:00Z",
        )
        val settings = mapOf("injured_leg" to "left", "heel_zero" to null,
            "rep_targets" to mapOf("squat" to 20, "sit_to_stand" to 5))
        val session = mapOf("id" to "migration-session", "started_at" to "2026-10-06T12:00:00Z",
            "ended_at" to null, "status" to "active", "exercises" to emptyList<Map<String, Any?>>())
        val sessionJson = JSONObject(session).apply { put("ended_at", JSONObject.NULL) }.toString()
        for ((version, branch) in listOf(1 to "base", 2 to "rehab", 2 to "gait", 3 to "rehab")) {
            val name = "migration_${branch}_v$version.db"
            context.deleteDatabase(name)
            try {
                context.openOrCreateDatabase(name, 0, null).use { old ->
                    old.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                    old.execSQL("INSERT INTO exercise_references VALUES (?, ?)", arrayOf("squat", JSONObject(exercise).toString()))
                    if (branch == "rehab") {
                        old.execSQL("CREATE TABLE app_settings (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)")
                        old.execSQL("INSERT INTO app_settings VALUES (1, ?)", arrayOf(JSONObject(settings).toString()))
                    }
                    if (version == 3) {
                        old.execSQL("CREATE TABLE workout_sessions (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                        old.execSQL("INSERT INTO workout_sessions VALUES (?, ?)", arrayOf("migration-session", sessionJson))
                    }
                    if (branch == "gait") {
                        old.execSQL("CREATE TABLE gait_reference (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)")
                        old.execSQL("INSERT INTO gait_reference VALUES (1, ?)", arrayOf(JSONObject(gaitReference()).toString()))
                    }
                    old.version = version
                }
                ExerciseReferenceStore(context, name).use { migrated ->
                    assertEquals(4, migrated.readableDatabase.version)
                    assertEquals(listOf(exercise), migrated.load())
                    if (branch == "rehab") assertEquals(settings, migrated.loadSettings())
                    else assertNull(migrated.loadSettings()["injured_leg"])
                    if (version == 3) assertEquals(listOf(session), migrated.loadSessions())
                    else assertTrue(migrated.loadSessions().isEmpty())
                    if (branch == "gait") assertEquals(gaitReference(), migrated.loadGait())
                    else assertNull(migrated.loadGait())
                    migrated.saveSettings(settings)
                    migrated.saveSession(session)
                    migrated.saveGait(gaitReference())
                }
                ExerciseReferenceStore(context, name).use { reopened ->
                    assertEquals(4, reopened.readableDatabase.version)
                    assertEquals(listOf(exercise), reopened.load())
                    assertEquals(settings, reopened.loadSettings())
                    assertEquals(listOf(session), reopened.loadSessions())
                    assertEquals(gaitReference(), reopened.loadGait())
                }
            } finally { context.deleteDatabase(name) }
        }
    }

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
                assertEquals(4, store.readableDatabase.version)
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

    fun testVersionTwoSettingsAndSessionsSurviveMigrationAndRetry() {
        val name = "workout_migration_device_test.db"
        context.deleteDatabase(name)
        val zero = mapOf("version" to 1, "adc_max" to 1023,
            "left" to mapOf("baseline" to 13.0, "deadband" to 5.0),
            "right" to mapOf("baseline" to 13.0, "deadband" to 5.0))
        val oldSettings = mapOf("injured_leg" to "right", "heel_zero" to zero)
        val session = mapOf("id" to "session-retry", "started_at" to "2026-10-06T12:00:00Z",
            "ended_at" to null, "status" to "active", "exercises" to emptyList<Map<String, Any?>>())
        val result = mapOf("repetitions" to 1, "rep_target" to 10, "active_s" to 4.5,
            "latest_peak_deg" to null, "reference_peak_deg" to 70.0, "difference_deg" to null, "outcome" to "interrupted")
        val attempt = mapOf("id" to "attempt-retry", "exercise_id" to "squat", "started_at" to "2026-10-06T12:00:01Z",
            "ended_at" to "2026-10-06T12:00:10Z", "result" to result)
        val ended = session + mapOf("ended_at" to "2026-10-06T12:00:11Z", "status" to "ended", "exercises" to listOf(attempt))
        try {
            context.openOrCreateDatabase(name, 0, null).use { old ->
                old.execSQL("CREATE TABLE exercise_references (exercise_id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                old.execSQL("CREATE TABLE app_settings (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)")
                old.execSQL("INSERT INTO app_settings VALUES (1, ?)", arrayOf(JSONObject(oldSettings).toString()))
                old.version = 2
            }
            ExerciseReferenceStore(context, name).use { migrated ->
                assertEquals("right", migrated.loadSettings()["injured_leg"])
                assertEquals(zero, migrated.loadSettings()["heel_zero"])
                assertEquals(mapOf("squat" to 10, "sit_to_stand" to 10), migrated.loadSettings()["rep_targets"])
                assertTrue(migrated.loadSessions().isEmpty())
                migrated.saveSettings(oldSettings + ("rep_targets" to mapOf("squat" to 20, "sit_to_stand" to 5)))
                migrated.saveSettings(oldSettings + ("injured_leg" to "left"))
                assertEquals(mapOf("squat" to 20, "sit_to_stand" to 5), migrated.loadSettings()["rep_targets"])
                migrated.saveSession(session)
                migrated.saveSession(session)
                assertEquals(1, migrated.loadSessions().size)
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                assertEquals(session, reopened.loadSessions().single())
                reopened.saveSession(ended)
                reopened.saveSession(ended)
                try {
                    reopened.saveSession(ended + ("ended_at" to "invalid"))
                    fail("Invalid session replacement accepted")
                } catch (_: IllegalArgumentException) { }
                assertEquals(ended, reopened.loadSessions().single())
            }
            ExerciseReferenceStore(context, name).use { reopened ->
                assertEquals(ended, reopened.loadSessions().single())
                assertEquals("left", reopened.loadSettings()["injured_leg"])
                assertEquals(zero, reopened.loadSettings()["heel_zero"])
            }
        } finally { context.deleteDatabase(name) }
    }

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
