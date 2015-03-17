--[[   \   /        Say It Again - a VLC extension
 _______\_/______
| .------------. |  "Learn a language while watching TV"
| |~           | |
| | tvlang.com | |        for more details visit:
| |            | |  =D.
| '------------' | _   )    http://tvlang.com
|  ###### o o [] |/ `-'
'================'

Features:
 -- Phrases navigation (go to previous, next subtitle) - keys [y], [u]
 -- "Again": go to previous phrase, show subtitle and pause video - key [backspace]

How To Install And Use:
 1. Copy say_it_again.lua (this file) to %ProgramFiles%\VideoLAN\VLC\lua\extensions\ (or /usr/share/vlc/lua/extensions/ for Linux users)
 2. Restart VLC, go to "View" and select "Say It Again" extension there
 3. PROFIT!

License -- MIT:
 Copyright (c) 2013 Vasily Goldobin
 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.

Thanks
 to lubozle (Subtitler, Previous frame) and hector (Dico) and others, whose extensions helped to create this one;

Abbreviations used in code:
 def     definition of a word (= translation)
 dlg     dialog (window)
 idx     index
 pos     part of speech (noun, verb etc)
 osd     on-screen display (text on screen)
 res     result
 str     string
 tbl     table
 tr      transcription of a word

]]--

--[[  Settings  ]]--
local sia_settings =
{
    charset = "iso-8859-1",          -- works for english and french subtitles (try also "Windows-1252")
    always_show_subtitles = false,
    osd_position = "top",
    help_duration = 6, -- sec; change to nil to disable osd help
    log_enable = true, -- Logs can be viewed in the console (Ctrl-M)
    definition_separator = "<br />", -- separator used if multiple definitions are selected for saving

    key_prev_subt = 121, -- y
    key_next_subt = 117, -- u
    key_again = 3538944, -- backspace
    key_save = 105, -- i
}

--[[  Global variables (no midifications beyond this point) ]]--
local g_version = "0.0.8"
local g_ignored_words = {"and", "the", "that", "not", "with", "you"}

local g_conf_path = nil
local g_osd_enabled = false
local g_osd_channel = nil
local g_paused_by_btn_again = false
local g_callbacks_set = false

local g_subtitles = {
    path = nil,
    loaded = false,
    currents = {}, -- indexes of current subtitles

    prev_time = nil, -- start time of previous subtitle
    begin_time = nil, -- start time of current subtitle
    end_time = nil, -- end time of current subtitle
    next_time = nil, -- next subtitle start time

    subtitles = {} -- contains all the subtitles
}

--[[  Functions required by VLC  ]]--

function descriptor()
    return {
        title = "Say It Again",
        version = g_version;
        author = "tv language",
        url = 'http://tvlang.com',
        shortdesc = "Learn a language while watching TV!",
        description = [[<html>
 -- Phrases navigation (go to previous, next subtitle) - keys <b>[y]</b>, <b>[u]</b><br />
 -- Word translation and export to Anki (together with context and transcription) - key <b>[i]</b><br />
 -- "Again": go to previous phrase, show subtitle and pause video - key <b>[backspace]</b><br />
</html>]],
        capabilities = {"input-listener", "menu"}
    }
end

-- extension activated
function activate()
    log("Activate")

    g_conf_path = vlc.config.configdir() .. (is_unix_platform() and "/" or "\\") .. "say_it_again.config.lua"

    if vlc.object.input() then
        local loaded, msg = g_subtitles:load(get_subtitles_path())
        if not loaded then
            return
        end
        g_osd_channel = vlc.osd.channel_register()
        gui_show_osd_help()
        g_osd_enabled = sia_settings.always_show_subtitles
    end

    add_callbacks()
end

-- extension deactivated
function deactivate()
    log("Deactivate")

    del_callbacks()

    -- TODO
    if vlc.object.input() and g_osd_channel then
        vlc.osd.channel_clear(g_osd_channel)
    end
end

-- input changed (playback stopped, file changed)
function input_changed()
    log("Input changed: " .. get_title())
    local loaded, msg = g_subtitles:load(get_subtitles_path())
    if not loaded then
        log(msg)
    end
    if not g_osd_channel then g_osd_channel = vlc.osd.channel_register() end
    change_callbacks()
end

-- a menu element is selected
function trigger_menu(id)

    if id == 1 then
        playback_pause()
        gui_show_dialog_settings()
    elseif id == 2 then
        log("Menu2 clicked")
    end
end


--[[  SIA Functions  ]]--

function sia_settings:load()
    local userconf_f, msg = loadfile(g_conf_path)
    if not userconf_f then
        log("Cant load user config, saving default")
        sia_settings:save()
        return true
    end

    for k, v in pairs(userconf_f()) do self[k] = v end

    return true
end

function g_ignored_words:contains(word)
    for _, w in ipairs(self) do
        if w == word:lower() then
            return true
        end
    end
    return false
end

