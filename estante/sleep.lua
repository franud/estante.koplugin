--[[
Estante sleep screen: a quiet, paper-like page drawn with ASCII ornaments.

   night sky with a cratered moon
   the book you're reading · chapter
   [##########··········] progress, time to the end
   ~.~.~ one of your own highlights ~.~.~
   an ASCII drawing from estante/art/*.txt, a different one every time (shuffle bag)
   date · battery · (-.-) zZ

All drawings are original. Monospace parts use DroidSansMono (bundled with KOReader).
]]
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DocSettings = require("docsettings")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local Library = require("estante/library")
local Stats = require("estante/stats")

local MONO = "DroidSansMono.ttf"
local SERIF = "NotoSerif-Regular.ttf"
local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"
local BLACK = Blitbuffer.COLOR_BLACK
local INK = Blitbuffer.Color8(0x44)
local SOFT = Blitbuffer.Color8(0x77)

local SKY = [[
 *       .           .-""""-.          +        .     *
     .        +    .'  o     '.    .        *         .
          .       /       .-.  \         .       +
  +         *    |    o   '-'   |   *          .
      .           \     ()     /          +   .      *
         *   .     '.        .'     .           .
  .           +      '-....-'           *          +
]]

-- Used only if no art files can be read.
local FALLBACK_SCENE = [[
        /\_/\     z
       ( -.- )  Z
  _____/ > < \__________
 |  __________________  |
 |_|__________________|_|
|  ===  =====  ===  ==  |
|_______________________|
]]

local VINE = "~.~.~.~.~.~.~.~.~  < * >  ~.~.~.~.~.~.~.~.~"

-- Turn a block of ASCII art into a centred, alignment-safe widget.
local function asciiBlock(art, size, color)
    local lines = {}
    for line in (art .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, (line:gsub("%s+$", "")))
    end
    while #lines > 0 and lines[1] == "" do table.remove(lines, 1) end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    -- strip the common indentation
    local indent = math.huge
    for _, l in ipairs(lines) do
        if l ~= "" then indent = math.min(indent, #l:match("^ *")) end
    end
    local face = Font:getFace(MONO, size)
    local widgets, max_w = {}, 0
    for _, l in ipairs(lines) do
        local w = TextWidget:new{ text = l:sub(indent + 1) .. " ", face = face, fgcolor = color or BLACK }
        max_w = math.max(max_w, w:getSize().w)
        table.insert(widgets, w)
    end
    local group = VerticalGroup:new{ align = "left" }
    for _, w in ipairs(widgets) do
        table.insert(group, LeftContainer:new{ dimen = Geom:new{ w = max_w, h = w:getSize().h }, w })
    end
    return group
end

local function asciiBar(percent, cells)
    local filled = math.floor(cells * percent + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep(".", cells - filled) .. "]"
end

local function fmtDuration(secs)
    secs = math.floor(secs or 0)
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h == 0 then return string.format("%d min", math.max(1, m)) end
    return string.format("%d h %02d min", h, m)
end

-- Pick one of the reader's own highlights, preferring a pleasant length.
local function pickHighlight(annotations, seed)
    local good, ok_len = {}, {}
    for _, a in ipairs(annotations or {}) do
        -- only real highlights (bookmarks carry an auto "in <chapter>" text and no drawer)
        local t = a.drawer and a.text and util.cleanupSelectedText(a.text)
        if t and #t >= 25 then
            if #t <= 320 then table.insert(good, { text = t, page = a.pageno or a.page }) end
            table.insert(ok_len, { text = t, page = a.pageno or a.page })
        end
    end
    local pool = #good > 0 and good or ok_len
    if #pool == 0 then return nil end
    return pool[(seed % #pool) + 1]
end

local Sleep = {
    art_dir = nil, -- set by main.lua to <plugin>/estante/art
}

-- Parse every art file: "# title" line, drawing lines, "%%" terminator.
function Sleep.loadArt()
    if Sleep._art then return Sleep._art end
    local files = {}
    if Sleep.art_dir and lfs.attributes(Sleep.art_dir, "mode") == "directory" then
        for f in lfs.dir(Sleep.art_dir) do
            if f:match("%.txt$") then table.insert(files, Sleep.art_dir .. "/" .. f) end
        end
    end
    table.sort(files)
    local user_file = DataStorage:getSettingsDir() .. "/estante-art.txt"
    if lfs.attributes(user_file, "mode") == "file" then table.insert(files, user_file) end

    local pieces = {}
    for _, path in ipairs(files) do
        local fh = io.open(path, "r")
        if fh then
            local base = path:match("([^/]+)$")
            local title, buf = nil, {}
            local function push()
                if #buf >= 3 then
                    local key = base .. ":" .. (title or tostring(#pieces + 1))
                    table.insert(pieces, { key = key, title = title, art = table.concat(buf, "\n") })
                end
                title, buf = nil, {}
            end
            for line in fh:lines() do
                line = line:gsub("\r$", "")
                if line:match("^%%%%%s*$") then
                    push()
                elseif not title and #buf == 0 and line:match("^# ") then
                    title = line:sub(3)
                else
                    table.insert(buf, line)
                end
            end
            push()
            fh:close()
        end
    end
    logger.dbg("Estante sleep: loaded", #pieces, "drawings from", #files, "files")
    Sleep._art = pieces
    return pieces
end

-- Shuffle bag: every drawing once before any repeats; survives restarts.
function Sleep.nextArt()
    local pieces = Sleep.loadArt()
    if #pieces == 0 then return { title = "", art = FALLBACK_SCENE } end
    local by_key = {}
    for _, p in ipairs(pieces) do by_key[p.key] = p end
    local bag = G_reader_settings:readSetting("estante_art_bag") or {}
    while #bag > 0 do
        local key = table.remove(bag, 1)
        if by_key[key] then
            G_reader_settings:saveSetting("estante_art_bag", bag)
            return by_key[key]
        end
    end
    -- refill and shuffle
    bag = {}
    for _, p in ipairs(pieces) do table.insert(bag, p.key) end
    math.randomseed(os.time())
    for i = #bag, 2, -1 do
        local j = math.random(i)
        bag[i], bag[j] = bag[j], bag[i]
    end
    local key = table.remove(bag, 1)
    G_reader_settings:saveSetting("estante_art_bag", bag)
    return by_key[key]
end


-- Gather everything we want to show. Works from the reader or the file manager.
function Sleep.collect(ui)
    local info = {}
    local file = ui and ui.document and ui.document.file or G_reader_settings:readSetting("lastfile")
    if not file or not util.fileExists(file) then return info end
    info.file = file

    local ds = ui and ui.doc_settings
    if not (ds and ui.document) then
        local ok, opened = pcall(DocSettings.open, DocSettings, file)
        ds = ok and opened or nil
    end

    -- title / author
    local props = ui and ui.doc_props
    if props then
        info.title = props.display_title or props.title
        info.authors = props.authors
    end
    if not info.title then
        local BIM = Library.bookInfoManager()
        local bi = BIM and select(2, pcall(BIM.getBookInfo, BIM, file, false))
        if type(bi) == "table" then
            info.title = bi.title
            info.authors = bi.authors
        end
    end
    if not info.title or info.title == "" then
        info.title = file:match("([^/]+)%.[^.]+$") or file
    end
    if info.authors then info.authors = info.authors:gsub("\n", ", ") end

    -- progress
    if ui and ui.document and ui.view and ui.view.state then
        local page = ui.view.state.page
        local total = ui.document:getPageCount()
        if page and total and total > 0 then
            info.page, info.total = page, total
            info.percent = page / total
        end
        if ui.toc and page then
            local ok, t = pcall(ui.toc.getTocTitleByPage, ui.toc, page)
            if ok and t and t ~= "" then info.chapter = t end
        end
    end
    if not info.percent and ds then
        info.percent = ds:readSetting("percent_finished")
        info.total = ds:readSetting("doc_pages")
        if info.percent and info.total then info.page = math.floor(info.percent * info.total + 0.5) end
    end

    local bs = Stats.book(file, info.percent, info.total)
    if bs and bs.secs_left then info.secs_left = bs.secs_left end

    -- a highlight of yours
    local annotations = ui and ui.annotation and ui.annotation.annotations
    if not annotations and ds then annotations = ds:readSetting("annotations") end
    math.randomseed(os.time())
    info.quote = pickHighlight(annotations, math.random(1, 1000000))
    return info
end

function Sleep.build(ui, event_message)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local inner_w = math.floor(W * 0.84)
    local info = Sleep.collect(ui)

    local vg = VerticalGroup:new{ align = "center" }
    local function add(w) table.insert(vg, w) end
    local function gap(px) add(VerticalSpan:new{ width = Screen:scaleBySize(px) }) end

    gap(18)
    add(asciiBlock(SKY, 11, SOFT))
    gap(22)

    if info.title then
        add(TextWidget:new{ text = "~ " .. _("bookmarked for later") .. " ~", face = Font:getFace(MONO, 9), fgcolor = SOFT })
        gap(12)
        add(TextBoxWidget:new{ text = info.title, face = Font:getFace(SERIF_BOLD, 24), width = inner_w,
            alignment = "center", height = Screen:scaleBySize(110), height_adjust = true,
            height_overflow_show_ellipsis = true })
        if info.authors then
            gap(4)
            add(TextWidget:new{ text = info.authors, face = Font:getFace(SERIF_ITALIC, 14), fgcolor = INK, max_width = inner_w })
        end
        if info.chapter then
            gap(8)
            add(TextWidget:new{ text = info.chapter, face = Font:getFace(SERIF, 11), fgcolor = SOFT, max_width = inner_w })
        end
        gap(20)
        if info.percent then
            local pct = math.floor(info.percent * 100 + 0.5)
            add(TextWidget:new{ text = asciiBar(info.percent, 34) .. string.format("  %d%%", pct), face = Font:getFace(MONO, 12) })
            local sub = {}
            if info.page and info.total then table.insert(sub, string.format("p. %d / %d", info.page, info.total)) end
            if info.secs_left then table.insert(sub, string.format(_("about %s to the last page"), fmtDuration(info.secs_left))) end
            if #sub > 0 then
                gap(6)
                add(TextWidget:new{ text = table.concat(sub, "   ·   "), face = Font:getFace(SERIF_ITALIC, 11), fgcolor = INK })
            end
        end
    else
        add(TextWidget:new{ text = _("Nothing open. The shelf is waiting."), face = Font:getFace(SERIF_ITALIC, 18) })
    end

    gap(26)
    add(TextWidget:new{ text = VINE, face = Font:getFace(MONO, 11), fgcolor = SOFT })
    gap(14)
    if info.quote then
        add(TextBoxWidget:new{ text = "\u{201C}" .. info.quote.text .. "\u{201D}", face = Font:getFace(SERIF_ITALIC, 14),
            width = math.floor(inner_w * 0.92), alignment = "center", height = Screen:scaleBySize(150),
            height_adjust = true, height_overflow_show_ellipsis = true })
        gap(8)
        add(TextWidget:new{ text = _("— from your margins") .. (info.quote.page and type(info.quote.page) == "number"
            and string.format(", p. %d", info.quote.page) or ""), face = Font:getFace(SERIF, 10), fgcolor = SOFT })
    else
        add(TextWidget:new{ text = _("No highlights here yet. The margins are patient."), face = Font:getFace(SERIF_ITALIC, 13), fgcolor = INK })
    end
    gap(14)
    add(TextWidget:new{ text = VINE, face = Font:getFace(MONO, 11), fgcolor = SOFT })

    -- the scene fills what's left, pinned above the footer
    local piece = Sleep.nextArt()
    local footer_bits = { (os.date("%A %d %B"):gsub(" 0", " ")) }
    if Device:hasBattery() then
        table.insert(footer_bits, Device:getPowerDevice():getCapacity() .. "%")
    end
    local footer = TextWidget:new{
        text = table.concat(footer_bits, "  ·  ") .. "     " .. (event_message or "(-.-) zZ"),
        face = Font:getFace(MONO, 10), fgcolor = INK }

    local used = vg:getSize().h
    local room = H - used - footer:getSize().h - Screen:scaleBySize(16 + 24 + 20)
    local scene
    for size = 14, 7, -1 do
        if scene then scene:free() end
        scene = asciiBlock(piece.art, size, BLACK)
        local sz = scene:getSize()
        if sz.w <= inner_w and sz.h <= room then break end
    end
    local bottom = VerticalGroup:new{ align = "center", scene, VerticalSpan:new{ width = Screen:scaleBySize(16) }, footer }
    local free = H - used - bottom:getSize().h - Screen:scaleBySize(24)
    if free > 0 then
        -- the drawing floats in the middle of the free space; the footer stays at the bottom
        local half = math.floor(free / 2)
        add(VerticalSpan:new{ width = half })
        add(scene)
        add(VerticalSpan:new{ width = free - half + Screen:scaleBySize(16) })
        add(footer)
    else
        -- not enough room for the scene: keep just the footer
        add(VerticalSpan:new{ width = math.max(0, H - used - footer:getSize().h - Screen:scaleBySize(24)) })
        add(footer)
    end

    vg:resetLayout() -- we measured mid-build; drop the cached offsets
    return FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, vg },
    }
end

return Sleep
