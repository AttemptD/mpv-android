-- Autoloaded only by run-tv-benchmark.py in the independent TV debug package.
local utils = require 'mp.utils'
local options = {duration=20, lifecycle=false, force_dolby=false}
require('mp.options').read_options(options, 'tv-benchmark')
local samples, started, completed, checks = {}, nil, false, {}
local wall_started = mp.get_time()
local report = mp.command_native({'expand-path', '~~/tv-benchmark.json'})
mp.msg.info('TV benchmark loaded; report=' .. report)
if options.force_dolby then
    -- Diagnostic only: exercise the decoder even when the HDMI display does
    -- not advertise Dolby. This never changes production capability detection.
    mp.add_hook('on_loaded', 10, function()
        mp.set_property_native('user-data/afuse-native-dolby/p5', true)
        mp.set_property_native('user-data/afuse-native-dolby/p8', true)
    end)
end
local function snapshot()
    local sample = {wall=mp.get_time()}
    for _, key in ipairs({'time-pos', 'pause', 'seeking', 'paused-for-cache',
        'hwdec-current', 'current-vo', 'container-fps', 'display-fps',
        'frame-drop-count', 'decoder-frame-drop-count', 'avsync',
        'demuxer-cache-duration', 'demuxer-cache-state', 'video-params',
        'audio-params', 'audio-out-params', 'android-native-hdr-status',
        'android-native-dolby-status', 'user-data/afuse-p5',
        'user-data/afuse-native-output', 'user-data/afuse-p7'}) do
        sample[key] = mp.get_property_native(key)
    end
    return sample
end
local function save(reason)
    if completed then return end
    completed = true
    local result = {reason=reason, samples=samples, checks=checks}
    local f = assert(io.open(report .. '.tmp', 'w'))
    f:write(utils.format_json(result)); f:close()
    assert(os.rename(report .. '.tmp', report))
    mp.set_property_native('pause', true)
end
local function native_state()
    local hdr = mp.get_property_native('android-native-hdr-status', {})
    if hdr.active then return hdr end
    return mp.get_property_native('android-native-dolby-status', {})
end
mp.add_periodic_timer(1, function()
    if completed then return end
    local sample = snapshot()
    if not started and (sample['time-pos'] or 0) >= 2 then started = sample.wall end
    if #samples < 180 then samples[#samples + 1] = sample end
    local partial = io.open(report .. '.partial.tmp', 'w')
    if partial then
        partial:write(utils.format_json({samples=samples})); partial:close()
        os.rename(report .. '.partial.tmp', report .. '.partial')
    end
    if started and sample.wall - started >= options.duration then save('duration')
    elseif not started and sample.wall - wall_started >= options.duration + 3 then save('stalled-before-2s') end
end)
mp.register_event('end-file', function(event)
    if not completed then samples[#samples + 1] = snapshot(); save(event.reason) end
end)
-- These exercise the actual player clock and caption layer, including redraw
-- while paused. run-tv-benchmark.py supplies a long, visible ASS subtitle.
if options.lifecycle then
    mp.register_event('file-loaded', function()
        mp.add_timeout(4, function()
            mp.set_property_native('pause', true)
            mp.commandv('seek', 3, 'absolute+exact')
        end)
        mp.add_timeout(7, function()
            checks['paused-seek'] = mp.get_property_bool('pause', false) and
                math.abs(mp.get_property_number('time-pos', -99) - 3) < 0.2 and
                not mp.get_property_bool('seeking', true)
            local state = native_state()
            checks.frames = state.frames
            checks.osd = state['osd-updates']
            mp.set_property_native('sub-visibility', false)
        end)
        mp.add_timeout(9, function()
            local state = native_state()
            checks['paused-caption-redraw'] = state.frames == checks.frames and
                (state['osd-updates'] or 0) > (checks.osd or 0)
            mp.set_property_native('sub-visibility', true)
            mp.set_property_native('pause', false)
        end)
        mp.add_timeout(12, function()
            checks['resume-clock'] = mp.get_property_number('time-pos', 0) > 5
        end)
        mp.add_timeout(13, function()
            mp.set_property_native('pause', true)
            mp.commandv('seek', 10, 'absolute+exact')
        end)
        mp.add_timeout(16, function()
            checks['paused-seek-forward'] = mp.get_property_bool('pause', false) and
                math.abs(mp.get_property_number('time-pos', -99) - 10) < 0.2 and
                not mp.get_property_bool('seeking', true)
            mp.commandv('seek', 2, 'absolute+exact')
        end)
        mp.add_timeout(20, function()
            checks['paused-seek-backward'] = mp.get_property_bool('pause', false) and
                math.abs(mp.get_property_number('time-pos', -99) - 2) < 0.2 and
                not mp.get_property_bool('seeking', true)
            mp.set_property_native('pause', false)
        end)
    end)
end
