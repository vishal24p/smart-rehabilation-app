package com.example.rehab_monitor

import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors

/** Owns one processor; every Python call runs in submission order on this worker. */
class RehabProcessing(
    private val createProcessor: () -> Processor,
    private val dispatch: (() -> Unit) -> Unit = { it() },
) {
    interface Processor {
        fun newParser()
        fun parse(line: String): String?
        fun command(action: String, config: Map<*, *>?): String
        fun interrupt(reason: String): String
        fun snapshot(): String
    }

    class UnavailableException(message: String) : IllegalStateException(message)
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "rehab-python") }
    private var processor: Processor? = null // Access only on the worker.
    private var hasParser = false
    private var ready = false
    private var closed = false
    private var closeResult: Result<String?>? = null
    private val closeCallbacks = mutableListOf<(Result<String?>) -> Unit>()
    private var epoch = 0L
    @Volatile var lastSnapshot: String? = null
        private set
    val generation: Long get() = synchronized(lock) { epoch }
    fun isCurrent(token: Long): Boolean = synchronized(lock) { !closed && token == epoch }
    fun dispatchCurrent(token: Long, callback: () -> Unit) = dispatch { if (isCurrent(token)) callback() }

    /** Called by the TCP reader, never by the Android main thread. */
    fun newParser(): (String) -> String? {
        val token: Long
        val setup = synchronized(lock) {
            check(!closed) { "Processing queue is closed." }
            token = ++epoch
            ready = false
            worker.submit {
                checkCurrent(token)
                val session = processor ?: createProcessor().also { processor = it }
                if (hasParser) session.interrupt("TCP connection restarted.")
                session.newParser()
                hasParser = true
                lastSnapshot = session.snapshot()
                synchronized(lock) { if (isCurrent(token)) ready = true }
            }
        }
        await(setup)
        return { line ->
            val parsed = synchronized(lock) {
                if (!isCurrent(token)) null else worker.submit<String?> {
                    if (!isCurrent(token)) null else {
                        val sample = processor!!.parse(line)
                        lastSnapshot = processor!!.snapshot()
                        if (isCurrent(token)) sample else null
                    }
                }
            }
            parsed?.let { await(it) }
        }
    }

    fun command(action: String, config: Map<*, *>?, completion: (Result<String>) -> Unit) {
        synchronized(lock) {
            val token = epoch
            if (closed || !ready) {
                dispatch { completion(Result.failure(UnavailableException("Connect to the wearable before controlling a session."))) }
                return
            }
            worker.execute {
                val result = runCatching {
                    checkCurrent(token)
                    processor!!.command(action, config).also { lastSnapshot = it }
                }
                dispatch {
                    completion(if (isCurrent(token)) result else Result.failure(UnavailableException("Session connection changed. Retry the command.")))
                }
            }
        }
    }

    /** Invalidate queued old work immediately, then interrupt on the ordered worker. */
    fun interrupt(reason: String, completion: (Result<String?>) -> Unit = {}) {
        synchronized(lock) {
            if (closed) return
            val token = ++epoch
            ready = false
            worker.execute {
                val result = runCatching { processor?.interrupt(reason)?.also { lastSnapshot = it } }
                dispatch {
                    completion(if (isCurrent(token)) result else Result.failure(UnavailableException("Session connection changed.")))
                }
            }
        }
    }

    fun close(reason: String, completion: (Result<String?>) -> Unit = {}) {
        synchronized(lock) {
            if (closed) {
                val result = closeResult
                if (result == null) closeCallbacks.add(completion) else dispatch { completion(result) }
                return
            }
            closeCallbacks.add(completion)
            closed = true
            ready = false
            epoch++
            worker.execute {
                val result = runCatching { processor?.interrupt(reason)?.also { lastSnapshot = it } }
                val callbacks = synchronized(lock) {
                    closeResult = result
                    closeCallbacks.toList().also { closeCallbacks.clear() }
                }
                callbacks.forEach { callback -> dispatch { callback(result) } }
            }
            // Drain the interruption after old work; shutdownNow would lose the frozen summary.
            worker.shutdown()
        }
    }

    private fun checkCurrent(token: Long) {
        if (!isCurrent(token)) throw UnavailableException("Session connection changed.")
    }

    private fun <T> await(future: java.util.concurrent.Future<T>): T = try { future.get() }
    catch (error: ExecutionException) { throw (error.cause ?: error) }

    companion object {
        private val actions = setOf("configure", "heel_unloaded", "heel_loaded", "standing", "movement",
            "finish_movement", "start", "end", "retry")

        fun validateCommand(arguments: Any?): Pair<String, Map<*, *>?> {
            require(arguments is Map<*, *>) { "Session command must contain an action." }
            val action = arguments["action"]
            require(action is String && action in actions) { "Choose a supported session action." }
            val config = arguments["config"]
            require(config == null || config is Map<*, *>) { "Session config must be a map." }
            if (action == "configure") {
                require(config is Map<*, *>) { "Confirm ranges and signed board axes." }
                require(config["ranges_confirmed"] is Boolean && config["mounting_confirmed"] is Boolean) {
                    "Range and mounting confirmations must be boolean values."
                }
                for (key in listOf("thigh_axis", "shin_axis")) {
                    val axis = config[key]
                    require(axis is Map<*, *> && axis["index"] is Int && axis["index"] in 0..2 &&
                        axis["sign"] is Int && axis["sign"] in setOf(-1, 1)) { "Choose each board axis (0..2) and sign (-1 or 1)." }
                }
            }
            return action to (config as Map<*, *>?)
        }
    }
}
