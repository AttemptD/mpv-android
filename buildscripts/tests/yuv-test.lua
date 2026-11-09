local utils = require 'mp.utils'
local root = '/data/user/0/is.xyz.mpv.yuvtest/files/'
local function capture()
    local props = {}
    for _, key in ipairs({'hwdec-current', 'current-vo', 'video-params',
                          'video-out-params', 'decoder-frame-drop-count',
                          'frame-drop-count', 'time-pos', 'vo-passes'}) do
        props[key] = mp.get_property_native(key)
    end
    local file = assert(io.open(root .. 'yuv-properties.json', 'w'))
    file:write(utils.format_json(props))
    file:close()
    mp.commandv('screenshot-to-file', root .. 'yuv-frame.png', 'video')
end
mp.register_event('file-loaded', function() mp.add_timeout(4, capture) end)
