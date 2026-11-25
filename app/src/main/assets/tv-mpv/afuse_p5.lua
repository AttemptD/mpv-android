-- Select HDR/SDR output from the selected track before decoder creation.
-- The app supplies display capability; an EGL failure still falls back to SDR.
local loaded, video_ready, mode, applying = false, false, "original", false
local inferred_track_id, inferred_transfer
local baseline
local preparing, saved_vo, saved_force_window = false, nil, nil
local mel_option_warned = false
local diagnostic_force_dual = false
local guard, native
local enhancement_active = false
local pending_sizing, sizing_serial
sizing_serial = 0
do
    -- get_script_directory() is nil for a single-file script in this mpv.
    local ok, module = pcall(function()
        local source = debug.getinfo(1, "S").source:gsub("^@", "")
        local directory = mp.get_script_directory() or source:match("^(.*)/[^/]+$") or "."
        native = dofile(directory .. "/afuse_native_dolby.lua").new(mp)
        return dofile(directory .. "/afuse_p7_guard.lua").new()
    end)
    if ok then guard = module
    else mp.msg.warn("P7 performance guard unavailable: " .. tostring(module)) end
end
local function guard_publish()
    if not guard then return end
    mp.set_property_native("user-data/afuse-p7", {
        mode=guard.mode, fallback=guard.fallback, attempted=guard.attempted,
        reason=guard.reason or "", phase=guard.phase, metrics=guard.metrics or {},
        actualDecoder=mp.get_property("hwdec-current") or "unknown",
        enhancementActive=enhancement_active
    })
end
local function switch_dual(enable)
    local ok, result, err = pcall(mp.command_native, {"android-p7-set-dual", enable and 1 or 0})
    if not ok or result ~= true then
        mp.msg.warn("P7 native composition switch failed: " .. tostring(err or result))
        return false
    end
    return true
end
local keys = {"vo", "gpu-api", "android-hdr-output", "target-colorspace-hint",
              "target-prim", "target-trc", "target-peak", "tone-mapping",
              "android-video-layer",
              "vd-queue-enable", "vd-queue-max-samples", "vd-queue-max-secs"}
local sdr = {vo="gpu-next", ["gpu-api"]="opengl", ["android-hdr-output"]="no",
             ["target-colorspace-hint"]="no", ["target-prim"]="bt.709",
             ["target-trc"]="bt.1886", ["target-peak"]="100", ["tone-mapping"]="bt.2390"}
-- Keep the target color parameters automatic: the Android EGL context reports
-- PQ only after a 10-bit BT.2020/PQ Surface has really been created.
local direct = {vo="android-native-dolby", ["android-hdr-output"]="no"}
local native_hdr = {vo="android-native-hdr", ["android-hdr-output"]="no",
                    ["vd-queue-enable"]="yes", ["vd-queue-max-samples"]="2",
                    ["vd-queue-max-secs"]="0.1"}
local native_sdr = {vo="android-native-sdr", ["android-hdr-output"]="no",
                    ["vd-queue-enable"]="yes", ["vd-queue-max-samples"]="2",
                    ["vd-queue-max-secs"]="0.1"}
local hdr = {vo="gpu-next", ["gpu-api"]="opengl", ["android-hdr-output"]="yes",
             ["target-colorspace-hint"]="auto", ["target-prim"]="auto",
             ["target-trc"]="auto", ["target-peak"]="auto", ["tone-mapping"]="auto"}

local function option(name)
    return mp.get_property("options/" .. name)
end

local function surface_ready()
    -- Older integrations without a Surface lifecycle signal remain compatible.
    return mp.get_property_bool("user-data/afuse-surface/ready", true)
end

local function set(name, value)
    if value == nil then return end
    local ok, err = mp.set_property(name, value)
    if not ok then error(name .. ": " .. tostring(err)) end
end

local function snapshot()
    local result = {}
    for _, key in ipairs(keys) do result[key] = option(key) end
    if preparing then result.vo = saved_vo end
    return result
end

local function profile()
    return mp.get_property_number("current-tracks/video/dolby-vision-profile")
end

