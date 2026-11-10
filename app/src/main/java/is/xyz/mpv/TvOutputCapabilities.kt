package `is`.xyz.mpv

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Display

/** Current display types and hardware decoders are checked independently. */
internal data class TvOutputCapabilities(
    val p5: Boolean = false,
    val p8: Boolean = false,
    val pqCodecs: Set<String> = emptySet(),
    val hlgCodecs: Set<String> = emptySet(),
    val dolbyDisplay: Boolean = false
) {
    val available get() = p5 || p8 || pqCodecs.isNotEmpty() || hlgCodecs.isNotEmpty()

    companion object {
        @Suppress("DEPRECATION")
        fun query(display: Display, hdr10Compatibility: Boolean = false,
                  platformDolbyCompatibility: Boolean = false): TvOutputCapabilities {
            if (Build.VERSION.SDK_INT < 29) return TvOutputCapabilities()
            val types = if (Build.VERSION.SDK_INT >= 34) display.mode.supportedHdrTypes
                else display.hdrCapabilities?.supportedHdrTypes ?: intArrayOf()
            val pq = hdr10Compatibility || types.any { it == Display.HdrCapabilities.HDR_TYPE_HDR10 ||
                it == Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS }
            val hlg = Display.HdrCapabilities.HDR_TYPE_HLG in types
            val dv = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types
            Log.i("tv-mpv", "Display HDR types=${types.contentToString()}, HDR10 compatibility=$hdr10Compatibility")
            return try {
                val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                    .filter { !it.isEncoder && it.isHardwareAccelerated }
                for (decoder in decoders.filter { codec -> codec.supportedTypes.any { it.startsWith("video/") } }) {
                    Log.i("tv-mpv", "Hardware decoder ${decoder.name}: ${decoder.supportedTypes.contentToString()}")
                }
                fun profiles(mime: String): Set<Int> = decoders
                    .filter { it.supportedTypes.any { type -> type.equals(mime, true) } }
                    .flatMap { it.getCapabilitiesForType(mime).profileLevels.toList() }
                    .map { it.profile }.toSet()
                val dolby = if (dv || platformDolbyCompatibility)
                    profiles(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) else emptySet()
                Log.i("tv-mpv", "Dolby decoder profiles=$dolby, platform compatibility=$platformDolbyCompatibility")
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
                TvOutputCapabilities(
                    MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheStn in dolby,
                    dv && MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheSt in dolby,
                    if (pq) codecs.toSet() else emptySet(),
                    if (hlg) codecs.toSet() else emptySet(), dv)
            } catch (error: RuntimeException) {
                Log.w("MpvNativeDolby", "Unable to query native HDR/Dolby capabilities", error)
                TvOutputCapabilities()
            }
        }
    }
}
