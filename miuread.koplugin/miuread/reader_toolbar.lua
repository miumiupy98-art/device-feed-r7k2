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
local VerticalSpan = require("ui/widget/verticalspan")
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
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

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
    value_w = 1,
    value_gap = 0,
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
    self.value_text = TextWidget:new{
        text = tostring(math.floor(self.value + .5)),
        face = Skin.face("smallinfofont", 9.1, 12.2, 7.8),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end
function SliderBar:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function SliderBar:_ratio()
    return math.max(0, math.min(1, (self.value - self.min) / math.max(1, self.max - self.min)))
end
function SliderBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.slide_dimen.x, self.slide_dimen.y = x, y
    local track_h = math.max(Skin.line("medium"), Skin.dp(3, 2, 5))
    local marker = Skin.dp(11, 9, 15)
    local bar_y = y + math.floor((self.dimen.h - track_h) / 2)
    local ratio = self:_ratio()
    local fill_w = math.floor(self.track_w * ratio)
    local marker_x = x + math.floor((self.track_w - marker) * ratio)
    bb:paintRect(x, bar_y, self.track_w, track_h, Blitbuffer.COLOR_GRAY)
    if fill_w > 0 then bb:paintRect(x, bar_y, math.min(self.track_w, fill_w), track_h, Blitbuffer.COLOR_BLACK) end
    bb:paintRect(marker_x, y + math.floor((self.dimen.h - marker) / 2), marker, marker, Blitbuffer.COLOR_BLACK)
    local value_size = self.value_text:getSize()
    local value_x = x + self.track_w + self.value_gap + math.floor((self.value_w - value_size.w) / 2)
    self.value_text:paintTo(bb, value_x, y + math.floor((self.dimen.h - value_size.h) / 2))
end
function SliderBar:_refresh(force)
    if not self.owner or self.owner.closed then return end
    local interval = Screen.low_pan_rate and .10 or .035
    local now = os.clock()
    if not force and now - (tonumber(self.last_refresh) or 0) < interval then return end
    self.last_refresh = now
    UIManager:setDirty(self.owner, function()
        return "ui", Skin.expand_region(self.dimen)
    end)
end
function SliderBar:setValue(value, force)
    self.value = math.max(self.min, math.min(self.max, tonumber(value) or self.value))
    self.value_text:setText(tostring(math.floor(self.value + .5)))
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

local function primary_cell(entry, width, height, activate, hold_activate)
    local enabled = entry.enabled ~= false
    local icon_h = math.max(Skin.dp(24, 21, 32), math.floor(height * .40))
    local label_h = math.max(Skin.dp(18, 16, 24), math.floor(height * .27))
    local detail_h = math.max(Skin.dp(14, 12, 19), height - icon_h - label_h - Skin.dp(3, 2, 5))
    local content = VerticalGroup:new{
        align = "center",
        icon_box(entry.icon_key or entry.icon, width, icon_h, enabled, Skin.dp(22, 19, 30)),
        centered_text(entry.label or entry.text, width, label_h, Skin.face("cfont", 10.1, 13.7, 8.7), {
            bold = true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }),
        centered_text(entry.detail or "", width, detail_h, Skin.face("smallinfofont", 7.5, 10.1, 6.5), {
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
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

local function device_cell(entry, width, height, activate, hold_activate)
    local enabled = entry.enabled ~= false
    local icon_h = math.max(Skin.dp(23, 20, 31), math.floor(height * .48))
    local label_h = math.max(1, height - icon_h)
    local content = VerticalGroup:new{
        align = "center",
        icon_box(entry.icon_key or entry.icon, width, icon_h, enabled, Skin.dp(20, 17, 27)),
        centered_text(entry.label or entry.text, width, label_h, Skin.face("smallinfofont", 8.2, 11.1, 7.1), {
            bold = entry.bold == true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }),
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() activate(entry.callback, entry.label or entry.key or "设备功能") end,
        hold_callback = entry.hold_callback and function()
            hold_activate(entry.hold_callback, entry.label or entry.key or "设备功能")
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

function Toolbar:handleEvent(event)
    return InputContainer.handleEvent(self, event)
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

function Toolbar:_setting_row(setting, width, height, icon, toggle_callback)
    if type(setting) ~= "table" then return nil end
    local side_w = Skin.dp(54, 46, 72)
    local value_w = Skin.dp(44, 38, 60)
    local gap = Skin.dp(7, 5, 10)
    local track_w = math.max(1, width - side_w - value_w - gap * 2)
    local label = tostring(setting.label or "")
    local enabled = setting.enabled ~= false
    local icon_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = height},
        enabled = enabled,
        callback = function()
            if type(toggle_callback) ~= "function" then return end
            local ok, value = pcall(toggle_callback)
            if not ok then
                logger.warn("[MiuRead][ReaderToolbar] frontlight toggle failed", tostring(value))
                return
            end
            if self._brightness_slider and tonumber(value) then self._brightness_slider:setValue(value, true) end
        end,
    }
    local icon_content = VerticalGroup:new{
        align = "center",
        icon_box(icon, side_w, math.floor(height * .58), enabled, Skin.dp(19, 16, 26)),
        centered_text(label, side_w, math.max(1, height - math.floor(height * .58)),
            Skin.face("smallinfofont", 7.7, 10.4, 6.6), {bold = true}),
    }
    icon_tap[1] = CenterContainer:new{dimen = Geom:new{w = side_w, h = height}, icon_content}

    local slider = SliderBar:new{
        dimen = Geom:new{w = track_w + gap + value_w, h = height},
        track_w = track_w,
        value_w = value_w,
        value_gap = gap,
        min = tonumber(setting.min) or 0,
        max = tonumber(setting.max) or 100,
        value = tonumber(setting.value) or 0,
        owner = self,
        on_change = setting.on_set,
    }
    if setting.kind == "brightness" then self._brightness_slider = slider end
    return HorizontalGroup:new{
        align = "center",
        icon_tap,
        HorizontalSpan:new{width = gap},
        slider,
    }
end

function Toolbar:init()
    self.opts = self.opts or {}
    self.action_locked = false
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local bottom_inset = Skin.dp(8, 6, 14)
    local pad = Skin.dp(10, 8, 16)
    local gap = Skin.dp(7, 5, 10)
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local device_buttons = type(self.opts.device_buttons) == "table" and self.opts.device_buttons or {}
    local frontlight = type(self.opts.frontlight) == "table" and self.opts.frontlight or nil
    local warmth = type(self.opts.warmth) == "table" and self.opts.warmth or nil
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local handle_h = Skin.dp(13, 10, 18)
    local title_h = math.max(Skin.dp(31, 27, 42), math.floor(sh * .031))
    local subtitle_h = tostring(self.opts.subtitle or "") ~= "" and math.max(Skin.dp(19, 16, 26), math.floor(sh * .019)) or 0
    local primary_h = math.max(Skin.dp(58, 50, 78), math.floor(sh * (portrait and .056 or .080)))
    local light_h = math.max(Skin.dp(40, 35, 54), math.floor(sh * (portrait and .039 or .058)))
    local device_h = math.max(Skin.dp(49, 42, 65), math.floor(sh * (portrait and .047 or .067)))
    local light_rows = frontlight and (warmth and 2 or 1) or 0
    local content_h = handle_h + title_h + subtitle_h + gap + primary_h
        + (light_rows > 0 and (gap + light_rows * light_h + (light_rows - 1) * Skin.dp(2, 1, 3)) or 0)
        + (#device_buttons > 0 and (gap + device_h) or 0)
    self.panel_h = math.min(sh - Skin.dp(40, 32, 64), pad * 2 + content_h)
    local panel_y = math.max(0, sh - bottom_inset - self.panel_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = outer_margin, y = panel_y, w = panel_w, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = panel_y,
        Skin.paper(panel_w, self.panel_h, {seed = 3, accent = false}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local handle_w = Skin.dp(36, 30, 50)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = panel_y + math.floor(handle_h * .38),
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))},
        },
    }

    local y = panel_y + pad + handle_h
    local side_w = Skin.dp(45, 39, 60)
    local title_w = math.max(1, content_w - side_w * 2)
    local close_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = title_h},
        callback = function() self:_close() end,
    }
    close_tap[1] = Ui.icon("close", side_w, title_h, Skin.dp(19, 16, 26), {
        face = Skin.face("cfont", 16.5, 21.5, 14), fgcolor = Blitbuffer.COLOR_BLACK,
    })
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        HorizontalGroup:new{
            align = "center",
            Widget:new{dimen = Geom:new{w = side_w, h = title_h}},
            Ui.textbox(tostring(self.opts.title or "阅读"), title_w, title_h,
                Skin.face("cfont", 14.8, 19.5, 12.5), {
                    bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
            close_tap,
        },
    }
    y = y + title_h

    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox(tostring(self.opts.subtitle or ""), content_w, subtitle_h,
                Skin.face("smallinfofont", 8.3, 11.2, 7.2), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
        y = y + subtitle_h
    end

    y = y + gap
    local primary_count = math.max(1, #buttons)
    local primary_w = math.max(1, math.floor(content_w / primary_count))
    for index, entry in ipairs(buttons) do
        local x = outer_margin + pad + (index - 1) * primary_w
        local actual_w = index == primary_count and (outer_margin + pad + content_w - x) or primary_w
        root[#root + 1] = OffsetContainer:new{
            x_off = x,
            y_off = y,
            primary_cell(entry, actual_w, primary_h,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end),
        }
    end
    y = y + primary_h

    if frontlight then
        y = y + gap
        frontlight.kind = "brightness"
        local row = self:_setting_row(frontlight, content_w, light_h, "frontlight", frontlight.on_toggle)
        if row then root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, row} end
        y = y + light_h
        if warmth then
            y = y + Skin.dp(2, 1, 3)
            local warm_row = self:_setting_row(warmth, content_w, light_h, warmth.icon or "☾", nil)
            if warm_row then root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, warm_row} end
            y = y + light_h
        end
    end

    if #device_buttons > 0 then
        y = y + gap
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Skin.divider(content_w, Blitbuffer.COLOR_GRAY),
        }
        local count = #device_buttons
        local cell_w = math.max(1, math.floor(content_w / count))
        for index, entry in ipairs(device_buttons) do
            local x = outer_margin + pad + (index - 1) * cell_w
            local actual_w = index == count and (outer_margin + pad + content_w - x) or cell_w
            root[#root + 1] = OffsetContainer:new{
                x_off = x,
                y_off = y + Skin.dp(2, 1, 3),
                device_cell(entry, actual_w, device_h - Skin.dp(2, 1, 3),
                    function(action, label) self:_activate(action, label) end,
                    function(action, label) self:_activate_hold(action, label) end),
            }
        end
    end

    self[1] = root
end

function Toolbar:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < self.panel_dimen.y or pos.x < self.panel_dimen.x or pos.x > self.panel_dimen.x + self.panel_dimen.w) then
        return self:_close()
    end
    return false
end

function Toolbar:onSwipeDismiss(_, ges)
    if ges and (ges.direction == "south" or ges.direction == "north") then return self:_close() end
    return false
end
function Toolbar:onClose() return self:_close() end
function Toolbar:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen) end)
end
function Toolbar:onCloseWidget()
    local region = self.panel_dimen and Skin.expand_region(self.panel_dimen) or nil
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
