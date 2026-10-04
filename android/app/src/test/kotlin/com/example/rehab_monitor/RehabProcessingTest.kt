package com.example.rehab_monitor

import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class RehabProcessingTest {
    private class FakeProcessor : RehabProcessing.Processor {
        val calls = mutableListOf<String>()
        val threads = mutableListOf<Thread>()
        var state = "setup"
        var cycles = 0
        var summary: String? = null
        var blockedCommand: (() -> Unit)? = null
        private fun record(call: String) { calls.add(call); threads.add(Thread.currentThread()) }
        override fun newParser() { record("parser"); state = "needs_calibration" }
        override fun parse(line: String): String { record(line); cycles++; return "sample:$cycles" }
        override fun command(action: String, config: Map<*, *>?): String {
            record(action); blockedCommand?.invoke(); state = if (action == "end") "ended" else "active"
            if (action == "end") summary = "completed:$cycles"
            return snapshot()
        }
        override fun interrupt(reason: String): String {
            record("interrupt:$reason")
            if (state == "active") summary = "interrupted:$cycles"
            state = "needs_calibration"
            return snapshot()
        }
        override fun snapshot() = "$state:$cycles:$summary"
    }

    private fun await(latch: CountDownLatch) = assertTrue(latch.await(3, TimeUnit.SECONDS))
    private fun close(queue: RehabProcessing) {
        val done = CountDownLatch(1)
        queue.close("disconnect") { done.countDown() }
        await(done)
    }

    @Test fun frames_and_commands_run_in_order_on_one_background_worker() {
        val fake = FakeProcessor()
        val caller = Thread.currentThread()
        var factoryThread: Thread? = null
        val queue = RehabProcessing({ factoryThread = Thread.currentThread(); fake })
        try {
            val parse = queue.newParser()
            assertEquals("sample:1", parse("first"))
            val commanded = CountDownLatch(1)
            queue.command("start", null) { assertTrue(it.isSuccess); commanded.countDown() }
            assertEquals("sample:2", parse("second"))
            await(commanded)
            assertEquals(listOf("parser", "first", "start", "second"), fake.calls)
            assertTrue(fake.threads.all { it !== caller && it === factoryThread })
            assertEquals("active:2:null", queue.lastSnapshot)
        } finally { close(queue) }
    }

    @Test fun retry_interrupts_before_replacement_parser_and_rejects_old_frames() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        try {
            val old = queue.newParser()
            old("first")
            val started = CountDownLatch(1)
            queue.command("start", null) { started.countDown() }; await(started)
            val fresh = queue.newParser()
            assertNull(old("stale"))
            assertEquals("sample:2", fresh("fresh"))
            assertEquals(listOf("parser", "first", "start", "interrupt:TCP connection restarted.", "parser", "fresh"), fake.calls)
            assertEquals("interrupted:1", fake.summary)
        } finally { close(queue) }
    }

    @Test fun disconnect_invalidates_inflight_and_queued_commands_but_retains_summary() {
        val fake = FakeProcessor()
        val callbacks = LinkedBlockingQueue<() -> Unit>()
        val queue = RehabProcessing({ fake }, { callbacks.add(it) })
        queue.newParser()("frame")
        val entered = CountDownLatch(1)
        val released = CountDownLatch(1)
        fake.blockedCommand = { entered.countDown(); released.await() }
        var oldResult: Result<String>? = null
        var queuedResult: Result<String>? = null
        queue.command("start", null) { oldResult = it }
        await(entered)
        queue.command("end", null) { queuedResult = it }
        var stopped: Result<String?>? = null
        queue.close("background") { stopped = it }
        released.countDown()
        repeat(3) { callbacks.poll(3, TimeUnit.SECONDS)!!.invoke() }
        assertTrue(oldResult!!.isFailure)
        assertTrue(queuedResult!!.isFailure)
        assertFalse(fake.calls.contains("end"))
        assertEquals("interrupted:1", fake.summary)
        assertEquals(queue.lastSnapshot, stopped!!.getOrThrow())
        assertThrows(IllegalStateException::class.java) { queue.newParser() }
        val restarted = RehabProcessing({ FakeProcessor() })
        assertEquals("sample:1", restarted.newParser()("fresh"))
        close(restarted)
    }

    @Test fun command_completion_is_guarded_again_when_ui_callback_runs() {
        val callbacks = LinkedBlockingQueue<() -> Unit>()
        val queue = RehabProcessing({ FakeProcessor() }, { callbacks.add(it) })
        queue.newParser()
        var result: Result<String>? = null
        queue.command("start", null) { result = it }
        val callback = callbacks.poll(3, TimeUnit.SECONDS)!!
        queue.newParser()
        callback()
        assertTrue(result!!.isFailure)
        queue.close("disconnect") {}
        callbacks.poll(3, TimeUnit.SECONDS)!!.invoke()
    }

    @Test fun inactive_commands_rejected_without_constructing_processor() {
        var created = false
        val queue = RehabProcessing({ created = true; FakeProcessor() })
        val done = CountDownLatch(1)
        queue.command("start", null) { assertTrue(it.isFailure); done.countDown() }
        await(done)
        close(queue)
        assertFalse(created)
    }

    @Test fun posted_sample_is_discarded_across_socket_generations() {
        val callbacks = LinkedBlockingQueue<() -> Unit>()
        val queue = RehabProcessing({ FakeProcessor() }, { callbacks.add(it) })
        queue.newParser()("frame")
        val oldToken = queue.generation
        var emitted = false
        queue.dispatchCurrent(oldToken) { emitted = true }
        val posted = callbacks.poll(3, TimeUnit.SECONDS)!!
        queue.newParser()
        posted()
        assertFalse(emitted)
        queue.close("disconnect") {}
        callbacks.poll(3, TimeUnit.SECONDS)!!.invoke()
    }

    @Test fun ended_summary_survives_disconnect() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        queue.newParser()("frame")
        val ended = CountDownLatch(1)
        queue.command("end", null) { ended.countDown() }; await(ended)
        close(queue)
        assertEquals("completed:1", fake.summary)
        assertEquals("needs_calibration:1:completed:1", queue.lastSnapshot)
    }

    @Test fun duplicate_close_waits_for_same_interrupted_summary() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        queue.newParser()("frame")
        val entered = CountDownLatch(1)
        val released = CountDownLatch(1)
        fake.blockedCommand = { entered.countDown(); released.await() }
        queue.command("start", null) {}
        await(entered)
        val first = CountDownLatch(1)
        val second = CountDownLatch(1)
        var firstSnapshot: String? = null
        var secondSnapshot: String? = null
        queue.close("background") { firstSnapshot = it.getOrThrow(); first.countDown() }
        queue.close("disconnect") { secondSnapshot = it.getOrThrow(); second.countDown() }
        val returnedEarly = second.await(100, TimeUnit.MILLISECONDS)
        released.countDown()
        await(first); await(second)
        assertFalse(returnedEarly)
        assertEquals("needs_calibration:1:interrupted:1", firstSnapshot)
        assertEquals(firstSnapshot, secondSnapshot)
        assertEquals(1, fake.calls.count { it.startsWith("interrupt:") })
        var repeated: String? = null
        queue.close("later disconnect") { repeated = it.getOrThrow() }
        assertEquals(firstSnapshot, repeated)
    }

    @Test fun channel_arguments_validate_exact_config_types_and_actions() {
        val config = mapOf("ranges_confirmed" to true, "mounting_confirmed" to false,
            "thigh_axis" to mapOf("index" to 1, "sign" to -1),
            "shin_axis" to mapOf("index" to 0, "sign" to 1))
        assertEquals("configure", RehabProcessing.validateCommand(mapOf("action" to "configure", "config" to config)).first)
        for (bad in listOf(null, mapOf("action" to "unknown"), mapOf("action" to "start", "config" to "bad"),
            mapOf("action" to "configure", "config" to config + ("ranges_confirmed" to 1)),
            mapOf("action" to "configure", "config" to config + ("thigh_axis" to mapOf("index" to 1.0, "sign" to true))))) {
            assertThrows(IllegalArgumentException::class.java) { RehabProcessing.validateCommand(bad) }
        }
    }

    @Test fun stale_retry_callback_cannot_interrupt_replacement_session() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        queue.newParser()("old frame")
        val oldEpoch = queue.generation
        val paused = CountDownLatch(1)
        val resumed = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val oldWorker = Thread {
            paused.countDown() // Old TCP worker has already passed its active check.
            resumed.await()
            queue.interrupt("stale TCP retry", oldEpoch) { completed.countDown() }
        }
        oldWorker.start()
        try {
            await(paused)
            val lost = CountDownLatch(1)
            queue.interrupt("Wi-Fi lost") { lost.countDown() }; await(lost)
            val fresh = queue.newParser()
            val started = CountDownLatch(1)
            queue.command("start", null) { started.countDown() }; await(started)
            val freshEpoch = queue.generation
            assertTrue(freshEpoch > oldEpoch)
            resumed.countDown(); await(completed)
            assertEquals(freshEpoch, queue.generation)
            assertEquals("active", fake.state)
            assertFalse(fake.calls.contains("interrupt:stale TCP retry"))
            assertEquals("sample:2", fresh("fresh frame"))
            val accepted = CountDownLatch(1)
            queue.command("end", null) { assertTrue(it.isSuccess); accepted.countDown() }; await(accepted)
        } finally { resumed.countDown(); oldWorker.join(3000); close(queue) }
    }

    @Test fun stale_parser_setup_cannot_reset_replacement_session() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        queue.newParser()
        val oldEpoch = queue.generation
        val fresh = queue.newParser()
        val started = CountDownLatch(1)
        queue.command("start", null) { started.countDown() }; await(started)
        val freshEpoch = queue.generation
        try {
            assertThrows(RehabProcessing.UnavailableException::class.java) { queue.newParser(oldEpoch) }
            assertEquals(freshEpoch, queue.generation)
            assertTrue(freshEpoch > oldEpoch)
            assertEquals("active", fake.state)
            assertEquals("sample:1", fresh("fresh frame"))
        } finally { close(queue) }
    }

    @Test fun current_retry_advances_epoch_and_allows_replacement_parser() {
        val fake = FakeProcessor()
        val queue = RehabProcessing({ fake })
        var captured = queue.generation
        val old = queue.newParser(captured) { captured = it }
        old("old frame")
        val oldEpoch = captured
        val interrupted = CountDownLatch(1)
        val next = queue.interrupt("current TCP retry", oldEpoch) { assertTrue(it.isSuccess); interrupted.countDown() }
        await(interrupted)
        assertEquals(oldEpoch + 1, next)
        assertEquals(next, queue.generation)
        val fresh = queue.newParser(next) { captured = it }
        try {
            assertEquals(queue.generation, captured)
            assertNull(old("stale frame"))
            assertEquals("sample:2", fresh("fresh frame"))
            assertTrue(fake.calls.indexOf("interrupt:current TCP retry") < fake.calls.lastIndexOf("parser"))
        } finally { close(queue) }
    }
}