local function output_mode()
    if not loaded then return "original" end
    local pq_capable = mp.get_property_bool("user-data/afuse-hdr/pq-capable", false) and
        not (native and native.requested == "no")
    local dv = profile()
    if dv == 5 then return pq_capable and "p5-hdr" or "p5-sdr" end
    if dv == 7 then
        if not (native and native.requested == "no") and
           mp.get_property_bool("user-data/tv-mpv/p7-hdr10-base", false) and
           mp.get_property_number("current-tracks/video/dolby-vision-compatibility-id") == 6 then
            return pq_capable and "p7-hdr-base" or "p7-sdr-base"
        end
        return pq_capable and "hdr" or "p7-sdr"
    end
    if not pq_capable then
        local trc = mp.get_property("current-tracks/video/demux-gamma") or
            (video_ready and mp.get_property("video-params/gamma")) or inferred_transfer
        return (dv or trc == "pq" or trc == "hlg") and "hdr-sdr" or "original"
    end
    if dv then return "hdr" end
    local track_id = mp.get_property_number("current-tracks/video/id")
    if track_id and track_id ~= inferred_track_id then
        inferred_track_id, inferred_transfer = track_id, nil
    end
    -- Recreating the VO temporarily clears video-params. Keep the decoded
    -- transfer for this selected track so that HDR -> VO reinit -> nil does
    -- not immediately bounce back to SDR.
    if video_ready then
        local decoded = mp.get_property("video-params/gamma")
        if decoded then inferred_transfer = decoded end
    end
    local transfer = mp.get_property("current-tracks/video/demux-gamma")
                     or inferred_transfer
    return (transfer == "pq" or transfer == "hlg") and "hdr" or "original"
end

local function hwplus(value)
    if value == "auto" or value == "auto-safe" then return true end
    for item in (value or ""):gmatch("[^,]+") do
        if item == "mediacodec" then return true end
    end
    return false
end

local function publish(selected_mode, bridge, target_vo)
    mp.set_property_native("user-data/afuse-p5", {
        ready=true, active=selected_mode ~= "original", bridge=bridge,
        vo=target_vo, mode=selected_mode,
        profile=profile() or 0, hwdec=option("hwdec") or "no",
        melFast=mp.get_property_bool("options/android-dovi-mel-fast", false),
        dual=mp.get_property_bool("options/android-dovi-dual", false)
    })
end

