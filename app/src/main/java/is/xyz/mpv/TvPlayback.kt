package `is`.xyz.mpv

import android.app.ActivityManager
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.preference.PreferenceManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File

/** TV policy stays in the independently installable .tv flavor. */
internal class TvPlayback(private val view: BaseMPVView) : MPVLib.EventObserver,
    DisplayManager.DisplayListener {
    private val context = view.context
    private val handler = Handler(Looper.getMainLooper())
    private val preferences = PreferenceManager.getDefaultSharedPreferences(context)
    private val displays = context.getSystemService(DisplayManager::class.java)
    private var started = false
    private var fps = 0f
    private var paused = false
    private var generation = 0
    @Volatile var currentVo: String? = null
        private set
    private val nativeEnabled get() = preferences.getBoolean("tv_native_output", true)

    fun configure() {
        val directory = File(context.filesDir, "tv-mpv").apply { mkdirs() }
        for (name in arrayOf("afuse_p5.lua", "afuse_native_dolby.lua", "afuse_p7_guard.lua")) {
            context.assets.open("tv-mpv/$name").use { input ->
                File(directory, name).outputStream().use { input.copyTo(it) }
            }
        }
        MPVLib.setOptionString("scripts", File(directory, "afuse_p5.lua").absolutePath)
        // Bound compressed packet storage separately from decoder/GPU memory.
        val memory = context.getSystemService(ActivityManager::class.java).memoryClass
        val forward = when { memory >= 512 -> 256; memory > 128 -> 128; else -> 64 }
        val backward = if (memory > 128) 32 else 16
        MPVLib.setOptionString("demuxer-max-bytes", (forward * 1024L * 1024).toString())
        MPVLib.setOptionString("demuxer-max-back-bytes", (backward * 1024L * 1024).toString())
        MPVLib.setOptionString("cache-secs", "30")
        if (preferences.getBoolean("tv_stereo_compatibility", false))
            MPVLib.setOptionString("audio-channels", "stereo")
        Log.i(TAG, "TV packet cache: forward=${forward}MiB back=${backward}MiB heap=${memory}MiB")
    }

    fun start() {
        started = true
        refreshDisplay()
        MPVLib.addObserver(this)
        MPVLib.observeProperty("container-fps", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        MPVLib.observeProperty("user-data/afuse-p5/vo", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        displays.registerDisplayListener(this, handler)
    }

    fun refreshDisplay() {
        if (!started) return
        val display = ContextCompat.getDisplayOrDefault(context)
        val queried = TvOutputCapabilities.query(display,
            preferences.getBoolean("tv_hdr10_compatibility", false),
            preferences.getBoolean("tv_platform_dolby", false))
        val caps = if (nativeEnabled) queried else TvOutputCapabilities()
        MPVLib.setPropertyBoolean("user-data/afuse-hdr/pq-capable", queried.pqCodecs.isNotEmpty())
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/p5", caps.p5)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/p8", caps.p8)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/automatic-decoder", false)
        MPVLib.setPropertyBoolean("user-data/tv-mpv/platform-dolby",
            preferences.getBoolean("tv_platform_dolby", false) && !queried.dolbyDisplay)
        MPVLib.setPropertyBoolean("user-data/tv-mpv/p7-hdr10-base",
            preferences.getBoolean("tv_p7_hdr10_base", true) && !queried.dolbyDisplay)
        for (codec in arrayOf("hevc", "vp9", "av1")) {
            MPVLib.setPropertyBoolean("user-data/afuse-native-hdr/$codec-pq", codec in caps.pqCodecs)
            MPVLib.setPropertyBoolean("user-data/afuse-native-hdr/$codec-hlg", codec in caps.hlgCodecs)
        }
        MPVLib.setPropertyString("display-fps-override", display.mode.refreshRate.toString())
        MPVLib.setPropertyInt("user-data/afuse-display/generation", ++generation)
        Log.i(TAG, "TV display=${display.mode}: Dolby P5=${caps.p5} P8=${caps.p8}, PQ=${caps.pqCodecs}, HLG=${caps.hlgCodecs}")
    }

    fun applyFrameRate() {
        if (started && preferences.getBoolean("tv_match_frame_rate", true))
            view.setVideoFrameRate(if (paused) 0f else fps)
    }

    private fun dispatch(action: () -> Unit) {
        handler.post { if (started) action() }
    }

    fun close() {
        started = false
        displays.unregisterDisplayListener(this)
        MPVLib.removeObserver(this)
        handler.removeCallbacksAndMessages(null)
        view.setVideoFrameRate(0f)
    }

    override fun eventProperty(property: String, value: Double) {
        if (property == "container-fps") dispatch {
            fps = if (value.isFinite() && value in 1.0..240.0) value.toFloat() else 0f
            applyFrameRate()
        }
    }
    override fun eventProperty(property: String, value: Boolean) {
        if (property == "pause") dispatch { paused = value; applyFrameRate() }
    }
    override fun event(eventId: Int) {
        if (eventId == MPVLib.MpvEvent.MPV_EVENT_START_FILE ||
            eventId == MPVLib.MpvEvent.MPV_EVENT_END_FILE) dispatch { fps = 0f; applyFrameRate() }
    }
    override fun onDisplayChanged(displayId: Int) {
        if (displayId == ContextCompat.getDisplayOrDefault(context).displayId) refreshDisplay()
    }
    override fun onDisplayAdded(displayId: Int) {}
    override fun onDisplayRemoved(displayId: Int) {}
    override fun eventProperty(property: String) {}
    override fun eventProperty(property: String, value: Long) {}
    override fun eventProperty(property: String, value: String) {
        if (property == "user-data/afuse-p5/vo") currentVo = value
    }

    companion object { private const val TAG = "tv-mpv" }
}
