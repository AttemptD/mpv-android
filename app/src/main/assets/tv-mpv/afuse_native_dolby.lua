-- Shared native Dolby/HDR policy. At most one retry per output kind and file.
local M = {}
function M.new(mp)
    local self = {mp=mp, requested=mp.get_property("options/hwdec") or "no",
                  active=false, used=false, failed=false, failures={}, kind="dolby", reason="", manual=false}
    local function flag(name) return mp.get_property_bool("user-data/afuse-native-dolby/" .. name, false) end
    local function publish()
        local actual = self.active and self.presenting or false
        for _, group in ipairs({"output", "dolby", "hdr"}) do
            local selected = group == "output" or (group == "dolby") == (self.kind == "dolby")
            local prefix = "user-data/afuse-native-" .. group .. "/"
            mp.set_property_native(prefix .. "active", actual and selected)
            mp.set_property_native(prefix .. "requested", self.active and selected)
            mp.set_property_native(prefix .. "recoverable", (self.recoverable or false) and selected)
            mp.set_property_native(prefix .. "fallback", group == "output" and self.failed or self.failures[group] or false)
            mp.set_property_native(prefix .. "reason", self.reason)
            mp.set_property_native(prefix .. "kind", self.kind)
            mp.set_property_native(prefix .. "generation", self.generation or 0)
        end
    end
    local function status()
        return mp.get_property_native(self.kind == "dolby" and
            "android-native-dolby-status" or "android-native-hdr-status", {})
    end
    function self:eligible()
        if not flag("surface-ready") then return false end
        local hw = self.requested == "auto" or self.requested == "auto-safe"
        for item in self.requested:gmatch("[^,]+") do if item == "mediacodec" then hw = true end end
        if not hw and not (not self.manual and flag("automatic-decoder")) then return false end
        return #(mp.get_property_native("vf", {})) == 0 and
               #(mp.get_property_native("glsl-shaders", {})) == 0
    end
    function self:request(value)
        if not value then return end
        self.requested, self.manual = value, true
    end
    function self:external_decoder(value)
        if value == self.internal_decoder then return end
        if value and value ~= self.requested then self:request(value) end
    end
    function self:wanted(profile)
        return not self.failures.dolby and (profile == 5 or profile == 8) and
               flag("p" .. profile) and self:eligible()
    end
    function self:wanted_hdr(profile, transfer, compatibility, codec)
        if self.failures.hdr or not self:eligible() then return nil end
        if profile then
            if profile == 7 and compatibility == 6 and
               mp.get_property_bool("user-data/tv-mpv/p7-hdr10-base", false) then transfer = "pq"
            elseif profile ~= 8 then return nil
            elseif compatibility == 1 then transfer = "pq"
            elseif compatibility == 4 then transfer = "hlg"
            else return nil end
        end
        if transfer ~= "pq" and transfer ~= "hlg" then return nil end
        if mp.get_property_bool("user-data/afuse-native-hdr/" .. (codec or "unknown") .. "-" .. transfer, false) then
            return transfer
        end
        return nil
    end
    function self:begin_file()
        self.generation = (self.generation or 0) + 1
        local path = mp.get_property("path")
        local retry = self.reload_pending and path == self.path
        if not retry then
            self.failed, self.reason, self.failures = false, "", {}
        elseif self.remove_entry_id then
            -- The inserted retry is now current. Removing the old entry before
            -- this hook could remove a still-current item and skip to next.
            local current = mp.get_property_number("playlist-pos")
            for i, entry in ipairs(mp.get_property_native("playlist", {})) do
                if entry.id == self.remove_entry_id and i - 1 ~= current then
                    mp.command_native({"playlist-remove", i - 1})
                    break
                end
            end
        end
        self.remove_entry_id = nil
        self.retry_command = nil
        self.reload_pending, self.path = false, path
        self.active, self.used, self.recoverable = false, false, false
        self.presenting = false
        self.last_position = nil
        self.start = mp.get_property("options/start") or "none"
        self.paused = mp.get_property_bool("pause", false)
        publish()
        return retry
    end
    function self:prepare_selection()
        self.aid, self.sid = mp.get_property("aid"), mp.get_property("sid")
        self.vid = mp.get_property("vid")
        if not self.vid or self.vid == "no" then
            -- on_loaded runs before decoder creation. vid may still be no
            -- even though the user's requested track is selected for decoding.
            self.vid = mp.get_property("options/vid", "auto")
        end
        self.playlist_index = mp.get_property_number("playlist-pos")
        local entry = mp.get_property_native("playlist", {})[(self.playlist_index or -1) + 1]
        self.entry_id = entry and entry.id
        self.last_position = mp.get_property_number("time-pos") or self.last_position
        self.paused = mp.get_property_bool("pause", false)
        self.primed = true
    end
    function self:selected(active, kind)
        kind = kind or self.kind
        if active and (not self.active or kind ~= self.kind) then
            self.progress_at, self.frames = mp.get_time(), 0
            if not self.primed then self:prepare_selection() end
        end
        self.active, self.kind = active, kind
        self.primed = false
        if not active then self.presenting = false end
        if active then self.used = true end
        self.recoverable = active or self.reload_pending or false
        publish()
    end
    function self:fail(reason, reload)
        local key = self.kind == "dolby" and "dolby" or "hdr"
        if self.failures[key] or not self.used then return false end
        self.failures[key] = true
        self.failed, self.reason, self.active = true, reason, false
        mp.msg.warn("Native " .. self.kind .. " output fallback: " .. reason)
        if reload and self.path then
            local path = self.path
            local options = {pause=self.paused and "yes" or "no"}
            if self.last_position then options.start = string.format("%.6f", self.last_position)
            elseif self.start ~= "none" then options.start = self.start end
            if self.aid then options.aid = self.aid end
            if self.sid then options.sid = self.sid end
            if self.vid then options.vid = self.vid end
            self.reload_pending = true
            local generation = self.generation
            -- Keep recoverable=true until the retry's on_load hook. Android
            -- receives the old end-file event before those later updates.
            local retry_command = function()
                if self.generation ~= generation then return end
                local index = self.playlist_index
                local playlist = mp.get_property_native("playlist", {})
                if index and index >= 0 and playlist[index + 1] then
                    if self.entry_id and playlist[index + 1].id ~= self.entry_id then return end
                    self.remove_entry_id = playlist[index + 1].id
                    mp.command_native({"loadfile", path, "insert-at", index, options})
                    -- Since mpv 0.42 the loadfile play flag starts only an idle
                    -- player. Explicitly switch from an audio-only failed item.
                    mp.command_native({"playlist-play-index", index})
                else
                    mp.command_native({"loadfile", path, "replace", -1, options})
                end
            end
            self.retry_command = retry_command
            mp.add_timeout(0, function()
                if self.retry_command == retry_command then self:flush_retry() end
            end)
        elseif self.on_fallback then
            self.on_fallback()
        end
        publish()
        return true
    end
    function self:flush_retry()
        local command = self.retry_command
        self.retry_command = nil
        if command then command() end
    end
    function self:check_failure()
        if not self.active then return false end
        local state = status()
        if state["decoder-failed"] then
            return self:fail("decoder-initialization-error", true)
        end
        if state.failed then return self:fail("surface-presentation-error", false) end
        -- A failed decoder can be deselected before Lua observes the old VO.
        -- Before file-loaded, vid still reports the requested auto selection;
        -- afterward it reports no. The missing selected track covers both.
        -- Explicit options/vid=no and Surface loss remain user/lifecycle choices.
        if flag("surface-ready") and self.vid and self.vid ~= "no" and
           mp.get_property("options/vid") ~= "no" and
           not mp.get_property_number("current-tracks/video/id") then
            return self:fail("video-decoder-unavailable", true)
        end
        return false
    end
    function self:end_file(event)
        if event and event.reason == "error" and self.active then
            return self:fail("decoder-or-surface-error", true)
        end
        self.active, self.recoverable = false, self.reload_pending or false
        publish()
        return false
    end
    function self:tick()
        if not self.active then return end
        local pos = mp.get_property_number("time-pos")
        if pos then self.last_position = pos end
        self.paused = mp.get_property_bool("pause", false)
        local state = status()
        if self.presenting ~= (state.active == true) then
            self.presenting = state.active == true
            publish()
        end
        local now = mp.get_time()
        if self:check_failure() then return end
        local frames = tonumber(state.frames) or 0
        if frames ~= self.frames then self.frames, self.progress_at = frames, now end
        if (self.paused and frames > 0) or mp.get_property_bool("seeking", false) or
           mp.get_property_bool("paused-for-cache", false) or
           mp.get_property_bool("eof-reached", false) or not flag("surface-ready") then
            self.progress_at = now
        elseif now - (self.progress_at or now) > 8 then
            self:fail("no-presented-frame", frames == 0)
        end
    end
    mp.add_periodic_timer(0.5, function() self:tick() end)
    return self
end
return M
