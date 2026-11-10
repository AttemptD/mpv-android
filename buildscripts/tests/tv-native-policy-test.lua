-- Run with Lua 5.2+ from the mpv-android checkout. Exercises the native policy module.
local root = arg[1] or "."
local factory = dofile(root .. "/app/src/main/assets/tv-mpv/afuse_native_dolby.lua")
local count = 0
local function check(value, message)
    assert(value, message); count = count + 1
end
local function fixture()
    local values = {
        ["options/hwdec"]="mediacodec-copy", path="p5.mp4", ["options/start"]="none",
        ["user-data/afuse-native-dolby/p5"]=true, ["user-data/afuse-native-dolby/p8"]=true,
        ["user-data/afuse-native-dolby/surface-ready"]=true,
        ["user-data/afuse-native-dolby/automatic-decoder"]=true,
        vf={}, ["glsl-shaders"]={}, ["android-native-dolby-status"]={frames=0},
        pause=false, vid="1", aid="2", sid="3", ["current-tracks/video/id"]=1
    }
    local now, timers, commands = 0, {}, {}
    local mp = {msg={warn=function() end}}
    function mp.get_property(k, default) local v=values[k]; if v==nil then return default end; return tostring(v) end
    function mp.get_property_bool(k, default) if values[k]==nil then return default end; return values[k] == true end
    function mp.get_property_number(k) return tonumber(values[k]) end
    function mp.get_property_native(k, default) if values[k]==nil then return default end; return values[k] end
    function mp.set_property_native(k,v) values[k]=v end
    function mp.get_time() return now end
    function mp.add_periodic_timer(_, fn) mp.tick=fn end
    function mp.add_timeout(_, fn) timers[#timers+1]=fn end
    function mp.command_native(cmd)
        commands[#commands+1]=cmd
        if cmd[1]=="loadfile" and cmd[3]=="insert-at" and values.playlist then
            table.insert(values.playlist,cmd[4]+1,{id=999,filename=cmd[2]})
        elseif cmd[1]=="playlist-play-index" then
            values["playlist-pos"]=cmd[2]
        elseif cmd[1]=="playlist-remove" and values.playlist then
            table.remove(values.playlist,cmd[2]+1)
        end
    end
    local native=factory.new(mp)
    return {native=native, values=values, commands=commands, advance=function(t) now=now+t;mp.tick() end,
            timers=function() for _,fn in ipairs(timers) do fn() end;timers={} end}
end

local f=fixture()
check(f.native:wanted(5), "automatic HW may use P5 native Dolby")
check(f.native:wanted(8), "declared P8 may use native Dolby")
check(not f.native:wanted(7), "P7/FEL never enters the P5/P8 path")
check(not f.native:wanted(nil), "ordinary video stays on its original renderer")
f.values["user-data/afuse-native-dolby/p5"]=false
check(not f.native:wanted(5), "missing decoder/display capability rejects native P5")
f.values["user-data/afuse-native-dolby/p5"]=true
f.values["user-data/afuse-native-dolby/surface-ready"]=false
check(not f.native:wanted(5), "detached Surface rejects native playback")
f.values["user-data/afuse-native-dolby/surface-ready"]=true
f.values.vf={{name="scale"}}
check(not f.native:wanted(5), "pixel filters retain GPU rendering")
f.values.vf={};f.values["glsl-shaders"]={"anime4k.glsl"}
check(not f.native:wanted(5), "shader users retain GPU rendering")
f.values["glsl-shaders"]={}
f.native:request("mediacodec-copy")
check(not f.native:wanted(5), "manual HW copy overrides automatic native selection")
f.native:request("no")
check(not f.native:wanted(5), "manual software decoding stays software")
f.native:request("mediacodec")
check(f.native:wanted(5), "manual HW+ can return to native Dolby")
f.native.internal_decoder="mediacodec"
f.native:external_decoder("mediacodec")
check(f.native.requested=="mediacodec", "internal decoder updates do not become user overrides")

f=fixture(); f.native:begin_file(); f.native:selected(true)
f.values["time-pos"]=13.75;f.values.pause=true
f.native:tick()
check(f.native:end_file({reason="error"}), "native decoder error schedules recovery")
f.timers()
check(#f.commands==1 and f.commands[1][1]=="loadfile", "exactly one reload is queued")
local options=f.commands[1][5]
check(options.start=="13.750000" and options.pause=="yes", "retry preserves position and pause")
check(options.vid=="1" and options.aid=="2" and options.sid=="3", "retry preserves selected video/audio/subtitle tracks")
f.native:selected(false)
check(f.values["user-data/afuse-native-output/recoverable"], "tearing down the failed output does not expose a premature app error")
f.native:end_file({reason="error"})
check(f.values["user-data/afuse-native-output/recoverable"], "the old end-file remains recoverable until the retry begins")
f.native:begin_file()
check(not f.native:wanted(5), "the retry is latched to the GPU path")
f.native:end_file({reason="error"});f.timers()
check(#f.commands==1, "a failed fallback cannot loop")
f.values.path="next-p5.mp4";f.native:begin_file()
check(f.native:wanted(5), "a new file receives a fresh native attempt")

f=fixture();f.native:begin_file();f.native:selected(true)
local fallbacks=0;f.native.on_fallback=function() fallbacks=fallbacks+1 end
f.values["android-native-dolby-status"]={frames=1,active=true}
f.values.pause=true;f.advance(20)
check(fallbacks==0, "pause never triggers the native watchdog")
f.values.pause=false;f.values["paused-for-cache"]=true;f.advance(20)
check(fallbacks==0, "cache waits never trigger the native watchdog")
f.values["paused-for-cache"]=false;f.values["user-data/afuse-native-dolby/surface-ready"]=false;f.advance(20)
check(fallbacks==0, "background Surface loss never triggers the watchdog")
f.values["user-data/afuse-native-dolby/surface-ready"]=true;f.advance(9)
check(fallbacks==1, "missing presented frames trigger one GPU fallback")
f.advance(20)
check(fallbacks==1, "the watchdog cannot repeatedly restart the player")
f=fixture();f.values["playlist-pos"]=0
f.values.playlist={{id=7,filename="p5.mp4"},{id=8,filename="next.mp4"}}
f.native:begin_file();f.native:selected(true)
f.values["android-native-dolby-status"]={frames=0,["decoder-failed"]=true}
check(f.native:check_failure(), "decoder init failure is caught before the selected track disappears")
f.timers()
check(#f.commands==2 and f.commands[2][1]=="playlist-play-index", "retry explicitly starts while the failed item still has audio")
f.native:begin_file()
check(#f.commands==3 and f.commands[1][3]=="insert-at" and f.commands[3][1]=="playlist-remove", "recovery removes the failed playlist entry after the retry starts")
check(f.commands[1][4]==0 and f.commands[3][2]==1, "the remaining playlist is preserved")
check(#f.values.playlist==2 and f.values.playlist[2].filename=="next.mp4", "retry does not skip to the distinct next file")

f=fixture();f.native:begin_file();f.native:selected(true)
f.values.pause=true;f.advance(9);f.timers()
check(f.native.failed and #f.commands==1, "paused startup without any frame still recovers")

f=fixture();f.native:begin_file();f.native:selected(true)
f.native:end_file({reason="error"})
f.values.path="user-selected-next.mp4";f.native:begin_file();f.timers()
check(#f.commands==0, "a late retry never replaces a newer user selection")

f=fixture();f.native:begin_file();f.native:selected(true)
f.values["android-native-dolby-status"]={}
f.values.vid="no";f.values["options/vid"]="auto"
f.values["current-tracks/video/id"]=nil
check(f.native:check_failure(), "a failed video track is recovered after the old VO has disappeared")
f.timers()
check(f.commands[1][5].vid=="1", "missing-track recovery reselects the original video")
f=fixture();f.native:begin_file();f.native:selected(true)
f.values.vid="no";f.values["options/vid"]="no"
check(not f.native:check_failure(), "explicit user video disable never restarts the file")
f=fixture();f.values["user-data/afuse-native-hdr/hevc-pq"]=true
f.values["user-data/afuse-native-hdr/hevc-hlg"]=true
check(f.native:wanted_hdr(nil,"pq",nil,"hevc")=="pq", "ordinary HDR10 uses a native PQ Surface")
check(f.native:wanted_hdr(nil,"hlg",nil,"hevc")=="hlg", "ordinary HLG uses its native transfer")
check(f.native:wanted_hdr(8,"pq",1,"hevc")=="pq", "P8.1 can use its compatible HDR10 base")
check(f.native:wanted_hdr(8,"pq",4,"hevc")=="hlg", "P8.4 compatibility overrides a Dolby-decoded PQ label")
check(not f.native:wanted_hdr(8,"pq",0,"hevc"), "unknown P8 compatibility is never guessed")
check(not f.native:wanted_hdr(5,"pq",0,"hevc"), "P5 has no ordinary HDR10 base")
check(not f.native:wanted_hdr(7,"pq",6,"hevc"), "P7/FEL never silently drops its enhancement layer")
check(not f.native:wanted_hdr(nil,"bt.1886",nil,"hevc"), "SDR never enters native HDR")
check(not f.native:wanted_hdr(nil,"pq",nil,"h264"), "an unadvertised decoder stays on the GPU path")
f.values["user-data/afuse-native-hdr/hevc-hlg"]=false
check(not f.native:wanted_hdr(8,"hlg",4,"hevc"), "PQ-only displays cannot natively present P8.4 HLG")
f.native:request("mediacodec-copy")
check(not f.native:wanted_hdr(8,"pq",1,"hevc"), "explicit HW copy retains GPU processing for HDR")
f.native:request("no")
check(not f.native:wanted_hdr(nil,"pq",nil,"hevc"), "software decode never claims native HDR")
f.native:request("mediacodec");f.values["glsl-shaders"]={"anime4k.glsl"}
check(not f.native:wanted_hdr(nil,"pq",nil,"hevc"), "HDR shader users retain their GPU path")

f=fixture();f.values["user-data/afuse-native-hdr/hevc-pq"]=true
f.native:begin_file();f.native:selected(true,"dolby")
check(f.native:fail("test-dolby-decoder",true), "Dolby failure may retry a compatible native HDR path")
f.timers();f.native:begin_file()
check(not f.native:wanted(8) and f.native:wanted_hdr(8,"pq",1,"hevc")=="pq", "a failed Dolby route does not disable HDR base fallback")
f.native:selected(true,"pq");f.values["android-native-hdr-status"]={frames=20,active=true}
f.native:tick()
check(f.values["user-data/afuse-native-hdr/active"] and f.values["user-data/afuse-native-output/active"], "actual native HDR is published separately from Dolby")
check(not f.values["user-data/afuse-native-dolby/active"], "native HDR is never reported as native Dolby")
check(f.native:fail("test-hdr-decoder",true), "HDR gets one bounded fallback after Dolby")
f.timers();f.native:begin_file()
check(not f.native:wanted(8) and not f.native:wanted_hdr(8,"pq",1,"hevc"), "failure of both native outputs stays on the GPU path")
f.values.path="next-hdr.mp4";f.native:begin_file()
check(f.native:wanted(8) and f.native:wanted_hdr(8,"pq",1,"hevc")=="pq", "a new file resets both failure latches")
f=fixture();f.native:begin_file();f.native:prepare_selection()
f.values.vid="no";f.values["options/vid"]="auto"
f.values["current-tracks/video/id"]=nil
f.native:selected(true,"pq")
check(f.native:check_failure(), "synchronous output failure retains the pre-transition video selection")
f.timers()
check(f.commands[1][5].vid=="1", "native HDR retry never reloads an audio-only file")
f=fixture();f.values.vid="no";f.values["options/vid"]="auto";f.values["current-tracks/video/id"]=1
f.native:begin_file();f.native:prepare_selection();f.native:selected(true,"dolby")
check(not f.native:check_failure(), "a selected track awaiting decoder creation is not a native failure")
f.values["current-tracks/video/id"]=nil
f.values.vid="auto"
check(f.native:check_failure(), "video-only initialization failure retains the pre-decoder auto selection")
f.native:flush_retry()
f.timers()
check(f.commands[1][5].vid=="auto", "a video-only retry does not inherit the decoder's temporary vid=no")
check(#f.commands==1, "the unload hook starts recovery before auto-next and its late timer cannot repeat it")
f=fixture();f.native:request("mediacodec")
f.values["user-data/afuse-native-hdr/hevc-pq"]=true
check(not f.native:wanted_hdr(7,"pq",6,"hevc"), "P7 HDR10 fallback requires an explicit host policy")
f.values["user-data/tv-mpv/p7-hdr10-base"]=true
check(f.native:wanted_hdr(7,"pq",6,"hevc")=="pq", "P7 CCID 6 may use HDR10 base with explicit host policy")
check(not f.native:wanted_hdr(7,"pq",1,"hevc"), "P7 with unexpected compatibility ID is rejected")
check(not f.native:wanted_hdr(5,"pq",6,"hevc"), "P5 never becomes an HDR10 base layer")
f.values["user-data/afuse-native-hdr/hevc-pq"]=false
f.values["user-data/afuse-native-hdr/hevc-hlg"]=true
check(not f.native:wanted_hdr(7,"hlg",6,"hevc"), "P7 HDR10 base cannot use an HLG-only display")
print("PASS: native Dolby/HDR policy, " .. count .. " assertions")