local function apply(decoder)
    if native and decoder then native:request(decoder) end
    if applying or pending_sizing or not surface_ready() then return end
    if native and native:check_failure() then return end
    applying = true
    local ok, err = pcall(function()
        -- Use the original BL decoder's RPU. EL-inherited metadata cannot
        -- establish that this selected compressed stream is safe to convert.
        if native and profile() == 7 and video_ready and
           not mp.get_property_bool("options/android-native-dolby", false) then
            local mel = mp.get_property_bool("video-dec-params/dolby-vision-mel")
            if mel ~= nil then native:classify_mel(mel) end
        end
        local native_kind = native and native:wanted(profile()) and "dolby" or nil
        if native and not native_kind then
            local transfer = mp.get_property("current-tracks/video/demux-gamma") or
                    (video_ready and mp.get_property("video-params/gamma")) or inferred_transfer
            local codec = mp.get_property("current-tracks/video/codec")
            native_kind = native:wanted_hdr(profile(), transfer,
                mp.get_property_number("current-tracks/video/dolby-vision-compatibility-id"), codec)
            if not native_kind and native:wanted_sdr(profile(), transfer, codec,
                    mp.get_property_number("current-tracks/video/demux-w") or 0,
                    mp.get_property_number("current-tracks/video/demux-h") or 0) then
                native_kind = "sdr"
            end
        end
        local selected_mode = native_kind == "dolby" and mp.get_property_bool("user-data/tv-mpv/platform-dolby", false) and "platform-dolby" or
                              native_kind == "sdr" and "native-sdr" or
                              native_kind and native_kind ~= "dolby" and profile() == 7 and "native-hdr-p7-base" or
                              native_kind == "dolby" and "native-dolby" or
                              native_kind and "native-hdr" or output_mode()
        local simple_pixels = #(mp.get_property_native("vf", {})) == 0 and
                              #(mp.get_property_native("glsl-shaders", {})) == 0
        local optimized_sdr = mp.get_property_bool("user-data/tv-mpv/sdr-video-layer", false) and simple_pixels
        if optimized_sdr and selected_mode == "original" and
           mp.get_property_number("current-tracks/video/id") then selected_mode = "tv-sdr" end
        local native_mode = native_kind ~= nil
        local was_native = mode == "native-dolby" or mode == "platform-dolby" or mode == "native-hdr" or
                           mode == "native-hdr-p7-base" or mode == "native-sdr"
        if native_kind == "pq" or native_kind == "hlg" then
            inferred_track_id = mp.get_property_number("current-tracks/video/id")
            inferred_transfer = native_kind
        end
        -- Output/decoder changes can synchronously deselect a failing track.
        -- Snapshot the user's selection before submitting those changes.
        if native_mode and (mode ~= selected_mode or native.kind ~= native_kind) then
            native:prepare_selection()
        end
        local p5 = selected_mode == "p5-hdr" or selected_mode == "p5-sdr"
        local bridge = p5 and hwplus(decoder or option("hwdec"))
        -- The native filter verifies every BL frame's original RPU before
        -- skipping zero-residual EL. P7 signalling alone never discards FEL.
        -- Installed by the TV flavor; ordinary files keep their renderer.
        local dual = profile() == 7 and not native_mode and selected_mode ~= "original" and
                     selected_mode ~= "p7-sdr-base" and selected_mode ~= "p7-hdr-base" and
                     (not guard or guard:wants_dual())
        set("android-dovi-dual", dual and "yes" or "no")
        if not dual and enhancement_active then
            enhancement_active = false
            guard_publish()
        end
        local mel_fast = dual and not diagnostic_force_dual and
                         not (native and native.p7_mel_failed)
        local mel_ok = mp.set_property("android-dovi-mel-fast", mel_fast and "yes" or "no")
        if not mel_ok and mel_fast and not mel_option_warned then
            mp.msg.warn("MEL optimization unavailable in this native library; retaining original EL path")
            mel_option_warned = true
        end
        if selected_mode ~= "original" and mode == "original" then baseline = snapshot() end
        local target = (native_kind == "dolby" and direct) or (native_kind == "sdr" and native_sdr) or
                       (native_mode and native_hdr) or ((selected_mode == "p5-sdr" or selected_mode == "p7-sdr" or selected_mode == "p7-sdr-base" or selected_mode == "hdr-sdr") and sdr) or
                       (selected_mode == "tv-sdr" and sdr) or (selected_mode ~= "original" and hdr) or
                       (mode ~= "original" and baseline or snapshot())
        local target_layer = (baseline and baseline["android-video-layer"]) or option("android-video-layer")
        if optimized_sdr and not native_mode and target == sdr then target_layer = "yes" end
        local buffered_fallback = optimized_sdr and
            (selected_mode == "p7-sdr-base" or selected_mode == "p7-hdr-base" or selected_mode == "hdr-sdr") and
            hwplus(decoder or option("hwdec"))
        local layer_changed = target_layer ~= nil and option("android-video-layer") ~= target_layer
        local bridge_changed = (option("android-dovi-yuv") == "yes") ~= bridge
        local rebuild = preparing or mode ~= selected_mode
        local output_changed = target["android-hdr-output"] ~= nil and
                               option("android-hdr-output") ~= target["android-hdr-output"]
        -- android-hdr-output is read when EGL is created, not on every frame.
        -- Setting vo=gpu-next again is a no-op when it is already selected.
        -- Only an actual HDR/SDR output transition needs this explicit teardown;
        -- decoder toggles within the same output mode keep the existing VO.
        if (output_changed or layer_changed or mode ~= selected_mode and (native_mode or was_native)) and option("vo") ~= "null" then set("vo", "null") end
        set("android-native-dolby", native_kind == "dolby" and "yes" or "no")
        set("android-native-dolby-hdr", selected_mode == "platform-dolby" and "yes" or "no")
        set("android-native-hdr", (native_kind == "pq" or native_kind == "hlg") and native_kind or "no")
        if option("android-native-sdr") ~= nil then
            set("android-native-sdr", native_kind == "sdr" and "yes" or "no")
        end
        set("android-native-dolby-p7-mel", native_kind == "dolby" and profile() == 7 and
            not mp.get_property_bool("user-data/afuse-native-dolby/p7", false) and "yes" or "no")
        set("android-native-hdr-p7-base", (selected_mode == "native-hdr-p7-base" or selected_mode == "p7-sdr-base" or selected_mode == "p7-hdr-base") and "yes" or "no")
        -- For a decoder toggle, set the bridge BEFORE hwdec's built-in decoder
        -- reinit. HW/SW do not use AImageReader. Do not create an intermediate
        -- null VO just for a decoder toggle: it needlessly reinitializes a
        -- hardware decoder mid-switch.
        set("android-dovi-yuv", bridge and "yes" or "no")
        if selected_mode ~= "original" or mode ~= "original" then
            for _, key in ipairs(keys) do
                if key ~= "vo" then
                    local value = target[key]
                    if key == "android-video-layer" then value = target_layer end
                    if value == nil and buffered_fallback and key:match("^vd%-queue%-") then
                        value = native_hdr[key]
                    end
                    -- Outside the measured hardware HDR/SDR paths, restore
                    -- the user's original queue, including manual CPU mode.
                    if value == nil and key:match("^vd%-queue%-") and baseline then
                        value = baseline[key]
                    end
                    set(key, value)
                end
            end
        end
        local target_decoder = native_mode and "mediacodec" or
                               (was_native and native and native.requested) or decoder
        if target_decoder then
            if native then native.internal_decoder = target_decoder end
            set("hwdec", target_decoder)
        end
        if rebuild or output_changed or layer_changed then set("vo", target.vo or "gpu") end
        local changed = mode ~= selected_mode or bridge_changed or decoder ~= nil
        mode = selected_mode
        if native then native:selected(native_mode, native_kind) end
        publish(mode, bridge, target.vo or "gpu")
        if changed then
            mp.msg.info(string.format("HDR policy: mode=%s transfer=%s profile=%s hwdec=%s bridge=%s",
                mode, tostring(mp.get_property("current-tracks/video/demux-gamma")),
                tostring(profile()), option("hwdec") or "?", tostring(bridge)))
        end
    end)
    applying = false
    if not ok then
        -- Never leave a failed transition with an enabled bridge or a null VO.
        mp.msg.error("P5 policy failed: " .. tostring(err))
        mp.set_property("android-native-dolby", "no")
        mp.set_property("android-native-dolby-hdr", "no")
        mp.set_property("android-native-dolby-p7-mel", "no")
        mp.set_property("android-native-hdr-p7-base", "no")
        mp.set_property("android-native-hdr", "no")
        if option("android-native-sdr") ~= nil then mp.set_property("android-native-sdr", "no") end
        if native then native:selected(false) end
        mp.set_property("android-dovi-yuv", "no")
        mp.set_property("android-dovi-dual", "no")
        mp.set_property("android-dovi-mel-fast", "no")
        if baseline then
            for _, key in ipairs(keys) do
                if key ~= "vo" and baseline[key] then mp.set_property(key, baseline[key]) end
            end
        end
        mp.set_property("vo", baseline and baseline.vo or "gpu")
        mode = "original"
        publish(mode, false, baseline and baseline.vo or "gpu")
    end
