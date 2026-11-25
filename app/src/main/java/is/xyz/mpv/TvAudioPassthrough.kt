package `is`.xyz.mpv

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioProfile
import android.os.Build
import android.os.Handler

/** Manages the automatic IEC61937 option for the current media output. */
class TvAudioPassthrough(context: Context, private val handler: Handler) : MPVLib.EventObserver {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val mediaAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
    private var enabled = false
    private var managing = false
    private var formats = ""
    private var applied = ""
    private val refresh = Runnable { if (managing) updateOption() }
    private val routeListener = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = updateRoute()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = updateRoute()
    }

    fun configure(enable: Boolean) {
        enabled = enable && Build.VERSION.SDK_INT >= 29
        if (!enabled) return
        formats = supportedFormats()
        applied = formats
        MPVLib.setOptionString("audio-spdif", applied)
    }

    fun start() {
        // An explicit audio-spdif in mpv.conf takes precedence over the preset.
        if (!enabled || MPVLib.getPropertyString("audio-spdif").orEmpty() != applied) return
        managing = true
        MPVLib.addObserver(this)
        MPVLib.observeProperty("speed", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        MPVLib.observeProperty("af", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        MPVLib.observeProperty("audio-channels", MPVLib.MpvFormat.MPV_FORMAT_STRING)
        audioManager.registerAudioDeviceCallback(routeListener, handler)
        updateRoute()
    }

    fun close() {
        if (!managing) return
        managing = false
        audioManager.unregisterAudioDeviceCallback(routeListener)
        MPVLib.removeObserver(this)
        handler.removeCallbacks(refresh)
    }

    private fun updateRoute() {
        if (!managing) return
        formats = supportedFormats()
        updateOption()
    }

    private fun supportedFormats(): String {
        val routes = if (Build.VERSION.SDK_INT >= 33) {
            audioManager.getAudioDevicesForAttributes(mediaAttributes)
        } else {
            // Prior to API 33, direct playback queries can include a connected
            // HDMI port even when media routes to headphones. Be conservative
            // when there is a competing output.
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filterNot {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER ||
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE ||
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
        }
        if (routes.isEmpty() || routes.any { it.type !in DIGITAL_OUTPUT_TYPES }) return ""
        val advertised = routes.map { it.encodings.toSet() }.reduce { a, b -> a intersect b }
        return buildList {
            if (AudioFormat.ENCODING_AC3 in advertised) add("ac3")
            if (AudioFormat.ENCODING_E_AC3 in advertised || AudioFormat.ENCODING_E_AC3_JOC in advertised) add("eac3")
            if (supportsIec61937(routes, AudioFormat.ENCODING_DTS)) {
                // mpv's dts-hd option also enables DTS core passthrough.
                add(if (supportsIec61937(routes, AudioFormat.ENCODING_DTS_HD, AudioFormat.ENCODING_DTS_HD_MA)) {
                    "dts-hd"
                } else {
                    "dts"
                })
            }
            if (AudioFormat.ENCODING_DOLBY_TRUEHD in advertised) add("truehd")
        }.joinToString(",")
    }

    private fun supportsIec61937(routes: List<AudioDeviceInfo>, vararg encodings: Int): Boolean {
        if (Build.VERSION.SDK_INT < 31) return false
        // A generic IEC61937 profile or a raw DTS format can be reported even
        // when the device cannot play DTS bursts supplied by the application.
        return routes.all { route ->
            route.audioProfiles.any { profile ->
                profile.format in encodings &&
                    profile.encapsulationType == AudioProfile.AUDIO_ENCAPSULATION_TYPE_IEC61937
            }
        }
    }

    private fun updateOption() {
        val speed = MPVLib.getPropertyDouble("speed") ?: 1.0
        val filters = MPVLib.getPropertyString("af").orEmpty()
        val stereo = MPVLib.getPropertyString("audio-channels") == "stereo"
        val requested = if (speed == 1.0 && (filters.isEmpty() || filters == "[]") && !stereo) formats else ""
        if (requested != applied) {
            applied = requested
            MPVLib.setPropertyString("audio-spdif", applied)
        }
    }

    private fun onOptionChanged(property: String) {
        if (property == "speed" || property == "af" || property == "audio-channels") {
            handler.removeCallbacks(refresh)
            handler.post(refresh)
        }
    }

    override fun event(eventId: Int) {}
    override fun eventEndFile(reason: Int, error: Int) {}
    override fun eventProperty(property: String) = onOptionChanged(property)
    override fun eventProperty(property: String, value: String) = onOptionChanged(property)
    override fun eventProperty(property: String, value: Double) = onOptionChanged(property)
    override fun eventProperty(property: String, value: Long) {}
    override fun eventProperty(property: String, value: Boolean) {}

    companion object {
        const val PREFERENCE = "mpv_audio_passthrough"
        private val DIGITAL_OUTPUT_TYPES = setOf(AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC, AudioDeviceInfo.TYPE_LINE_DIGITAL)
    }
}
