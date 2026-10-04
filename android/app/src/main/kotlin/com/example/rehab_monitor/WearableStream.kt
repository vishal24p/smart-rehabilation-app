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
            } catch (_: ProtocolException) {
                status("error", "invalid_protocol")
                break
            } catch (_: ConnectException) {
                if (!active) break
                status("reconnecting", "connection_refused")
            } catch (_: IOException) {
                if (!active) break
                status("reconnecting", "connection_lost")
            } catch (_: RuntimeException) {
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
        fun checkDeadline() {
            if (clock() - lastValid >= 3000) {
                if (receivedFrames && !receivedValid) throw ProtocolException("No valid samples")
                throw SocketTimeoutException("Sensor readings stale")
            }
        }
        while (active) {
            val count = try { input.read(buffer) } catch (_: SocketTimeoutException) { 0 }
            checkDeadline()
            if (count < 0) return
            for (index in 0 until count) {
                if (!active) return
                val byte = buffer[index]
                if (byte == '\n'.code.toByte()) {
                    val line = frame.toString(Charsets.UTF_8.name()).removeSuffix("\r")
                    frame.reset()
                    receivedFrames = true
                    if (line.toByteArray(Charsets.UTF_8).size > 512) throw ProtocolException("Frame too long")
                    val sample = parse(line)
                    if (sample != null) {
                        receivedValid = true
                        lastValid = clock()
                        valid()
                        pendingRestart = pendingRestart || sample.contains("\"restart\":true")
                        if (lastEmission == null || lastValid - lastEmission >= 100) {
                            emit(if (pendingRestart) sample.replace("\"restart\":false", "\"restart\":true") else sample)
                            pendingRestart = false
                            lastEmission = lastValid
                        }
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
