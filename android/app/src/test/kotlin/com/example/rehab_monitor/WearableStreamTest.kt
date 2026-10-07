package com.example.rehab_monitor

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class WearableStreamTest {
    private class TestSocket(private val source: InputStream) : Socket() {
        var closedByOwner = false
        override fun getInputStream() = source
        override fun setSoTimeout(timeout: Int) {}
        override fun close() { closedByOwner = true; source.close() }
    }

    private val sample = "{\"type\":\"sample\",\"restart\":false}"
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(3, TimeUnit.SECONDS))

    @Test fun diagnostics_distinguish_device_gaps_from_rejected_frames() {
        for (rejected in listOf(false, true)) {
            val diagnostics = CopyOnWriteArrayList<String>()
            val parsed = CopyOnWriteArrayList<String>()
            val retried = CountDownLatch(1)
            val rows = "time_us,header\n100000,valid\n" +
                (if (rejected) "120000,bad\n" else "") + "2802000,valid\n"
            val stream = WearableStream({ TestSocket(ByteArrayInputStream(rows.toByteArray())) },
                { { line -> parsed.add(line); if (line.endsWith(",valid"))
                    "{\"type\":\"sample\",\"time_us\":${line.substringBefore(',')}}" else null } }, {},
                clock = { 0 }, delay = { retried.countDown(); throw InterruptedException() },
                diagnostic = { diagnostics.add(it) })
            stream.start(); await(retried); stream.stop()
            assertEquals(if (rejected) 4 else 3, parsed.size)
            assertTrue(diagnostics.any { it.contains("device_gap_us=2702000") &&
                it.contains("rejected=${if (rejected) 1 else 0}") && it.contains("accepted=2") })
            assertTrue(diagnostics.none { it.contains(",valid") || it.contains(",bad") })
        }
    }

    @Test fun diagnostics_report_stale_socket_without_changing_retry() {
        var now = 0L
        val diagnostics = CopyOnWriteArrayList<String>()
        val retried = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(object : InputStream() {
            override fun read(): Int { now += 1000; throw SocketTimeoutException() }
        }) }, { { sample } }, {}, clock = { now },
            delay = { retried.countDown(); throw InterruptedException() },
            diagnostic = { diagnostics.add(it) })
        stream.start(); await(retried); stream.stop()
        assertEquals(10000L, now)
        assertTrue(diagnostics.any { it.contains("stale") && it.contains("accepted=0") })
        assertTrue(diagnostics.any { it.contains("SocketTimeoutException") })
    }

    @Test fun diagnostics_separate_parser_latency_rollover_and_rate_limit() {
        var now = 0L
        var parsed = 0
        val diagnostics = CopyOnWriteArrayList<String>()
        val retried = CountDownLatch(1)
        val times = listOf(4294960000L, 1000L, 21000L, 41000L)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("a\nb\nc\nd\n".toByteArray())) },
            { { _ ->
                if (parsed > 0) now += 300
                "{\"type\":\"sample\",\"time_us\":${times[parsed++]}}"
            } }, {}, clock = { now },
            delay = { retried.countDown(); throw InterruptedException() },
            diagnostic = { diagnostics.add(it) })
        stream.start(); await(retried); stream.stop()
        assertEquals(4, parsed)
        val anomalies = diagnostics.filter { it.startsWith("frame_timing") }
        assertEquals(1, anomalies.size)
        assertTrue(anomalies.single().contains("device_event=reset_or_rollover"))
        assertTrue(anomalies.single().contains("parse_ms=300"))
        assertTrue(anomalies.single().contains("read_wait_ms=0"))
        assertTrue(anomalies.single().contains("rejected=0"))
    }

    @Test fun diagnostics_quiet_after_rejected_stream_recovers() {
        var now = 0L
        var parsed = 0
        val diagnostics = CopyOnWriteArrayList<String>()
        val retried = CountDownLatch(1)
        val rows = "0,bad\n" + (1..100).joinToString("") { "${it * 20000},ok\n" }
        val stream = WearableStream({ TestSocket(ByteArrayInputStream(rows.toByteArray())) },
            { { line ->
                now += 20
                parsed++
                if (line.endsWith("bad")) null else
                    "{\"type\":\"sample\",\"time_us\":${line.substringBefore(',')}}"
            } }, {}, clock = { now },
            delay = { retried.countDown(); throw InterruptedException() },
            diagnostic = { diagnostics.add(it) })
        stream.start(); await(retried); stream.stop()
        assertEquals(101, parsed)
        assertEquals(1, diagnostics.count { it.startsWith("frame_timing") })
    }

    @Test fun diagnostics_distinguish_incoming_rejects_from_socket_silence() {
        var now = 0L
        val diagnostics = CopyOnWriteArrayList<String>()
        val done = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read() = throw UnsupportedOperationException()
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                now += 1000
                "100,bad\n".toByteArray().copyInto(bytes, offset)
                return 8
            }
        }
        val stream = WearableStream({ TestSocket(input) }, { { null } },
            { if (it.contains("invalid_protocol")) done.countDown() }, clock = { now },
            diagnostic = { diagnostics.add(it) })
        stream.start(); await(done); stream.stop()
        assertTrue(diagnostics.any { it.startsWith("stale") && it.contains("rejected=9") &&
            it.contains("receive_idle_ms=0") && it.contains("read_wait_ms=1000") })
    }

    @Test fun diagnostics_report_slow_rejected_parser_without_payload() {
        var now = 0L
        val diagnostics = CopyOnWriteArrayList<String>()
        val failed = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("100,private\n".toByteArray())) },
            { { now += 10001; null } }, { if (it.contains("invalid_protocol")) failed.countDown() },
            clock = { now }, diagnostic = { diagnostics.add(it) })
        stream.start(); await(failed); stream.stop()
        assertTrue(diagnostics.any { it.startsWith("parse_timing") && it.contains("parse_ms=10001") })
        assertTrue(diagnostics.any { it.startsWith("stale") && it.contains("receive_idle_ms=10001") })
        assertTrue(diagnostics.none { it.contains("private") })
    }

    @Test fun fragmented_and_coalesced_frames() {
        val lines = CopyOnWriteArrayList<String>()
        val retried = CountDownLatch(1)
        val input = object : ByteArrayInputStream("header\r\nfirst\nsecond\n".toByteArray()) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                super.read(bytes, offset, minOf(length, 2))
        }
        val stream = WearableStream({ TestSocket(input) }, { { line -> lines.add(line); sample } },
            {}, delay = { retried.countDown(); throw InterruptedException() })
        stream.start(); await(retried); stream.stop()
        assertEquals(listOf("header", "first", "second"), lines)
    }

    @Test fun overlong_frame_rejected() {
        val parsed = CopyOnWriteArrayList<String>()
        val failed = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream(("x".repeat(513) + "\n").toByteArray())) },
            { { line -> parsed.add(line); sample } }, { if (it.contains("protocol")) failed.countDown() })
        stream.start(); await(failed); stream.stop()
        assertTrue(parsed.isEmpty())
    }

    @Test fun eof_and_valid_sample_timeout() {
        for (timeout in listOf(false, true)) {
            val events = CopyOnWriteArrayList<String>()
            val retried = CountDownLatch(1)
            var now = 0L
            val input = if (timeout) object : InputStream() {
                override fun read(): Int { now += 1000; throw SocketTimeoutException() }
            } else ByteArrayInputStream(byteArrayOf())
            val stream = WearableStream({ TestSocket(input) }, { { sample } }, { events.add(it) },
                clock = { now }, delay = { retried.countDown(); throw InterruptedException() })
            stream.start(); await(retried); stream.stop()
            assertTrue(events.any { it.contains("reconnecting") })
            if (timeout) assertTrue(now >= 10000)
        }
    }

    @Test fun invalid_samples_do_not_keep_session_live() {
        var now = 0L
        val failed = CountDownLatch(1)
        val events = CopyOnWriteArrayList<String>()
        val input = object : InputStream() {
            override fun read(): Int { now += 1000; return '\n'.code }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                bytes[offset] = read().toByte(); return 1
            }
        }
        val stream = WearableStream({ TestSocket(input) }, { { null } },
            { events.add(it); if (it.contains("protocol")) failed.countDown() }, clock = { now })
        stream.start(); await(failed); stream.stop()
        assertTrue(events.none { it.contains("\"sample\"") })
    }

    @Test fun retry_delays_are_1_2_5_seconds() {
        val delays = CopyOnWriteArrayList<Long>()
        val finished = CountDownLatch(1)
        val stream = WearableStream({ throw java.io.IOException("refused") }, { { sample } }, {},
            delay = { delays.add(it); if (delays.size == 3) { finished.countDown(); throw InterruptedException() } })
        stream.start(); await(finished); stream.stop()
        assertEquals(listOf(1000L, 2000L, 5000L), delays)
    }

    @Test fun stop_cancels_read_and_retry() {
        val entered = CountDownLatch(1)
        val released = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read(): Int { entered.countDown(); released.await(); return -1 }
            override fun close() { released.countDown() }
        }
        val socket = TestSocket(input)
        val stream = WearableStream({ socket }, { { sample } }, {})
        stream.start(); await(entered); stream.stop()
        assertTrue(socket.closedByOwner)
        val delayEntered = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val retryStream = WearableStream({ throw java.io.IOException() }, { { sample } }, {},
            delay = { delayEntered.countDown(); try { CountDownLatch(1).await() } catch (e: InterruptedException) {
                interrupted.countDown(); throw e
            } })
        retryStream.start(); await(delayEntered); retryStream.stop(); await(interrupted)
    }

    @Test fun old_generation_cannot_emit() {
        val entered = CountDownLatch(1)
        val released = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val parserThread = java.util.concurrent.atomic.AtomicReference<Thread>()
        val events = CopyOnWriteArrayList<String>()
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("frame\n".toByteArray())) },
            { { parserThread.set(Thread.currentThread()); entered.countDown(); while (true) { try { released.await(); break } catch (_: InterruptedException) {} }; completed.countDown(); sample } },
            { events.add(it) })
        stream.start(); await(entered); stream.stop(); released.countDown(); await(completed)
        parserThread.get().join(3000)
        assertFalse(parserThread.get().isAlive)
        assertTrue(events.none { it.contains("\"sample\"") })
    }

    @Test fun parses_every_frame_but_throttles_and_latches_restart() {
        var now = 0L
        var parsed = 0
        val events = CopyOnWriteArrayList<String>()
        val finished = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("a\nb\nc\nd\n".toByteArray())) },
            { { _ ->
                now = listOf(0L, 10L, 50L, 100L)[parsed++]
                if (parsed == 2) sample.replace("false", "true") else sample
            } }, { if (it.contains("\"sample\"")) events.add(it) }, clock = { now },
            delay = { finished.countDown(); throw InterruptedException() })
        stream.start(); await(finished); stream.stop()
        assertEquals(4, parsed)
        assertEquals(2, events.size)
        assertTrue(events.last().contains("\"restart\":true"))
    }

    @Test fun new_parser_for_every_tcp_retry() {
        var parserCount = 0
        var retries = 0
        val finished = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("frame\n".toByteArray())) },
            { parserCount++; { sample } }, {}, delay = {
                if (++retries == 2) { finished.countDown(); throw InterruptedException() }
            })
        stream.start(); await(finished); stream.stop()
        assertEquals(2, parserCount)
    }

    @Test fun retry_interrupts_session_before_backoff_and_new_samples() {
        val calls = CopyOnWriteArrayList<String>()
        val finished = CountDownLatch(1)
        var retries = 0
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("frame\n".toByteArray())) },
            { calls.add("parser"); { calls.add("frame"); sample } }, {},
            delay = { calls.add("backoff"); if (++retries == 2) { finished.countDown(); throw InterruptedException() } },
            interruptSession = { calls.add("interrupt") })
        stream.start(); await(finished); stream.stop()
        assertEquals(listOf("parser", "frame", "interrupt", "backoff", "parser", "frame", "interrupt", "backoff"), calls)
    }

    @Test fun display_throttle_retains_cumulative_analytics() {
        val queue = RehabProcessing({ object : RehabProcessing.Processor {
            var count = 0
            override fun newParser() {}
            override fun parse(line: String): String { count++; return "{\"type\":\"sample\",\"analytics\":{\"cycles\":$count}}" }
            override fun command(action: String, config: Map<*, *>?) = snapshot()
            override fun interrupt(reason: String) = snapshot()
            override fun snapshot() = "cycles:$count"
        } })
        var now = 0L
        val events = CopyOnWriteArrayList<String>()
        val finished = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("a\nb\nc\nd\n".toByteArray())) },
            { val parse = queue.newParser(); { line -> now += 40; parse(line) } },
            { if (it.contains("\"sample\"")) events.add(it) }, clock = { now },
            delay = { finished.countDown(); throw InterruptedException() })
        stream.start(); await(finished); stream.stop()
        assertEquals(2, events.size)
        assertTrue(events.last().contains("\"cycles\":4"))
        assertEquals("cycles:4", queue.lastSnapshot)
        val closed = CountDownLatch(1)
        queue.close("disconnect") { closed.countDown() }; await(closed)
    }

    @Test fun previously_live_invalid_frames_become_stale_and_retry() {
        var now = 0L
        var parsed = 0
        val retried = CountDownLatch(1)
        val stream = WearableStream({ TestSocket(ByteArrayInputStream("valid\nbad\nbad\nbad\n".toByteArray())) },
            { { _ -> if (parsed++ == 0) sample else { now += 1000; null } } }, {},
            clock = { now }, delay = { retried.countDown(); throw InterruptedException() })
        stream.start(); await(retried); stream.stop()
        assertEquals(4, parsed)
    }

    @Test fun single_use_stream_cannot_restart() {
        val oldParser = CountDownLatch(1)
        val releaseParser = CountDownLatch(1)
        val secondAttempt = CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val stream = WearableStream({
            if (attempts.incrementAndGet() > 1) secondAttempt.countDown()
            TestSocket(ByteArrayInputStream("frame\n".toByteArray()))
        }, { { oldParser.countDown(); while (true) {
            try { releaseParser.await(); break } catch (_: InterruptedException) {}
        }; sample } }, {})
        stream.start(); await(oldParser); stream.stop(); stream.start()
        try { assertFalse(secondAttempt.await(250, TimeUnit.MILLISECONDS)) }
        finally { stream.stop(); releaseParser.countDown() }
    }

    @Test fun valid_frame_after_deadline_cannot_refresh_liveness() {
        var now = 0L
        var parsed = 0
        var reads = 0
        val retried = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read() = throw UnsupportedOperationException()
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (reads == 2) return -1
                if (reads++ == 1) now = 10000
                val chunk = if (reads == 1) "frame\nframe".toByteArray() else "\n".toByteArray()
                chunk.copyInto(bytes, offset)
                return chunk.size
            }
        }
        val stream = WearableStream({ TestSocket(input) }, { { parsed++; sample } }, {},
            clock = { now }, delay = { retried.countDown(); throw InterruptedException() })
        stream.start(); await(retried); stream.stop()
        assertEquals(1, parsed)
    }

    @Test fun valid_frame_before_ten_seconds_recovers_without_interrupting() {
        var now = 0L
        var reads = 0
        val diagnostics = CopyOnWriteArrayList<String>()
        val events = CopyOnWriteArrayList<String>()
        val retried = CountDownLatch(1)
        var interrupts = 0
        val input = object : InputStream() {
            override fun read() = throw UnsupportedOperationException()
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (++reads in 2..10) { now += 1000; throw SocketTimeoutException() }
                if (reads > 11) return -1
                if (reads == 11) now = 9999
                val row = "frame\n".toByteArray()
                row.copyInto(bytes, offset)
                return row.size
            }
        }
        val stream = WearableStream({ TestSocket(input) }, { { sample } }, { events.add(it) },
            clock = { now }, delay = { retried.countDown(); throw InterruptedException() },
            interruptSession = { interrupts++ }, diagnostic = { diagnostics.add(it) })
        stream.start(); await(retried); stream.stop()
        assertEquals(2, events.count { it.contains("\"sample\"") })
        assertEquals(1, interrupts) // Only the later EOF interrupts the session.
        assertEquals(1, diagnostics.count { it.startsWith("readings_waiting") })
        assertEquals(1, diagnostics.count { it.startsWith("readings_resumed") })
        assertTrue(diagnostics.none { it.startsWith("stale") })
    }
}
