package `is`.xyz.mpv

import android.app.Activity
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Query Android's explicit HDR-to-SDR request without touching display settings. */
class TvToneMapProbeActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        Thread {
            val results = JSONArray()
            for ((mime, profile) in listOf(
                MediaFormat.MIMETYPE_VIDEO_HEVC to MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10,
                MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION to MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheStn,
                MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION to MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheSt)) {
                val result = JSONObject().put("mime", mime).put("profile", profile)
                var codec: MediaCodec? = null
                val texture = SurfaceTexture(false)
                val surface = Surface(texture)
                try {
                    if (Build.VERSION.SDK_INT < 31) error("Requires Android 12")
                    val format = MediaFormat.createVideoFormat(mime, 3840, 2160).apply {
                        setInteger(MediaFormat.KEY_PROFILE, profile)
                        setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT2020)
                        setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_ST2084)
                        setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                        setInteger(MediaFormat.KEY_COLOR_TRANSFER_REQUEST, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                    }
                    codec = MediaCodec.createDecoderByType(mime)
                    result.put("decoder", codec.name)
                    codec.configure(format, surface, null, 0)
                    val input = codec.inputFormat
                    result.put("input-format", input.toString())
                    result.put("sdr-request-supported", input.containsKey(MediaFormat.KEY_COLOR_TRANSFER_REQUEST) &&
                        input.getInteger(MediaFormat.KEY_COLOR_TRANSFER_REQUEST) == MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                } catch (error: RuntimeException) {
                    result.put("error", error.toString())
                } finally {
                    codec?.release()
                    surface.release()
                    texture.release()
                }
                results.put(result)
            }
            File(filesDir, "tv-tonemap-probe.json").writeText(results.toString(2))
            runOnUiThread { finish() }
        }.start()
    }
}
