package com.example.rehab_monitor

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import com.chaquo.python.PyException
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

class WearableConnection(private val activity: Activity, private val event: (String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var stream: WearableStream? = null
    private var processing: RehabProcessing? = null
    private var closing: RehabProcessing? = null
    private var stoppedSnapshot: String? = null
    private var selectedNetwork: Network? = null
    private var generation = 0L
    private var active = false
    private var pendingPermission: Long? = null
    private var networkRetry = 0
    private fun diagnostic(message: String) {
        if (BuildConfig.DEBUG) Log.d("RehabWearable", message)
    }

    fun connect(scaleConfirmed: Boolean) {
        if (active) { status("error", "connection_busy", "Disconnect before starting another connection."); return }
        active = true
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        generation++
        stoppedSnapshot = null
        processing = RehabProcessing({ pythonProcessor(scaleConfirmed) }, { main.post(it) })
        networkRetry = 0
        status("connecting", "requesting_wifi", "Connecting to REHAB-WEARABLE…")
        val permissions = when {
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            Build.VERSION.SDK_INT >= 31 -> arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
            Build.VERSION.SDK_INT >= 29 -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> emptyArray()
        }
        if (permissions.any { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            pendingPermission = generation
            activity.requestPermissions(permissions, PERMISSION_REQUEST)
        } else requestNetwork(generation)
    }

    fun permissionResult() {
        val requestedGeneration = pendingPermission ?: return
        pendingPermission = null
        if (!active || requestedGeneration != generation) return
        val required = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        if (activity.checkSelfPermission(required) != PackageManager.PERMISSION_GRANTED) {
            fail("permission_denied", "Allow nearby Wi-Fi access to connect. On older Android, allow precise location.")
        } else requestNetwork(generation)
    }

    private fun requestNetwork(token: Long) {
        if (!active || token != generation) return
        if (!wifi.isWifiEnabled) { fail("wifi_disabled", "Turn on Wi-Fi and retry."); return }
        if (Build.VERSION.SDK_INT in 29..32 &&
            !(activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager).isLocationEnabled) {
            fail("location_disabled", "Turn on Location services for this Android version's Wi-Fi connection, then retry.")
            return
        }
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (Build.VERSION.SDK_INT >= 29) {
            request.setNetworkSpecifier(WifiNetworkSpecifier.Builder().setSsid("REHAB-WEARABLE")
                .setWpa2Passphrase("rehab1234").build())
        }
        val observer = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = main.post {
                if (active && token == generation && stream == null) startStream(network, token)
            }.let { Unit }
            override fun onUnavailable() = main.post {
                retryNetwork(token, "Wearable Wi-Fi unavailable. Power on the wearable; reconnecting…")
            }.let { Unit }
            override fun onLost(network: Network) = main.post {
                if (active && token == generation && selectedNetwork == network) {
                    retryNetwork(token, "Wearable Wi-Fi disconnected. Reconnecting…")
                }
            }.let { Unit }
        }
        callback = observer
        try {
            if (Build.VERSION.SDK_INT >= 29) connectivity.requestNetwork(request.build(), observer, 20000)
            else {
                val connectedWifi = connectivity.allNetworks.firstOrNull {
                    connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
                if (connectedWifi == null) { fail("join_wifi", "Join REHAB-WEARABLE in Wi-Fi settings, then retry."); return }
                connectivity.registerNetworkCallback(request.build(), observer)
                startStream(connectedWifi, token)
            }
        } catch (_: SecurityException) {
            fail("permission_denied", "Wi-Fi access was denied. Check permissions and retry.")
        } catch (_: RuntimeException) {
            fail("network_unavailable", "Wi-Fi connection could not start. Open Wi-Fi settings and retry.")
        }
    }

    private fun retryNetwork(token: Long, message: String) {
        if (!active || token != generation) return
        val nextToken = ++generation
        processing?.interrupt(message) { result ->
            if (active && nextToken == generation) result.getOrNull()?.let { analytics(it) }
        }
        releaseResources()
        status("reconnecting", "network_lost", message)
        main.postDelayed({ requestNetwork(nextToken) }, longArrayOf(1000, 2000, 5000)[minOf(networkRetry++, 2)])
    }

    private fun startStream(network: Network, token: Long) {
        val queue = processing ?: return
        selectedNetwork = network
        val factory = network.socketFactory
        val socketGeneration = AtomicLong(queue.generation)
        stream = WearableStream(
            createSocket = {
                factory.createSocket().also { socket ->
                    try { socket.connect(InetSocketAddress("192.168.4.1", 5000), 3000) }
                    catch (error: Exception) { socket.close(); throw error }
                }
            },
            parserFactory = {
                queue.newParser(socketGeneration.get()) { socketGeneration.set(it) }
            },
            interruptSession = {
                val nextEpoch = queue.interrupt("Wearable TCP connection lost.", socketGeneration.get()) { result ->
                    if (active && token == generation) result.getOrNull()?.let { analytics(it) }
                }
                nextEpoch?.let { socketGeneration.set(it) }
            },
            event = { payload ->
                if (payload.contains("\"type\":\"status\"")) diagnostic(payload)
                val socketToken = socketGeneration.get()
                queue.dispatchCurrent(socketToken) {
                    if (active && token == generation && queue === processing) {
                        if (payload.contains("\"type\":\"sample\"")) networkRetry = 0
                        event(payload)
                        if (payload.contains("\"status\":\"error\"")) {
                            finishConnection("Sensor stream stopped.")
                        }
                    }
                }
            },
            diagnostic = if (BuildConfig.DEBUG) { message -> diagnostic(message) } else null,
        ).also { it.start() }
    }

    fun sessionCommand(arguments: Any?, completion: (Result<String>) -> Unit) {
        val command = try { RehabProcessing.validateCommand(arguments) }
        catch (error: IllegalArgumentException) { completion(Result.failure(error)); return }
        val queue = processing
        if (!active || queue == null) {
            completion(Result.failure(RehabProcessing.UnavailableException("Connect to the wearable before controlling a session.")))
            return
        }
        val token = generation
        queue.command(command.first, command.second) { result ->
            if (!active || token != generation || queue !== processing) {
                completion(Result.failure(RehabProcessing.UnavailableException("Session connection changed. Retry the command.")))
            } else {
                result.getOrNull()?.let { analytics(it) }
                completion(result)
                val error = result.exceptionOrNull()
                if (error != null && error !is RehabProcessing.UnavailableException) {
                    fail("processing_failed", "Session processing failed. Disconnect and retry.")
                }
            }
        }
    }

    fun disconnect(origin: String = "manual", completion: (String?) -> Unit = {}) {
        diagnostic("stop origin=$origin")
        finishConnection("Wearable disconnected.",
            finalStatus = { status("disconnected", "disconnected", "Wearable disconnected.") }, completion = completion)
    }

    private fun finishConnection(reason: String, finalStatus: () -> Unit = {}, completion: (String?) -> Unit = {}) {
        diagnostic("finish reason=$reason")
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val pendingClose = closing
        if (!active && processing == null && pendingClose != null) {
            val token = generation
            pendingClose.close(reason) { result -> completion(if (token == generation) result.getOrNull() else null) }
            return
        }
        active = false
        val token = ++generation
        pendingPermission = null
        val queue = processing
        processing = null
        closing = queue
        releaseResources()
        if (queue == null) { finalStatus(); completion(stoppedSnapshot); return }
        queue.close(reason) { result ->
            if (closing === queue) closing = null
            if (token == generation) {
                stoppedSnapshot = result.getOrNull()
                stoppedSnapshot?.let { analytics(it) }
                finalStatus()
            }
            completion(if (token == generation) result.getOrNull() else null)
        }
    }

    private fun releaseResources() {
        stream?.stop()
        stream = null
        selectedNetwork = null
        callback?.let { try { connectivity.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) {} }
        callback = null
    }

    private fun fail(code: String, message: String) {
        finishConnection(message, finalStatus = { status("error", code, message) })
    }

    private fun analytics(snapshot: String) = event("{\"type\":\"analytics\",\"analytics\":$snapshot}")

    /** Constructed on rehab-python; no Python startup, parser or command runs on main. */
    private fun pythonProcessor(scaleConfirmed: Boolean): RehabProcessing.Processor {
        synchronized(Python::class.java) {
            if (!Python.isStarted()) Python.start(AndroidPlatform(activity.applicationContext))
        }
        val python = Python.getInstance()
        val session = python.getModule("rehab_session").callAttr("SessionProcessor")
        val sensor = python.getModule("rehab_sensor")
        val json = python.getModule("json")
        return object : RehabProcessing.Processor {
            private var parser: PyObject? = null
            private fun encode(snapshot: PyObject) = json.callAttr("dumps", snapshot).toString()
            override fun newParser() {
                try {
                    parser = sensor.callAttr("SensorParser", scaleConfirmed, session)
                    val store = ExerciseReferenceStore(activity.applicationContext)
                    val zero = try { store.loadSettings()["heel_zero"] } finally { store.close() }
                    if (zero != null) restoreHeelZero(session, json, zero as Map<*, *>)
                } catch (error: RuntimeException) {
                    Log.e("RehabWearable", "Could not initialize sensor processing", error)
                    throw error
                }
            }
            override fun parse(line: String): String? = try { parser!!.callAttr("process_line", line)?.toString() }
                catch (error: PyException) { throw WearableStream.ProtocolException(error.message ?: "Invalid CSV header") }
            override fun command(action: String, config: Map<*, *>?): String {
                val pythonConfig = config?.let { json.callAttr("loads", JSONObject(it).toString()) }
                return encode(session.callAttr("command", action, pythonConfig))
            }
            override fun interrupt(reason: String) = encode(session.callAttr("interrupt", reason))
            override fun snapshot() = encode(session.callAttr("snapshot"))
        }
    }

    private fun status(state: String, code: String, message: String) {
        val payload = JSONObject().put("type", "status").put("status", state)
            .put("code", code).put("message", message).toString()
        diagnostic(payload)
        event(payload)
    }

    companion object {
        const val PERMISSION_REQUEST = 6401

        internal fun restoreHeelZero(session: PyObject, json: PyObject, zero: Map<*, *>) {
            val validated = AppSettingsPayload.validateHeelZero(zero)
            val config = json.callAttr("loads", JSONObject(validated).toString())
            val restored = session.callAttr("command", "heel_restore", config)
            // PyObject.get reads an attribute; Python dict keys require dict.get.
            check(restored.callAttr("get", "heel_zero") != null) { "Stored heel baseline could not be restored." }
        }
    }
}
