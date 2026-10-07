package com.example.rehab_monitor

import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

object WorkoutSessionPayload {
    private fun record(value: Any?, keys: Set<String>): Map<*, *> {
        require(value is Map<*, *> && value.keys == keys) { "Invalid workout record fields." }
        return value
    }

    private fun id(value: Any?): String {
        require(value is String && value.length in 1..128 && value.trim() == value && value.isNotBlank()) { "Invalid workout ID." }
        return value
    }

    private fun timestamp(value: Any?): Long {
        require(value is String && Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,6})?Z").matches(value)) { "Invalid workout timestamp." }
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT).apply {
            isLenient = false; timeZone = TimeZone.getTimeZone("UTC")
        }
        val position = ParsePosition(0)
        val date = format.parse(value.take(19), position)
        require(date != null && position.index == 19) { "Invalid workout date." }
        val micros = if (value.length > 20) value.substring(20, value.length - 1).padEnd(6, '0').toLong() else 0
        return date.time * 1000 + micros
    }

    private fun result(value: Any?): Map<String, Any?> {
        val raw = record(value, setOf("repetitions", "rep_target", "active_s", "latest_peak_deg",
            "reference_peak_deg", "difference_deg", "outcome"))
        fun count(key: String, range: IntRange): Int {
            val count = raw[key]
            require((count is Int || count is Long) && (count as Number).toLong() in range) { "Invalid $key." }
            return (count as Number).toInt()
        }
        val target = count("rep_target", 1..1000)
        val repetitions = count("repetitions", 0..target)
        val outcome = raw["outcome"]
        require(outcome in setOf("target_reached", "ended_early", "interrupted")) { "Invalid exercise outcome." }
        require(outcome != "target_reached" || repetitions == target) { "Target completion needs the target repetitions." }
        fun metric(key: String, range: ClosedFloatingPointRange<Double>): Double? {
            val number = raw[key] ?: return null
            require(number is Number && number.toDouble().isFinite() && number.toDouble() in range) { "Invalid $key." }
            return number.toDouble()
        }
        val activeSeconds = metric("active_s", 0.0..Double.MAX_VALUE)
        require(activeSeconds != null) { "Exercise duration is required." }
        val latest = metric("latest_peak_deg", 0.0..180.0)
        val reference = metric("reference_peak_deg", 0.0..180.0)
        val difference = metric("difference_deg", -180.0..180.0)
        require(if (latest == null || reference == null) difference == null
            else difference != null && kotlin.math.abs(difference - (latest - reference)) <= 0.000001) {
            "Invalid reference difference."
        }
        return mapOf("repetitions" to repetitions, "rep_target" to target, "outcome" to outcome,
            "active_s" to activeSeconds, "latest_peak_deg" to latest,
            "reference_peak_deg" to reference, "difference_deg" to difference)
    }

    fun validate(value: Any?): Map<String, Any?> {
        val raw = record(value, setOf("id", "started_at", "ended_at", "status", "exercises"))
        val sessionId = id(raw["id"])
        val start = timestamp(raw["started_at"])
        val end = raw["ended_at"]?.let { timestamp(it) }
        require(raw["status"] in setOf("active", "ended") && (raw["status"] == "ended") == (end != null)) { "Session status must match its end timestamp." }
        require(end == null || end >= start) { "Session end precedes its start." }
        val attempts = raw["exercises"]
        require(attempts is List<*>) { "Exercises must be a list." }
        val seen = mutableSetOf<String>()
        var previousEnd = start
        val exercises = attempts.map { value ->
            val attempt = record(value, setOf("id", "exercise_id", "started_at", "ended_at", "result"))
            val attemptId = id(attempt["id"])
            require(seen.add(attemptId)) { "Duplicate exercise attempt." }
            require(attempt["exercise_id"] in setOf("squat", "sit_to_stand")) { "Unsupported exercise." }
            val attemptStart = timestamp(attempt["started_at"])
            val attemptEnd = timestamp(attempt["ended_at"])
            require(attemptStart >= previousEnd && attemptEnd >= attemptStart && (end == null || attemptEnd <= end)) { "Exercise timestamps are out of order." }
            previousEnd = attemptEnd
            mapOf("id" to attemptId, "exercise_id" to attempt["exercise_id"], "started_at" to attempt["started_at"],
                "ended_at" to attempt["ended_at"], "result" to result(attempt["result"]))
        }
        return mapOf("id" to sessionId, "started_at" to raw["started_at"], "ended_at" to raw["ended_at"],
            "status" to raw["status"], "exercises" to exercises)
    }
}
