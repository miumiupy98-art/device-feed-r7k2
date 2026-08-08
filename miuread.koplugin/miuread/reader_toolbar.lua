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
        face = Skin.face("smallinfofont", 8.8, 11.8, 7.5),
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
    local marker = Skin.dp(10, 8, 14)
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
    UIManager:setDirty(self.owner, function() return "ui", Skin.expand_region(self.dimen) end)
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

local function action_cell(entry, width, height, activate, hold_activate)
    local enabled = entry.enabled ~= false
    local icon_h = math.max(Skin.dp(23, 20, 31), math.floor(height * .52))
    local label_h = math.max(1, height - icon_h)
    local content = VerticalGroup:new{
        align = "center",
        icon_box(entry.icon_key or entry.icon, width, icon_h, enabled, Skin.dp(20, 17, 27)),
        centered_text(entry.label or entry.text, width, label_h, Skin.face("smallinfofont", 8.3, 11.1, 7.1), {
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
    expanded = false,
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

function Toolbar:_run_inline(action, label, delay)
    if self.closed or type(action) ~= "function" then return true end
    logger.info("[MiuRead][ReaderToolbar] inline", tostring(label or "unknown"))
    local ok, err = pcall(action)
    if not ok then logger.warn("[MiuRead][ReaderToolbar] inline action failed", tostring(err)) end
    UIManager:scheduleIn(delay or .25, function()
        if self.closed then return end
        if type(self.opts.refresh_status) == "function" then
            local ok_status, status = pcall(self.opts.refresh_status)
            if ok_status and type(status) == "table" then
                self.opts.header = status.header or self.opts.header
            end
        end
        self:_rebuild()
    end)
    return true
end

function Toolbar:_setting_row(setting, width, height, icon, toggle_callback)
    if type(setting) ~= "table" then return nil end
    local side_w = Skin.dp(48, 41, 65)
    local value_w = Skin.dp(48, 40, 64)
    local gap = Skin.dp(7, 5, 10)
    local track_w = math.max(1, width - side_w - value_w - gap * 2)
    local enabled = setting.enabled ~= false
    local icon_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = height},
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
        dimen = Geom:new{w = side_w, h = height},
        icon_box(icon, side_w, height, enabled, Skin.dp(19, 16, 26)),
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

function Toolbar:_header_cell(text, width, height, callback, hold_callback, options)
    options = options or {}
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = options.enabled ~= false,
        callback = callback,
        hold_callback = hold_callback,
    }
    tap[1] = centered_text(text, width, height, Skin.face("smallinfofont", options.size or 8.4, 11.4, 7.2), {
        bold = options.bold == true,
        fgcolor = options.enabled == false and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
    })
    return tap
end

function Toolbar:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(9, 7, 16)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(9, 7, 14)
    local gap = Skin.dp(6, 4, 9)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(34, 29, 45), math.floor(sh * .033))
    local primary_h = math.max(Skin.dp(48, 41, 64), math.floor(sh * (portrait and .046 or .067)))
    local light_h = math.max(Skin.dp(36, 31, 49), math.floor(sh * (portrait and .035 or .052)))
    local tools_h = math.max(Skin.dp(46, 39, 61), math.floor(sh * (portrait and .044 or .064)))
    local toggle_h = Skin.dp(26, 22, 34)
    local frontlight = type(self.opts.frontlight) == "table" and self.opts.frontlight or nil
    local warmth = type(self.opts.warmth) == "table" and self.opts.warmth or nil
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local tool_buttons = type(self.opts.tool_buttons) == "table" and self.opts.tool_buttons or {}
    local light_rows = frontlight and (warmth and 2 or 1) or 0
    local content_h = header_h + gap + primary_h
        + (light_rows > 0 and (gap + light_rows * light_h + (light_rows - 1) * Skin.dp(2, 1, 3)) or 0)
        + (self.expanded and #tool_buttons > 0 and (gap + tools_h) or 0)
        + gap + toggle_h
    self.panel_h = math.min(sh - Skin.dp(40, 32, 64), pad * 2 + content_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {seed = 3, accent = false}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local header = type(self.opts.header) == "table" and self.opts.header or {}
    local home_w = Skin.dp(42, 36, 56)
    local right_w = Skin.dp(62, 52, 80)
    local battery_w = Skin.dp(48, 40, 64)
    local title_w = math.max(1, content_w - home_w - right_w * 2 - battery_w)

    local home = TapBox:new{
        dimen = Geom:new{w = home_w, h = header_h},
        enabled = type(header.home_callback) == "function",
        callback = function() self:_activate(header.home_callback, "主页") end,
    }
    home[1] = icon_box("home", home_w, header_h, type(header.home_callback) == "function", Skin.dp(19, 16, 26))

    local book = self:_header_cell(header.title or "正在阅读", title_w, header_h,
        type(header.book_callback) == "function" and function() self:_activate(header.book_callback, "当前书籍") end or nil,
        nil, {bold = true, size = 9.2})
    local wifi = self:_header_cell(header.wifi_label or "Wi-Fi", right_w, header_h,
        type(header.wifi_callback) == "function" and function() self:_run_inline(header.wifi_callback, "Wi-Fi", .8) end or nil,
        type(header.wifi_hold_callback) == "function" and function() self:_activate_hold(header.wifi_hold_callback, "Wi-Fi 列表") end or nil,
        {bold = header.wifi_alert == true})
    local sync = self:_header_cell(header.sync_label or "同步", right_w, header_h,
        type(header.sync_callback) == "function" and function() self:_run_inline(header.sync_callback, "同步", .4) end or nil,
        type(header.sync_hold_callback) == "function" and function() self:_activate_hold(header.sync_hold_callback, "同步设置") end or nil,
        {bold = header.sync_alert == true})
    local battery = self:_header_cell(header.battery_label or "", battery_w, header_h, nil, nil, {size = 8.0})
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        HorizontalGroup:new{align = "center", home, book, wifi, sync, battery},
    }
    y = y + header_h

    if frontlight then
        y = y + gap
        frontlight.kind = "brightness"
        local row = self:_setting_row(frontlight, content_w, light_h, "frontlight", frontlight.on_toggle)
        if row then root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, row} end
        y = y + light_h
        if warmth then
            y = y + Skin.dp(2, 1, 3)
            local warm_row = self:_setting_row(warmth, content_w, light_h, "☾", nil)
            if warm_row then root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, warm_row} end
            y = y + light_h
        end
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
            action_cell(entry, actual_w, primary_h,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end),
        }
    end
    y = y + primary_h

    if self.expanded and #tool_buttons > 0 then
        y = y + gap
        root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, Skin.divider(content_w, Blitbuffer.COLOR_GRAY)}
        local count = #tool_buttons
        local cell_w = math.max(1, math.floor(content_w / count))
        for index, entry in ipairs(tool_buttons) do
            local x = outer_margin + pad + (index - 1) * cell_w
            local actual_w = index == count and (outer_margin + pad + content_w - x) or cell_w
            root[#root + 1] = OffsetContainer:new{
                x_off = x,
                y_off = y + Skin.dp(2, 1, 3),
                action_cell(entry, actual_w, tools_h - Skin.dp(2, 1, 3),
                    function(action, label) self:_activate(action, label) end,
                    function(action, label) self:_activate_hold(action, label) end),
            }
        end
        y = y + tools_h
    end

    y = y + gap
    local toggle = TapBox:new{
        dimen = Geom:new{w = content_w, h = toggle_h},
        callback = function() self:_toggle_tools() end,
    }
    toggle[1] = centered_text(self.expanded and "工具 ︿" or "工具 ﹀", content_w, toggle_h,
        Skin.face("smallinfofont", 8.4, 11.4, 7.2), {bold = true})
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, toggle}

    local handle_w = Skin.dp(36, 30, 50)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = top_inset + self.panel_h - Skin.dp(3, 2, 5),
        LineWidget:new{background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))}},
    }
    self[1] = root
end

function Toolbar:_rebuild()
    if self.closed then return end
    local old = self.panel_dimen and self.panel_dimen:copy() or nil
    self:_build_content()
    local dirty = self.panel_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.panel_dimen.x),
            y = math.min(old.y, self.panel_dimen.y),
            w = math.max(old.x + old.w, self.panel_dimen.x + self.panel_dimen.w) - math.min(old.x, self.panel_dimen.x),
            h = math.max(old.y + old.h, self.panel_dimen.y + self.panel_dimen.h) - math.min(old.y, self.panel_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Toolbar:_toggle_tools()
    self.expanded = not self.expanded
    self:_rebuild()
    return true
end

function Toolbar:init()
    self.opts = self.opts or {}
    self.action_locked = false
    self.expanded = self.opts.expanded == true
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
    if pos and (pos.y < self.panel_dimen.y or pos.y > self.panel_dimen.y + self.panel_dimen.h
        or pos.x < self.panel_dimen.x or pos.x > self.panel_dimen.x + self.panel_dimen.w) then
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