end

if native then native.on_fallback = function() apply() end end

mp.add_hook("on_load", 50, function()
    local retry = native and native:begin_file()
    enhancement_active = false
    if guard then guard:reset_file(); guard_publish() end
    loaded = false
    video_ready = false
    if not retry then inferred_track_id, inferred_transfer = nil, nil end
    mp.set_property("android-dovi-mel-fast", "no")
    saved_vo, saved_force_window = option("vo"), option("force-window")
    -- A force-window placeholder makes a VO option change in on_loaded call
    -- reinit_video_chain BEFORE loadfile finishes selecting demux streams.
    -- Remove it while no tracks are selected, then configure the output without
    -- creating a decoder. Normal decoder creation proceeds after on_loaded.
    set("force-window", "no")
    set("vo", "null")
    mp.set_property("android-dovi-dual", "no")
    preparing = true
end)
mp.add_hook("on_loaded", 50, function(hook)
    loaded = true
    if not hook or not mp.get_property_bool("user-data/tv-mpv/source-size-auto", false) then
        apply()
        return
    end
    local width = mp.get_property_number("current-tracks/video/demux-w") or 0
    local height = mp.get_property_number("current-tracks/video/demux-h") or 0
    local par = mp.get_property_number("current-tracks/video/demux-par") or 1
    local rotation = mp.get_property_number("current-tracks/video/demux-rotation") or 0
    -- Keep every coded pixel, correcting non-square pixels by expanding only
    -- the other axis. Sending an SD anamorphic DVD to the physical 4K canvas
    -- needlessly makes the GPU upscale every frame before HWC scales again.
    -- Even dimensions also satisfy the optional YUV presentation buffer.
    if width > 0 and height > 0 and par > 0 and par < 100 then
        if par > 1.001 then width = math.ceil(width * par / 2) * 2
        elseif par < .999 then height = math.ceil(height / par / 2) * 2 end
        if rotation % 180 ~= 0 then width, height = height, width end
    else
        width, height = 0, 0
    end
    sizing_serial = sizing_serial + 1
    local token = string.format("%.0f", mp.get_time() * 1000000 + sizing_serial)
    local request = {generation=native and native.generation, finished=false}
    local deadline = mp.get_time() + 2
    pending_sizing = request
    hook:defer()
    local function complete()
        if request.finished then return end
        request.finished = true
        if request.timer then request.timer:kill() end
        if pending_sizing == request then
            pending_sizing = nil
            if loaded and (not native or request.generation == native.generation) then apply() end
        end
        hook:cont()
    end
    request.timer = mp.add_periodic_timer(.025, function()
        if mp.get_property_native("user-data/tv-mpv/render-ready") == token then
            complete()
        elseif mp.get_time() >= deadline then
            mp.msg.warn("TV source surface sizing timed out; retaining the available surface")
            complete()
        end
    end)
    mp.add_timeout(2.1, complete) -- Also release the hook after cancellation or Surface loss.
    mp.set_property_native("user-data/tv-mpv/render-request", string.format("%s:%d:%d", token, width, height))
end)
mp.add_hook("on_unload", 50, function()
    if native then
        -- Video-only decoder failure can finish the file before Lua timers
        -- run. Retry while this hook still holds the old playlist entry.
        native:check_failure()
        native:flush_retry()
    end
end)
local function finish_preparing()
    if not surface_ready() then return end
    if preparing then
        preparing = false
        if option("vo") == "null" and saved_vo then set("vo", saved_vo) end
        if saved_force_window then set("force-window", saved_force_window) end
    end
