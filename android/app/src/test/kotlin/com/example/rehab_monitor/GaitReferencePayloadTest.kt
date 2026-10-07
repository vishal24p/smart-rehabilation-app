package com.example.rehab_monitor

import org.junit.Assert.*
import org.junit.Test

class GaitReferencePayloadTest {
    private fun reference() = mapOf<String, Any>(
        "measurement_version" to "gait_forefoot_timing_v1",
        "placement" to "right_thigh_shin_bilateral_forefeet",
        "recorded_at" to "2026-10-06T06:00:00.123456Z",
        "right_strides" to 10, "left_strides" to 11,
        "metrics" to mapOf("cadence_spm" to 120.0, "right_step_time_s" to 0.5,
            "left_step_time_s" to 0.5, "right_stride_time_s" to 1.0, "left_stride_time_s" to 1.0),
    )

    @Test fun accepts_complete_reference_and_gait_commands() {
        assertEquals(reference(), GaitReferencePayload.validate(reference()))
        assertEquals(10L, GaitReferencePayload.validate(reference() + ("right_strides" to 10L))["right_strides"])
        assertEquals("1582-10-10T06:00:00Z", GaitReferencePayload.validate(reference() + ("recorded_at" to "1582-10-10T06:00:00Z"))["recorded_at"])
        val config = mapOf("ranges_confirmed" to true, "mounting_confirmed" to true,
            "forefoot_mapping_confirmed" to true, "thigh_axis" to mapOf("index" to 1, "sign" to -1),
            "shin_axis" to mapOf("index" to 0, "sign" to 1))
        assertEquals("gait_configure", RehabProcessing.validateCommand(mapOf("action" to "gait_configure", "config" to config)).first)
        val begin = mapOf("distance_m" to 10.0, "tolerance_pct" to 20.0)
        assertEquals("gait_reference_begin", RehabProcessing.validateCommand(mapOf("action" to "gait_reference_begin", "config" to begin)).first)
        assertEquals("gait_session_begin", RehabProcessing.validateCommand(mapOf("action" to "gait_session_begin", "config" to begin + ("reference" to reference()))).first)
        for (action in listOf("gait_forefoot_unloaded", "gait_forefoot_loaded", "gait_standing",
            "gait_reference_finish", "gait_session_end", "gait_cancel")) {
            assertEquals(action, RehabProcessing.validateCommand(mapOf("action" to action)).first)
        }
    }

    @Test fun rejects_invalid_reference_types_metrics_counts_dates_and_compatibility() {
        val metrics = reference()["metrics"] as Map<*, *>
        val edits = listOf(
            mapOf("extra" to true),
            mapOf("measurement_version" to "thigh_tilt_v1"), mapOf("placement" to "front_thigh"),
            mapOf("right_strides" to 9), mapOf("left_strides" to 10.0), mapOf("right_strides" to true),
            mapOf("recorded_at" to "2026-02-30T06:00:00Z"), mapOf("recorded_at" to "2026-10-06T06:00:00+00:00"),
            mapOf("recorded_at" to "1500-02-29T06:00:00Z"), mapOf("recorded_at" to "0000-10-06T06:00:00Z"),
            mapOf("metrics" to metrics - "cadence_spm"), mapOf("metrics" to metrics + ("other" to 1)),
        ) + listOf(Double.NaN, Double.POSITIVE_INFINITY, 0.0, -1.0, "120", true).map {
            mapOf("metrics" to metrics + ("cadence_spm" to it))
        }
        for (edit in edits) assertThrows(IllegalArgumentException::class.java) { GaitReferencePayload.validate(reference() + edit) }
    }

    @Test fun rejects_heel_gait_contract_but_keeps_other_exercise_heel_actions() {
        val legacy = reference() + mapOf("measurement_version" to "gait_heel_timing_v1",
            "placement" to "right_thigh_shin_bilateral_heels")
        assertThrows(IllegalArgumentException::class.java) { GaitReferencePayload.validate(legacy) }
        assertThrows(IllegalArgumentException::class.java) {
            RehabProcessing.validateCommand(mapOf("action" to "gait_session_begin", "config" to
                mapOf("distance_m" to 10.0, "tolerance_pct" to 20.0, "reference" to legacy)))
        }
        for (action in listOf("gait_heel_unloaded", "gait_heel_loaded")) {
            assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(mapOf("action" to action)) }
        }
        for (action in listOf("heel_unloaded", "heel_loaded")) {
            assertEquals(action, RehabProcessing.validateCommand(mapOf("action" to action)).first)
        }
        val config = mapOf("ranges_confirmed" to true, "mounting_confirmed" to true,
            "heel_mapping_confirmed" to true, "thigh_axis" to mapOf("index" to 1, "sign" to -1),
            "shin_axis" to mapOf("index" to 0, "sign" to 1))
        assertThrows(IllegalArgumentException::class.java) {
            RehabProcessing.validateCommand(mapOf("action" to "gait_configure", "config" to config))
        }
    }

    @Test fun rejects_invalid_gait_config_and_begin_arguments() {
        val config = mapOf("distance_m" to 10.0, "tolerance_pct" to 20.0)
        for (edit in listOf(mapOf("distance_m" to Double.NaN), mapOf("distance_m" to -1),
            mapOf("extra" to true), mapOf("reference" to reference()),
            mapOf("distance_m" to 0), mapOf("distance_m" to true), mapOf("tolerance_pct" to 0),
            mapOf("tolerance_pct" to 101), mapOf("tolerance_pct" to Double.POSITIVE_INFINITY))) {
            assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(mapOf("action" to "gait_reference_begin", "config" to config + edit)) }
        }
        assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(mapOf("action" to "gait_session_begin", "config" to config)) }
        assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(mapOf("action" to "gait_configure", "config" to mapOf("ranges_confirmed" to true))) }
        val setup = mapOf("ranges_confirmed" to true, "mounting_confirmed" to true,
            "forefoot_mapping_confirmed" to true, "thigh_axis" to mapOf("index" to 1, "sign" to -1),
            "shin_axis" to mapOf("index" to 0, "sign" to 1))
        for (edit in listOf(mapOf("forefoot_mapping_confirmed" to 1), mapOf("mounting_confirmed" to "true"),
            mapOf("extra" to true), mapOf("shin_axis" to mapOf("index" to 0, "sign" to 1, "extra" to true)),
            mapOf("ranges_confirmed" to null), mapOf("thigh_axis" to mapOf("index" to 1.0, "sign" to 1)),
            mapOf("shin_axis" to mapOf("index" to 3, "sign" to 1)),
            mapOf("shin_axis" to mapOf("index" to 0, "sign" to true)))) {
            assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(mapOf("action" to "gait_configure", "config" to setup + edit)) }
        }
        assertEquals("gait_reference_begin", RehabProcessing.validateCommand(mapOf("action" to "gait_reference_begin", "config" to config + ("tolerance_pct" to 100))).first)
    }
}
