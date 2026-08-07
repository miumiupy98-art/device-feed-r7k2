local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_panel

local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = options.radius or 0,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    hold_callback = nil,
    _hold_handled = false,
}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
    if self.hold_callback then
        self.ges_events.HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}}
        self.ges_events.HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}}
    end
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil) end
    return true
end
function TapBox:onHoldSelect()
    self._hold_handled = false
    if self.hold_callback then
        self._hold_handled = true
        self.hold_callback(self.dimen and self.dimen:copy() or nil)
    end
    return true
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    return false
end

local function tappable(width, height, child, callback, hold_callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local function panel_button(entry, width, height, close_callback, compact)
    local label = tostring(entry.label or entry.text or "")
    local detail = tostring(entry.detail or "")
    local icon = tostring(entry.icon_key or entry.icon or "")
    local enabled = entry.enabled ~= false
    local pad = UiScale.dp(compact and 3 or 4, 2, 7)
    local inner_w = math.max(1, width - pad * 2)
    local gap_h = UiScale.dp(2, 1, 4)
    local icon_slot_h = UiScale.dp(compact and 27 or 31, compact and 24 or 27, compact and 37 or 43)
    local label_slot_h = UiScale.dp(compact and 20 or 22, compact and 18 or 20, compact and 27 or 31)
    -- Always reserve the detail slot. Buttons without a subtitle keep the same
    -- icon and title axes as buttons that do have one.
    local detail_slot_h = UiScale.dp(compact and 16 or 18, compact and 14 or 16, compact and 22 or 25)
    local icon_size = UiScale.dp(compact and 22 or 25, compact and 20 or 22, compact and 30 or 34)

    local content = VerticalGroup:new{
        align = "center",
        Ui.icon(icon, inner_w, icon_slot_h, icon_size, {
            icon_key = icon,
            icon_path = entry.icon_path,
            face = UiScale.iconFace("cfont", compact and 18 or 21, compact and 24 or 29, compact and 15 or 17),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }),
        VerticalSpan:new{height = gap_h},
        Ui.textbox(label, inner_w, label_slot_h,
            face("smallinfofont", compact and 9.2 or 10.5, compact and 13 or 15), {
                bold = true, alignment = "center", halign = "center",
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
        Ui.textbox(detail, inner_w, detail_slot_h, face("smallinfofont", 8.2, 11.5), {
            alignment = "center", halign = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }),
    }

    local card = fixed_frame(width, height, {
        bordersize = UiScale.line("thin"),
        padding = pad,
        radius = UiScale.radius(6, 4, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = enabled and Blitbuffer.COLOR_GRAY or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY),
    }, CenterContainer:new{dimen = Geom:new{w = inner_w, h = math.max(1, height - pad * 2)}, content})

    local function run_action(action, anchor)
        if not enabled or type(action) ~= "function" then return end
        if entry.keep_open == true then
            UIManager:nextTick(function()
                local ok, err = pcall(action, anchor)
                if not ok then logger.warn("[MiuRead][QuickPanel] action failed", tostring(err)) end
            end)
            return
        end
        if close_callback then
            close_callback(function() return action(anchor) end)
        end
    end

    return tappable(width, height, card,
        function(anchor) run_action(entry.callback, anchor) end,
        type(entry.hold_callback) == "function"
            and function(anchor) run_action(entry.hold_callback, anchor) end
            or nil)
end

local QuickPanelWidget = InputContainer:extend{
    name = "miuread_quick_panel",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    panel_h = 0,
    _closed = false,
    pending_action = nil,
}

function QuickPanelWidget:handleEvent(event)
    if event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local gesture = ges and ges.ges
        local pointer_action = gesture == "tap" or gesture == "hold" or gesture == "hold_release"
            or gesture == "double_tap" or gesture == "two_finger_tap"
        if not pointer_action and not (ges and ges.direction == "north")
            and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self, event)
end

function QuickPanelWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function QuickPanelWidget:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    return true
end

function QuickPanelWidget:_build()
    local scale = UiScale.metrics()
    local sw, sh = scale.sw, scale.sh
    local portrait = scale.portrait
    -- Leave a little breathing room around the control center. The previous
    -- edge-to-edge cards looked cramped, especially in large text mode.
    local margin = math.max(UiScale.dp(10, 9, 18), math.floor(scale.short * .018))
    local gap = UiScale.dp(7, 5, 12)
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local more_buttons = type(self.opts.more_buttons) == "table" and self.opts.more_buttons or {}
    local more_expanded = self.opts.more_expanded == true

    local preferred_columns = portrait and 6 or 8
    local min_button_w = UiScale.dp(78, 70, 112)
    local possible_columns = math.max(1, math.floor((sw - margin * 2 + gap) / (min_button_w + gap)))
    local columns = math.max(1, math.min(preferred_columns, possible_columns, math.max(1, #buttons)))
    local rows = math.max(1, math.ceil(#buttons / columns))
    local more_columns = math.max(1, math.min(preferred_columns, possible_columns, math.max(1, #more_buttons)))
    local more_rows = more_expanded and math.max(1, math.ceil(#more_buttons / more_columns)) or 0

    local title_h = UiScale.dp(54, 50, 74)
    local status_h = (self.opts.status_text and self.opts.status_text ~= "") and UiScale.dp(30, 27, 42) or 0
    local button_h = UiScale.dp(82, 74, 112)
    local more_button_h = UiScale.dp(74, 66, 102)
    local more_title_h = #more_buttons > 0 and UiScale.dp(40, 35, 52) or 0
    local line = UiScale.line("thin")

    self.panel_h = margin * 2 + title_h + line + gap * 3
        + rows * button_h + math.max(0, rows - 1) * gap
    if more_title_h > 0 then
        self.panel_h = self.panel_h + more_title_h + gap
        if more_expanded then
            self.panel_h = self.panel_h + more_rows * more_button_h + math.max(0, more_rows - 1) * gap
        end
    end
    if status_h > 0 then self.panel_h = self.panel_h + status_h + gap end
    self.panel_h = math.min(sh - margin, self.panel_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }

    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(children, 0, 0, fixed_frame(sw, self.panel_h, {background = Blitbuffer.COLOR_WHITE}))

    local close_w = UiScale.dp(62, 58, 78)
    local customize_w = self.opts.on_customize and UiScale.dp(72, 66, 92) or 0
    local title_w = math.max(1, sw - margin * 2 - close_w - customize_w - gap * (customize_w > 0 and 2 or 1))
    local title_row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = title_w, h = title_h}, VerticalGroup:new{
            align = "left",
            Ui.textbox(tostring(self.opts.title or "快捷控制"), title_w, math.floor(title_h * .56),
                face("cfont", 18.5, 26), {bold = true, alignment = "left"}),
            Ui.textbox(tostring(self.opts.subtitle or ""), title_w, math.ceil(title_h * .44),
                face("smallinfofont", 10.6, 15.5), {alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK}),
        }},
        HorizontalSpan:new{width = gap},
    }
    if customize_w > 0 then
        title_row[#title_row + 1] = tappable(customize_w, title_h, fixed_frame(customize_w, math.max(1, title_h - gap), {
            bordersize = line,
            radius = UiScale.radius(5, 4, 9),
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_GRAY,
        }, Ui.text("自定义", customize_w - UiScale.dp(8, 6, 12), math.max(1, title_h - gap),
            face("smallinfofont", 10, 14), {bold = true})), function()
            self:_close(function()
                if self.opts.on_customize then self.opts.on_customize() end
            end)
        end)
        title_row[#title_row + 1] = HorizontalSpan:new{width = gap}
    end
    title_row[#title_row + 1] = tappable(close_w, title_h, fixed_frame(close_w, math.max(1, title_h - gap), {
            bordersize = line,
            radius = UiScale.radius(5, 4, 9),
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_GRAY,
        }, Ui.text("收起", close_w - UiScale.dp(8, 6, 12), math.max(1, title_h - gap),
            face("smallinfofont", 10, 14), {bold = true})), function()
            self:_close()
        end)
    self:_add(children, margin, margin, title_row)

    local y = margin + title_h + gap
    self:_add(children, margin, y, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = sw - margin * 2, h = line},
    })
    y = y + line + gap

    local button_w = math.floor((sw - margin * 2 - gap * (columns - 1)) / columns)
    for index, entry in ipairs(buttons) do
        local row = math.floor((index - 1) / columns)
        local col = (index - 1) % columns
        self:_add(children, margin + col * (button_w + gap), y + row * (button_h + gap),
            panel_button(entry, button_w, button_h, function(action) self:_close(action) end, false))
    end
    y = y + rows * button_h + math.max(0, rows - 1) * gap + gap

    if more_title_h > 0 and y + more_title_h <= self.panel_h then
        local marker = more_expanded and "⌃" or "⌄"
        local more_header = tappable(sw - margin * 2, more_title_h, fixed_frame(sw - margin * 2, more_title_h, {
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
        }, HorizontalGroup:new{
            align = "center",
            Ui.text("更多功能", sw - margin * 2 - UiScale.dp(42, 38, 50), more_title_h,
                face("cfont", 14.2, 20), {bold = true, halign = "left"}),
            Ui.text(marker, UiScale.dp(42, 38, 50), more_title_h, face("cfont", 14.5, 19), {bold = true}),
        }), function()
            self:_close(function()
                if self.opts.on_toggle_more then self.opts.on_toggle_more(not more_expanded) end
            end)
        end)
        self:_add(children, margin, y, more_header)
        y = y + more_title_h + gap
    end

    if more_expanded and #more_buttons > 0 then
        local more_w = math.floor((sw - margin * 2 - gap * (more_columns - 1)) / more_columns)
        for index, entry in ipairs(more_buttons) do
            local row = math.floor((index - 1) / more_columns)
            local col = (index - 1) % more_columns
            if y + row * (more_button_h + gap) + more_button_h <= self.panel_h then
                self:_add(children, margin + col * (more_w + gap), y + row * (more_button_h + gap),
                    panel_button(entry, more_w, more_button_h, function(action) self:_close(action) end, true))
            end
        end
        y = y + more_rows * more_button_h + math.max(0, more_rows - 1) * gap + gap
    end

    if status_h > 0 and y + status_h <= self.panel_h - gap then
        self:_add(children, margin, y, fixed_frame(sw - margin * 2, status_h, {
            bordersize = line,
            padding = UiScale.dp(3, 2, 5),
            radius = UiScale.radius(4, 3, 8),
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_GRAY,
        }, Ui.textbox(tostring(self.opts.status_text or ""),
            sw - margin * 2 - UiScale.dp(12, 10, 18), status_h - UiScale.dp(6, 4, 10),
            face("smallinfofont", 9.2, 13), {alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK})))
    end

    self:_add(children, 0, self.panel_h - UiScale.line("thick"), LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{w = sw, h = UiScale.line("thick")},
    })
    self[1] = children
end

function QuickPanelWidget:init() self:_build() end

function QuickPanelWidget:onTapDismiss(_, ges)
    if not (ges and ges.pos) then return false end
    if ges.pos.y > self.panel_h then
        self:_close()
        return true
    end
    return false
end

function QuickPanelWidget:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then
        self:_close()
        return true
    end
    return false
end

function QuickPanelWidget:onBack()
    self:_close()
    return true
end
function QuickPanelWidget:onScreenResize()
    self._rotation_close = true
    self:_close(nil, true)
    return true
end
function QuickPanelWidget:onRotation()
    self._rotation_close = true
    self:_close(nil, true)
    return true
end

function QuickPanelWidget:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
end

function QuickPanelWidget:onCloseWidget()
    local region = self.panel_dimen and self.panel_dimen:copy() or nil
    local action = self.pending_action
    self.pending_action = nil
    self._closed = true
    if live_panel == self then live_panel = nil end
    if not self._rotation_close and region then
        UIManager:setDirty(nil, function() return "ui", region end)
    end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][QuickPanel] action failed", tostring(err)) end
        end)
    end
end

local QuickPanel = {}
function QuickPanel.close()
    if live_panel and not live_panel._closed then live_panel:_close(nil, true) end
    live_panel = nil
end
function QuickPanel.show(opts)
    QuickPanel.close()
    local ok, panel = pcall(QuickPanelWidget.new, QuickPanelWidget, {opts = opts or {}})
    if not ok or not panel then
        logger.warn("[MiuRead][QuickPanel] build failed", tostring(panel))
        return nil, tostring(panel)
    end
    live_panel = panel
    UIManager:show(panel, "ui", panel.panel_dimen)
    return panel
end
return QuickPanel