end
mp.register_event("file-loaded", function()
    finish_preparing()
    video_ready = true
    apply()
end)
mp.register_event("end-file", function(event)
    if native then native:end_file(event) end
    loaded = false
    enhancement_active = false
    if guard then guard:interrupt("end-file"); guard_publish() end
    mp.set_property("android-dovi-dual", "no")
    mp.set_property("android-dovi-mel-fast", "no")
    finish_preparing()
end)
mp.observe_property("current-tracks/video/dolby-vision-profile", "native", function()
    if loaded then apply() end
end)
mp.observe_property("current-tracks/video/demux-gamma", "string", function()
    if loaded then apply() end
end)
local guarded_track
mp.observe_property("current-tracks/video/id", "native", function(_, id)
    if guard and loaded and guarded_track and id and id ~= guarded_track then
        guard:reset_file()
    end
    guarded_track = id
    if loaded then apply() end
end)
mp.observe_property("video-params/gamma", "string", function()
    if loaded and video_ready then apply() end
end)
mp.observe_property("video-dec-params/dolby-vision-mel", "bool", function()
    if loaded and video_ready and profile() == 7 then apply() end
end)
mp.observe_property("user-data/afuse-surface/ready", "bool", function(_, ready)
    if ready and loaded then
        apply()
        finish_preparing()
    end
end)
mp.observe_property("user-data/afuse-display/generation", "number", function()
    if loaded then apply() end
end)
-- Also handle advanced user scripts that change hwdec without the app's picker.
mp.observe_property("options/hwdec", "string", function(_, value)
    if native then native:external_decoder(value) end
    if guard then guard:interrupt("decoder-change") end
    if loaded then apply() end
end)
for _, property in ipairs({"vf", "glsl-shaders"}) do
    mp.observe_property(property, "native", function() if loaded then apply() end end)
end
-- Manual overrides are per file. Returning to auto explicitly retries full
-- composition; automatic fallback never oscillates or marks a device forever.
mp.register_script_message("set-p7-dual-mode", function(value)
    if not guard or not loaded or profile() ~= 7 or not surface_ready() then return end
    if value ~= "auto" and value ~= "full" and value ~= "base" then return end
    local enable = value ~= "base"
    if mp.get_property_bool("options/android-dovi-dual", false) ~= enable then
        if not switch_dual(enable) then return end
    end
    guard:set_mode(value)
    apply()
    guard_publish()
end)
-- Events reset measurement history, not a successful per-file fallback latch.
mp.register_event("seek", function() if guard then guard:interrupt("seek") end end)
for _, property in ipairs({"pause", "paused-for-cache", "user-data/afuse-surface/ready"}) do
    mp.observe_property(property, "bool", function()
        if guard then guard:interrupt("lifecycle-or-cache") end
    end)
