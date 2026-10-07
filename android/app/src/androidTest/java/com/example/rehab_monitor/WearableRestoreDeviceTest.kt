package com.example.rehab_monitor

import android.test.AndroidTestCase
import android.test.ActivityInstrumentationTestCase2
import android.view.WindowManager
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
