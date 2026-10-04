package com.example.rehab_monitor

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.content.ActivityNotFoundException
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private lateinit var wearable: WearableConnection

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wearable = WearableConnection(this) { sink?.success(it) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "rehab/wearable/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { wearable.disconnect(); sink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rehab/wearable")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> { wearable.connect(call.argument<Boolean>("scaleConfirmed") ?: false); result.success(null) }
                    "disconnect" -> { wearable.disconnect(); result.success(null) }
                    "openWifiSettings" -> {
                        try { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)); result.success(null) }
                        catch (_: ActivityNotFoundException) { result.error("settings_unavailable", "Open Wi-Fi settings manually.", null) }
                        catch (_: SecurityException) { result.error("settings_denied", "Open Wi-Fi settings manually.", null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == WearableConnection.PERMISSION_REQUEST && ::wearable.isInitialized) wearable.permissionResult()
    }

    override fun onStop() { if (::wearable.isInitialized) wearable.disconnect(); super.onStop() }
    override fun onDestroy() { if (::wearable.isInitialized) wearable.disconnect(); sink = null; super.onDestroy() }
}
