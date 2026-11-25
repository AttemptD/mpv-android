package `is`.xyz.mpv

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Display

/** Display output and hardware decoder support are independent capabilities. */
internal data class TvOutputCapabilities(
    val p5: Boolean = false,
    val p8: Boolean = false,
    val pqCodecs: Set<String> = emptySet(),
    val hlgCodecs: Set<String> = emptySet(),
    val dolbyDisplay: Boolean = false,
    val pqDisplay: Boolean = false,
    // Candidate only: the engine must verify actual BT.2020/PQ codec output.
    val p5Hdr: Boolean = false,
    val p7: Boolean = false
) {
    fun canMapPq(gpuFlags: Int) = pqDisplay && (gpuFlags and 8) != 0

    internal data class Decoder(val mime: String, val profiles: Set<Int>)

    companion object {
        @Suppress("DEPRECATION")
        fun query(display: Display): TvOutputCapabilities {
            if (Build.VERSION.SDK_INT < 29) return TvOutputCapabilities()
            val types = runCatching {
                if (Build.VERSION.SDK_INT >= 34) display.mode.supportedHdrTypes
                else display.hdrCapabilities?.supportedHdrTypes ?: intArrayOf()
            }.getOrElse {
                Log.w("tv-mpv", "Unable to query display HDR capabilities", it)
                intArrayOf()
            }
            val decoders = mutableListOf<Decoder>()
            val infos = runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos }
                .getOrElse {
                    Log.w("tv-mpv", "Unable to enumerate hardware decoders", it)
                    emptyArray()
                }
            for (codec in infos) {
                if (!runCatching { !codec.isEncoder && codec.isHardwareAccelerated }.getOrDefault(false)) continue
                for (mime in runCatching { codec.supportedTypes }.getOrDefault(emptyArray())) {
                    if (!mime.startsWith("video/")) continue
                    // One broken vendor entry must not hide the other codecs.
                    runCatching {
                        val caps = codec.getCapabilitiesForType(mime)
                        if (!caps.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback) &&
                            !caps.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback)) {
                            decoders += Decoder(mime.lowercase(), caps.profileLevels.map { it.profile }.toSet())
                        }
                    }.onFailure { Log.w("tv-mpv", "Ignoring unreadable codec capability ${codec.name}/$mime", it) }
                }
            }
            return resolve(types, decoders).also {
                Log.i("tv-mpv", "Display HDR=${types.contentToString()}, capabilities=$it")
            }
        }

        internal fun resolve(types: IntArray, decoders: List<Decoder>): TvOutputCapabilities {
            val pq = types.any { it == Display.HdrCapabilities.HDR_TYPE_HDR10 ||
                it == Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS }
            val hlg = Display.HdrCapabilities.HDR_TYPE_HLG in types
            val dv = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types
            fun profiles(mime: String) = decoders.filter { it.mime == mime }.flatMap { it.profiles }.toSet()
            val dolby = profiles(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION)
            val p5 = MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheStn in dolby
            val p8 = MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheSt in dolby
            val p7 = MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheDtb in dolby
            val codecs = mutableSetOf<String>()
            if (profiles(MediaFormat.MIMETYPE_VIDEO_HEVC).any { it in setOf(
                        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10,
                        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10,
                        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus) }) codecs += "hevc"
            if (profiles(MediaFormat.MIMETYPE_VIDEO_VP9).any { it in setOf(
                        MediaCodecInfo.CodecProfileLevel.VP9Profile2,
                        MediaCodecInfo.CodecProfileLevel.VP9Profile3,
                        MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR,
                        MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR,
                        MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR10Plus,
                        MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR10Plus) }) codecs += "vp9"
            if (profiles(MediaFormat.MIMETYPE_VIDEO_AV1).any { it in setOf(
                        MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10,
                        MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10,
                        MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10Plus) }) codecs += "av1"
            return TvOutputCapabilities(
                p5 = dv && p5, p7 = dv && p7, p8 = dv && p8, dolbyDisplay = dv, pqDisplay = pq,
                p5Hdr = !dv && pq && p5,
                pqCodecs = if (pq) codecs else emptySet(),
                hlgCodecs = if (hlg) codecs else emptySet())
        }
    }
}
