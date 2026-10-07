package com.example.rehab_monitor

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.LinkProperties
import android.net.NetworkInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiInfo
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.SupplicantState
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import com.chaquo.python.PyException
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.net.InetSocketAddress
import java.net.Inet4Address
import java.io.File
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
    private var wifiDiagnostics: BroadcastReceiver? = null
    private val diagnosticFile = File(activity.filesDir, "wearable-connection.log")
    private var thighReadingsAvailable: Boolean? = null
    private var thighDiagnostic: Pair<String, String>? = null
    private var thighRepDiagnostic: Pair<String, Int>? = null
    private var lastThighDeviceTime: Long? = null
    private fun diagnostic(message: String) {
        if (!BuildConfig.DEBUG) return
        val line = message.take(1024).replace('\n', ' ').replace('\r', ' ')
        Log.d("RehabWearable", line)
        runCatching {
            synchronized(diagnosticFile) {
                if (diagnosticFile.length() > 64 * 1024) diagnosticFile.writeText("Earlier diagnostics rotated.\n")
                diagnosticFile.appendText("${System.currentTimeMillis()} $line\n")
            }
        }
    }

    private fun traceThigh(payload: String, sample: Boolean) {
        if (!BuildConfig.DEBUG) return
        runCatching {
            val json = JSONObject(payload)
            val deviceTime = if (sample) json.optLong("time_us") else null
            val gap = deviceTime?.let { current -> lastThighDeviceTime?.let { current - it } }
            if (sample) {
                val available = !json.isNull("thigh_accel") && !json.isNull("thigh_gyro")
                if (available != thighReadingsAvailable) {
                    diagnostic("thigh_readings available=$available device_us=$deviceTime device_gap_us=$gap")
                    thighReadingsAvailable = available
                }
                lastThighDeviceTime = deviceTime
            }
            val snapshot = if (sample) json.optJSONObject("analytics") else json
            val thigh = snapshot?.optJSONObject("thigh") ?: return@runCatching
            val state = thigh.optString("state")
            val reason = if (thigh.isNull("reason")) "none" else thigh.optString("reason")
            val current = state to reason
            if (current != thighDiagnostic) {
                diagnostic("thigh_transition previous=${thighDiagnostic?.first} state=$state reason=$reason device_us=$deviceTime device_gap_us=$gap zero_progress=${thigh.optDouble("zero_progress")} repetitions=${thigh.optInt("repetitions")} tilt_deg=${thigh.opt("tilt_deg")} accel=${json.opt("thigh_accel")} gyro=${json.opt("thigh_gyro")} scaled=${json.opt("scaled")}")
                thighDiagnostic = current
            }
            val phase = thigh.optString("rep_phase", "none")
            val rep = phase to thigh.optInt("repetitions")
            if (state == "active" && rep != thighRepDiagnostic) {
                diagnostic("thigh_cycle phase=$phase repetitions=${rep.second} tilt_deg=${thigh.opt("tilt_deg")} cycle_peak_deg=${thigh.opt("cycle_peak_deg")} last_completed_cycle_peak_deg=${thigh.opt("last_completed_cycle_peak_deg")} reference_peak_deg=${thigh.opt("reference_peak_deg")} upright_band_deg=${thigh.opt("upright_band_deg")} device_us=$deviceTime device_gap_us=$gap")
            }
            thighRepDiagnostic = if (state == "active") rep else null
        }
    }

    @Suppress("DEPRECATION")
    private fun startWifiDiagnostics() {
        if (!BuildConfig.DEBUG || wifiDiagnostics != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiManager.WIFI_STATE_CHANGED_ACTION -> diagnostic("wifi_radio state=${intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1)}")
                    WifiManager.SUPPLICANT_STATE_CHANGED_ACTION -> {
                        val state = intent.getParcelableExtra<SupplicantState>(WifiManager.EXTRA_NEW_STATE)
                        val error = intent.getIntExtra(WifiManager.EXTRA_SUPPLICANT_ERROR, -1)
                        diagnostic("wifi_handshake state=$state error=$error authentication_failed=${error == WifiManager.ERROR_AUTHENTICATING}")
                    }
                    WifiManager.NETWORK_STATE_CHANGED_ACTION -> {
                        val info = intent.getParcelableExtra<NetworkInfo>(WifiManager.EXTRA_NETWORK_INFO)
                        diagnostic("wifi_link state=${info?.detailedState}")
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiManager.SUPPLICANT_STATE_CHANGED_ACTION)
            addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            else activity.registerReceiver(receiver, filter)
            wifiDiagnostics = receiver
        }.onFailure { diagnostic("wifi_diagnostics unavailable=${it.javaClass.simpleName}") }
    }

    fun connect(scaleConfirmed: Boolean) {
        if (active) { status("error", "connection_busy", "Disconnect before starting another connection."); return }
        active = true
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        generation++
        diagnostic("connect_begin generation=$generation sdk=${Build.VERSION.SDK_INT} wifi_enabled=${wifi.isWifiEnabled}")
        startWifiDiagnostics()
        stoppedSnapshot = null
        processing = RehabProcessing({ pythonProcessor(scaleConfirmed) }, { main.post(it) })
        networkRetry = 0
        status("connecting", "requesting_wifi", "Connecting to REHAB…")
        val permissions = when {
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            Build.VERSION.SDK_INT >= 31 -> arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
            Build.VERSION.SDK_INT >= 26 -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> emptyArray()
        }
        if (permissions.any { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            diagnostic("permissions requested=${permissions.joinToString()}")
            pendingPermission = generation
            activity.requestPermissions(permissions, PERMISSION_REQUEST)
        } else requestNetwork(generation)
    }

    fun permissionResult() {
        val requestedGeneration = pendingPermission ?: return
        pendingPermission = null
        if (!active || requestedGeneration != generation) return
        val required = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        diagnostic("permission_result granted=${activity.checkSelfPermission(required) == PackageManager.PERMISSION_GRANTED}")
        if (activity.checkSelfPermission(required) != PackageManager.PERMISSION_GRANTED) {
            fail("permission_denied", "Allow nearby Wi-Fi access to connect. On older Android, allow precise location.")
        } else requestNetwork(generation)
    }

    private fun requestNetwork(token: Long) {
        if (!active || token != generation) return
        startWifiDiagnostics()
        diagnostic("wifi_request generation=$token wifi_enabled=${wifi.isWifiEnabled}")
        if (!wifi.isWifiEnabled) { fail("wifi_disabled", "Turn on Wi-Fi and retry."); return }
        if (Build.VERSION.SDK_INT in 26..32) {
            val location = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val enabled = if (Build.VERSION.SDK_INT >= 28) location.isLocationEnabled
                else location.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            if (!enabled) {
                fail("location_disabled", "Turn on Location services for this Android version's Wi-Fi connection, then retry.")
                return
            }
        }
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        val wifiNetworks = connectivity.allNetworks.mapNotNull { network ->
            connectivity.getNetworkCapabilities(network)?.takeIf {
                it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            }?.let { network to it }
        }
        val joinedNetwork = findWearableNetwork(wifiNetworks.map { (network, capabilities) ->
            network to if (Build.VERSION.SDK_INT >= 31) {
                (capabilities.transportInfo as? WifiInfo)?.ssid
            } else if (wifiNetworks.size == 1) wifi.connectionInfo?.ssid else null
        })
        if (joinedNetwork == null && Build.VERSION.SDK_INT >= 29) {
            request.setNetworkSpecifier(WifiNetworkSpecifier.Builder().setSsid("REHAB")
                .setWpa2Passphrase("rehab1234").build())
        }
        val observer = networkObserver(token, joinedNetwork)
        callback = observer
        diagnostic("wifi_request mode=${if (joinedNetwork != null) "reuse_joined" else "approval"} wifi_networks=${wifiNetworks.size} generation=$token")
        try {
            if (joinedNetwork != null) {
                connectivity.registerNetworkCallback(request.build(), observer)
                startStream(joinedNetwork, token)
            } else if (Build.VERSION.SDK_INT >= 29) connectivity.requestNetwork(request.build(), observer)
            else fail("join_wifi", "Join REHAB in Wi-Fi settings, then retry.")
        } catch (_: SecurityException) {
            fail("permission_denied", "Wi-Fi access was denied. Check permissions and retry.")
        } catch (_: RuntimeException) {
            fail("network_unavailable", "Wi-Fi connection could not start. Open Wi-Fi settings and retry.")
        }
    }

    internal fun networkObserver(token: Long, joinedNetwork: Network? = null): ConnectivityManager.NetworkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = main.post {
                diagnostic("wifi_available network=$network generation=$token current=${active && token == generation}")
                if (active && token == generation && stream == null &&
                    (joinedNetwork == null || joinedNetwork == network)) startStream(network, token)
            }.let { Unit }
            override fun onUnavailable() = main.post {
                diagnostic("wifi_unavailable generation=$token current=${active && token == generation}")
                if (active && token == generation) fail("network_unavailable",
                    "Wi-Fi connection was declined or could not complete. Open Wi-Fi settings, join REHAB, then retry.")
            }.let { Unit }
            override fun onLost(network: Network) = main.post {
                diagnostic("wifi_lost network=$network generation=$token selected=${selectedNetwork == network}")
                if (active && token == generation && selectedNetwork == network) {
                    retryNetwork(token, "Wearable Wi-Fi disconnected. Reconnecting…")
                }
            }.let { Unit }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = main.post {
                if (active && token == generation) diagnostic("wifi_capabilities network=$network wifi=${capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)} internet=${capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)} validated=${capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)}")
            }.let { Unit }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = main.post {
                if (active && token == generation) diagnostic("wifi_ip network=$network interface=${properties.interfaceName} address_count=${properties.linkAddresses.size} ipv4_count=${properties.linkAddresses.count { it.address is Inet4Address }} route_count=${properties.routes.size}")
            }.let { Unit }
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) = main.post {
                if (active && token == generation) diagnostic("wifi_blocked network=$network blocked=$blocked")
            }.let { Unit }
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
                val started = SystemClock.elapsedRealtime()
                diagnostic("tcp_connect_begin network=$network endpoint=192.168.4.1:5000 generation=$token")
                factory.createSocket().also { socket ->
                    try {
                        socket.connect(InetSocketAddress("192.168.4.1", 5000), 3000)
                        diagnostic("tcp_connected network=$network duration_ms=${SystemClock.elapsedRealtime() - started}")
                    } catch (error: Exception) {
                        diagnostic("tcp_connect_failed kind=${error.javaClass.simpleName} detail=${error.message}")
                        socket.close()
                        throw error
                    }
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
        val started = SystemClock.elapsedRealtime()
        diagnostic("session_command_begin action=${command.first} generation=$token")
        queue.command(command.first, command.second) { result ->
            val reason = result.exceptionOrNull()?.javaClass?.simpleName ?: "none"
            diagnostic("session_command_end action=${command.first} success=${result.isSuccess} error=$reason duration_ms=${SystemClock.elapsedRealtime() - started} generation=$token")
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
        diagnostic("resources_release generation=$generation network=$selectedNetwork")
        wifiDiagnostics?.let { runCatching { activity.unregisterReceiver(it) } }
        wifiDiagnostics = null
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
            override fun parse(line: String): String? = try {
                parser!!.callAttr("process_line", line)?.toString()?.also { traceThigh(it, true) }
            }
                catch (error: PyException) { throw WearableStream.ProtocolException(error.message ?: "Invalid CSV header") }
            override fun command(action: String, config: Map<*, *>?): String {
                val pythonConfig = config?.let { json.callAttr("loads", JSONObject(it).toString()) }
                return encode(session.callAttr("command", action, pythonConfig)).also { traceThigh(it, false) }
            }
            override fun interrupt(reason: String) = encode(session.callAttr("interrupt", reason)).also { traceThigh(it, false) }
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

        internal fun findWearableNetwork(candidates: List<Pair<Network, String?>>): Network? =
            candidates.firstOrNull { (_, ssid) -> ssid == "REHAB" || ssid == "\"REHAB\"" }?.first

        internal fun restoreHeelZero(session: PyObject, json: PyObject, zero: Map<*, *>) {
            val validated = AppSettingsPayload.validateHeelZero(zero)
            val config = json.callAttr("loads", JSONObject(validated).toString())
            val restored = session.callAttr("command", "heel_restore", config)
            // PyObject.get reads an attribute; Python dict keys require dict.get.
            check(restored.callAttr("get", "heel_zero") != null) { "Stored heel baseline could not be restored." }
        }
    }
}
