package com.example.rehab_monitor

import android.test.AndroidTestCase
import android.test.ActivityInstrumentationTestCase2
import android.view.WindowManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.LinkProperties
import android.os.Parcel
import java.io.File
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject

@Suppress("DEPRECATION")
class WearableRestoreDeviceTest : AndroidTestCase() {
    fun testSavedBaselineRestoresThroughActualPythonParser() {
        synchronized(Python::class.java) {
            if (!Python.isStarted()) Python.start(AndroidPlatform(context.applicationContext))
        }
        val python = Python.getInstance()
        val session = python.getModule("rehab_session").callAttr("SessionProcessor")!!
        val parser = python.getModule("rehab_sensor").callAttr("SensorParser", false, session)!!
        val json = python.getModule("json")
        val zero = mapOf("version" to 1, "adc_max" to 1023,
            "left" to mapOf("baseline" to 13.0, "deadband" to 5.0),
            "right" to mapOf("baseline" to 13.0, "deadband" to 5.0))
        WearableConnection.restoreHeelZero(session, json, zero)
        val restored = session.callAttr("snapshot")!!
        assertNull(restored.get("heel_zero")) // Regression: this was the faulty attribute lookup.
        assertNotNull(restored.callAttr("get", "heel_zero"))
        parser.callAttr("process_line", "time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr,fsr_left")
        val free = JSONObject(parser.callAttr("process_line", "20000,0,0,16384,0,0,0,0,0,16384,0,0,0,13,13").toString())
        assertEquals("No load detected", free.getJSONObject("analytics").getString("heel_share_reason"))
        val pressed = JSONObject(parser.callAttr("process_line", "40000,0,0,16384,0,0,0,0,0,16384,0,0,0,113,13").toString())
        assertEquals(100.0, pressed.getJSONObject("analytics").getDouble("heel_share_left"))
        assertEquals(0.0, pressed.getJSONObject("analytics").getDouble("heel_share_right"))
        parser.callAttr("process_line", "60000,0,0,16384,0,0,0,0,0,16384,0,0,0,13,13")
        val both = JSONObject(parser.callAttr("process_line", "80000,0,0,16384,0,0,0,0,0,16384,0,0,0,19,18").toString())
        assertEquals(100.0 * 6 / 11, both.getJSONObject("analytics").getDouble("heel_share_left"), 0.001)
        assertEquals(100.0 * 5 / 11, both.getJSONObject("analytics").getDouble("heel_share_right"), 0.001)
    }
}

@Suppress("DEPRECATION")
class WearableRecoveryDeviceTest : ActivityInstrumentationTestCase2<MainActivity>(MainActivity::class.java) {
    fun testDiagnosticsAreBoundedAndReceiverStopsWithConnection() {
        val screen = activity
        val file = File(screen.filesDir, "wearable-connection.log")
        val saved = if (file.exists()) file.readBytes() else null
        val log = WearableConnection::class.java.getDeclaredMethod("diagnostic", String::class.java).apply { isAccessible = true }
        val start = WearableConnection::class.java.getDeclaredMethod("startWifiDiagnostics").apply { isAccessible = true }
        val receiver = WearableConnection::class.java.getDeclaredField("wifiDiagnostics").apply { isAccessible = true }
        try {
            instrumentation.runOnMainSync {
                val connection = WearableConnection(screen) {}
                file.writeText("x".repeat(65 * 1024))
                log.invoke(connection, "test_diagnostic\nsecond_line")
                assertTrue(file.length() < 2048)
                assertTrue(file.readText().contains("test_diagnostic second_line"))
                start.invoke(connection)
                assertNotNull(receiver.get(connection))
                connection.disconnect()
                assertNull(receiver.get(connection))
            }
        } finally {
            if (saved != null) file.writeBytes(saved) else file.delete()
        }
    }

    fun testDiagnosticCallbacksDoNotChangeConnectionAndIgnoreStaleEpochs() {
        val screen = activity
        val file = File(screen.filesDir, "wearable-connection.log")
        val events = mutableListOf<String>()
        val active = WearableConnection::class.java.getDeclaredField("active").apply { isAccessible = true }
        val generation = WearableConnection::class.java.getDeclaredField("generation").apply { isAccessible = true }
        val parcel = Parcel.obtain()
        parcel.writeInt(43)
        parcel.setDataPosition(0)
        val network = Network.CREATOR.createFromParcel(parcel)
        parcel.recycle()
        fun countEntries(prefix: String) = if (file.exists()) file.readLines().count { it.contains("$prefix network=$network ") } else 0
        val capabilitiesBefore = countEntries("wifi_capabilities")
        val ipBefore = countEntries("wifi_ip")
        lateinit var connection: WearableConnection
        instrumentation.runOnMainSync {
            connection = WearableConnection(screen) { events.add(it) }
            active.setBoolean(connection, true)
            generation.setLong(connection, 9)
            val capabilities = NetworkCapabilities()
            val properties = LinkProperties()
            connection.networkObserver(8).onCapabilitiesChanged(network, capabilities)
            connection.networkObserver(8).onLinkPropertiesChanged(network, properties)
            connection.networkObserver(9).onCapabilitiesChanged(network, capabilities)
            connection.networkObserver(9).onLinkPropertiesChanged(network, properties)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertTrue(active.getBoolean(connection))
            assertEquals(9L, generation.getLong(connection))
            assertTrue(events.isEmpty())
            assertEquals(capabilitiesBefore + 1, countEntries("wifi_capabilities"))
            assertEquals(ipBefore + 1, countEntries("wifi_ip"))
            connection.disconnect()
        }
    }

