package com.example.rehab_monitor

import org.junit.Assert.*
import org.junit.Test

class ExerciseReferencePayloadTest {
    private fun reference() = mapOf<String, Any>(
        "exercise_id" to "squat", "measurement_version" to "thigh_tilt_v1",
        "reference_peak_deg" to 70.0, "bend_threshold_deg" to 42.0,
        "upright_band_deg" to 10.0, "placement" to "front_thigh",
        "recorded_at" to "2026-10-06T06:00:00.123456Z",
    )
    @Test fun accepts_reference_and_matching_single_thigh_command() {
        assertEquals(reference(), ExerciseReferencePayload.validate(reference()))
        val args = mapOf("action" to "thigh_session_begin", "config" to
            mapOf("exercise_id" to "squat", "reference" to reference()))
        assertEquals("thigh_session_begin", RehabProcessing.validateCommand(args).first)
    }
    @Test fun rejects_bad_numbers_version_date_and_exercise_mismatch() {
        for (edit in listOf(
            mapOf("reference_peak_deg" to Double.NaN), mapOf("upright_band_deg" to 50.0),
            mapOf("measurement_version" to "other"), mapOf("recorded_at" to "bad"),
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                ExerciseReferencePayload.validate(reference() + edit)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            RehabProcessing.validateCommand(mapOf("action" to "thigh_session_begin", "config" to
                mapOf("exercise_id" to "sit_to_stand", "reference" to reference())))
        }
    }
}
