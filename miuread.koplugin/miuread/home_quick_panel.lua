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
    local has_detail = detail ~= ""
    local pad = UiScale.dp(compact and 3 or 4, 2, 6)
    local inner_w = math.max(1, width - pad * 2)
    local gap_h = UiScale.dp(3, 2, 5)
    local icon_slot_h = UiScale.dp(compact and 34 or 38, compact and 30 or 34, compact and 44 or 50)
    local label_slot_h = UiScale.dp(compact and 31 or 34, compact and 27 or 30, compact and 40 or 44)
    -- Reserve the same third line in every cell. Without this, Wi-Fi (which
    -- has an SSID detail) becomes taller and its icon is vertically shifted.
    local detail_slot_h = UiScale.dp(compact and 20 or 22, compact and 18 or 20, compact and 26 or 29)
    local icon_size = UiScale.dp(compact and 27 or 30, compact and 24 or 27, compact and 35 or 39)

    local content = VerticalGroup:new{
        align = "center",
        Ui.icon(icon, inner_w, icon_slot_h, icon_size, {
            icon_key = icon,
            icon_path = entry.icon_path,
            face = UiScale.iconFace("cfont", compact and 22 or 25, compact and 29 or 33, compact and 18 or 20),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }),
        VerticalSpan:new{height = gap_h},
        Ui.textbox(label, inner_w, label_slot_h,
            face("smallinfofont", compact and 11.6 or 12.3, compact and 14.8 or 16.0, compact and 10.1 or 10.7), {
                bold = true, alignment = "center", halign = "center",
                height_overflow_show_ellipsis = true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
    }
    content[#content + 1] = Ui.textbox(has_detail and detail or " ", inner_w, detail_slot_h,
        face("smallinfofont", compact and 9.2 or 9.8, compact and 12.0 or 12.8, compact and 8.0 or 8.5), {
            alignment = "center", halign = "center",
            height_overflow_show_ellipsis = true,
            fgcolor = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        })

    local surface = fixed_frame(width, height, {
        bordersize = 0,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
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

    return tappable(width, height, surface,
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
    local margin = math.max(UiScale.dp(11, 9, 18), math.floor(scale.short * .018))
    local gap = UiScale.dp(6, 5, 10)
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local line = UiScale.line("thin")

    -- Keep the default six controls on one row. Custom layouts use the same
    -- six-column grid, so 7–12 controls simply add a second row.
    local columns = 6
    local rows = #buttons > 0 and math.ceil(math.min(#buttons, 12) / columns) or 0

    local title_h = UiScale.dp(52, 47, 70)
    local button_h = UiScale.dp(98, 90, 128)
    local footer_h = (self.opts.on_customize or self.opts.on_tools) and UiScale.dp(48, 43, 64) or 0
    local status_h = (self.opts.status_text and self.opts.status_text ~= "") and UiScale.dp(34, 30, 46) or 0

    self.panel_h = margin * 2 + title_h + line + gap * 2
    if rows > 0 then
        self.panel_h = self.panel_h + rows * button_h + math.max(0, rows - 1) * gap + gap
    end
    if status_h > 0 then self.panel_h = self.panel_h + status_h + gap end
    if footer_h > 0 then self.panel_h = self.panel_h + line + gap + footer_h end
    self.panel_h = math.min(sh - margin, self.panel_h)

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }

    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(children, 0, 0, fixed_frame(sw, self.panel_h, {background = Blitbuffer.COLOR_WHITE}))

    local close_w = UiScale.dp(92, 80, 120)
    local battery_w = UiScale.dp(98, 84, 126)
    local time_w = math.max(1, sw - margin * 2 - close_w - battery_w - gap * 2)

    local title_row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = time_w, h = title_h},
            Ui.text(tostring(self.opts.time_text or os.date("%H:%M")), time_w, title_h,
                face("cfont", 20.5, 28.5), {bold = true, halign = "left"})},
        HorizontalSpan:new{width = gap},
        Ui.text("电量 "..tostring(self.opts.battery_text or "未知"), battery_w, title_h,
            face("smallinfofont", 11.8, 16), {bold = true}),
        HorizontalSpan:new{width = gap},
        tappable(close_w, title_h,
            fixed_frame(close_w, title_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                Ui.text("收起 ↑", close_w, title_h, face("smallinfofont", 11.8, 16), {bold = true})),
            function() self:_close() end),
    }
    self:_add(children, margin, margin, title_row)

    local y = margin + title_h + gap
    self:_add(children, margin, y, LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = sw - margin * 2, h = line},
    })
    y = y + line + gap

    if rows > 0 then
        local button_w = math.floor((sw - margin * 2 - gap * (columns - 1)) / columns)
        for index, entry in ipairs(buttons) do
            if index > 12 then break end
            local row = math.floor((index - 1) / columns)
            local col = (index - 1) % columns
            self:_add(children, margin + col * (button_w + gap), y + row * (button_h + gap),
                panel_button(entry, button_w, button_h, function(action) self:_close(action) end, true))
        end
        y = y + rows * button_h + math.max(0, rows - 1) * gap + gap
    end

    if status_h > 0 and y + status_h <= self.panel_h then
        -- Status/notice is intentionally text-first, not another boxed card.
        self:_add(children, margin, y, Ui.textbox(tostring(self.opts.status_text or ""),
            sw - margin * 2, status_h,
            face("smallinfofont", 10.8, 15), {
                bold = true, alignment = "left", halign = "left",
                height_overflow_show_ellipsis = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }))
        y = y + status_h + gap
    end

    if footer_h > 0 and y + line + gap + footer_h <= self.panel_h then
        self:_add(children, margin, y, LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = sw - margin * 2, h = line},
        })
        y = y + line + gap

        local available_w = sw - margin * 2
        local has_customize = type(self.opts.on_customize) == "function"
        local has_tools = type(self.opts.on_tools) == "function"
        local count = (has_customize and 1 or 0) + (has_tools and 1 or 0)
        local footer_gap = count > 1 and UiScale.dp(18, 14, 26) or 0
        local item_w = count > 0 and math.floor((available_w - footer_gap * math.max(0, count - 1)) / count) or available_w
        local x = margin

        if has_customize then
            local customize = tappable(item_w, footer_h,
                fixed_frame(item_w, footer_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                    Ui.text("自定义", item_w, footer_h, face("cfont", 13.2, 18), {bold = true})),
                function()
                    self:_close(function() self.opts.on_customize() end)
                end)
            self:_add(children, x, y, customize)
            x = x + item_w + footer_gap
        end
        if has_tools then
            local tools = tappable(item_w, footer_h,
                fixed_frame(item_w, footer_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                    Ui.text("工具与维护  ›", item_w, footer_h, face("cfont", 13.2, 18), {bold = true})),
                function()
                    self:_close(function() self.opts.on_tools() end)
                end)
            self:_add(children, x, y, tools)
        end
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
    local started=os.clock()
    QuickPanel.close()
    local ok, panel = pcall(QuickPanelWidget.new, QuickPanelWidget, {opts = opts or {}})
    local built=os.clock()
    if not ok or not panel then
        logger.warn("[MiuRead][QuickPanel] build failed", tostring(panel))
        return nil, tostring(panel)
    end
    live_panel = panel
    UIManager:show(panel, "ui", panel.panel_dimen)
    logger.info("[MiuRead][QuickPanel] build timing",
        "build_ms=",tostring(math.floor((built-started)*1000+.5)),
        "submit_ms=",tostring(math.floor((os.clock()-built)*1000+.5)))
    return panel
end
return QuickPanel
