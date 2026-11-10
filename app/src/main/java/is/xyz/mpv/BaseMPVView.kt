package `is`.xyz.mpv

import android.content.Context
import android.os.Build
import android.util.AttributeSet
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView

// Contains only the essential code needed to get a picture on the screen

abstract class BaseMPVView(context: Context, attrs: AttributeSet) : SurfaceView(context, attrs), SurfaceHolder.Callback {
    private var nativeSurface: NativeDolbySurface? = null
    private var initialized = false
    /**
     * Initialize libmpv.
     *
     * Call this once before the view is shown.
     */
    fun initialize(configDir: String, cacheDir: String) {
        MPVLib.create(context.applicationContext)

        /* set normal options (user-supplied config can override) */
        MPVLib.setOptionString("config", "yes")
        MPVLib.setOptionString("config-dir", configDir)
        for (opt in arrayOf("gpu-shader-cache-dir", "icc-cache-dir"))
            MPVLib.setOptionString(opt, cacheDir)
        initOptions()

        MPVLib.init()
        initialized = true

        /* set hardcoded options */
        postInitOptions()
        // could mess up VO init before surfaceCreated() is called
        MPVLib.setOptionString("force-window", "no")
        // need to idle at least once for playFile() logic to work
        MPVLib.setOptionString("idle", "once")

        holder.addCallback(this)
        observeProperties()
    }

    /**
     * Deinitialize libmpv.
     *
     * Call this once before the view is destroyed.
     */
    fun destroy() {
        if (!initialized) return
        initialized = false
        // Disable surface callbacks to avoid using uninitialized mpv state
        holder.removeCallback(this)
        onPlaybackDestroyed()
        MPVLib.setPropertyBoolean("user-data/afuse-surface/ready", false)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/surface-ready", false)
        MPVLib.setPropertyString("vo", "null")
        MPVLib.setPropertyString("force-window", "no")
        MPVLib.attachNativeDolbySurface(null)
        nativeSurface = null
        MPVLib.detachSurface()
        MPVLib.destroy()
    }

    protected abstract fun initOptions()
    protected abstract fun postInitOptions()

    protected abstract fun observeProperties()
    protected open fun refreshOutputCapabilities() {}
    protected open fun onPlaybackSurfaceReady() {}
    protected open fun onPlaybackDestroyed() {}
    protected open fun surfaceVo(fallback: String): String = fallback

    internal fun setVideoFrameRate(rate: Float) {
        if (Build.VERSION.SDK_INT < 30 || !holder.surface.isValid) return
        try {
            if (Build.VERSION.SDK_INT >= 31)
                holder.surface.setFrameRate(rate, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                    android.view.Surface.CHANGE_FRAME_RATE_ALWAYS)
            else
                holder.surface.setFrameRate(rate, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            nativeSurface?.setFrameRate(rate)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Display frame rate request unavailable", error)
        }
    }

    private var filePath: String? = null

    /**
     * Set the first file to be played once the player is ready.
     */
    fun playFile(filePath: String) {
        this.filePath = filePath
    }

    private var voInUse: String = "gpu"

    /**
     * Sets the VO to use.
     * It is automatically disabled/enabled when the surface dis-/appears.
     */
    fun setVo(vo: String) {
        voInUse = vo
        MPVLib.setOptionString("vo", vo)
    }

    // Surface callbacks

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (!initialized) return
        MPVLib.setPropertyString("android-surface-size", "${width}x$height")
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (!initialized) return
        refreshOutputCapabilities()
        Log.w(TAG, "attaching surface")
        MPVLib.attachSurfaceForPlayback(holder.surface)
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                nativeSurface = NativeDolbySurface.create(this)
                MPVLib.attachNativeDolbySurface(nativeSurface)
                MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/surface-ready", true)
            } catch (error: RuntimeException) {
                MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/surface-ready", false)
                Log.w(TAG, "Native Dolby Surface host unavailable", error)
            } catch (error: LinkageError) {
                MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/surface-ready", false)
                Log.w(TAG, "Native Surface API unavailable on this firmware", error)
            }
        }
        MPVLib.setPropertyString("android-surface-size", "${width}x$height")
        // This forces mpv to render subs/osd/whatever into our surface even if it would ordinarily not
        MPVLib.setOptionString("force-window", "yes")
        MPVLib.setPropertyBoolean("user-data/afuse-surface/ready", true)

        if (filePath != null) {
            MPVLib.command(arrayOf("loadfile", filePath as String))
            filePath = null
        } else {
            // We disable video output when the context disappears, enable it back
            MPVLib.setPropertyString("vo", surfaceVo(voInUse))
        }
        onPlaybackSurfaceReady()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (!initialized) return
        MPVLib.setPropertyBoolean("user-data/afuse-surface/ready", false)
        MPVLib.setPropertyBoolean("user-data/afuse-native-dolby/surface-ready", false)
        Log.w(TAG, "detaching surface")
        MPVLib.setPropertyString("vo", "null")
        MPVLib.setPropertyString("force-window", "no")
        // Note that before calling detachSurface() we need to be sure that libmpv
        // is done using the surface.
        // FIXME: There could be a race condition here, because I don't think
        // setting a property will wait for VO deinit.
        MPVLib.attachNativeDolbySurface(null)
        nativeSurface = null
        MPVLib.detachSurface()
    }

    companion object {
        private const val TAG = "mpv"
    }
}
