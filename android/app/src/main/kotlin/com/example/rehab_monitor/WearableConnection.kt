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
import com.chaquo.python.PyException
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.net.InetSocketAddress
import org.json.JSONObject

class WearableConnection(private val activity: Activity, private val event: (String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var stream: WearableStream? = null
    private var selectedNetwork: Network? = null
    private var generation = 0L
    private var active = false
    private var pendingPermission: Long? = null
    private var scaleConfirmed = false
    private var networkRetry = 0

    fun connect(scaleConfirmed: Boolean) {
        if (active) { status("error", "connection_busy", "Disconnect before starting another connection."); return }
        active = true
        generation++
        this.scaleConfirmed = scaleConfirmed
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
                if (active && token == generation) fail("network_unavailable", "Power on the wearable and approve its Wi-Fi connection, then retry.")
            }.let { Unit }
            override fun onLost(network: Network) = main.post {
                if (active && token == generation && selectedNetwork == network) {
                    generation++
                    releaseResources()
                    status("reconnecting", "network_lost", "Wearable Wi-Fi disconnected. Reconnecting…")
                    val nextToken = generation
                    main.postDelayed({ requestNetwork(nextToken) }, longArrayOf(1000, 2000, 5000)[minOf(networkRetry++, 2)])
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

    private fun startStream(network: Network, token: Long) {
        selectedNetwork = network
        val factory = network.socketFactory
        stream = WearableStream(
            createSocket = {
                factory.createSocket().also { socket ->
                    try { socket.connect(InetSocketAddress("192.168.4.1", 5000), 3000) }
                    catch (error: Exception) { socket.close(); throw error }
                }
            },
            parserFactory = {
                synchronized(Python::class.java) {
                    if (!Python.isStarted()) Python.start(AndroidPlatform(activity.applicationContext))
                }
                val parser = Python.getInstance().getModule("rehab_sensor").callAttr("SensorParser", scaleConfirmed)
                val parse: (String) -> String? = { line ->
                    try { parser.callAttr("process_line", line)?.toString() }
                    catch (error: PyException) { throw WearableStream.ProtocolException(error.message ?: "Invalid CSV header") }
                }
                parse
            },
            event = { payload -> main.post {
                if (active && token == generation) {
                    event(payload)
                    if (payload.contains("\"status\":\"error\"")) {
                        active = false
                        generation++
                        releaseResources()
                    }
                }
            } },
        ).also { it.start() }
    }

    fun disconnect() {
        active = false
        generation++
        pendingPermission = null
        releaseResources()
        status("disconnected", "disconnected", "Wearable disconnected.")
    }

    private fun releaseResources() {
        stream?.stop()
        stream = null
        selectedNetwork = null
        callback?.let { try { connectivity.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) {} }
        callback = null
    }

    private fun fail(code: String, message: String) {
        active = false
        generation++
        pendingPermission = null
        releaseResources()
        status("error", code, message)
    }

    private fun status(state: String, code: String, message: String) = event(JSONObject()
        .put("type", "status").put("status", state).put("code", code).put("message", message).toString())

    companion object { const val PERMISSION_REQUEST = 6401 }
}
