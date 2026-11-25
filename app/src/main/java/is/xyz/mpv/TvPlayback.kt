package `is`.xyz.mpv

import android.app.ActivityManager
import android.app.Activity
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.preference.PreferenceManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import org.json.JSONTokener

/** TV policy stays in the independently installable .tv flavor. */
internal class TvPlayback(private val view: BaseMPVView) : MPVLib.EventObserver,
    DisplayManager.DisplayListener {
    private val context = view.context
    private val handler = Handler(Looper.getMainLooper())
    private val audioPassthrough = TvAudioPassthrough(context, handler)
    private val preferences = PreferenceManager.getDefaultSharedPreferences(context)
    private val displays = context.getSystemService(DisplayManager::class.java)
    private var started = false
    private var fps = 0f
    private var paused = false
    private var generation = 0
    private var surfaceRequest: String? = null
    @Volatile var currentVo: String? = null
        private set
    private var gpuCapabilities = 0
    private var originalWindowColorMode: Int? = null
    private val fastVideoLayer get() = gpuCapabilities and 6 != 0

    fun configure() {
        if (Build.VERSION.SDK_INT < 29) return
        MPVLib.setOptionString("hwdec", "mediacodec,mediacodec-copy")
        val mode = ContextCompat.getDisplayOrDefault(context).mode
        gpuCapabilities = runCatching { MPVLib.probeTvGpu(mode.physicalWidth, mode.physicalHeight) }
            .onFailure { Log.w(TAG, "GPU fast-path probe failed; using compatible rendering", it) }.getOrDefault(0)
        val directory = File(context.filesDir, "tv-mpv").apply { mkdirs() }
        for (name in arrayOf("afuse_p5.lua", "afuse_native_dolby.lua", "afuse_p7_guard.lua")) {
            context.assets.open("tv-mpv/$name").use { input ->
                File(directory, name).outputStream().use { input.copyTo(it) }
            }
        }
        MPVLib.setOptionString("scripts", File(directory, "afuse_p5.lua").absolutePath)
        // Bound compressed packet storage separately from decoder/GPU memory.
        val memory = context.getSystemService(ActivityManager::class.java).memoryClass
        // Give distant HTTP track switches room to amortize connection setup.
        // This ring is separate from the bounded raw and demux packet caches.
        MPVLib.setOptionString("curl-buffer-size", if (memory > 128) "16MiB" else "4MiB")
        MPVLib.setOptionString("curl-seek-cache-size", if (memory > 128) "64MiB" else "32MiB")
        val forward = when { memory >= 512 -> 256; memory > 128 -> 128; else -> 64 }
        // High bitrate + TrueHD needs more than 32 MiB for a backward seek.
        val backward = when {
            memory > 128 -> 96
            else -> 16
        }
        MPVLib.setOptionString("demuxer-max-bytes", (forward * 1024L * 1024).toString())
        MPVLib.setOptionString("demuxer-max-back-bytes", (backward * 1024L * 1024).toString())
        MPVLib.setOptionString("cache-secs", "30")
        MPVLib.setOptionString("cache-pause-initial", "yes")
        MPVLib.setOptionString("cache-pause-wait", "3")
        MPVLib.setOptionString("cache-pause-seek-wait", "0.75")
        // Float PCM and this ring size passed the box's TrueHD/AC3 sync tests.
        // These are defaults set before mpv.conf, so explicit user audio options
        // and passthrough configuration retain precedence.
        MPVLib.setOptionString("audio-format", "float")
        MPVLib.setOptionString("audio-buffer", "1")
        // Keep an explicitly selected hardware path from silently becoming
        // CPU decoding after all available hardware decoders have failed.
        MPVLib.setOptionString("android-require-hwdec", "yes")
        MPVLib.setOptionString("android-surface-drain", "yes")
        if (gpuCapabilities and 1 != 0) {
            MPVLib.setOptionString("android-color-lut", "yes")
            MPVLib.setOptionString("android-color-lut-size", "32")
            MPVLib.setOptionString("android-color-lut-format", "unorm10")
            MPVLib.setOptionString("android-color-lut-direct", "yes")
            MPVLib.setOptionString("android-color-lut-3d", "yes")
        }
        MPVLib.setOptionString("android-video-layer-contiguous", if (gpuCapabilities and 2 != 0) "camera" else "no")
        MPVLib.setOptionString("opengl-swapinterval", "0")
        val stereo = preferences.getBoolean("tv_stereo_compatibility", false)
        if (stereo)
            MPVLib.setOptionString("audio-channels", "stereo")
        audioPassthrough.configure(!stereo && preferences.getBoolean(TvAudioPassthrough.PREFERENCE, true))
        Log.i(TAG, "TV packet cache: forward=${forward}MiB back=${backward}MiB heap=${memory}MiB")
    }

    fun start() {
        started = true
        audioPassthrough.start()
        MPVLib.setPropertyBoolean("android-require-hwdec", true)
        MPVLib.setPropertyString("hwdec", "mediacodec,mediacodec-copy")
        MPVLib.setPropertyInt("user-data/tv-mpv/gpu-capabilities", gpuCapabilities)
        MPVLib.setPropertyString("user-data/tv-mpv/initial-vo", MPVLib.getPropertyString("options/vo") ?: "unknown")
        refreshDisplay()
        MPVLib.addObserver(this)
        MPVLib.observeProperty("container-fps", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        MPVLib.observeProperty("user-data/afuse-p5/vo", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        MPVLib.observeProperty("user-data/afuse-p5/mode", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        MPVLib.observeProperty("user-data/tv-mpv/render-request", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        MPVLib.setPropertyBoolean("user-data/tv-mpv/source-size-auto", view.tvAutoSourceSize)
        displays.registerDisplayListener(this, handler)
    }

    private fun sizeSurface(request: String) {
        val parts = request.split(':')
        if (parts.size != 3 || parts[0].toLongOrNull() == null) return
        val sourceWidth = parts[1].toIntOrNull() ?: return
        val sourceHeight = parts[2].toIntOrNull() ?: return
        val mode = ContextCompat.getDisplayOrDefault(context).mode
        val sourceFits = sourceWidth in 1..mode.physicalWidth && sourceHeight in 1..mode.physicalHeight
        val width = if (sourceFits) sourceWidth else mode.physicalWidth
        val height = if (sourceFits) sourceHeight else mode.physicalHeight
        surfaceRequest = request
        Log.i(TAG, "TV render surface: source=${sourceWidth}x$sourceHeight target=${width}x$height")
        view.setTvSurfaceSize(width, height)
        val deadline = android.os.SystemClock.uptimeMillis() + 1500
        val acknowledge = object : Runnable {
            override fun run() {
                if (!started || surfaceRequest != request) return
                val frame = view.holder.surfaceFrame
                if (view.holder.surface.isValid && frame.width() == width && frame.height() == height) {
                    // The decoder hook remains deferred until the buffer size
                    // is real, rather than racing the first decoded frame.
                    MPVLib.setPropertyString("android-surface-size", "${width}x$height")
                    MPVLib.setPropertyString("user-data/tv-mpv/render-size", "${width}x$height")
                    MPVLib.setPropertyString("user-data/tv-mpv/render-ready", parts[0])
                } else if (android.os.SystemClock.uptimeMillis() < deadline) {
                    handler.postDelayed(this, 16)
                }
            }
        }
        handler.post(acknowledge)
    }

    fun refreshDisplay() {
        if (!started) return
        val display = ContextCompat.getDisplayOrDefault(context)
        val actual = TvOutputCapabilities.query(display)
        // Debug benchmarks can remove capabilities to test real fallback code.
        // They never add a capability or alter the system HDMI configuration.
        val queried = when (if (BuildConfig.DEBUG) preferences.getString("tv_test_capabilities", "auto") else "auto") {
            "hdr10" -> actual.copy(p5=false, p7=false, p8=false, p5Hdr=false, dolbyDisplay=false)
            "sdr" -> TvOutputCapabilities()
            else -> actual
        }
        val caps = queried
        MPVLib.setPropertyBoolean("user-data/afuse-hdr/pq-capable", caps.canMapPq(gpuCapabilities))
        MPVLib.setPropertyBoolean("user-data/tv-mpv/sdr-video-layer", fastVideoLayer)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/p5", caps.p5 || caps.p5Hdr)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/p7", caps.p7)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/p8", caps.p8)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/automatic-decoder", true)
        MPVLib.setPropertyBoolean("user-data/tv-mpv/platform-dolby",
            caps.p5Hdr)
        MPVLib.setPropertyBoolean("user-data/tv-mpv/p7-hdr10-base", true)
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

    private fun updateWindowColorMode(mode: String) {
        if (Build.VERSION.SDK_INT < 26) return
        var owner = context
        while (owner is ContextWrapper && owner !is Activity) {
            val next = owner.baseContext
            if (next === owner) break
            owner = next
        }
        val window = (owner as? Activity)?.window ?: return
        val mappedHdr = gpuCapabilities and 8 != 0 && mode in setOf("p5-hdr", "hdr", "p7-hdr-base")
        if (mappedHdr && originalWindowColorMode == null) originalWindowColorMode = window.colorMode
        val desired = if (mappedHdr) ActivityInfo.COLOR_MODE_HDR else originalWindowColorMode ?: return
        if (window.colorMode != desired) window.colorMode = desired
        if (!mappedHdr) originalWindowColorMode = null
    }


    fun close() {
        started = false
        audioPassthrough.close()
        surfaceRequest = null
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
        // user-data is a node property: MPV_FORMAT_STRING serializes its
        // string nodes as JSON. Decode that layer before using the value.
        val text = if (value.startsWith('"'))
            runCatching { JSONTokener(value).nextValue() as? String }.getOrNull() ?: return
        else value
        if (property == "user-data/afuse-p5/vo") currentVo = text
        if (property == "user-data/afuse-p5/mode") dispatch { updateWindowColorMode(text) }
        if (property == "user-data/tv-mpv/render-request") dispatch { sizeSurface(text) }
    }

    companion object { private const val TAG = "tv-mpv" }
}
