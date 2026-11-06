--[[
Estante tile: one book on the shelf.
Real cover when CoverBrowser has one cached; otherwise a generated
typographic "plate" (black label band, serif title, italic author).
A slim reading-state line sits under every tile.
]]
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen

local Library = require("estante/library")

local SERIF = "NotoSerif-Regular.ttf"
local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"
local SANS = "NotoSans-Regular.ttf"
local SANS_BOLD = "NotoSans-Bold.ttf"

local Tile = InputContainer:extend{
    book = nil,
    width = nil,      -- cover box width
    height = nil,     -- cover box height (state line is extra)
    show_state = true,
    hide_new = false, -- don't label unread books (redundant on Unread / New rows)
    on_tap = nil,
    on_hold = nil,
}

Tile.STATE_H = Screen:scaleBySize(18)
local INK = Blitbuffer.Color8(0x44)

local function fitFace(text, name, size, min, width, max_h, bold)
    local w
    while true do
        if w then w:free(true) end
        w = TextBoxWidget:new{
            text = text, face = Font:getFace(name, size), width = width,
            alignment = "center", bold = bold,
        }
        if w:getSize().h <= max_h or size <= min then break end
        size = size - 1
    end
    if w:getSize().h > max_h then
        w:free(true)
        w = TextBoxWidget:new{
            text = text, face = Font:getFace(name, size), width = width, alignment = "center",
            height = max_h, height_adjust = true, height_overflow_show_ellipsis = true, bold = bold,
        }
    end
    return w
end

function Tile.plate(book, w, h)
    local border = Screen:scaleBySize(2)
    local inner_w = w - 2 * border
    local band_h = math.floor(h * 0.10)
    local pad = math.floor(w * 0.08)
    local text_w = inner_w - 2 * pad
    local fmt = (book.ext or ""):upper()
    if book.is_article then fmt = "ARTICLE" end
    local band = FrameContainer:new{
        width = inner_w, height = band_h, bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = band_h },
            TextWidget:new{ text = fmt, face = Font:getFace(SANS_BOLD, 9), fgcolor = Blitbuffer.COLOR_WHITE },
        },
    }
    local title_max_h = math.floor((h - band_h) * 0.58)
    local title = fitFace(book.title or book.name, SERIF_BOLD, h > Screen:scaleBySize(150) and 17 or 12, 9, text_w, title_max_h)
    local author
    if book.authors then
        author = fitFace(book.authors, SERIF_ITALIC, 11, 8, text_w, math.floor((h - band_h) * 0.2))
    end
    local rule = LineWidget:new{ dimen = Geom:new{ w = math.floor(text_w * 0.3), h = Screen:scaleBySize(1) }, background = Blitbuffer.COLOR_DARK_GRAY }
    local body = VerticalGroup:new{ align = "center",
        VerticalSpan:new{ width = math.floor((h - band_h) * 0.12) },
        title,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        rule,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
    }
    if author then table.insert(body, author) end
    return FrameContainer:new{
        width = w, height = h, bordersize = border, padding = 0, margin = 0,
        color = Blitbuffer.COLOR_BLACK, background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "center",
            band,
            CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = h - band_h - 2 * border }, body },
        },
    }
end

function Tile.cover(book, w, h)
    local BIM = Library.bookInfoManager()
    if not (BIM and book.has_cover) then return nil end
    local ok, bi = pcall(BIM.getBookInfo, BIM, book.path, true)
    if not (ok and bi and bi.cover_bb) then return nil end
    local border = Size.border.thin
    local _, _, scale = BIM.getCachedCoverSize(bi.cover_w, bi.cover_h, w - 2 * border, h - 2 * border)
    local img = ImageWidget:new{ image = bi.cover_bb, image_disposable = true, scale_factor = scale }
    img:_render()
    local isz = img:getSize()
    book._cover_cached_h = bi.cover_h
    return BottomContainer:new{
        dimen = Geom:new{ w = w, h = h },
        FrameContainer:new{
            width = isz.w + 2 * border, height = isz.h + 2 * border,
            bordersize = border, padding = 0, margin = 0, color = Blitbuffer.COLOR_DARK_GRAY,
            img,
        },
    }
end

function Tile.stateLine(book, w, hide_new)
    local h = Tile.STATE_H
    local status = book.status
    local function label(str)
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
            TextWidget:new{ text = str, face = Font:getFace(SERIF, 10), fgcolor = INK } }
    end
    if status == "complete" then
        return label("✓ finished")
    elseif status == "abandoned" then
        return label("on hold")
    elseif status == "reading" and (book.percent or 0) > 0 then
        local pct = TextWidget:new{ text = string.format("%d%%", math.floor(book.percent * 100 + 0.5)),
            face = Font:getFace(SANS, 10) }
        local bar_w = w - pct:getSize().w - Screen:scaleBySize(6)
        return HorizontalGroup:new{ align = "center",
            ProgressWidget:new{ width = bar_w, height = Screen:scaleBySize(7), percentage = book.percent,
                margin_h = 0, margin_v = 0, radius = 0, bordersize = Screen:scaleBySize(1),
                bordercolor = Blitbuffer.COLOR_BLACK, bgcolor = Blitbuffer.COLOR_WHITE,
                fillcolor = Blitbuffer.COLOR_BLACK },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            pct,
        }
    elseif status == "new" and not hide_new then
        return label("new")
    end
    return VerticalSpan:new{ width = h }
end

function Tile:init()
    local book = self.book
    local face = Tile.cover(book, self.width, self.height) or Tile.plate(book, self.width, self.height)
    local group = VerticalGroup:new{ align = "center", face }
    if self.show_state then
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(5) })
        table.insert(group, LeftContainer:new{ dimen = Geom:new{ w = self.width, h = Tile.STATE_H }, Tile.stateLine(book, self.width, self.hide_new) })
    end
    self[1] = group
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = group:getSize().h }
    self.ges_events = {
        TapTile = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldTile = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tile:onTapTile()
    if self.on_tap then self.on_tap(self.book) end
    return true
end

function Tile:onHoldTile()
    if self.on_hold then self.on_hold(self.book) end
    return true
end

return Tile