    fun testUnavailableStopsOnceWithoutRetryAndIgnoresStaleCallbacks() {
        val screen = activity
        val events = mutableListOf<String>()
        val active = WearableConnection::class.java.getDeclaredField("active").apply { isAccessible = true }
        val generation = WearableConnection::class.java.getDeclaredField("generation").apply { isAccessible = true }
        lateinit var connection: WearableConnection
        lateinit var pending: ConnectivityManager.NetworkCallback
        var stoppedGeneration = 0L
        instrumentation.runOnMainSync {
            connection = WearableConnection(screen) { events.add(it) }
            active.setBoolean(connection, true)
            generation.setLong(connection, 7)
            connection.networkObserver(6).onUnavailable() // An old denial cannot cancel current approval.
            pending = connection.networkObserver(7)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertTrue(active.getBoolean(connection))
            assertTrue(events.isEmpty())
            pending.onUnavailable()
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertFalse(active.getBoolean(connection))
            stoppedGeneration = generation.getLong(connection)
            assertEquals("error", JSONObject(events.single()).getString("status"))
            assertTrue(JSONObject(events.single()).getString("message").contains("Open Wi-Fi settings"))
            pending.onUnavailable() // A duplicate denial must not emit or restart.
        }
        Thread.sleep(1300)
        instrumentation.runOnMainSync {
            assertEquals(stoppedGeneration, generation.getLong(connection))
            assertEquals(1, events.size)
        }
    }

    fun testJoinedNetworkSelectionRejectsUnknownAndUnrelatedSsids() {
        val parcel = Parcel.obtain()
        parcel.writeInt(41)
        parcel.setDataPosition(0)
        val unrelated = Network.CREATOR.createFromParcel(parcel)
        parcel.setDataPosition(0)
        parcel.writeInt(42)
        parcel.setDataPosition(0)
        val wearable = Network.CREATOR.createFromParcel(parcel)
        parcel.recycle()
        assertEquals(wearable, WearableConnection.findWearableNetwork(listOf(
            unrelated to "Other Wi-Fi", wearable to "\"REHAB-WEARABLE\"")))
        assertEquals(wearable, WearableConnection.findWearableNetwork(listOf(wearable to "REHAB-WEARABLE")))
        assertNull(WearableConnection.findWearableNetwork(listOf(
            unrelated to "Other Wi-Fi", wearable to "<unknown ssid>")))
        assertNull(WearableConnection.findWearableNetwork(listOf(wearable to null)))
    }

    fun testStaleRetriesAndDisconnectedDelayedRetryAreIgnored() {
        val screen = activity
        val events = mutableListOf<String>()
        lateinit var connection: WearableConnection
        val active = WearableConnection::class.java.getDeclaredField("active").apply { isAccessible = true }
        val generation = WearableConnection::class.java.getDeclaredField("generation").apply { isAccessible = true }
        val retry = WearableConnection::class.java.getDeclaredMethod("retryNetwork", Long::class.javaPrimitiveType, String::class.java)
            .apply { isAccessible = true }
        var afterDisconnect = 0
        instrumentation.runOnMainSync {
            connection = WearableConnection(screen) { events.add(it) }
            active.setBoolean(connection, true)
            generation.setLong(connection, 7)
            retry.invoke(connection, 6L, "Old request")
            assertEquals(7L, generation.getLong(connection))
            assertTrue(events.isEmpty())
            retry.invoke(connection, 7L, "Retry current request")
            assertEquals(8L, generation.getLong(connection))
            assertEquals("reconnecting", JSONObject(events.single()).getString("status"))
            screen.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            connection.disconnect()
            assertFalse(active.getBoolean(connection))
            assertEquals(0, screen.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            afterDisconnect = events.size
        }
        Thread.sleep(1300) // Let the first scheduled retry run after disconnect invalidated it.
        instrumentation.runOnMainSync {
            assertEquals(afterDisconnect, events.size)
            assertFalse(active.getBoolean(connection))
        }
    }
}
