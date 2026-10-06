package com.example.rehab_monitor

import android.test.AndroidTestCase

@Suppress("DEPRECATION")
class ExerciseReferenceStoreDeviceTest : AndroidTestCase() {
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
