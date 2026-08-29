-- media-card.lua — 资料卡
-- 本地技术规格 + 格式徽章（复用 startup-format-logos 的识别思路）
-- CTRL+ALT+i 开/关卡片；CTRL+ALT+S 公开分享；CTRL+ALT+SHIFT+S 私有分享
-- 分享 = 脱敏 JSON + 用 ffmpeg 把 ASS 卡片渲染成 PNG（内嵌当前画面截图）
--         再经 gh CLI 提交：公开 → emoeem/cards（上墙）+ mpv-cards（全量存档）
--                        私有 → 仅 mpv-cards（private，只有你能看）
-- 依赖：mpv、ffmpeg、gh（已登录）

local msg = require 'mp.msg'
local opts = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    repo_cards = "emoeem/mpv-cards",   -- 私有全量卡片仓库
    repo_site = "emoeem/cards",        -- 公开画廊仓库（Pages: emoeem.github.io/cards/）
    outbox = "~~/media-cards",         -- 本地产物目录（JSON/PNG 都会留底）
    ffmpeg = "ffmpeg",                 -- ffmpeg 可执行文件（用你的 ffmpeg-full）
    font = "Sans",                     -- 卡片字体（libass 会做 CJK 回退）
    auto_show = "no",                  -- 加载文件时自动显示卡片
}
opts.read_options(o)

-- Catppuccin Mocha
local C = {
    text = "cdd6f4", subtext = "a6adc8", muted = "6c7086",
    base = "1e1e2e", surface = "313244",
    mauve = "cba6f7", blue = "89b4fa", green = "a6e3a1",
    yellow = "f9e2af", red = "f38ba8", teal = "94e2d5", peach = "fab387",
}

local osd = nil
local shown = false
local refresh = nil

-- ---------------------------------------------------------------- utilities

local function expand(path)
    return mp.command_native({ "expand-path", path })
end

local function subprocess(args, capture)
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = capture and true or false,
        args = args,
    })
    return res
end

local function basename(s)
    return (s or ""):match("([^/\\]+)$") or (s or "")
end

-- 脱敏：去路径、去 URL 主机与查询串，卡片 JSON 里不该出现本地痕迹
local function sanitize_title(s)
    s = s or ""
    s = s:gsub("^%w+://[^/]+/", "")
    s = s:gsub("%?.*$", "")
    return basename(s)
end

local function slug(data)
    local seed = tostring(data.title) .. tostring(data.generated_at)
    local h = 5381
    for i = 1, #seed do
        h = (h * 33 + seed:byte(i)) % 4294967296
    end
    return os.date("%Y%m%d-%H%M%S") .. "-" .. string.format("%08x", h)
end