end
mp.add_periodic_timer(1, function()
    if not guard or not loaded or not video_ready then return end
    -- Ordinary/P5 playback must not run cache/render-performance sampling.
    -- A manual selection or a latched fallback also needs no further samples.
    if profile() ~= 7 then
        enhancement_active = false
        guard:interrupt("not-p7")
        guard_publish()
        return
    end
    if not mp.get_property_bool("options/android-dovi-dual", false) then
        enhancement_active = false
        guard_publish()
        return
    end
    local passes = mp.get_property_native("vo-passes", {})
    local fel = false
    for _, pass in ipairs(passes.fresh or {}) do
        if (pass.desc or ""):find("enhancement layer", 1, true) then fel = true end
    end
    -- Publish actual composition for the short format badge, including manual
    -- full-EL mode. This does not change the performance guard's decisions.
    enhancement_active = fel
    if guard.mode ~= "auto" or guard.attempted then
        guard_publish()
        return
    end
    local network = mp.get_property_bool("demuxer-via-network")
    local cache = mp.get_property_native("demuxer-cache-state", {})
    local cache_safe = network == false or cache["eof-cached"] == true or
                       (tonumber(cache["cache-duration"]) or 0) >= 3
    local reason = guard:sample({
        eligible=profile() == 7 and fel and
                 mp.get_property_bool("options/android-dovi-dual", false),
        ready=surface_ready() and mp.get_property_bool("vo-configured", false),
        pause=mp.get_property_bool("pause", true),
        seeking=mp.get_property_bool("seeking", true),
        idle=mp.get_property_bool("core-idle", true),
        eof=mp.get_property_bool("eof-reached", true),
        cache_stall=mp.get_property_bool("paused-for-cache", true),
        cache_safe=cache_safe, now=mp.get_time(),
        pos=mp.get_property_number("time-pos"),
        speed=mp.get_property_number("speed"),
        fps=mp.get_property_number("container-fps"),
        refresh=mp.get_property_number("display-fps") or mp.get_property_number("estimated-display-fps") or
                mp.get_property_number("user-data/afuse-display/refresh"),
        vo_drops=mp.get_property_number("frame-drop-count"),
        decoder_drops=mp.get_property_number("decoder-frame-drop-count"),
        decoder=mp.get_property("hwdec-current")
    })
    if reason then
        local ok = switch_dual(false)
        guard:commit(ok)
        if ok then
            apply()
            mp.msg.warn("P7 auto fallback: sustained FEL performance deficit; base layer, resolution/HDR/hwdec retained")
        end
    end
    guard_publish()
end)
mp.register_script_message("set-hwdec", function(value)
    if value == "mediacodec" or value == "mediacodec-copy" or value == "no"
        or value == "mediacodec,mediacodec-copy" then
        apply(value)
    end
end)
mp.register_script_message("set-vo", function(value)
    if value ~= "gpu" and value ~= "gpu-next" then return end
    if preparing then saved_vo = value end
    if mode ~= "original" then
        -- Keep the automatic native/HDR output for the current file. Restore the user's renderer
        -- as soon as the content-specific policy no longer applies.
        if baseline then baseline.vo = value end
        publish(mode, option("android-dovi-yuv") == "yes", option("vo") or "gpu-next")
    else
        if surface_ready() then set("vo", value) end
        publish(mode, false, value)
    end
end)
-- The app owns this option: ordinary files must not inherit a previous P5 bridge.
mp.set_property("android-native-dolby", "no")
mp.set_property("android-native-dolby-hdr", "no")
mp.set_property("android-native-dolby-p7-mel", "no")
mp.set_property("android-native-hdr-p7-base", "no")
mp.set_property("android-native-hdr", "no")
set("android-dovi-yuv", "no")
set("android-dovi-dual", "no")
mp.set_property("android-dovi-mel-fast", "no")
publish(mode, false, option("vo") or "gpu")
