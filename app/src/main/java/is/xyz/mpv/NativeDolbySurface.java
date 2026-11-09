package is.xyz.mpv;

import android.annotation.TargetApi;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.view.Surface;
import android.view.SurfaceControl;
import android.view.SurfaceView;
import androidx.annotation.Keep;

/** Separate native HDR/Dolby video and SDR caption layers preserve decoder output. */
@Keep
@TargetApi(29)
public final class NativeDolbySurface {
    private final SurfaceControl backgroundControl, videoControl, captionControl;
    private final Surface backgroundSurface, videoSurface, captionSurface;
    private boolean released, visible;

    public static NativeDolbySurface create(SurfaceView view) {
        return new NativeDolbySurface(view.getSurfaceControl());
    }

    private NativeDolbySurface(SurfaceControl parent) {
        SurfaceControl background = null, video = null, captions = null;
        Surface blackSurface = null, decodedSurface = null, subtitleSurface = null;
        try {
            background = new SurfaceControl.Builder().setName("Afuse native Dolby background")
                    .setParent(parent).setBufferSize(1, 1).setFormat(PixelFormat.RGBA_8888)
                    .setOpaque(true).setHidden(true).build();
            video = new SurfaceControl.Builder().setName("Afuse native Dolby video")
                    .setParent(parent).setBufferSize(1, 1).setOpaque(true).setHidden(true).build();
            captions = new SurfaceControl.Builder().setName("Afuse native Dolby captions")
                    .setParent(parent).setBufferSize(1, 1).setFormat(PixelFormat.RGBA_8888)
                    .setOpaque(false).setHidden(true).build();
            blackSurface = new Surface(background);
            decodedSurface = new Surface(video);
            subtitleSurface = new Surface(captions);
            Canvas canvas = blackSurface.lockCanvas(null);
            canvas.drawColor(Color.BLACK);
            blackSurface.unlockCanvasAndPost(canvas);
            try (SurfaceControl.Transaction tx = new SurfaceControl.Transaction()) {
                tx.setLayer(background, 0).setLayer(video, 1).setLayer(captions, 2).apply();
            }
        } catch (RuntimeException error) {
            if (blackSurface != null) blackSurface.release();
            if (decodedSurface != null) decodedSurface.release();
            if (subtitleSurface != null) subtitleSurface.release();
            if (background != null) background.release();
            if (video != null) video.release();
            if (captions != null) captions.release();
            throw error;
        }
        backgroundControl = background; videoControl = video; captionControl = captions;
        backgroundSurface = blackSurface; videoSurface = decodedSurface; captionSurface = subtitleSurface;
    }

    public synchronized Surface getVideoSurface() { return videoSurface; }
    public synchronized Surface getCaptionSurface() { return captionSurface; }

    /** Called on the MPV VO thread using mpv's crop, zoom, aspect and OSD geometry. */
    public synchronized void setGeometry(int sx0, int sy0, int sx1, int sy1,
            int dx0, int dy0, int dx1, int dy1, int rotation, int width, int height,
            int bufferWidth, int bufferHeight) {
        if (released) throw new IllegalStateException("Native Dolby Surface was released");
        if (width <= 0 || height <= 0 || bufferWidth <= 0 || bufferHeight <= 0 ||
                sx1 <= sx0 || sy1 <= sy0 || dx1 <= dx0 || dy1 <= dy0)
            throw new IllegalArgumentException("Invalid native Dolby geometry");
        Rect screen = new Rect(0, 0, width, height);
        int angle = (rotation % 360 + 360) % 360;
        boolean swap = angle == 90 || angle == 270;
        int dw = dx1 - dx0, dh = dy1 - dy0;
        int sw = sx1 - sx0, sh = sy1 - sy0;
        int frameWidth = swap ? Math.round((float)dw * sw / sh) : dw;
        int frameHeight = swap ? Math.round((float)dh * sh / sw) : dh;
        float xs = (float)frameWidth / sw, ys = (float)frameHeight / sh;
        float x = dx0 - xs * sx0, y = dy0 - ys * sy0;
        // The native setGeometry implementation consumes buffer transform bits,
        // not Surface.ROTATION_* ordinals. Its rotation offsets are unscaled;
        // supply the rotated scale and then set the correct crop translation.
        // Its matrix arguments also reverse the direction of the quarter turns.
        int transform = 0;
        if (angle == 90) {
            transform = 7; // NATIVE_WINDOW_TRANSFORM_ROT_270
            x = dx0 + xs * sy1; y = dy0 - ys * sx0;
        } else if (angle == 180) {
            transform = 3; // NATIVE_WINDOW_TRANSFORM_ROT_180
            x = dx0 + xs * sx1; y = dy0 + ys * sy1;
        } else if (angle == 270) {
            transform = 4; // NATIVE_WINDOW_TRANSFORM_ROT_90
            x = dx0 - xs * sy0; y = dy0 + ys * sx1;
        }
        try (SurfaceControl.Transaction tx = new SurfaceControl.Transaction()) {
            // Surface(SurfaceControl) uses a child BLAST queue on newer Android.
            // Its default size must match the producer, or it first scales each
            // decoded/caption buffer into the original 1x1 placeholder.
            tx.setBufferSize(videoControl, bufferWidth, bufferHeight)
                    .setBufferSize(captionControl, width, height)
                    .setGeometry(backgroundControl, new Rect(0, 0, 1, 1), screen, Surface.ROTATION_0)
                    .setGeometry(videoControl, new Rect(sx0, sy0, sx1, sy1),
                            new Rect(0, 0, frameWidth, frameHeight), transform)
                    .setPosition(videoControl, x, y)
                    .setGeometry(captionControl, screen, screen, Surface.ROTATION_0).apply();
        }
    }

    public synchronized void setVisible(boolean value) {
        if (released || visible == value) return;
        try (SurfaceControl.Transaction tx = new SurfaceControl.Transaction()) {
            tx.setVisibility(backgroundControl, value).setVisibility(videoControl, value)
                    .setVisibility(captionControl, value).apply();
        }
        visible = value;
    }

    /** JNI calls this only after vo=null and the host-property completion barrier. */
    public synchronized void release() {
        if (released) return;
        setVisible(false);
        released = true;
        try (SurfaceControl.Transaction tx = new SurfaceControl.Transaction()) {
            tx.reparent(captionControl, null).reparent(videoControl, null)
                    .reparent(backgroundControl, null).apply();
        }
        captionSurface.release(); videoSurface.release(); backgroundSurface.release();
        captionControl.release(); videoControl.release(); backgroundControl.release();
    }
}