local function json_encode(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        return tostring(math.floor(v) == v and math.floor(v) or v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', {
            ['"'] = '\\"', ['\\'] = '\\\\',
            ['\n'] = '\\n', ['\t'] = '\\t', ['\r'] = '\\r',
        }) .. '"'
    elseif t == "table" then
        local n, is_array = 0, true
        for k in pairs(v) do
            n = n + 1
            if k ~= n then is_array = false end
        end
        local parts = {}
        if is_array then
            for _, x in ipairs(v) do parts[#parts + 1] = json_encode(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, x in pairs(v) do
                parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(x)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- ------------------------------------------------------------ data collect

local VIDEO_BADGES = {
    { key = "dolby-vision", label = "杜比视界", color = C.mauve },
    { key = "hdr-vivid", label = "HDR Vivid", color = C.red },
    { key = "hdr10-plus", label = "HDR10+", color = C.teal },
    { key = "hdr10", label = "HDR10", color = C.blue },
    { key = "hlg", label = "HLG", color = C.green },
}

local AUDIO_BADGES = {
    { key = "dolby-atmos", label = "Atmos", color = C.blue },
    { key = "dts-x", label = "DTS:X", color = C.peach },
    { key = "audio-vivid", label = "Audio Vivid", color = C.yellow },
    { key = "dolby-truehd", label = "TrueHD", color = C.mauve },
    { key = "dts-hd", label = "DTS-HD", color = C.peach },
}

local VIDEO_CODEC_NAMES = {
    h264 = "H.264/AVC", hevc = "H.265/HEVC", av01 = "AV1", av1 = "AV1",
    vp9 = "VP9", vp8 = "VP8", vvc = "H.266/VVC", mpeg2video = "MPEG-2",
    mpeg4 = "MPEG-4", mjpeg = "MJPEG", flv1 = "Sorenson H.263",
    vc1 = "VC-1", prores = "Apple ProRes", png = "PNG", ffv1 = "FFV1",
    libsvt_hevc = "HEVC (SVT)", libx264 = "H.264 (x264)",
}

local AUDIO_CODEC_NAMES = {
    truehd = "Dolby TrueHD", eac3 = "E-AC-3", ac3 = "AC-3", dts = "DTS",
    ["dts-hd"] = "DTS-HD", flac = "FLAC", alac = "ALAC", opus = "Opus",
    vorbis = "Vorbis", mp3 = "MP3", aac = "AAC", pcm = "PCM",
    mpegh = "Audio Vivid/AV3A", apcm = "Audio Vivid/AV3A",
    wmapro = "WMA Pro", wmav2 = "WMA", amr_nb = "AMR-NB",
}

local function selected_track(kind)
    local tracks = mp.get_property_native("track-list") or {}
    for _, t in ipairs(tracks) do
        if t.type == kind and t.selected then
            return t
        end
    end
    return nil
end

local function video_badges(track)
    local badges = {}
    if not track then return badges end

    local gamma = (mp.get_property("video-params/gamma") or ""):lower()
    local dv = tonumber(track["dolby-vision-profile"])
        or tonumber(mp.get_property("video-params/dolby-vision-profile"))
    local tagline = ((track.title or "") .. " " .. (track["codec-desc"] or "") .. " " .. (mp.get_property("video-format") or "")):lower()

    if dv then
        badges[#badges + 1] = "dolby-vision"
    elseif tagline:find("dolby.?vision") or tagline:find("dovi") then
        badges[#badges + 1] = "dolby-vision"
    end
    if tagline:find("hdr.?vivid") or tagline:find("hivivid") then
        badges[#badges + 1] = "hdr-vivid"
    end
    if tagline:find("hdr10plus") or tagline:find("hdr10%-plus") then
        badges[#badges + 1] = "hdr10-plus"
    end
    if gamma == "pq" and not badges[1] then
        badges[#badges + 1] = "hdr10"
    end
    if gamma == "hlg" then
        badges[#badges + 1] = "hlg"
    end
    return badges
end

local function audio_badges(track)
    local badges = {}
    if not track then return badges end
    local codec = (mp.get_property("audio-codec-name") or track.codec or ""):lower()
    local title = ((track.title or "") .. " " .. (track["codec-desc"] or "")):lower()

    if title:find("atmos") then badges[#badges + 1] = "dolby-atmos" end
    if title:find("dts:?x") then badges[#badges + 1] = "dts-x" end
    if codec:find("mpegh") or codec:find("apcm") or title:find("audio.?vivid") or title:find("av3a") then
        badges[#badges + 1] = "audio-vivid"
    end
    if codec:find("truehd") then badges[#badges + 1] = "dolby-truehd" end
    if codec:find("dts") then badges[#badges + 1] = "dts-hd" end
    return badges
end

local function badge_labels(keys, table_ref)
    local out = {}
    for _, b in ipairs(table_ref) do
        for _, k in ipairs(keys) do
            if b.key == k then
                out[#out + 1] = { label = b.label, color = b.color }
            end
        end
    end
    return out
end

local function collect()
    local vtrack = selected_track("video")
    local atrack = selected_track("audio")

    local vp = mp.get_property_native("video-params") or {}
    local ap = mp.get_property_native("audio-params") or {}

    local codec_raw = mp.get_property("video-format") or (vtrack and vtrack.codec) or ""
    local acodec_raw = (mp.get_property("audio-codec-name") or (atrack and atrack.codec) or ""):lower()

    local fps = mp.get_property("container-fps") or mp.get_property("estimated-vf-fps")
    local chapters = mp.get_property_native("chapter-list") or {}
    local subs = 0
    local tracks = mp.get_property_native("track-list") or {}
    for _, t in ipairs(tracks) do
        if t.type == "sub" then subs = subs + 1 end
    end

    local cache = mp.get_property("demuxer-cache-duration")

    return {
        schema = 1,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title = sanitize_title(mp.get_property("media-title") or mp.get_property("filename")),
        badges = {
            video = video_badges(vtrack),
            audio = audio_badges(atrack),
        },
        video = {
            codec = VIDEO_CODEC_NAMES[(codec_raw:lower()):gsub("^v_", "")] or codec_raw,
            codec_raw = codec_raw,
            width = vp.width,
            height = vp.height,
            pixelformat = vp.pixelformat,
            fps = fps and tonumber(fps) or nil,
            bitrate_kbps = mp.get_property("video-bitrate")
                and math.floor(mp.get_property("video-bitrate") / 1000) or nil,
            colorspace = vp.colorspace,
            gamma = vp.gamma,
            primaries = vp.primaries,
            hwdec = mp.get_property("hwdec-current") ~= "no" and mp.get_property("hwdec-current") or nil,
        },
        audio = {
            codec = AUDIO_CODEC_NAMES[acodec_raw] or acodec_raw,
            codec_raw = acodec_raw,
            channels = ap["channel-count"],
            layout = ap["hr-channels"] or ap.channels,
            samplerate = ap.samplerate and (ap.samplerate / 1000) or nil,
        },
        file = {
            container = mp.get_property("file-format"),
            size_bytes = mp.get_property("file-size")
                and tonumber(mp.get_property("file-size")) or nil,
            chapters = #chapters > 0 and #chapters or nil,
            subtitle_tracks = subs > 0 and subs or nil,
        },
        playback = {
            position_pct = mp.get_property("percent-pos")
                and math.floor(mp.get_property("percent-pos") * 10) / 10 or nil,
            speed = mp.get_property("speed"),
            vo = mp.get_property("current-vo"),
            cache_seconds = cache and math.floor(tonumber(cache)) or nil,
        },
    }
end

-- ------------------------------------------------------------------- render

local function esc(s)
    return (s or ""):gsub("\\", "\\\\")
end

-- ASS 颜色是 &HBBGGRR，这里把 RRGGFF 转 &HBBGGRR&
local function ass_color(hex)
    return "&H" .. hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2) .. "&"
end

local function chips(badges)
    local out = {}
    for _, b in ipairs(badges) do
        out[#out + 1] = ("{\\c%s}【%s】{\\c%s}"):format(
            ass_color(b.color), b.label, ass_color(C.text))
    end
    return table.concat(out)
end

local function fmt_value(v, suffix)
    if v == nil then return "—" end
    return tostring(v) .. (suffix or "")
end

local function card_lines(d)
    local v, a, f, p = d.video, d.audio, d.file, d.playback
    local lines = {}
    lines[#lines + 1] = { style = "title", text = d.title or "未命名" }

    local vb = badge_labels(d.badges.video, VIDEO_BADGES)
    local ab = badge_labels(d.badges.audio, AUDIO_BADGES)
    if #vb > 0 or #ab > 0 then
        local chips_text = chips(vb)
        if #vb > 0 and #ab > 0 then chips_text = chips_text .. "  " end
        chips_text = chips_text .. chips(ab)
        lines[#lines + 1] = { style = "badges", text = chips_text }
    end

    local res = (v.width and v.height) and (v.width .. "×" .. v.height) or "—"
    lines[#lines + 1] = {
        style = "spec",
        text = table.concat({
            "视频 " .. res,
            (v.codec or "—"),
            (v.pixelformat or "—"),
            fmt_value(v.fps and math.floor(v.fps * 100) / 100 or nil, " fps"),
            v.bitrate_kbps and (v.bitrate_kbps .. " kbps") or "—",
        }, "  ·  "),
    }
    lines[#lines + 1] = {
        style = "spec",
        text = table.concat({
            "音频 " .. (a.codec or "—"),
            fmt_value(a.layout, ""),
            fmt_value(a.channels, " ch"),
            a.samplerate and (a.samplerate .. " kHz") or "—",
        }, "  ·  "),
    }
    lines[#lines + 1] = {
        style = "spec",
        text = table.concat({
            "文件 " .. (f.container or "—"),
            f.size_bytes and string.format("%.2f GiB", f.size_bytes / 1073741824) or "—",
            f.chapters and (f.chapters .. " 章节") or nil,
            f.subtitle_tracks and (f.subtitle_tracks .. " 字幕轨") or nil,
        }, "  ·  "),
    }
    lines[#lines + 1] = {
        style = "muted",
        text = table.concat({
            "播放 " .. (p.position_pct and (p.position_pct .. "%") or "—"),
            (p.vo or "—"),
            (p.hwdec and ("硬解 " .. p.hwdec) or "软解"),
            p.speed and (p.speed .. "×") or nil,
            p.cache_seconds and ("缓冲 " .. p.cache_seconds .. "s") or nil,
        }, "  ·  "),
    }
    return lines
end

local STYLES = {
    title = { size = 46, color = C.text, bold = true },
    badges = { size = 34, color = C.text, bold = false },
    spec = { size = 30, color = C.subtext, bold = false },
    muted = { size = 26, color = C.muted, bold = false },
}

local function build_ass(d, w, h, top)
    local header = table.concat({
        "[Script Info]",
        "ScriptType: v4.00+",
        ("PlayResX: %d"):format(w),
        ("PlayResY: %d"):format(h),
        "WrapStyle: 2",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, BorderStyle",
    }, "\n")

    local styles = {}
    for name, s in pairs(STYLES) do
        styles[#styles + 1] = ("Style: %s,%s,%d,%s,%d,2,1,5,40,40,%d,1"):format(
            name, o.font, s.size, ass_color(s.color),
            s.bold and 1 or 0, math.floor(h * 0.04))
    end

    local events = { "", "[Events]", "Format: Layer, Start, End, Style, Text" }
    local y = top
    for _, line in ipairs(card_lines(d)) do
        local s = STYLES[line.style]
        events[#events + 1] = ("Dialogue: 0,0:00:00.00,0:00:10.00,%s,,0,0,0,,{\\an7\\pos(%d,%d)%s}%s"):format(
            line.style, 44, y, s.bold and "\\b1" or "", line.text)
        y = y + s.size * 1.6
    end

    return header .. "\n" .. table.concat(styles, "\n") .. "\n" .. table.concat(events, "\n")
end

local function show_osd(d)
    if not osd then
        osd = mp.create_osd_overlay("ass-events")
        osd.res_x = 1280
        osd.res_y = 720
    end
    osd.data = build_ass(d, 1280, 720, 90)
    osd:update()
end

-- -------------------------------------------------------------------- share

local function outbox_dir()
    local dir = expand(o.outbox)
    subprocess({ "mkdir", "-p", dir })
    return dir
end

local function render_png(d, frame_path, out_path)
    local ass_path = out_path:gsub("%.png$", ".ass")
    local f = io.open(ass_path, "w")
    if not f then
        msg.error("无法写入 " .. ass_path)
        return false
    end
    -- ASS 颜色 &HBBGGRR：libass 的 ass 滤镜读取时直接写正确格式
    f:write(build_ass(d, 1280, 820, 490))
    f:close()

    local res = subprocess({
        o.ffmpeg, "-y", "-loglevel", "error",
        "-i", frame_path,
        "-f", "lavfi", "-i", "color=c=0x" .. C.base .. ":s=1280x820",
        "-filter_complex",
        ("[0:v]scale=1280:-2:force_original_aspect_ratio=increase,crop=1280:460,setsar=1[shot];"
            .. "[1:v][shot]overlay=0:0[base];[base]ass='" .. ass_path .. "'[out]"),
        "-map", "[out]", "-frames:v", "1", out_path,
    })
    if res and res.status == 0 then
        return true
    end
    msg.error("ffmpeg 渲染失败: " .. ((res and res.stderr) or "unknown"))
    return false
end

local function gh_put(repo, path, file)
    local b64 = subprocess({ "base64", "-w0", file }, true)
    if not b64 or b64.status ~= 0 or not b64.stdout or b64.stdout == "" then
        msg.error("base64 编码失败")
        return false
    end
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "gh", "api", "-X", "PUT",
            ("repos/%s/contents/%s"):format(repo, path),
            "-f", ("message=%s"):format(("card: %s"):format(basename(path))),
            "-f", ("content=%s"):format(b64.stdout:gsub("%s", "")) },
    })
    if not res or res.status ~= 0 then
        msg.error("gh 提交失败: " .. ((res and res.stderr) or "unknown"))
        return false
    end
    return true
end

local function share(visibility)
    local d = collect()
    local id = slug(d)
    d.visibility = visibility
    local dir = outbox_dir()
    local json_path = dir .. "/" .. id .. ".json"

    local f = io.open(json_path, "w")
    if not f then
        mp.osd_message("资料卡：无法写入 JSON", 2)
        return
    end
    f:write(json_encode(d))
    f:close()

    mp.osd_message("资料卡：正在截图…", 3)
    local frame_path = dir .. "/" .. id .. "-frame.png"
    mp.commandv("screenshot-to-file", frame_path, "video")

    mp.osd_message("资料卡：正在渲染卡片…", 3)
    local png_path = dir .. "/" .. id .. ".png"
    if not render_png(d, frame_path, png_path) then
        mp.osd_message("资料卡：渲染失败（看终端日志）", 3)
        return
    end

    mp.osd_message("资料卡：正在提交…", 3)
    local ok = gh_put(o.repo_cards, "cards/" .. id .. ".json", json_path)
        and gh_put(o.repo_cards, "cards/" .. id .. ".png", png_path)
    if ok and visibility == "public" then
        ok = gh_put(o.repo_site, "cards/data/" .. id .. ".json", json_path)
            and gh_put(o.repo_site, "cards/data/" .. id .. ".png", png_path)
    end

    if ok then
        mp.osd_message(("资料卡：已%s提交（%s）"):format(
            visibility == "public" and "公开" or "私有", id), 4)
    else
        mp.osd_message("资料卡：提交失败（看终端日志），本地已留底 " .. dir, 5)
    end
end

-- ------------------------------------------------------------------ control

local function toggle()
    shown = not shown
    if shown then
        show_osd(collect())
        refresh = mp.add_periodic_timer(2, function()
            if shown then show_osd(collect()) end
        end)
    else
        if refresh then refresh:kill() refresh = nil end
        if osd then osd:remove() end
    end
end

mp.add_key_binding(nil, "toggle", toggle)
mp.add_key_binding(nil, "share-public", function() share("public") end)
mp.add_key_binding(nil, "share-private", function() share("private") end)

mp.register_event("file-loaded", function()
    if o.auto_show == "yes" then
        shown = true
        show_osd(collect())
        refresh = mp.add_periodic_timer(2, function()
            if shown then show_osd(collect()) end
        end)
    end
end)
