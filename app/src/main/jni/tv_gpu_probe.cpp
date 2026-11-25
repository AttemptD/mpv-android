// Probe optional fast paths with actual allocations and GL imports, without
// selecting a video renderer or modifying the application's display mode.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <cstring>
#include "jni_utils.h"

static bool has_extension(const char *extensions, const char *name)
{
    if (!extensions) return false;
    const size_t n = strlen(name);
    const char *p = extensions;
    while ((p = strstr(p, name))) {
        if ((p == extensions || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return true;
        p += n;
    }
    return false;
}

static bool nv21_target(EGLDisplay display, int width, int height, uint64_t extra_usage)
{
    void *library = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) return false;
    using Allocate = int (*)(const AHardwareBuffer_Desc *, AHardwareBuffer **);
    using Release = void (*)(AHardwareBuffer *);
    auto allocate = reinterpret_cast<Allocate>(dlsym(library, "AHardwareBuffer_allocate"));
    auto release = reinterpret_cast<Release>(dlsym(library, "AHardwareBuffer_release"));
    auto client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
    auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    auto destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
    auto bind = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    bool ok = false;
    AHardwareBuffer *buffer = nullptr;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint texture = 0, fbo = 0;
    AHardwareBuffer_Desc desc = {};
    desc.width = width; desc.height = height; desc.layers = 1;
    desc.format = 0x11; // HAL NV21; availability is probed, never assumed.
    desc.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
                 AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER |
                 AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY | extra_usage;
    if (allocate && release && client && create && destroy && bind && !allocate(&desc, &buffer)) {
        image = create(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, client(buffer), nullptr);
        if (image != EGL_NO_IMAGE_KHR) {
            glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
            bind(GL_TEXTURE_EXTERNAL_OES, image);
            glGenFramebuffers(1, &fbo);
            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_EXTERNAL_OES, texture, 0);
            ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE && glGetError() == GL_NO_ERROR;
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (texture) glDeleteTextures(1, &texture);
    if (image != EGL_NO_IMAGE_KHR) destroy(display, image);
    if (buffer) release(buffer);
    dlclose(library);
    return ok;
}

extern "C" jni_func(jint, probeTvGpu, jint width, jint height)
{
    (void)env; (void)obj;
    if (width < 1 || height < 1 || width > 8192 || height > 8192) return 0;
    EGLDisplay old_display = eglGetCurrentDisplay();
    EGLContext old_context = eglGetCurrentContext();
    EGLSurface old_draw = eglGetCurrentSurface(EGL_DRAW), old_read = eglGetCurrentSurface(EGL_READ);
    EGLenum old_api = eglQueryAPI();
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) return 0;
    const bool initialize = !eglQueryString(display, EGL_VERSION);
    eglGetError();
    if (initialize && !eglInitialize(display, nullptr, nullptr)) return 0;
    EGLConfig config;
    EGLint count = 0;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    int result = 0;
    const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_NONE};
    const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLint surface_attrs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    if (eglBindAPI(EGL_OPENGL_ES_API) && eglChooseConfig(display, attrs, &config, 1, &count) && count) {
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctx_attrs);
        surface = eglCreatePbufferSurface(display, config, surface_attrs);
        if (context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE && eglMakeCurrent(display, surface, surface, context)) {
            // A native HDR video plane does not imply that RGB GPU windows
            // can reach HDR. Require an advertised PQ window contract and an
            // actual ten-bit window configuration, not merely a dataspace
            // setter returning success on an SDR-only client compositor.
            const char *egl_extensions = eglQueryString(display, EGL_EXTENSIONS);
            if (has_extension(egl_extensions, "EGL_EXT_gl_colorspace_bt2020_pq")) {
                const EGLint hdr_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                    EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 10,
                    EGL_GREEN_SIZE, 10, EGL_BLUE_SIZE, 10, EGL_NONE};
                EGLConfig hdr_config;
                EGLint hdr_count = 0;
                if (eglChooseConfig(display, hdr_attrs, &hdr_config, 1, &hdr_count) && hdr_count)
                    result |= 8;
            }
            const char *extensions = reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
            if (has_extension(extensions, "GL_EXT_YUV_target")) {
                GLint tex2d = 0, tex3d = 0;
                glGetIntegerv(GL_MAX_TEXTURE_SIZE, &tex2d);
                glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &tex3d);
                GLuint texture = 0, fbo = 0;
                glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, 32, 32, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, nullptr);
                glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
                if (tex2d >= 1024 && tex3d >= 32 && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE && glGetError() == GL_NO_ERROR)
                    result |= 1; // 32^3 RGB10 LUT.
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &texture);
                // Public camera-write usage can provide scanout-compatible
                // buffers; fall back to the ordinary allocation when rejected.
                if (nv21_target(display, width, height, 1ULL << 17)) result |= 2;
                else if (nv21_target(display, width, height, 0)) result |= 4;
            }
        }
    }
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
    eglBindAPI(old_api);
    if (old_context != EGL_NO_CONTEXT) eglMakeCurrent(old_display, old_draw, old_read, old_context);
    if (initialize) eglTerminate(display);
    return result;
}