function g_subtitles:load(spath)
    self.loaded = false

    if is_nil_or_empty(spath) then return false, "cant load subtitles: path is nil" end

    if spath == self.path then
        self.loaded = true
        return false, "cant load subtitles: already loaded"
    end

    self.path = spath

    local data = read_file(self.path)
    if not data then return false end
 
    data = data:gsub("\r\n", "\n") -- fixes issues with Linux
    local srt_pattern = "(%d%d):(%d%d):(%d%d),(%d%d%d) %-%-> (%d%d):(%d%d):(%d%d),(%d%d%d).-\n(.-)\n\n"
    for h1, m1, s1, ms1, h2, m2, s2, ms2, text in string.gmatch(data, srt_pattern) do
        if not is_nil_or_empty(text) then
            if sia_settings.charset then
                text = vlc.strings.from_charset(sia_settings.charset, text)
            end
            table.insert(self.subtitles, {to_sec(h1, m1, s1, ms1), to_sec(h2, m2, s2, ms2), text})
        end
    end

    if #self.subtitles==0 then return false, "cant load subtitles: could not parse" end

    self.loaded = true

    log("loaded subtitles: " .. self.path)

    return true
end

function g_subtitles:get_prev_time(time)
    local epsilon = 0.8 -- sec -- TODO to settings!
    if time < self.begin_time + epsilon or #self.currents == 0 then
        return self.prev_time
    else
        return self.begin_time
    end
end

function g_subtitles:get_next_time(time)
    return self.next_time
end

-- works only if there is current subtitle!
function g_subtitles:get_previous()
    return filter_html(self.currents[1] and
        self.subtitles[self.currents[1]-1] and
        self.subtitles[self.currents[1]-1][3])
end

