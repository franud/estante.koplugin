--[[
Estante home: a full-screen "reading desk" shown on top of the FileManager.

  ┌ header: weekday · date ··················· time · battery ┐
  │ tabs:   Desk  All  Reading  Unread  Finished                │
  │ Desk  → now-reading card + "Continue" row + "New on the shelf" row
  │ other → paginated cover wall (swipe ← →)                     │
  └ dock:   Files  Search  History  Z-library  [Web]  Menu       ┘
]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Library = require("estante/library")
local Stats = require("estante/stats")
local Tile = require("estante/tile")

local SERIF = "NotoSerif-Regular.ttf"
local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"
local SANS = "NotoSans-Regular.ttf"
local SANS_BOLD = "NotoSans-Bold.ttf"

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, LIGHT = Blitbuffer.Color8(0x44), Blitbuffer.Color8(0x99)

-- A tappable region wrapping any widget.
local Tappable = InputContainer:extend{ on_tap = nil, on_hold = nil }
function Tappable:init()
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }
    self.ges_events = {
        TapIt = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldIt = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end
function Tappable:onTapIt() if self.on_tap then self.on_tap() return true end end
function Tappable:onHoldIt() if self.on_hold then self.on_hold() return true end end

local function hline(w, thick, color)
    return LineWidget:new{ dimen = Geom:new{ w = w, h = thick or Screen:scaleBySize(1) }, background = color or BLACK }
end

local function text(str, face, size, opts)
    opts = opts or {}
    return TextWidget:new{ text = str, face = Font:getFace(face, size), bold = opts.bold,
        fgcolor = opts.color or BLACK, max_width = opts.max_width }
end

local function fmtDuration(secs)
    secs = math.floor(secs or 0)
    if secs < 60 then return "< 1 min" end
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h == 0 then return string.format("%d min", m) end
    if m == 0 then return string.format("%d h", h) end
    return string.format("%d h %02d min", h, m)
end

local Home = InputContainer:extend{
    name = "estante_home",
    covers_fullscreen = true,
    ui = nil,          -- FileManager instance
    plugin = nil,
    view = nil,        -- { kind = "desk"|"all"|"reading"|"unread"|"finished" }
    page = 1,
}

function Home:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.pad = math.floor(self.W * 0.04)
    self.inner_w = self.W - 2 * self.pad
    self.view = self.view or { kind = "desk" }
    self.page = 1
    self.ges_events = {
        SwipeHome = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    self:reload()
end

function Home:reload()
    self.books = Library.scan()
    self.current = Library.current(self.books)
    self.stats = Stats.overview()
    self.book_stats = nil
    if self.current then
        self.book_stats = Stats.book(self.current.path, self.current.percent, self.current.pages)
    end
    self:build()
    self:scheduleCoverExtraction()
end

------------------------------------------------------------------ layout

function Home:buildHeader()
    local h = math.floor(self.H * 0.05)
    local date_str = os.date("%A, %d %B"):gsub(" 0", " ")
    local left = text(date_str, SERIF_ITALIC, 13)
    local bits = { os.date("%H:%M") }
    local powerd = Device:getPowerDevice()
    if Device:hasBattery() then
        local cap = powerd:getCapacity()
        table.insert(bits, (powerd:isCharging() and "⚡" or "") .. cap .. "%")
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then table.insert(bits, "wi-fi") end
    local right = text(table.concat(bits, "  ·  "), SANS, 12, { color = GRAY })
    return VerticalGroup:new{
        OverlapGroup:new{
            dimen = Geom:new{ w = self.inner_w, h = h },
            LeftContainer:new{ dimen = Geom:new{ w = self.inner_w, h = h }, left },
            RightContainer:new{ dimen = Geom:new{ w = self.inner_w, h = h }, right },
        },
    }, h
end

function Home:tabDefs()
    return {
        { kind = "desk", label = _("Desk") },
        { kind = "all", label = _("All") },
        { kind = "reading", label = _("Reading") },
        { kind = "unread", label = _("Unread") },
        { kind = "finished", label = _("Finished") },
    }
end

function Home:buildTabs()
    local h = math.floor(self.H * 0.062)
    local defs = self:tabDefs()
    local row = HorizontalGroup:new{ align = "bottom" }
    local gap = Screen:scaleBySize(22)
    local items = {}
    local total = 0
    for _, d in ipairs(defs) do
        local active = d.kind == self.view.kind
        local t = text(d.label, active and SANS_BOLD or SANS, 13, { color = active and BLACK or GRAY,
        })
        local tw = t:getSize().w
        local cell = VerticalGroup:new{ align = "left",
            t,
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            active and hline(tw, Screen:scaleBySize(4)) or VerticalSpan:new{ width = Screen:scaleBySize(4) },
        }
        table.insert(items, { def = d, widget = cell })
        total = total + tw
    end
    gap = math.max(Screen:scaleBySize(10), math.floor((self.inner_w - total) / (#items - 1)))
    for i, it in ipairs(items) do
        local d = it.def
        table.insert(row, Tappable:new{ it.widget, on_tap = function() self:switchTab(d) end })
        if i < #items then table.insert(row, HorizontalSpan:new{ width = gap }) end
    end
    return VerticalGroup:new{ align = "left",
        LeftContainer:new{ dimen = Geom:new{ w = self.inner_w, h = h }, row },
        hline(self.inner_w, Screen:scaleBySize(1), GRAY),
    }, h + Screen:scaleBySize(1)
end

function Home:buildDock()
    local h = math.floor(self.H * 0.065)
    local entries = {
        { _("Files"), function() self:openFiles() end },
        { _("Search"), function() self:openSearch() end },
        { _("History"), function() self:openHistory() end },
        { _("Z-library"), function() self:openZlibrary() end },
        { _("Menu"), function() self:openMenu() end },
    }
    if self.ui and self.ui.ventana then
        -- the Ventana browser plugin is installed: give it a dock slot
        table.insert(entries, #entries, { _("Web"), function() self.ui:handleEvent(Event:new("OpenVentana")) end })
    end
    local cell_w = math.floor(self.inner_w / #entries)
    local row = HorizontalGroup:new{}
    for _, e in ipairs(entries) do
        table.insert(row, Tappable:new{
            CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = h }, text(e[1], SANS, 13) },
            on_tap = e[2], on_hold = e[3],
        })
    end
    return VerticalGroup:new{
        hline(self.inner_w, Screen:scaleBySize(2)),
        row,
    }, h + Screen:scaleBySize(2)
end

function Home:buildWeekBars(w, h)
    local week = self.stats and self.stats.week
    if not week then return nil end
    local max = 1
    for _, d in ipairs(week) do max = math.max(max, d.pages) end
    local slot_w = math.floor(w / 7)
    local bar_w = math.floor(slot_w * 0.55)
    local label_h = Screen:scaleBySize(20)
    local cap_h = Screen:scaleBySize(16)
    local bars_h = h - label_h - cap_h
    local stub = Screen:scaleBySize(2)
    local row = HorizontalGroup:new{ align = "bottom" }
    for _, d in ipairs(week) do
        local bh = d.pages > 0 and math.max(stub * 2, math.floor(bars_h * d.pages / max)) or stub
        -- today: wide bar; past days: thin bars (solid black either way, e-ink safe)
        local this_w = d.today and bar_w or math.max(stub * 2, math.floor(bar_w * 0.4))
        if d.pages == 0 then this_w = bar_w end
        local bar = LineWidget:new{ dimen = Geom:new{ w = this_w, h = bh }, background = BLACK }
        table.insert(row, VerticalGroup:new{ align = "center",
            CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = bh }, bar },
            CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = label_h },
                text(d.day, d.today and SANS_BOLD or SANS, 9, { color = d.today and BLACK or GRAY }) },
        })
    end
    return VerticalGroup:new{ align = "right",
        RightContainer:new{ dimen = Geom:new{ w = w, h = cap_h },
            text(string.format(_("pages · best %d"), max), SANS, 8, { color = GRAY }) },
        VerticalSpan:new{ width = 0 },
        row,
    }
end

function Home:buildNowCard(h)
    local b = self.current
    local w = self.inner_w
    if not b then
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{ align = "center",
                text(_("Nothing on the desk."), SERIF_ITALIC, 18),
                VerticalSpan:new{ width = Screen:scaleBySize(10) },
                text(_("Pick something below and it will wait here for you."), SERIF, 11, { color = GRAY }),
            } }
    end
    local cover_h = h - Screen:scaleBySize(10)
    local cover_w = math.floor(cover_h * 0.68)
    local cover = Tile:new{ book = b, width = cover_w, height = cover_h, show_state = false,
        on_tap = function(book) self:openBook(book) end, on_hold = function(book) self:bookMenu(book) end }
    local gap = Screen:scaleBySize(24)
    local tw = w - cover_w - gap

    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, text(_("NOW READING"), SANS_BOLD, 9, { color = GRAY }))
    table.insert(col, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    table.insert(col, TextBoxWidget:new{ text = b.title, face = Font:getFace(SERIF_BOLD, 21), width = tw,
        height = math.floor(h * 0.36), height_adjust = true, height_overflow_show_ellipsis = true })
    if b.authors then
        table.insert(col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(col, text(b.authors, SERIF_ITALIC, 13, { max_width = tw, color = GRAY }))
    end
    table.insert(col, VerticalSpan:new{ width = Screen:scaleBySize(16) })

    local pct = math.floor((b.percent or 0) * 100 + 0.5)
    local pct_w = text(pct .. "%", SERIF_BOLD, 15)
    table.insert(col, HorizontalGroup:new{ align = "center",
        ProgressWidget:new{ width = tw - pct_w:getSize().w - Screen:scaleBySize(12), height = Screen:scaleBySize(9),
            percentage = b.percent or 0, margin_h = 0, margin_v = 0, radius = 0, bordersize = Screen:scaleBySize(1),
            bordercolor = BLACK, bgcolor = WHITE, fillcolor = BLACK },
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        pct_w,
    })
    table.insert(col, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    local facts = {}
    local bs = self.book_stats
    if bs and bs.secs_left then
        table.insert(facts, string.format(_("≈ %s left in the book"), fmtDuration(bs.secs_left)))
    elseif bs and bs.pages_left then
        table.insert(facts, string.format(_("%d pages to go"), bs.pages_left))
    end
    local st = self.stats
    if st then
        if st.today_pages > 0 then
            table.insert(facts, string.format(_("Today: %d pages · %s"), st.today_pages, fmtDuration(st.today_secs)))
        else
            table.insert(facts, _("Not opened yet today"))
        end
        if st.streak >= 2 then
            table.insert(facts, string.format(_("%d days in a row"), st.streak))
        end
    end
    -- facts on the left, this week's reading as little bars on the right
    local bars_w = math.floor(tw * 0.36)
    local facts_w = tw - bars_w - Screen:scaleBySize(16)
    local facts_col = VerticalGroup:new{ align = "left" }
    for _, f in ipairs(facts) do
        table.insert(facts_col, text(f, SERIF, 11, { max_width = facts_w }))
        table.insert(facts_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    end
    local bars_h = math.max(Screen:scaleBySize(40), facts_col:getSize().h)
    local bars = self:buildWeekBars(bars_w, bars_h)
    table.insert(col, HorizontalGroup:new{ align = "bottom",
        LeftContainer:new{ dimen = Geom:new{ w = facts_w, h = facts_col:getSize().h }, facts_col },
        HorizontalSpan:new{ width = Screen:scaleBySize(16) },
        bars or HorizontalSpan:new{ width = 0 },
    })

    return HorizontalGroup:new{ align = "top",
        cover,
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = tw, h = h }, Tappable:new{ col,
            on_tap = function() self:openBook(b) end, on_hold = function() self:bookMenu(b) end } },
    }
end

-- one row (or grid) of tiles
function Home:buildTiles(list, cols, rows, tile_w, tile_h, hgap, vgap, hide_new)
    local grid = VerticalGroup:new{ align = "left" }
    local i = 1
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, cols do
            local b = list[i]
            if b then
                table.insert(row, Tile:new{ book = b, width = tile_w, height = tile_h, hide_new = hide_new,
                    on_tap = function(book) self:openBook(book) end,
                    on_hold = function(book) self:bookMenu(book) end })
                self._visible[#self._visible + 1] = b
            else
                table.insert(row, HorizontalSpan:new{ width = tile_w })
            end
            if c < cols then table.insert(row, HorizontalSpan:new{ width = hgap }) end
            i = i + 1
        end
        table.insert(grid, row)
        if r < rows and list[i] then table.insert(grid, VerticalSpan:new{ width = vgap }) end
    end
    return grid
end

function Home:sectionTitle(label, right)
    local h = Screen:scaleBySize(34)
    local l = text(label, SERIF_ITALIC, 13)
    local og = OverlapGroup:new{ dimen = Geom:new{ w = self.inner_w, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = self.inner_w, h = h }, l } }
    if right then
        table.insert(og, RightContainer:new{ dimen = Geom:new{ w = self.inner_w, h = h }, right })
    end
    return og, h
end

function Home:buildDesk(avail_h)
    local card_h = math.floor(avail_h * 0.36)
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(16) })
    table.insert(vg, self:buildNowCard(card_h))

    -- Geometry first: the row height decides the cover size, the width decides how many fit.
    local title_h = select(2, self:sectionTitle("x"))
    local rest = avail_h - card_h - Screen:scaleBySize(16)
    local per = math.floor(rest / 2)
    local tile_h = per - title_h - Tile.STATE_H - Screen:scaleBySize(30)
    local tile_w = math.floor(tile_h / 1.45)
    local min_gap = Screen:scaleBySize(16)
    local cols = math.max(3, math.floor((self.inner_w + min_gap) / (tile_w + min_gap)))
    local hgap = math.floor((self.inner_w - cols * tile_w) / (cols - 1))

    local continue, by_added = {}, {}
    for _, b in ipairs(self.books) do
        if b ~= self.current and (b.status == "reading" or b.status == "abandoned") and #continue < cols then
            table.insert(continue, b)
        end
        if b.status == "new" then table.insert(by_added, b) end
    end
    table.sort(by_added, function(a, c) return a.mtime > c.mtime end)
    local fresh = {}
    for i = 1, math.min(cols, #by_added) do fresh[i] = by_added[i] end

    local sections = {}
    if #continue > 0 then table.insert(sections, { _("Also on the go"), continue }) end
    if #fresh > 0 then table.insert(sections, { _("New on the shelf"), fresh, true }) end
    for _, s in ipairs(sections) do
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(vg, (self:sectionTitle(s[1])))
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(vg, self:buildTiles(s[2], cols, 1, tile_w, tile_h, hgap, 0, s[3]))
    end
    return vg
end

function Home:buildWall(avail_h)
    local list = Library.filter(self.books, self.view)
    local cols, rows = 4, 3
    local per_page = cols * rows
    self.pages = math.max(1, math.ceil(#list / per_page))
    self.page = math.max(1, math.min(self.page, self.pages))

    local count_label = string.format(#list == 1 and _("%d book") or _("%d books"), #list)
    local pager
    if self.pages > 1 then
        pager = Tappable:new{ text(string.format("‹  %d / %d  ›", self.page, self.pages), SANS, 11, { color = GRAY }),
            on_tap = function() self:turnPage(1) end }
    end
    local title, title_h = self:sectionTitle(count_label, pager)

    local vg = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = Screen:scaleBySize(10) }, title,
        VerticalSpan:new{ width = Screen:scaleBySize(8) } }
    if #list == 0 then
        local empty = { reading = _("Nothing in progress."), unread = _("Every book has been opened. Impressive."),
            finished = _("No finished books yet."), }
        table.insert(vg, CenterContainer:new{ dimen = Geom:new{ w = self.inner_w, h = avail_h - title_h - Screen:scaleBySize(40) },
            text(empty[self.view.kind] or _("Nothing here."), SERIF_ITALIC, 15, { color = GRAY }) })
        return vg
    end
    local hgap = Screen:scaleBySize(18)
    local vgap = Screen:scaleBySize(18)
    local grid_h = avail_h - title_h - Screen:scaleBySize(24)
    local tile_h = math.floor((grid_h - (rows - 1) * vgap) / rows) - Tile.STATE_H - Screen:scaleBySize(5)
    local tile_w = math.floor((self.inner_w - (cols - 1) * hgap) / cols)
    tile_w = math.min(tile_w, math.floor(tile_h / 1.42))
    hgap = math.floor((self.inner_w - cols * tile_w) / (cols - 1))
    local slice = {}
    for i = (self.page - 1) * per_page + 1, math.min(#list, self.page * per_page) do
        table.insert(slice, list[i])
    end
    table.insert(vg, self:buildTiles(slice, cols, rows, tile_w, tile_h, hgap, vgap, self.view.kind == "unread"))
    return vg
end

function Home:build()
    if self[1] then self[1]:free() end
    self._visible = {}
    local header, header_h = self:buildHeader()
    local tabs, tabs_h = self:buildTabs()
    local dock, dock_h = self:buildDock()
    local top_pad = Screen:scaleBySize(6)
    local avail_h = self.H - header_h - tabs_h - dock_h - top_pad - Screen:scaleBySize(6)
    local body
    local ok, err = pcall(function()
        if self.view.kind == "desk" then
            body = self:buildDesk(avail_h)
        else
            body = self:buildWall(avail_h)
        end
    end)
    if not ok then
        logger.err("Estante: failed to build view:", err)
        body = text("Estante: " .. tostring(err), SANS, 10)
    end
    self[1] = FrameContainer:new{
        width = self.W, height = self.H, bordersize = 0, margin = 0,
        padding = 0, padding_left = self.pad, padding_right = self.pad, padding_top = top_pad,
        background = WHITE,
        VerticalGroup:new{ align = "left",
            header,
            tabs,
            VerticalGroup:new{ align = "left", body,
                VerticalSpan:new{ width = math.max(0, avail_h - body:getSize().h) } },
            dock,
        },
    }
end

function Home:refresh(flash)
    UIManager:setDirty(self, function() return flash and "flashui" or "ui", self.dimen end, true)
end

------------------------------------------------------------------ covers

function Home:scheduleCoverExtraction()
    local BIM = Library.bookInfoManager()
    if not BIM or self._extracting then return end
    local specs = { max_cover_w = math.floor(self.W * 0.3), max_cover_h = math.floor(self.H * 0.3) }
    local todo = {}
    for _, b in ipairs(self.books) do
        if not b.indexed then
            table.insert(todo, { filepath = b.path, cover_specs = specs })
        end
    end
    if #todo == 0 then return end
    logger.dbg("Estante: extracting", #todo, "books in background")
    self._extracting = true
    UIManager:nextTick(function()
        if not BIM:extractInBackground(todo) then self._extracting = false return end
        local function poll()
            if not self._shown then return end
            if BIM:isExtractingInBackground() then
                UIManager:scheduleIn(2, poll)
            else
                self._extracting = false
                self.books = Library.scan()
                self.current = Library.current(self.books)
                self:build()
                self:refresh(true)
            end
        end
        UIManager:scheduleIn(2, poll)
    end)
end

------------------------------------------------------------------ actions

function Home:switchTab(def)
    self.view = { kind = def.kind }
    self.page = 1
    self:build()
    self:refresh(true)
end

function Home:turnPage(dir)
    if self.view.kind == "desk" or not self.pages or self.pages <= 1 then return end
    local p = self.page + dir
    if p > self.pages then p = 1 elseif p < 1 then p = self.pages end
    self.page = p
    self:build()
    self:refresh(true)
end

function Home:onSwipeHome(_, ges)
    local d = ges.direction
    if d == "west" then self:turnPage(1)
    elseif d == "east" then self:turnPage(-1)
    elseif d == "south" then
        if ges.pos.y < self.H * 0.12 then
            self:openMenu()
        else
            self:reload()
            self:refresh(true)
        end
    elseif d == "north" then
        if self.view.kind == "desk" then self:switchTab({ kind = "all" }) end
    end
    return true
end

function Home:openBook(book)
    self:close()
    filemanagerutil.openFile(self.ui, book.path)
end

function Home:bookMenu(book)
    local dialog
    local function done() UIManager:close(dialog) end
    local function after() done() self:reload() self:refresh(true) end
    local buttons = {
        filemanagerutil.genStatusButtonsRow(book.path, after),
        {
            { text = _("Open"), callback = function() done() self:openBook(book) end },
            filemanagerutil.genBookInformationButton(book.path, nil, done),
        },
        {
            filemanagerutil.genShowFolderButton(book.path, function() done() self:close() end),
            filemanagerutil.genResetSettingsButton(book.path, after, not book.opened),
        },
    }
    dialog = ButtonDialog:new{
        title = book.title .. (book.authors and ("\n" .. book.authors) or ""),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Home:openFiles()
    self:close()
end

function Home:openSearch()
    if self.ui.filesearcher then self.ui.filesearcher:onShowFileSearch() end
end

function Home:openMenu()
    if self.ui.menu then self.ui.menu:onShowMenu() end
end

function Home:openHistory()
    if self.ui.history then self.ui.history:onShowHist() end
end

function Home:openZlibrary()
    self.ui:handleEvent(Event:new("ZlibrarySearch"))
end

function Home:onShow()
    self._shown = true
    self:refresh(true)
end

function Home:onCloseWidget()
    self._shown = false
    if self.plugin then self.plugin.home = nil end
    if self[1] then self[1]:free() end
end

function Home:close()
    UIManager:close(self, "flashui")
end

-- after resume the clock/battery are stale
function Home:onResume()
    if not self._shown then return end
    UIManager:scheduleIn(1, function()
        if self._shown then
            self.stats = Stats.overview()
            self:build()
            self:refresh(true)
        end
    end)
end

return Home
