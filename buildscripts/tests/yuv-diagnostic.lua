local utils = require 'mp.utils'
local root = '/data/user/0/is.xyz.mpv.yuvtest/files/'
local records = {}
local function record(event)
    local row = {event = event, wall = mp.get_time()}
    for _, key in ipairs({'time-pos', 'pause', 'paused-for-cache', 'hwdec-current',
                          'current-vo', 'frame-drop-count', 'decoder-frame-drop-count'}) do
        row[key] = mp.get_property_native(key)
    end
    records[#records + 1] = row
    if #records > 120 then table.remove(records, 1) end
    local f = assert(io.open(root .. 'yuv-diagnostic.json', 'w'))
    f:write(utils.format_json(records))
    f:close()
end
record('init')
mp.register_event('file-loaded', function() record('file-loaded') end)
mp.register_event('playback-restart', function() record('playback-restart') end)
mp.add_periodic_timer(1, function() record('tick') end)
