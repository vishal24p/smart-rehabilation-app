package com.example.rehab_monitor

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.ConnectException

/** Foreground TCP reader. Android supplies network-bound sockets; Python parses each frame. */
class WearableStream(
    private val createSocket: () -> Socket,
    private val parserFactory: () -> ((String) -> String?),
    private val event: (String) -> Unit,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val delay: (Long) -> Unit = { Thread.sleep(it) },
    private val interruptSession: () -> Unit = {},
    private val diagnostic: ((String) -> Unit)? = null,
) {
    class ProtocolException(message: String) : IOException(message)
    private val lock = Any()
    @Volatile private var active = false
    @Volatile private var socket: Socket? = null
    private var worker: Thread? = null

    fun start() = synchronized(lock) {
        if (worker != null) return@synchronized
        active = true
        worker = Thread({ run() }, "rehab-wearable").also { it.start() }
    }

    fun stop() {
        synchronized(lock) { active = false }
        try { socket?.close() } catch (_: IOException) {}
        worker?.interrupt()
    }

    private fun emit(value: String) = synchronized(lock) { if (active) event(value) }
    private fun diagnose(message: String) { runCatching { diagnostic?.invoke(message) } }
    private fun status(state: String, code: String) {
        val message = when (code) {
            "waiting_for_samples" -> "Connected to Wi-Fi. Waiting for sensor readings."
            "invalid_protocol" -> "Wearable data format is unsupported. Check the firmware CSV header."
            "connection_refused" -> "Wearable TCP connection refused. Check power and firmware port 5000. Retrying."
            "processing_failed" -> "Sensor processing failed. Disconnect and retry."
            else -> "Sensor readings stopped. Check wearable power. Reconnecting."
        }
        emit("{\"type\":\"status\",\"status\":\"$state\",\"code\":\"$code\",\"message\":\"$message\"}")
    }

    private fun run() {
        var retry = 0
        while (active) {
            try {
                val connected = createSocket()
                synchronized(lock) {
                    if (!active) { connected.close(); return }
                    socket = connected
                }
                connected.soTimeout = 1000
                status("receiving", "waiting_for_samples")
                read(connected, parserFactory()) { retry = 0 }
                if (active) throw IOException("Wearable closed stream")
            } catch (_: InterruptedException) {
                break
            } catch (error: ProtocolException) {
                diagnose("transport_failure kind=protocol exception=${error.javaClass.simpleName}")
                status("error", "invalid_protocol")
                break
            } catch (error: ConnectException) {
                if (!active) break
                diagnose("transport_failure kind=connect exception=${error.javaClass.simpleName}")
                interruptSession()
                status("reconnecting", "connection_refused")
            } catch (error: IOException) {
                if (!active) break
                val reason = when {
                    error is SocketTimeoutException -> "timeout"
                    error.message == "Wearable closed stream" -> "peer_closed"
                    else -> "socket_io"
                }
                diagnose("transport_failure kind=io reason=$reason exception=${error.javaClass.simpleName}")
                interruptSession()
                status("reconnecting", "connection_lost")
            } catch (error: RuntimeException) {
                diagnose("transport_failure kind=processing exception=${error.javaClass.simpleName}")
                status("error", "processing_failed")
                break
            } finally {
                try { socket?.close() } catch (_: IOException) {}
                socket = null
            }
            if (active) {
                try { delay(longArrayOf(1000, 2000, 5000)[minOf(retry++, 2)]) }
                catch (_: InterruptedException) { break }
            }
        }
        synchronized(lock) { active = false }
    }

    private fun read(connected: Socket, parse: (String) -> String?, valid: () -> Unit) {
        val input = connected.getInputStream()
        val buffer = ByteArray(512)
        val frame = ByteArrayOutputStream(513)
        var lastValid = clock()
        var lastEmission: Long? = null
        var receivedFrames = false
        var receivedValid = false
        var pendingRestart = false
        var accepted = 0L
        var rejected = 0L
        var rejectedSinceAccepted = 0L
        var lastDeviceTime: Long? = null
        var lastAnomaly: Long? = null
        var lastReceived = lastValid
        var readWaitMs = 0L
        var waiting = false
        val sampleTimestamp = diagnostic?.let { Regex("\"time_us\"\\s*:\\s*(\\d+)") }
        val csvTimestamp = diagnostic?.let { Regex("[+-]?[0-9]+") }
        fun checkDeadline() {
            val idleMs = clock() - lastValid
            if (idleMs >= 1000 && !waiting) {
                waiting = true
                diagnose("readings_waiting accepted=$accepted rejected=$rejected accepted_gap_ms=$idleMs deadline_ms=10000")
            }
            if (idleMs >= 10000) {
                if (diagnostic != null) diagnose("stale accepted=$accepted rejected=$rejected last_device_us=$lastDeviceTime accepted_gap_ms=${clock() - lastValid} receive_idle_ms=${clock() - lastReceived} read_wait_ms=$readWaitMs")
                if (receivedFrames && !receivedValid) throw ProtocolException("No valid samples")
                throw SocketTimeoutException("Sensor readings stale")
            }
        }
        while (active) {
            val readStart = if (diagnostic != null) clock() else 0
            val count = try { input.read(buffer) } catch (_: SocketTimeoutException) { 0 }
            if (diagnostic != null) {
                readWaitMs = clock() - readStart
                if (count > 0) lastReceived = clock()
            }
            checkDeadline()
            if (count < 0) {
                diagnose("eof accepted=$accepted rejected=$rejected last_device_us=$lastDeviceTime")
                return
            }
            for (index in 0 until count) {
                if (!active) return
                val byte = buffer[index]
                if (byte == '\n'.code.toByte()) {
                    val line = frame.toString(Charsets.UTF_8.name()).removeSuffix("\r")
                    frame.reset()
                    receivedFrames = true
                    if (line.toByteArray(Charsets.UTF_8).size > 512) throw ProtocolException("Frame too long")
                    val parseStart = if (diagnostic != null) clock() else 0
                    val sample = parse(line)
                    val parseMs = if (diagnostic != null) clock() - parseStart else 0
                    if (sample != null) {
                        if (waiting) {
                            diagnose("readings_resumed accepted_gap_ms=${clock() - lastValid}")
                            waiting = false
                        }
                        if (diagnostic != null) {
                            accepted++
                            val deviceTime = sampleTimestamp!!.find(sample)?.groupValues?.get(1)?.toLongOrNull()
                            val deviceGap = deviceTime?.let { current -> lastDeviceTime?.let { current - it } }
                            val arrivalGap = clock() - lastValid
                            if ((deviceGap != null && (deviceGap < 0 || deviceGap > 250000)) ||
                                arrivalGap > 250 || parseMs > 250 || rejectedSinceAccepted > 0) {
                                val now = clock()
                                if (lastAnomaly == null || now - lastAnomaly >= 1000) {
                                    val deviceEvent = when {
                                        deviceGap == null -> "first"
                                        deviceGap < 0 -> "reset_or_rollover"
                                        deviceGap > 250000 -> "gap"
                                        else -> "contiguous"
                                    }
                                    diagnose("frame_timing accepted=$accepted rejected=$rejected rejected_since_accepted=$rejectedSinceAccepted previous_device_us=$lastDeviceTime device_us=$deviceTime device_event=$deviceEvent device_gap_us=$deviceGap accepted_gap_ms=$arrivalGap receive_idle_ms=${clock() - lastReceived} read_wait_ms=$readWaitMs parse_ms=$parseMs")
                                    lastAnomaly = now
                                }
                            }
                            rejectedSinceAccepted = 0
                            lastDeviceTime = deviceTime
                        }
                        receivedValid = true
                        lastValid = clock()
                        valid()
                        pendingRestart = pendingRestart || sample.contains("\"restart\":true")
                        if (lastEmission == null || lastValid - lastEmission >= 100) {
                            emit(if (pendingRestart) sample.replace("\"restart\":false", "\"restart\":true") else sample)
                            pendingRestart = false
                            lastEmission = lastValid
                        }
                    } else if (csvTimestamp?.matches(line.substringBefore(',').trim()) == true) {
                        rejected++
                        rejectedSinceAccepted++
                    }
                    if (diagnostic != null && sample == null && parseMs > 250 &&
                        (lastAnomaly == null || clock() - lastAnomaly >= 1000)) {
                        diagnose("parse_timing accepted=$accepted rejected=$rejected last_device_us=$lastDeviceTime parse_ms=$parseMs receive_idle_ms=${clock() - lastReceived} read_wait_ms=$readWaitMs")
                        lastAnomaly = clock()
                    }
                } else {
                    if (frame.size() >= 513) throw ProtocolException("Frame too long")
                    frame.write(byte.toInt())
                }
                checkDeadline()
            }
            checkDeadline()
        }
    }
}
