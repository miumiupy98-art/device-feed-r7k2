local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_toolbar

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    hold_callback = nil,
    enabled = true,
}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
    if self.hold_callback then
        self.ges_events.HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}}
    end
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.enabled ~= false and self.callback then self.callback() end
    return true
end
function TapBox:onHoldSelect()
    if self.enabled ~= false and self.hold_callback then self.hold_callback() end
    return true
end
function TapBox:handleEvent(event) return InputContainer.handleEvent(self, event) end

local function centered_text(text, width, height, face, options)
    options = options or {}
    return Ui.textbox(tostring(text or ""), width, height, face, {
        bold = options.bold == true,
        alignment = "center",
        halign = "center",
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    })
end

local function icon_box(icon, width, height, enabled, size)
    return Ui.icon(tostring(icon or ""), width, height, math.min(width, height, size or Skin.dp(22, 19, 30)), {
        icon_key = tostring(icon or ""),
        face = Skin.face("cfont", 17.2, 23.2, 14.4),
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local SliderBar = InputContainer:extend{
    dimen = nil,
    min = 0,
    max = 100,
    value = 0,
    track_w = 1,
    owner = nil,
    on_change = nil,
    last_refresh = 0,
}
function SliderBar:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.min = tonumber(self.min) or 0
    self.max = tonumber(self.max) or 100
    if self.max <= self.min then self.max = self.min + 1 end
    self.value = math.max(self.min, math.min(self.max, tonumber(self.value) or self.min))
    self.slide_dimen = Geom:new{x = 0, y = 0, w = math.max(1, self.track_w), h = self.dimen.h}
    self.ges_events = {
        TapSlide = {GestureRange:new{ges = "tap", range = self.slide_dimen}},
        PanSlide = {GestureRange:new{ges = "pan", range = self.slide_dimen}},
    }
end
function SliderBar:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function SliderBar:_ratio()
    return math.max(0, math.min(1, (self.value - self.min) / math.max(1, self.max - self.min)))
end
function SliderBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.slide_dimen.x, self.slide_dimen.y = x, y
    local track_h = math.max(1, Skin.line("medium"))
    local marker = Skin.dp(8, 7, 11)
    local bar_y = y + math.floor((self.dimen.h - track_h) / 2)
    local ratio = self:_ratio()
    local fill_w = math.floor(self.track_w * ratio)
    local marker_x = x + math.floor((self.track_w - marker) * ratio)
    bb:paintRect(x, bar_y, self.track_w, track_h, Blitbuffer.COLOR_GRAY)
    if fill_w > 0 then bb:paintRect(x, bar_y, math.min(self.track_w, fill_w), track_h, Blitbuffer.COLOR_BLACK) end
    bb:paintRect(marker_x, y + math.floor((self.dimen.h - marker) / 2), marker, marker, Blitbuffer.COLOR_BLACK)
end
function SliderBar:_refresh(force)
    if not self.owner or self.owner.closed then return end
    local interval = Screen.low_pan_rate and .10 or .04
    local now = os.clock()
    if not force and now - (tonumber(self.last_refresh) or 0) < interval then return end
    self.last_refresh = now
    UIManager:setDirty(self.owner, function() return "ui", Skin.expand_region(self.dimen, Skin.dp(2, 2, 3)) end)
end
function SliderBar:setValue(value, force)
    self.value = math.max(self.min, math.min(self.max, tonumber(value) or self.value))
    self:_refresh(force ~= false)
end
function SliderBar:_set_from_position(ges, force)
    local pos = ges and ges.pos
    if not pos then return false end
    local ratio = math.max(0, math.min(1, (pos.x - self.dimen.x) / math.max(1, self.track_w)))
    local target = math.floor(self.min + ratio * (self.max - self.min) + .5)
    local actual = target
    if self.on_change then
        local ok, result = pcall(self.on_change, target)
        if not ok then
            logger.warn("[MiuRead][ReaderToolbar] slider action failed", tostring(result))
            return true
        end
        if result == false then return true end
        if tonumber(result) then actual = tonumber(result) end
    end
    self:setValue(actual, force)
    return true
end
function SliderBar:onTapSlide(_, ges) return self:_set_from_position(ges, true) end
function SliderBar:onPanSlide(_, ges) return self:_set_from_position(ges, false) end
function SliderBar:handleEvent(event) return InputContainer.handleEvent(self, event) end

local function action_item(entry, width, height, activate, hold_activate)
    local enabled = entry.enabled ~= false
    local icon_area_h = math.floor(height * .68)
    local label_h = math.max(1, height - icon_area_h)
    local circle = math.min(Skin.dp(39, 33, 52), math.floor(icon_area_h * .78), math.floor(width * .52))
    local icon_size = math.max(Skin.dp(17, 15, 23), math.floor(circle * .52))
    local circle_widget = Skin.frame(circle, circle, {
        bordersize = Skin.line("thin"),
        padding = 0,
        radius = math.floor(circle / 2),
        background = Blitbuffer.COLOR_WHITE,
        color = enabled and Blitbuffer.COLOR_GRAY or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY),
    }, icon_box(entry.icon_key or entry.icon, circle, circle, enabled, icon_size))
    local content = VerticalGroup:new{
        align = "center",
        CenterContainer:new{dimen = Geom:new{w = width, h = icon_area_h}, circle_widget},
        centered_text(entry.label or entry.text, width, label_h,
            Skin.face("smallinfofont", 7.8, 10.5, 6.6), {
                bold = entry.active == true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() activate(entry.callback, entry.label or entry.key or "功能") end,
        hold_callback = entry.hold_callback and function()
            hold_activate(entry.hold_callback, entry.label or entry.key or "功能")
        end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, content}
    return tap
end

local Toolbar = InputContainer:extend{
    name = "miuread_reader_toolbar",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    action_locked = false,
}

function Toolbar:handleEvent(event) return InputContainer.handleEvent(self, event) end

function Toolbar:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Toolbar:_activate(action, label)
    if self.closed or self.action_locked then return true end
    self.action_locked = true
    logger.info("[MiuRead][ReaderToolbar] tapped", tostring(label or "unknown"))
    return self:_close(action)
end

function Toolbar:_activate_hold(action, label)
    if self.closed or self.action_locked then return true end
    self.action_locked = true
    logger.info("[MiuRead][ReaderToolbar] held", tostring(label or "unknown"))
    return self:_close(action)
end

function Toolbar:_header(root, header, x, y, width, title_h, status_h)
    header = type(header) == "table" and header or {}
    local side = Skin.dp(46, 39, 62)
    local title_w = math.max(1, width - side * 2)

    local home = TapBox:new{
        dimen = Geom:new{w = side, h = title_h},
        enabled = type(header.home_callback) == "function",
        callback = function() self:_activate(header.home_callback, "主页") end,
    }
    home[1] = icon_box("home", side, title_h, true, Skin.dp(20, 17, 27))

    local book = TapBox:new{
        dimen = Geom:new{w = title_w, h = title_h},
        enabled = type(header.book_callback) == "function",
        callback = function() self:_activate(header.book_callback, "当前书籍") end,
    }
    book[1] = centered_text(header.title or "正在阅读", title_w, title_h,
        Skin.face("cfont", 10.5, 14.2, 9), {bold = true})

    local more = TapBox:new{
        dimen = Geom:new{w = side, h = title_h},
        enabled = type(header.more_callback) == "function",
        callback = function() self:_activate(header.more_callback, "更多") end,
    }
    more[1] = icon_box("more", side, title_h, true, Skin.dp(19, 16, 25))

    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        HorizontalGroup:new{align = "center", home, book, more},
    }
    y = y + title_h

    local half = math.floor(width / 2)
    local wifi = TapBox:new{
        dimen = Geom:new{w = half, h = status_h},
        enabled = type(header.wifi_callback) == "function",
        callback = function() self:_activate(header.wifi_callback, "Wi-Fi") end,
        hold_callback = type(header.wifi_hold_callback) == "function" and function()
            self:_activate_hold(header.wifi_hold_callback, "Wi-Fi 设置")
        end or nil,
    }
    wifi[1] = Ui.textbox(tostring(header.status_left or ""), half, status_h,
        Skin.face("smallinfofont", 7.2, 9.7, 6.1), {
            alignment = "left",
            fgcolor = header.status_left_alert and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            bold = header.status_left_alert == true,
        })
    local battery_w = width - half
    local battery = Ui.textbox(tostring(header.status_right or ""), battery_w, status_h,
        Skin.face("smallinfofont", 7.2, 9.7, 6.1), {
            alignment = "right", halign = "right", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        HorizontalGroup:new{align = "center", wifi, battery},
    }
    return y + status_h
end

function Toolbar:_action_row(root, entries, x, y, width, height)
    entries = type(entries) == "table" and entries or {}
    local count = math.max(1, #entries)
    local cell_w = math.floor(width / count)
    for index, entry in ipairs(entries) do
        local cell_x = x + (index - 1) * cell_w
        local actual_w = index == count and (x + width - cell_x) or cell_w
        root[#root + 1] = OffsetContainer:new{
            x_off = cell_x, y_off = y,
            action_item(entry, actual_w, height,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end),
        }
    end
end

function Toolbar:_frontlight_row(root, setting, x, y, width, height)
    if type(setting) ~= "table" then return end
    local label_w = math.max(Skin.dp(78, 66, 104), math.floor(width * .23))
    local control_w = math.max(1, width - label_w)
    local slider_pad = Skin.dp(12, 10, 16)
    local slider_w = math.max(1, control_w - slider_pad * 2)
    local enabled = setting.enabled ~= false

    local label_tap = TapBox:new{
        dimen = Geom:new{w = label_w, h = height},
        enabled = enabled and type(setting.on_toggle) == "function",
        callback = function()
            if type(setting.on_toggle) ~= "function" then return end
            local ok, value = pcall(setting.on_toggle)
            if not ok then
                logger.warn("[MiuRead][ReaderToolbar] frontlight toggle failed", tostring(value))
                return
            end
            if self._brightness_slider and tonumber(value) then self._brightness_slider:setValue(value, true) end
            UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
        end,
    }
    local value = math.floor((tonumber(setting.value) or tonumber(setting.min) or 0) + .5)
    label_tap[1] = HorizontalGroup:new{
        align = "center",
        icon_box("frontlight", Skin.dp(25, 21, 34), height, enabled, Skin.dp(16, 14, 22)),
        HorizontalSpan:new{width = Skin.dp(2, 2, 3)},
        Ui.textbox("前光 " .. tostring(value), math.max(1, label_w - Skin.dp(27, 23, 37)), height,
            Skin.face("smallinfofont", 7.7, 10.4, 6.5), {alignment = "left", bold = true}),
    }
    local slider = SliderBar:new{
        dimen = Geom:new{w = slider_w, h = height},
        track_w = slider_w,
        min = tonumber(setting.min) or 0,
        max = tonumber(setting.max) or 100,
        value = tonumber(setting.value) or 0,
        owner = self,
        on_change = function(target)
            local actual = target
            if setting.on_set then
                local ok, result = pcall(setting.on_set, target)
                if not ok then
                    logger.warn("[MiuRead][ReaderToolbar] frontlight change failed", tostring(result))
                    return false
                end
                if result == false then return false end
                if tonumber(result) then actual = tonumber(result) end
            end
            return actual
        end,
    }
    self._brightness_slider = slider
    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        HorizontalGroup:new{
            align = "center",
            label_tap,
            HorizontalSpan:new{width = slider_pad},
            slider,
            HorizontalSpan:new{width = slider_pad},
        },
    }
end

function Toolbar:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local side_pad = math.max(Skin.dp(14, 12, 23), math.floor(sw * .022))
    local top_pad = Skin.dp(5, 4, 8)
    local bottom_pad = Skin.dp(7, 6, 11)
    local gap = Skin.dp(3, 2, 5)
    local content_w = math.max(1, sw - side_pad * 2)

    local title_h = math.max(Skin.dp(33, 29, 44), math.floor(sh * (portrait and .031 or .044)))
    local status_h = math.max(Skin.dp(20, 17, 27), math.floor(sh * (portrait and .018 or .026)))
    local group_title_h = math.max(Skin.dp(18, 16, 24), math.floor(sh * (portrait and .017 or .024)))
    local action_h = math.max(Skin.dp(61, 52, 79), math.floor(sh * (portrait and .057 or .075)))
    local light_h = math.max(Skin.dp(34, 29, 44), math.floor(sh * (portrait and .031 or .044)))
    local divider_h = math.max(1, Skin.line("thin"))

    local groups = type(self.opts.groups) == "table" and self.opts.groups or {}
    local frontlight = type(self.opts.frontlight) == "table" and self.opts.frontlight or nil
    local header = type(self.opts.header) == "table" and self.opts.header or {}

    local panel_h = top_pad + title_h + status_h + gap + divider_h
    for index, _ in ipairs(groups) do
        panel_h = panel_h + group_title_h + action_h
        if index < #groups then panel_h = panel_h + gap + divider_h + gap end
    end
    if frontlight then panel_h = panel_h + gap + divider_h + gap + light_h end
    panel_h = panel_h + bottom_pad
    panel_h = math.min(sh - Skin.dp(28, 24, 46), panel_h)

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_h = panel_h
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = 0, y_off = 0,
        Skin.frame(sw, panel_h, {
            bordersize = 0, padding = 0, radius = 0,
            background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_WHITE,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_pad
    y = self:_header(root, header, side_pad, y, content_w, title_h, status_h)
    y = y + gap
    root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, Skin.divider(content_w, (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY), divider_h)}
    y = y + divider_h

    for index, group in ipairs(groups) do
        root[#root + 1] = OffsetContainer:new{
            x_off = side_pad, y_off = y,
            Ui.textbox(tostring(group.title or ""), content_w, group_title_h,
                Skin.face("smallinfofont", 7.2, 9.7, 6.1), {
                    bold = true, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                }),
        }
        y = y + group_title_h
        self:_action_row(root, group.actions or group.items, side_pad, y, content_w, action_h)
        y = y + action_h
        if index < #groups then
            y = y + gap
            root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, Skin.divider(content_w, (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY), divider_h)}
            y = y + divider_h + gap
        end
    end

    if frontlight then
        y = y + gap
        root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, Skin.divider(content_w, (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY), divider_h)}
        y = y + divider_h + gap
        self:_frontlight_row(root, frontlight, side_pad, y, content_w, light_h)
        y = y + light_h
    end

    root[#root + 1] = OffsetContainer:new{
        x_off = 0, y_off = panel_h - math.max(1, Skin.line("thin")),
        LineWidget:new{background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{w = sw, h = math.max(1, Skin.line("thin"))}},
    }

    self[1] = root
end

function Toolbar:init()
    self.opts = self.opts or {}
    self.action_locked = false
    self:_build_content()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function Toolbar:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < 0 or pos.y > self.panel_h or pos.x < 0 or pos.x > self.panel_dimen.w) then
        return self:_close()
    end
    return false
end
function Toolbar:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close() end
    return false
end
function Toolbar:onClose() return self:_close() end
function Toolbar:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen, Skin.dp(2, 2, 3)) end)
end
function Toolbar:onCloseWidget()
    local region = self.panel_dimen and Skin.expand_region(self.panel_dimen, Skin.dp(2, 2, 3)) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_toolbar == self then live_toolbar = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderToolbar] action failed", tostring(err)) end
        end)
    end
end

local M = {}
function M.close()
    if live_toolbar and not live_toolbar.closed then live_toolbar:_close(nil, true) end
    live_toolbar = nil
end
function M.show(opts)
    M.close()
    local ok, toolbar = pcall(Toolbar.new, Toolbar, {opts = opts or {}})
    if not ok or not toolbar then return nil, tostring(toolbar) end
    live_toolbar = toolbar
    UIManager:show(toolbar, "ui", toolbar.panel_dimen)
    return toolbar
end
return M
