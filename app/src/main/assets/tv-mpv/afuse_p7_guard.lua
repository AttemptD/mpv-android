-- Pure decision logic. No device blacklist, MediaCodec query or hwdec writes.
-- Unknown measurements are deliberately NOT evidence of weak hardware.
local M = {}
local State = {}
State.__index = State
local WARMUP, WINDOW, MAX_GAP = 15, 10, 2.5
local function finite(v)
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end
local function counters(s)
    return finite(s.vo_drops) and s.vo_drops >= 0 and
           finite(s.decoder_drops) and s.decoder_drops >= 0
end
function M.new()
    local self = setmetatable({}, State)
    self:reset_file()
    return self
end
function State:interrupt(reason)
    self.start, self.window, self.last, self.bad = nil, nil, nil, 0
    self.phase = self.attempted and (self.fallback and "base" or "switch-failed") or
                 self.mode == "base" and "manual-base" or
                 self.mode == "full" and "manual-full" or reason or "warming"
end
function State:reset_file()
    self.mode, self.fallback, self.attempted = "auto", false, false
    self.reason, self.metrics = nil, nil
    self:interrupt("warming")
end
function State:set_mode(mode)
    assert(mode == "auto" or mode == "full" or mode == "base")
    self:reset_file()
    self.mode = mode
    self.reason = mode == "base" and "manual-base" or nil
    self.phase = mode == "base" and "manual-base" or
                 mode == "full" and "manual-full" or "warming"
end
function State:wants_dual()
    return self.mode ~= "base" and not self.fallback
end
function State:commit(success)
    self.fallback = success == true
    self.phase = success and "base" or "switch-failed"
    if not success then self.reason = "native-switch-failed" end
end
function State:sample(s)
    if self.mode ~= "auto" or self.attempted then return end
    local exclusion
    if not s.eligible then exclusion = "not-fel"
    elseif not s.ready or s.pause or s.seeking or s.idle or s.eof then exclusion = "interrupted"
    elseif s.cache_stall or s.cache_safe ~= true then exclusion = "buffering-or-unknown"
    elseif not finite(s.speed) or math.abs(s.speed - 1) > .01 then exclusion = "speed"
    elseif not finite(s.fps) or s.fps < 1 or s.fps > 240 or not counters(s) or
           not finite(s.now) or not finite(s.pos) or not finite(s.refresh) or
           s.refresh <= 0 then exclusion = "unknown-metrics"
    elseif finite(s.refresh) and s.refresh > 0 and s.fps > s.refresh * 1.03 then
        exclusion = "refresh-limited"
    end
    if exclusion then self:interrupt(exclusion); return end
    if self.last then
        local dt, dp = s.now - self.last.now, s.pos - self.last.pos
        if dt <= 0 or dt > MAX_GAP or dp < -.05 or dp > dt * 1.5 + .25 or
           s.vo_drops < self.last.vo_drops or s.decoder_drops < self.last.decoder_drops or
           math.abs(s.fps - self.last.fps) > self.last.fps * .1 or
           math.abs(s.refresh - self.last.refresh) > .5 or
           s.decoder ~= self.last.decoder then
            self:interrupt("discontinuity")
        end
    end
    self.last = s
    if not self.start then self.start = s.now end
    if s.now - self.start < WARMUP then self.phase = "warming"; return end
    self.phase = "measuring"
    if not self.window then self.window = s; return end
    local elapsed = s.now - self.window.now
    if elapsed < WINDOW then return end
    -- Decoder/VO counts can describe the same lost frame. Never add them.
    local lost = math.max(s.vo_drops - self.window.vo_drops,
                          s.decoder_drops - self.window.decoder_drops)
    local drop = lost / (elapsed * s.fps)
    local progress = (s.pos - self.window.pos) / elapsed
    -- A clock shortage alone could be an unusual stream. Require dropped
    -- frames too; audio-clock playback can instead prove severe sustained loss.
    local bad = (drop >= .18 and progress < .85) or drop >= .35
    self.bad = bad and self.bad + 1 or 0
    self.metrics = {dropRatio=drop, progress=progress, seconds=elapsed,
                    dropped=lost, consecutive=self.bad}
    self.window = s
    if self.bad >= 2 then
        self.attempted, self.reason = true, "sustained-fel-performance"
        return self.reason
    end
end
return M
