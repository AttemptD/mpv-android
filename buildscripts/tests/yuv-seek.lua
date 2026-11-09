local utils = require 'mp.utils'
local root = '/data/user/0/is.xyz.mpv.yuvtest/files/'
local events = {}
local function record(name)
    events[#events + 1] = {event = name, time = mp.get_property_number('time-pos'),
                           hwdec = mp.get_property('hwdec-current')}
    local f = assert(io.open(root .. 'yuv-seek.json', 'w'))
    f:write(utils.format_json(events))
    f:close()
end
mp.register_event('playback-restart', function() record('playback-restart') end)
mp.register_event('file-loaded', function()
    mp.add_timeout(3, function() mp.commandv('seek', '12', 'absolute+exact') end)
    mp.add_timeout(6, function() mp.commandv('seek', '2', 'absolute+exact') end)
    mp.add_timeout(9, function() mp.set_property_native('pause', true); record('paused') end)
    mp.add_timeout(10, function() mp.set_property_native('pause', false); record('resumed') end)
    mp.add_timeout(13, function() record('complete'); mp.set_property_native('pause', true) end)
end)
