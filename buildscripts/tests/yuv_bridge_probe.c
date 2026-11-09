/* On-device validation of the exact shaders used by the HW+ YUV bridge.
 * Build for Android API 29+, link -landroid -lEGL -lGLESv3 -lm.
 * CPU writes/readbacks are test assertions only, not part of the playback path.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "../deps/mpv/video/out/hwdec/android_yuv_shaders.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (GL=%x EGL=%x)\n", \
    __LINE__, #x, glGetError(), eglGetError()); exit(1); } } while (0)

static GLuint compile(GLenum type, const char *src)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
    }
    CHECK(ok);
    return shader;
}

static void test_buffer(EGLDisplay display, GLuint program, int depth)
{
    const int w = 16, h = 16;
    const int codes[3][2] = {{65, 191}, {97, 161}, {177, 81}};
    // P010 was added to the NDK in API 33. Probe support without requiring
    // any API 33 functions on API 29-32 devices.
    AHardwareBuffer_Desc desc = {
        .width = w, .height = h, .layers = 1,
        .format = depth == 10 ? 0x36 : AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420,
        .usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
                 AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    };
    AHardwareBuffer *buffer = NULL;
    int ret = AHardwareBuffer_allocate(&desc, &buffer);
    if (depth == 10 && ret) {
        printf("SKIP P010 allocation unsupported (%d); 10-bit decoding remains unverified.\n", ret);
        return;
    }
    CHECK(ret == 0);
    AHardwareBuffer_Planes planes;
    CHECK(AHardwareBuffer_lockPlanes(buffer, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
                                    -1, NULL, &planes) == 0);
    printf("%d-bit lockPlanes: %u planes\n", depth, planes.planeCount);
    CHECK(planes.planeCount == 3 || (depth == 10 && planes.planeCount == 2));
    for (int c = 0; c < 3; c++) {
        const AHardwareBuffer_Plane *p = &planes.planes[planes.planeCount == 2 && c ? 1 : c];
        int cw = c ? w / 2 : w, ch = c ? h / 2 : h;
        for (int y = 0; y < ch; y++) {
            for (int x = 0; x < cw; x++) {
                uint8_t *dst = (uint8_t *)p->data + y * p->rowStride + x * p->pixelStride;
                int code = codes[c][y >= ch / 2];
                if (depth == 10) {
                    // Include low bits, so silent 10 -> 8 truncation is detected.
                    if (planes.planeCount == 2 && c == 2) dst += 2;
                    *(uint16_t *)dst = (uint16_t)((code * 4 + 1) << 6);
                } else {
                    *dst = code;
                }
            }
        }
    }
    CHECK(AHardwareBuffer_unlock(buffer, NULL) == 0);
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_client =
        (void *)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    PFNEGLCREATEIMAGEKHRPROC create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target_image =
        (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    CHECK(get_client && create_image && destroy_image && target_image);
    EGLImageKHR image = create_image(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                                     get_client(buffer), (EGLint[]){EGL_NONE});
    CHECK(image != EGL_NO_IMAGE_KHR);
    GLuint source, textures[3], fbo, vao;
    glGenTextures(1, &source);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, source);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    target_image(GL_TEXTURE_EXTERNAL_OES, image);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenTextures(3, textures);
    const GLenum attachments[3] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2};
    for (int c = 0; c < 3; c++) {
        glBindTexture(GL_TEXTURE_2D, textures[c]);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_R16F, w, h);
        glFramebufferTexture2D(GL_FRAMEBUFFER, attachments[c], GL_TEXTURE_2D, textures[c], 0);
    }
    glDrawBuffers(3, attachments);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "source"), 0);
    glViewport(0, 0, w, h);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    CHECK(glGetError() == GL_NO_ERROR);
    for (int c = 0; c < 3; c++) {
        glReadBuffer(attachments[c]);
        for (int half = 0; half < 2; half++) {
            float pixel[4] = {0};
            glReadPixels(4, half ? 12 : 2, 1, 1, GL_RGBA, GL_FLOAT, pixel);
            CHECK(glGetError() == GL_NO_ERROR);
            float expected = depth == 10 ? (codes[c][half] * 4 + 1) / 1023.0f
                                         : codes[c][half] / 255.0f;
            printf("%d-bit plane %d half %d: %.6f expected %.6f\n", depth, c, half, pixel[0], expected);
            CHECK(fabsf(pixel[0] - expected) < 0.0006f);
        }
    }
    printf("PASS %d-bit raw YUV -> three R16F targets (values and orientation).\n", depth);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteVertexArrays(1, &vao);
    glDeleteTextures(3, textures);
    glDeleteTextures(1, &source);
    destroy_image(display, image);
    AHardwareBuffer_release(buffer);
}

int main(void)
{
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    CHECK(eglInitialize(display, NULL, NULL));
    EGLConfig config;
    EGLint count;
    CHECK(eglChooseConfig(display, (EGLint[]) {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE,
    }, &config, 1, &count) && count);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                                          (EGLint[]){EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE});
    EGLSurface surface = eglCreatePbufferSurface(display, config,
                                                 (EGLint[]){EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE});
    CHECK(eglMakeCurrent(display, surface, surface, context));
    printf("GPU: %s; %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    GLuint vs = compile(GL_VERTEX_SHADER, android_yuv_vertex_shader);
    GLuint fs = compile(GL_FRAGMENT_SHADER, android_yuv_fragment_shader);
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    CHECK(linked);
    test_buffer(display, program, 8);
    test_buffer(display, program, 10);
    glDeleteProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, surface);
    eglDestroyContext(display, context);
    eglTerminate(display);
    return 0;
}
