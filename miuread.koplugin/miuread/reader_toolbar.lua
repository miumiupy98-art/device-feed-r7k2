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
        text = tostring(math.floor(self.value + .5)) .. "%",
        face = Skin.face("smallinfofont", 8.4, 11.2, 7.2),
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
    local track_h = math.max(1, Skin.line("medium"))
    local marker = Skin.dp(8, 7, 11)
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
    UIManager:setDirty(self.owner, function() return "ui", Skin.expand_region(self.dimen, Skin.dp(2, 2, 3)) end)
end
function SliderBar:setValue(value, force)
    self.value = math.max(self.min, math.min(self.max, tonumber(value) or self.value))
    self.value_text:setText(tostring(math.floor(self.value + .5)) .. "%")
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

local function action_cell(entry, width, height, activate, hold_activate, compact)
    local enabled = entry.enabled ~= false
    local icon_h = compact and math.floor(height * .57) or math.floor(height * .60)
    local label_h = math.max(1, height - icon_h)
    local icon_size = compact and Skin.dp(18, 16, 24) or Skin.dp(21, 18, 28)
    local content = VerticalGroup:new{
        align = "center",
        icon_box(entry.icon_key or entry.icon, width, icon_h, enabled, icon_size),
        centered_text(entry.label or entry.text, width, label_h,
            Skin.face("smallinfofont", compact and 7.7 or 8.4, compact and 10.4 or 11.2, compact and 6.5 or 7.1), {
                bold = entry.bold == true or entry.active == true,
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

function Toolbar:_setting_row(setting, width, height, icon, toggle_callback)
    if type(setting) ~= "table" then return nil end
    local icon_w = Skin.dp(42, 36, 56)
    local value_w = Skin.dp(46, 40, 62)
    local gap = Skin.dp(7, 6, 10)
    local track_w = math.max(1, width - icon_w - value_w - gap * 2)
    local enabled = setting.enabled ~= false
    local icon_tap = TapBox:new{
        dimen = Geom:new{w = icon_w, h = height},
        enabled = enabled,
        callback = function()
            if type(toggle_callback) ~= "function" then return end
            local ok, value = pcall(toggle_callback)
            if not ok then
                logger.warn("[MiuRead][ReaderToolbar] light toggle failed", tostring(value))
                return
            end
            if self._brightness_slider and tonumber(value) then self._brightness_slider:setValue(value, true) end
        end,
    }
    icon_tap[1] = CenterContainer:new{
        dimen = Geom:new{w = icon_w, h = height},
        icon_box(icon, icon_w, height, enabled, Skin.dp(18, 16, 24)),
    }
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
    return HorizontalGroup:new{align = "center", icon_tap, HorizontalSpan:new{width = gap}, slider}
end

function Toolbar:_add_action_row(root, entries, x, y, width, height, compact)
    entries = type(entries) == "table" and entries or {}
    if #entries == 0 then return end
    local count = #entries
    local cell_w = math.floor(width / count)
    for index, entry in ipairs(entries) do
        local cell_x = x + (index - 1) * cell_w
        local actual_w = index == count and (x + width - cell_x) or cell_w
        root[#root + 1] = OffsetContainer:new{
            x_off = cell_x,
            y_off = y,
            action_cell(entry, actual_w, height,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end,
                compact),
        }
    end
end

function Toolbar:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh

    -- Fixed geometry by state: no nested/expanding panel, so rows can never
    -- overlap. The only height difference is whether the device has warmth.
    local side_pad = math.max(Skin.dp(16, 13, 26), math.floor(sw * .025))
    local top_pad = Skin.dp(6, 5, 9)
    local bottom_pad = Skin.dp(8, 6, 12)
    local section_gap = Skin.dp(5, 4, 8)
    local row_gap = Skin.dp(2, 2, 4)
    local content_w = math.max(1, sw - side_pad * 2)

    local top_h = math.max(Skin.dp(43, 37, 56), math.floor(sh * (portrait and .040 or .057)))
    local light_h = math.max(Skin.dp(34, 29, 44), math.floor(sh * (portrait and .031 or .045)))
    local main_h = math.max(Skin.dp(54, 47, 70), math.floor(sh * (portrait and .050 or .070)))
    local tool_h = math.max(Skin.dp(50, 43, 65), math.floor(sh * (portrait and .046 or .065)))

    local frontlight = type(self.opts.frontlight) == "table" and self.opts.frontlight or nil
    local warmth = type(self.opts.warmth) == "table" and self.opts.warmth or nil
    local top_actions = type(self.opts.top_actions) == "table" and self.opts.top_actions or {}
    local primary = type(self.opts.primary_actions) == "table" and self.opts.primary_actions or {}
    local secondary = type(self.opts.secondary_actions) == "table" and self.opts.secondary_actions or {}

    local light_rows = frontlight and (warmth and 2 or 1) or 0
    local divider_h = math.max(1, Skin.line("thin"))
    local panel_h = top_pad + top_h
    if light_rows > 0 then panel_h = panel_h + section_gap + light_rows * light_h + (light_rows - 1) * row_gap end
    panel_h = panel_h + section_gap + divider_h + main_h + row_gap + tool_h + bottom_pad
    panel_h = math.min(sh - Skin.dp(32, 26, 52), panel_h)

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_h = panel_h
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = 0,
        Skin.frame(sw, panel_h, {
            bordersize = 0,
            padding = 0,
            radius = 0,
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_WHITE,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_pad
    self:_add_action_row(root, top_actions, side_pad, y, content_w, top_h, true)
    y = y + top_h

    if frontlight then
        y = y + section_gap
        frontlight.kind = "brightness"
        local light = self:_setting_row(frontlight, content_w, light_h, "frontlight", frontlight.on_toggle)
        if light then root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, light} end
        y = y + light_h
        if warmth then
            y = y + row_gap
            local warm = self:_setting_row(warmth, content_w, light_h, "sleep", nil)
            if warm then root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, warm} end
            y = y + light_h
        end
    end

    y = y + section_gap
    root[#root + 1] = OffsetContainer:new{x_off = side_pad, y_off = y, Skin.divider(content_w, Blitbuffer.COLOR_GRAY, divider_h)}
    y = y + divider_h

    self:_add_action_row(root, primary, side_pad, y, content_w, main_h, false)
    y = y + main_h + row_gap
    self:_add_action_row(root, secondary, side_pad, y, content_w, tool_h, true)

    root[#root + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = panel_h - math.max(1, Skin.line("thin")),
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
