package is.xyz.mpv;

import androidx.annotation.Keep;

/** One decoder per selected Exo track. All calls run on its subtitle worker. */
@Keep
public final class ExoSubtitles {
    static { System.loadLibrary("mpv"); }
    private ExoSubtitles() {}
    public static native long open(String configDir, String font, String codec, byte[][] init,
                                   int width, int height, int codecTag);
    public static native void close(long handle);
    public static native void reset(long handle);
    public static native boolean settings(long handle, int mode, boolean stretch, float position, float scale, long delayUs, boolean scaleWithVideo);
    public static native void font(long handle, String family);
    public static native void video(long handle, int width, int height, float pixelRatio);
    public static native void packet(long handle, byte[] data, int start, long ptsUs, long durationUs);
    public static native boolean draw(long handle, long ptsUs, int width, int height, int ml, int mt, int mr, int mb,
                                      int colorUniform, int maskUniform, boolean force);

    /** Called synchronously on the Exo loading thread while demuxing a bounded text file. */
    @Keep
    public interface TextPackets {
        void header(byte[] data);
        void sample(long ptsUs, long durationUs, byte[] data);
    }
    /** Streams a private, already resolved subtitle file into one packet cache per track. */
    @Keep
    public interface FilePackets {
        void font(byte[] filename, byte[] data);
        void stream(int index, String codec, byte[] language, byte[] title, int width, int height,
                    int codecTag, byte[] header);
        void sample(int index, long ptsUs, long durationUs, byte[] data);
    }
    public static native boolean demuxFile(String path, FilePackets output);
    public static native boolean demuxText(String format, byte[] file, TextPackets output);
}