-- works only if there is current subtitle!
function g_subtitles:get_next()
    return filter_html(self.currents[#self.currents] and
        self.subtitles[self.currents[#self.currents]+1] and
        self.subtitles[self.currents[#self.currents]+1][3])
end

function g_subtitles:get_current()
    if #self.currents == 0 then return nil end

    local subtitle = ""
    for i = 1, #self.currents do
        subtitle = subtitle .. self.subtitles[self.currents[i]][3] .. "\n"
    end

    subtitle = subtitle:sub(1,-2) -- remove trailing \n
    subtitle = filter_html(subtitle)

    return subtitle 
end

-- returns false if time is withing current subtitle
function g_subtitles:move(time)
    if self.begin_time and self.end_time and self.begin_time <= time and time <= self.end_time then
        --log("same title")
        return false, self:get_current(), self.end_time-time
    end
    
    self:_fill_currents(time)

    return true, self:get_current(), self.end_time and self.end_time-time or 0
end

-- private
function g_subtitles:_fill_currents(time)
    self.currents = {} -- there might be several current overlapping subtitles
    self.prev_time = nil
    self.begin_time = nil
    self.end_time = nil
    self.next_time = nil

    local last_checked = 0
    for i = 1, #self.subtitles do
        last_checked = i
        if self.subtitles[i][1] <= time and time <= self.subtitles[i][2] then
            self.prev_time = self.subtitles[i-1] and self.subtitles[i-1][1]
            self.begin_time = self.subtitles[i][1]
            self.end_time = math.min(self.subtitles[i+1] and self.subtitles[i+1][1] or 9999999, self.subtitles[i][2])
            table.insert(self.currents, i)
        end
        if self.subtitles[i][1] > time then
            self.next_time = self.subtitles[i][1]
            break
        end
    end

    -- if there are no current subtitles
    if #self.currents == 0 then
        self.prev_time = self.subtitles[last_checked-1] and self.subtitles[last_checked-1][1]
        self.begin_time = self.subtitles[last_checked-1] and self.subtitles[last_checked-1][2] or 0
        if last_checked < #self.subtitles then
            self.end_time = self.subtitles[last_checked] and self.subtitles[last_checked][1]
        else
            self.end_time = nil -- no end time after the last subtitle
        end
        self.next_time = self.end_time
    end
end

function add_intf_callback()
    if vlc.object.input() then
        vlc.var.add_callback(vlc.object.input(), "intf-event", input_events_handler, 0)
    end
end

function del_intf_callback()
    if vlc.object.input() then
        vlc.var.del_callback(vlc.object.input(), "intf-event", input_events_handler, 0)
    end
end

function add_callbacks()
    if g_callbacks_set then return end
    add_intf_callback()
    vlc.var.add_callback(vlc.object.libvlc(), "key-pressed", key_pressed_handler, 0)
    g_callbacks_set = true
end

function del_callbacks()
    if not g_callbacks_set then return end
    del_intf_callback()
    vlc.var.del_callback(vlc.object.libvlc(), "key-pressed", key_pressed_handler, 0)
    g_callbacks_set = false
end

function change_callbacks()
    if vlc.object.input() then
        vlc.var.add_callback(vlc.object.input(), "intf-event", input_events_handler, 0) -- TODO is it obligatory?
    end
end

function input_events_handler(var, old, new, data)

    -- listen to input events only to show subtitles
    if not g_osd_enabled or not g_subtitles.loaded then return end

    -- get current time
    local input = vlc.object.input()
    local current_time = vlc.var.get(input, "time")

    -- if the video was paused by 'again!' button (backspace by default)
    --  then restore initial g_osd_enabled state
    if g_paused_by_btn_again and vlc.playlist.status() ~= "paused" then
        g_paused_by_btn_again = false
        g_osd_enabled = sia_settings.always_show_subtitles
    end

    local _, subtitle, duration = g_subtitles:move(current_time)

    osd_show(subtitle, duration)
end

function key_pressed_handler(var, old, new, data)
    if new == sia_settings.key_prev_subt then
        goto_prev_subtitle()
    elseif new == sia_settings.key_next_subt then
        goto_next_subtitle()
    elseif new == sia_settings.key_again then
        subtitle_again()
    end
end

function goto_prev_subtitle()
    local input = vlc.object.input()
    if not input then return end

    local curr_time = vlc.var.get(input, "time")

    g_subtitles:move(curr_time)

    playback_goto(input, g_subtitles:get_prev_time(curr_time))
end

function goto_next_subtitle()
    local input = vlc.object.input()
    if not input then return end

    local curr_time = vlc.var.get(input, "time")

    g_subtitles:move(curr_time)

    playback_goto(input, g_subtitles:get_next_time(curr_time))
end

function subtitle_again()
    local input = vlc.object.input()
    if not input then return end

    local current_time = vlc.var.get(input, "time")

    playback_pause()
    g_paused_by_btn_again = true
    g_osd_enabled = true

    g_subtitles:move(current_time)

    playback_goto(input, g_subtitles:get_prev_time(current_time))
end

--[[  User Interface  ]]--

function gui_show_osd_loading()
    vlc.osd.message("SIA LOADING...", vlc.osd.channel_register(), "center")
end

function gui_show_osd_help()
    if not sia_settings.help_duration or sia_settings.help_duration <= 0 then return end

    local duration = sia_settings.help_duration * 1000000

    vlc.osd.message("!!! Press [v] to disable subtitles !!!", vlc.osd.channel_register(), "top", duration/2)
    vlc.osd.message("[y] - previous\n       phrase", vlc.osd.channel_register(), "left", duration)
    vlc.osd.message("[u] - next    \nphrase", vlc.osd.channel_register(), "right", duration)
    vlc.osd.message("[i] - save\n\n[backspace] - again!", vlc.osd.channel_register(), "center", duration)
end

--[[  Utils  ]]--

-- shows osd message in specified [position]
-- if 'subtitle' is nil, then clears osd
function osd_show(subtitle, duration, position)
    duration = math.max(duration, 1) -- to prevent blinking if duration is too small
    if subtitle and duration and duration > 0 then
        vlc.osd.message(subtitle, g_osd_channel, position or sia_settings.osd_position, duration*1000000)
    else
        vlc.osd.message("", g_osd_channel)
    end
end

function log(msg, ...)
    if sia_settings.log_enable then
        vlc.msg.info("[sia] " .. tostring(msg), unpack(arg))
    end
end

function get_input_item()
    return vlc.input.item()
end

-- Returns title or empty string if not available
function get_title()
    local item = get_input_item()
    if not item then return "" end

    local metas = item.metas and item:metas()
    if not metas then return string.match(item:name() or "", "^(.*)%.") or item:name() end

    if metas["title"] then
        return metas["title"]
    else
        return string.match(item:name() or "", "^(.*)%.") or item:name()
    end
end

function uri_to_path(uri, is_unix_platform)
    if is_nil_or_empty(uri) then return "" end
    local path
    if not is_unix_platform then
        if uri:match("file://[^/]") then -- path to windows share
            path = uri:gsub("file://", "\\\\")
        else
            path = uri:gsub("file:///", "")
        end
        return path:gsub("/", "\\")
    else
        return uri:gsub("file://", "")
    end
end

function is_unix_platform()
    if string.match(vlc.config.homedir(), "^/") then
        return true
    else
        return false
    end
end

function get_subtitles_path()
    local item = get_input_item()
    if not item then return "" end

    local path_to_video = uri_to_path(vlc.strings.decode_uri(item:uri()), is_unix_platform())

    return path_to_video:gsub("[^.]*$", "") .. "srt"
end

function filter_html(str)
    local res = str or ""
    res = string.gsub(res, "&apos;", "'")
    res = string.gsub(res, "<.->", "")
    return res
end

function trim(str)
    if not str then return "" end
    return str:match("^%s*(.*%S)") or ""
end

function to_sec(h,m,s,ms)
    return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) + tonumber(ms)/1000
end

function playback_goto(input, time)
    if input and time then
        vlc.var.set(input, "time", time)
    end
end

function playback_pause()
    if vlc.playlist.status() == "playing" then
        vlc.playlist.pause()
    end
end

function read_file(path, binary)
    if is_nil_or_empty(path) then
        log("Can't open file: Path is empty")
        return nil
    end

    local f, msg = io.open(path, "r" .. (binary and "b" or ""))

    if not f then
        log("Can't open file '"..path.."': ".. (msg or "unknown error"))
        return nil
    end

    local res = f:read("*all")

    f:close()

    return res
end

function is_nil_or_empty(str)
    return not str or str == ""
end
