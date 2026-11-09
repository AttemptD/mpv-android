local utils = require 'mp.utils'
local root = '/data/user/0/is.xyz.mpv.yuvtest/files/'
local started, finished
local function snapshot()
    local data = {wall = mp.get_time()}
    for _, key in ipairs({'hwdec-current', 'current-vo', 'time-pos',
                          'decoder-frame-drop-count', 'frame-drop-count',
                          'video-params'}) do
        data[key] = mp.get_property_native(key)
    end
    return data
end
mp.add_periodic_timer(0.2, function()
    if finished then return end
    local pos = mp.get_property_number('time-pos', 0)
    if pos >= 3 and not started then started = snapshot() end
    if pos >= 20 and started then
        finished = true
        local data = {start = started, finish = snapshot()}
        local f = assert(io.open(root .. 'yuv-benchmark.json', 'w'))
        f:write(utils.format_json(data))
        f:close()
        mp.set_property_native('pause', true)
    end
end)
