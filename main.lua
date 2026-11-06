--[[
Estante — a reading-desk home screen for KOReader.
Shows on top of the File Manager at startup and whenever a book is closed.
The File Manager's home icon brings it back; "Files" in the dock hides it.
]]
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Must be required while the plugin dir is on package.path (i.e. at load time).
local Home = require("estante/home")
local Sleep = require("estante/sleep")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/main%.lua$")
Sleep.art_dir = plugin_dir and (plugin_dir .. "/estante/art")

local function sleepEnabled()
    return G_reader_settings:nilOrTrue("estante_sleep")
end

-- Sleep screen: wrap Screensaver:show() once, for the whole session (reader included).
-- Anything unusual (landscape, gesture lock, an error) falls back to KOReader's own screen.
do
    local Screensaver = require("ui/screensaver")
    if not Screensaver._estante_wrapped then
        Screensaver._estante_wrapped = true
        local orig_show = Screensaver.show
        Screensaver.show = function(ss)
            if not sleepEnabled() or not ss.ui
                    or G_reader_settings:readSetting("screensaver_delay") == "gesture" then
                return orig_show(ss)
            end
            local Device = require("device")
            local Screen = Device.screen
            local rot = Screen:getRotationMode()
            if rot ~= Screen.DEVICE_ROTATED_UPRIGHT and rot ~= Screen.DEVICE_ROTATED_UPSIDE_DOWN then
                return orig_show(ss)
            end
            local message = (ss.prefix and ss.prefix ~= "") and ss.event_message or nil
            local ok, widget = pcall(function()
                local w = Sleep.build(ss.ui, message)
                -- trial paint off-screen: a layout bug must never crash the suspend path
                local Blitbuffer = require("ffi/blitbuffer")
                local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(), Screen.bb:getType())
                local painted, err = pcall(w.paintTo, w, bb, 0, 0)
                bb:free()
                if not painted then error(err) end
                return w
            end)
            if not ok or not widget then
                logger.warn("Estante: sleep screen failed, using default:", widget)
                return orig_show(ss)
            end
            Device.screen_saver_mode = true
            local ScreenSaverWidget = require("ui/widget/screensaverwidget")
            ss.screensaver_widget = ScreenSaverWidget:new{
                widget = widget,
                background = require("ffi/blitbuffer").COLOR_WHITE,
                covers_fullscreen = true,
            }
            ss.screensaver_widget.modal = true
            ss.screensaver_widget.dithered = true
            UIManager:show(ss.screensaver_widget, "full")
        end
    end
end

-- Full-screen preview of the sleep screen; tap anywhere to close.
local function previewSleep(ui)
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Screen = require("device").screen
    local preview = InputContainer:new{
        covers_fullscreen = true,
        dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
    }
    preview.ges_events = { TapClose = { GestureRange:new{ ges = "tap", range = preview.dimen } } }
    function preview:onTapClose() UIManager:close(self, "full") return true end
    preview[1] = Sleep.build(ui)
    UIManager:show(preview, "full")
end

local Estante = WidgetContainer:extend{
    name = "estante",
    is_doc_only = false,
    home = nil,
}

local function autoShow()
    return G_reader_settings:nilOrTrue("estante_autoshow")
end

function Estante:onDispatcherRegisterActions()
    Dispatcher:registerAction("estante_home", {
        category = "none", event = "ShowEstante", title = _("Estante home screen"), general = true,
    })
end

function Estante:init()
    -- Hands off the reader: no menu entry, no actions, nothing.
    if self.ui.document then return end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- File Manager context: the home icon opens Estante (hold still opens the folder menu).
    local fm = self.ui
    if fm.title_bar and autoShow() then
        fm.title_bar.left_icon_tap_callback = function() self:onShowEstante() end
    end
    if autoShow() and not Estante._suppress_once then
        UIManager:nextTick(function() self:onShowEstante() end)
    end
    Estante._suppress_once = nil
end

function Estante:onShowEstante()
    if self.home then
        UIManager:setDirty(self.home, "flashui")
        return true
    end
    local ok, err = pcall(function()
        self.home = Home:new{ ui = self.ui, plugin = self }
        UIManager:show(self.home, "flashui")
    end)
    if not ok then
        logger.err("Estante: could not show home:", err)
        self.home = nil
    end
    return true
end

function Estante:addToMainMenu(menu_items)
    menu_items.estante = {
        text = _("Estante home screen"),
        sorting_hint = "filemanager_settings",
        sub_item_table = {
            {
                text = _("Open home screen"),
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:onShowEstante()
                end,
            },
            {
                text = _("ASCII sleep screen"),
                checked_func = sleepEnabled,
                callback = function()
                    G_reader_settings:saveSetting("estante_sleep", not sleepEnabled())
                end,
            },
            {
                text = _("Preview sleep screen (next drawing)"),
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    previewSleep(self.ui)
                end,
            },
            {
                text = _("Show on startup and after closing a book"),
                checked_func = autoShow,
                callback = function()
                    G_reader_settings:saveSetting("estante_autoshow", not autoShow())
                end,
            },
        },
    }
end

return Estante
