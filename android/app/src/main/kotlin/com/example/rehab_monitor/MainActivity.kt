package com.example.rehab_monitor

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.content.ActivityNotFoundException
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private lateinit var wearable: WearableConnection
    private lateinit var references: ExerciseReferenceStore
    private val referenceWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wearable = WearableConnection(this) { sink?.success(it) }
        references = ExerciseReferenceStore(applicationContext)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "rehab/wearable/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { wearable.disconnect(); sink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rehab/wearable")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getExerciseReferences", "saveExerciseReference", "getGaitReference", "saveGaitReference" -> referenceWorker.execute {
                        val response = runCatching {
                            when (call.method) {
                                "getExerciseReferences" -> references.load()
                                "saveExerciseReference" -> references.save(call.arguments)
                                "getGaitReference" -> references.loadGait()
                                else -> references.saveGait(call.arguments)
                            }
                        }
                        runOnUiThread {
                            response.fold(
                                onSuccess = { result.success(it) },
                                onFailure = { result.error("reference_storage_failed", "Could not load or save the reference. Retry.", null) },
                            )
                        }
                    }
                    "connect" -> { wearable.connect(call.argument<Boolean>("scaleConfirmed") ?: false); result.success(null) }
                    "disconnect" -> wearable.disconnect { snapshot -> result.success(snapshot) }
                    "sessionCommand" -> wearable.sessionCommand(call.arguments) { response ->
                        response.fold(
                            onSuccess = { result.success(null) },
                            onFailure = { error ->
                                val code = when (error) {
                                    is IllegalArgumentException -> "invalid_session_command"
                                    is RehabProcessing.UnavailableException -> "session_unavailable"
                                    else -> "processing_failed"
                                }
                                result.error(code, error.message, null)
                            },
                        )
                    }
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
    override fun onDestroy() {
        if (::wearable.isInitialized) wearable.disconnect()
        referenceWorker.execute { if (::references.isInitialized) references.close() }
        referenceWorker.shutdown()
        sink = null
        super.onDestroy()
    }
}
