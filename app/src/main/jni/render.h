#pragma once

#include <jni.h>
#include <stdint.h>

// A wid reply is the lifetime barrier for the previous Java Surface reference.
bool handle_surface_reply(JNIEnv *env, uint64_t userdata, int error);
// Call only after the event thread and libmpv core have both terminated.
void release_surface_references(JNIEnv *env);
