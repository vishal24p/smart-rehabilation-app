package com.example.rehab_monitor

import org.junit.Assert.*
import org.junit.Test

class WorkoutSessionPayloadTest {
    private fun result() = mapOf("repetitions" to 2, "rep_target" to 2, "active_s" to 8.0,
        "latest_peak_deg" to 65.0, "reference_peak_deg" to 70.0, "difference_deg" to -5.0,
        "outcome" to "target_reached")
    private fun attempt() = mapOf("id" to "attempt-1", "exercise_id" to "squat",
        "started_at" to "2026-10-06T12:00:01.000001Z", "ended_at" to "2026-10-06T12:00:10Z", "result" to result())
    private fun session() = mapOf("id" to "session-1", "started_at" to "2026-10-06T12:00:00Z",
        "ended_at" to "2026-10-06T12:00:11Z", "status" to "ended", "exercises" to listOf(attempt()))

    @Test fun settings_default_old_payloads_and_validate_each_target() {
        val old = mapOf("injured_leg" to "right", "heel_zero" to null)
        assertEquals(mapOf("squat" to 10, "sit_to_stand" to 10), AppSettingsPayload.validate(old)["rep_targets"])
        assertEquals("right", AppSettingsPayload.validate(old)["injured_leg"])
        for (targets in listOf(mapOf("squat" to 0, "sit_to_stand" to 10),
            mapOf("squat" to 1001, "sit_to_stand" to 10), mapOf("squat" to 1.0, "sit_to_stand" to 10),
            mapOf("squat" to true, "sit_to_stand" to 10), mapOf("squat" to 10))) {
            assertThrows(IllegalArgumentException::class.java) { AppSettingsPayload.validate(old + ("rep_targets" to targets)) }
        }
    }

    @Test fun session_accepts_finished_and_unfinished_records_with_nullable_metrics() {
        assertEquals(session(), WorkoutSessionPayload.validate(session()))
        val missing = result() + mapOf("latest_peak_deg" to null, "reference_peak_deg" to null, "difference_deg" to null)
        val active = session() + mapOf("status" to "active", "ended_at" to null,
            "exercises" to listOf(attempt() + ("result" to missing)))
        assertNull(WorkoutSessionPayload.validate(active)["ended_at"])
        val partial = result() + mapOf("repetitions" to 1, "outcome" to "interrupted")
        WorkoutSessionPayload.validate(session() + ("exercises" to listOf(attempt() + ("result" to partial))))
    }

    @Test fun session_rejects_invalid_dates_counts_duplicates_and_unknown_fields() {
        val edits = listOf(mapOf("started_at" to "2026-02-30T12:00:00Z"),
            mapOf("ended_at" to "2026-10-06T11:59:00Z"), mapOf("status" to "active"),
            mapOf("id" to " "), mapOf("id" to "x".repeat(129)), mapOf("unexpected" to true),
            mapOf("exercises" to listOf(attempt(), attempt())),
            mapOf("exercises" to listOf(attempt() + ("started_at" to "2026-10-06T11:59:00Z"))),
            mapOf("exercises" to listOf(attempt() + ("result" to result() + ("repetitions" to 3)))),
            mapOf("exercises" to listOf(attempt() + ("result" to result() + ("rep_target" to 2.0)))),
            mapOf("exercises" to listOf(attempt() + ("result" to result() + ("latest_peak_deg" to Double.NaN)))),
            mapOf("exercises" to listOf(attempt() + ("result" to result() + ("repetitions" to 1)))))
        for (edit in edits) assertThrows(IllegalArgumentException::class.java) { WorkoutSessionPayload.validate(session() + edit) }
    }

    @Test fun stored_results_match_dart_duration_and_difference_contract() {
        for (edit in listOf(mapOf("active_s" to null), mapOf("active_s" to Double.POSITIVE_INFINITY),
            mapOf("difference_deg" to null), mapOf("difference_deg" to 5.0),
            mapOf("latest_peak_deg" to null), mapOf("reference_peak_deg" to null))) {
            val record = session() + ("exercises" to listOf(attempt() + ("result" to result() + edit)))
            assertThrows(IllegalArgumentException::class.java) { WorkoutSessionPayload.validate(record) }
        }
        val unknown = result() + mapOf("latest_peak_deg" to null, "difference_deg" to null)
        WorkoutSessionPayload.validate(session() + ("exercises" to listOf(attempt() + ("result" to unknown))))
    }
}
