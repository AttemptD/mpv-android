#include <jni.h>
#include <map>
#include <mutex>
#include <vector>

#include <mpv/client.h>

#include "jni_utils.h"
#include "log.h"
#include "globals.h"
#include "render.h"

extern "C" {
    jni_func(void, attachSurface, jobject surface_);
    jni_func(void, attachSurfaceOwned, jobject surface_);
    jni_func(void, detachSurface);
    jni_func(void, attachNativeDolbySurface, jobject host_);
};

static jobject surface;
static jobject native_dolby_host;
static std::mutex surface_mutex;
static uint64_t next_surface_request = 0x5355524600000000ULL;
static std::map<uint64_t, jobject> retiring_surfaces;
static std::vector<jobject> failed_surfaces;
static std::map<jobject, jmethodID> owned_surfaces;

static void release_reference(JNIEnv *env, jobject ref)
{
    if (!ref)
        return;
    auto owned = owned_surfaces.find(ref);
    if (owned != owned_surfaces.end()) {
        env->CallVoidMethod(ref, owned->second); // Surface.release(), off the UI thread
        owned_surfaces.erase(owned);
    }
    env->DeleteGlobalRef(ref);
}

// The MPV dispatch queue processes vo=null, force-window=no and wid changes in
// submission order. Never wait for that queue from a SurfaceHolder callback.
// Keep the old GlobalRef alive until the wid reply proves the core replaced it.
static bool queue_reference(JNIEnv *env, const char *property, jobject &current,
                            jobject replacement, jmethodID release = nullptr)
{
    std::lock_guard<std::mutex> lock(surface_mutex);
    if (release)
        owned_surfaces.emplace(replacement, release);
    uint64_t request = ++next_surface_request;
    int64_t wid = reinterpret_cast<intptr_t>(replacement);
    int result = mpv_set_property_async(g_mpv, request, property, MPV_FORMAT_INT64, &wid);
    if (result < 0) {
        ALOGE("Could not queue Surface transition: %s", mpv_error_string(result));
        release_reference(env, replacement);
        return false;
    }
    retiring_surfaces.emplace(request, current);
    current = replacement;
    return true;
}

bool handle_surface_reply(JNIEnv *env, uint64_t userdata, int error)
{
    std::lock_guard<std::mutex> lock(surface_mutex);
    auto pending = retiring_surfaces.find(userdata);
    if (pending == retiring_surfaces.end())
        return false;
    jobject previous = pending->second;
    retiring_surfaces.erase(pending);
    if (error < 0) {
        ALOGE("Surface transition failed: %s; retaining old reference until shutdown",
              mpv_error_string(error));
        if (previous)
            failed_surfaces.push_back(previous);
    } else if (previous) {
        release_reference(env, previous);
    }
    return true;
}

void release_surface_references(JNIEnv *env)
{
    std::lock_guard<std::mutex> lock(surface_mutex);
    release_reference(env, surface);
    surface = NULL;
    release_reference(env, native_dolby_host);
    native_dolby_host = NULL;
    for (const auto &pending : retiring_surfaces) {
        release_reference(env, pending.second);
    }
    retiring_surfaces.clear();
    for (jobject failed : failed_surfaces)
        release_reference(env, failed);
    failed_surfaces.clear();
}

jni_func(void, attachSurface, jobject surface_) {
    CHECK_MPV_INIT();

    jobject replacement = env->NewGlobalRef(surface_);
    if (!replacement)
        die("invalid surface provided");
    queue_reference(env, "wid", surface, replacement);
}

jni_func(void, detachSurface) {
    CHECK_MPV_INIT();

    queue_reference(env, "wid", surface, NULL);
}

jni_func(void, attachSurfaceOwned, jobject surface_) {
    CHECK_MPV_INIT();
    jclass cls = env->GetObjectClass(surface_);
    jmethodID release = env->GetMethodID(cls, "release", "()V");
    env->DeleteLocalRef(cls);
    if (!release) // Leave the real JNI lookup exception pending for Java.
        return;
    jobject replacement = env->NewGlobalRef(surface_);
    if (!replacement)
        return; // NewGlobalRef already raised OutOfMemoryError.
    queue_reference(env, "wid", surface, replacement, release);
}

jni_func(void, attachNativeDolbySurface, jobject host_) {
    CHECK_MPV_INIT();
    if (!host_) {
        queue_reference(env, "android-native-dolby-surface", native_dolby_host, NULL);
        return;
    }
    jclass cls = env->GetObjectClass(host_);
    jmethodID release = env->GetMethodID(cls, "release", "()V");
    env->DeleteLocalRef(cls);
    if (!release) return;
    jobject replacement = env->NewGlobalRef(host_);
    if (!replacement) return;
    queue_reference(env, "android-native-dolby-surface", native_dolby_host, replacement, release);
}
