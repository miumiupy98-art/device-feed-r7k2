local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
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
local TransientGuard = require("miuread.transient_guard")
local UiScale = require("miuread.ui_scale")

local Screen = Device.screen
local live_sheet
local MAX_PRIMARY_ACTIONS = 6

local function clock_ms()
    return math.floor((os.clock() or 0) * 1000 + .5)
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or 0
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
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
        background = options.background or Blitbuffer.COLOR_WHITE,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{w = math.max(1, width - inset * 2), h = math.max(1, height - inset * 2)},
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil) end
    return true
end

local function tappable(width, height, child, callback)
    local tap = TapBox:new{dimen = Geom:new{w = width, h = height}, callback = callback}
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

-- A very small, fixed-cost accent. It suggests a pencil-drawn frame without
-- tracing every edge or doing any unbounded work on the UI thread.
local PencilAccent = Widget:extend{width = 1, height = 1, seed = 1, danger = false}
function PencilAccent:getSize() return Geom:new{w = self.width, h = self.height} end
function PencilAccent:paintTo(bb, x, y)
    if not bb or type(bb.paintRect) ~= "function" then return end
    local t = math.max(1, UiScale.line("thin"))
    local inset = UiScale.dp(5, 4, 8)
    local short = math.max(UiScale.dp(10, 8, 15), math.floor(self.width * .10))
    local color = self.danger and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    local shift = (tonumber(self.seed) or 1) % 2
    -- Six paint calls total, regardless of card dimensions.
    bb:paintRect(x + inset + shift, y + 1, short, t, color)
    bb:paintRect(x + 1, y + inset + shift, t, short, color)
    bb:paintRect(x + self.width - inset - short - shift, y + self.height - t - 1, short, t, color)
    bb:paintRect(x + self.width - t - 1, y + self.height - inset - short - shift, t, short, color)
    bb:paintRect(x + inset + short + UiScale.dp(3, 2, 5), y + 2, UiScale.dp(5, 4, 8), t, color)
    bb:paintRect(x + self.width - inset - short - UiScale.dp(8, 6, 12), y + self.height - t - 2, UiScale.dp(5, 4, 8), t, color)
end

local function light_card(width, height, options, content)
    options = options or {}
    local layers = OverlapGroup:new{
        dimen = Geom:new{w = width, h = height},
        allow_mirroring = false,
    }
    layers[#layers + 1] = fixed_frame(width, height, {
        bordersize = UiScale.line("thin"),
        padding = options.padding or 0,
        radius = UiScale.radius(7, 5, 11),
        background = Blitbuffer.COLOR_WHITE,
        color = options.danger and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }, content)
    layers[#layers + 1] = PencilAccent:new{
        width = width,
        height = height,
        seed = options.seed or 1,
        danger = options.danger == true,
    }
    return layers
end

-- Filled pointer with an open base. It overlaps the panel border by two pixels,
-- covering the seam so the tail and bubble read as one shape. The row count is
-- bounded by pointer height (normally 9-16 rows).
local BubblePointer = Widget:extend{width = 20, height = 10, direction = "up", overlap = 2}
function BubblePointer:getSize() return Geom:new{w = self.width, h = self.height} end
function BubblePointer:paintTo(bb, x, y)
    if not bb or type(bb.paintRect) ~= "function" then return end
    local w = math.max(7, math.floor(self.width or 20))
    local h = math.max(5, math.min(20, math.floor(self.height or 10)))
    local t = math.max(1, UiScale.line("thin"))
    local denom = math.max(1, h - 1)
    for row = 0, h - 1 do
        local step = self.direction == "down" and (h - 1 - row) or row
        local span = math.max(1, math.floor(1 + (w - 1) * step / denom))
        if span % 2 == 0 then span = span + 1 end
        span = math.min(w, span)
        local sx = x + math.floor((w - span) / 2)
        bb:paintRect(sx, y + row, span, 1, Blitbuffer.COLOR_BLACK)
        if span > t * 2 + 1 then
            bb:paintRect(sx + t, y + row, span - t * 2, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local SheetWidget = InputContainer:extend{
    name = "miuread_action_sheet",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    panel_dimen = nil,
    bubble_dimen = nil,
    pending_action = nil,
    _closed = false,
    _first_paint_logged = false,
    _build_started_ms = 0,
}

function SheetWidget:_close(action)
    if action and not self.pending_action then self.pending_action = action end
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    return true
end

function SheetWidget:_card(action, width, height, seed)
    local enabled = action.enabled ~= false
    local icon = tostring(action.icon or (action.danger and "!" or "•"))
    local label = tostring(action.label or action.text or "")
    local detail = tostring(action.detail or "")
    local pad = UiScale.dp(6, 5, 9)
    local icon_w = UiScale.dp(32, 29, 44)
    local arrow_w = action.submenu == true and UiScale.dp(17, 15, 23) or 0
    local inner_h = math.max(1, height - pad * 2)
    local text_w = math.max(1, width - pad * 2 - icon_w - arrow_w)
    local label_h = detail ~= "" and math.floor(inner_h * .55) or inner_h
    local detail_h = math.max(0, inner_h - label_h)

    local text_group = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = label,
            face = UiScale.face("cfont", action.danger and 11.6 or 11.0, action.danger and 17.2 or 16.4, 9.8),
            bold = true,
            width = text_w,
            height = label_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        },
    }
    if detail ~= "" and detail_h > 0 then
        text_group[#text_group + 1] = TextBoxWidget:new{
            text = detail,
            face = UiScale.face("smallinfofont", 7.9, 11.5, 7.1),
            width = text_w,
            height = detail_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }
    end

    local content = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{dimen = Geom:new{w = icon_w, h = inner_h}, TextWidget:new{
            text = icon,
            face = UiScale.iconFace("cfont", 14.2, 20.5, 12),
            bold = true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }},
        LeftContainer:new{dimen = Geom:new{w = text_w, h = inner_h}, text_group},
    }
    if arrow_w > 0 then
        content[#content + 1] = CenterContainer:new{dimen = Geom:new{w = arrow_w, h = inner_h}, TextWidget:new{
            text = "›",
            face = UiScale.iconFace("cfont", 14, 20, 12),
            bold = true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }}
    end

    local card = light_card(width, height, {
        padding = pad,
        danger = action.danger == true,
        seed = seed,
    }, content)
    return tappable(width, height, card, function()
        if not enabled then return end
        self:_close(action.callback)
    end)
end

function SheetWidget:_footer(action, width, height)
    if type(action) ~= "table" then return nil end
    local enabled = action.enabled ~= false
    local layers = OverlapGroup:new{
        dimen = Geom:new{w = width, h = height},
        allow_mirroring = false,
    }
    layers[#layers + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = 0,
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = width, h = math.max(1, UiScale.line("thin"))},
        },
    }
    layers[#layers + 1] = TextBoxWidget:new{
        text = tostring(action.label or action.text or "更多操作  ›"),
        face = UiScale.face("cfont", 9.8, 13.8, 8.4),
        bold = true,
        width = width,
        height = height,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = function()
            if enabled then self:_close(action.callback) end
        end,
    }
    tap[1] = layers
    return tap
end

local function normalized_anchor(anchor)
    if type(anchor) ~= "table" then return nil end
    local x, y = tonumber(anchor.x), tonumber(anchor.y)
    local w, h = tonumber(anchor.w), tonumber(anchor.h)
    if not x or not y then return nil end
    return Geom:new{x = x, y = y, w = math.max(1, w or 1), h = math.max(1, h or 1)}
end

function SheetWidget:_build()
    self._build_started_ms = clock_ms()
    local metrics = UiScale.metrics()
    local sw, sh = metrics.sw, metrics.sh
    local actions = {}
    for _, action in ipairs(type(self.opts.actions) == "table" and self.opts.actions or {}) do
        if type(action) == "table" and action.hidden ~= true then
            actions[#actions + 1] = action
            if #actions >= MAX_PRIMARY_ACTIONS then break end
        end
    end

    local outer_margin = UiScale.dp(10, 8, 18)
    local pad = UiScale.dp(10, 8, 15)
    local gap = UiScale.dp(8, 6, 12)
    local pointer_h = UiScale.dp(11, 9, 16)
    local pointer_w = UiScale.dp(24, 20, 34)
    local pointer_overlap = math.max(1, UiScale.line("thick"))
    local count = #actions
    local ratio
    if self.opts.width_ratio then
        ratio = tonumber(self.opts.width_ratio)
    elseif count <= 2 then
        ratio = metrics.portrait and .58 or .46
    elseif count <= 4 then
        ratio = metrics.portrait and .72 or .58
    else
        ratio = metrics.portrait and .78 or .64
    end
    ratio = clamp(ratio or .74, .44, .86)
    local min_w = math.min(sw - outer_margin * 2, UiScale.dp(300, 270, 500))
    local panel_w = math.floor(clamp(sw * ratio, min_w, sw - outer_margin * 2) + .5)
    local inner_w = math.max(1, panel_w - pad * 2)

    local has_title = tostring(self.opts.title or "") ~= ""
    local has_subtitle = tostring(self.opts.subtitle or "") ~= ""
    local title_h = has_title and UiScale.dp(has_subtitle and 32 or 29, has_subtitle and 29 or 26, has_subtitle and 44 or 39) or 0
    local subtitle_h = has_subtitle and UiScale.dp(21, 19, 29) or 0
    local card_h = UiScale.dp(58, 53, 79)
    local footer_action = type(self.opts.footer_action) == "table" and self.opts.footer_action or nil
    local footer_h = footer_action and UiScale.dp(39, 35, 52) or 0
    local show_close = self.opts.show_close == true
    if show_close and count < MAX_PRIMARY_ACTIONS then
        actions[#actions + 1] = {icon = "×", label = tostring(self.opts.close_label or "关闭"), close_only = true}
        count = #actions
    end
    local columns = count <= 1 and 1 or 2
    local rows = math.max(1, math.ceil(count / columns))
    local card_w = columns == 1 and inner_w or math.floor((inner_w - gap) / 2)
    local header_h = title_h + subtitle_h
    local content_h = header_h + (header_h > 0 and count > 0 and gap or 0)
        + rows * card_h + math.max(0, rows - 1) * gap
        + (footer_h > 0 and (gap + footer_h) or 0)
    local panel_h = pad * 2 + content_h
    local max_h = math.floor(sh * (metrics.portrait and .66 or .82))
    panel_h = math.min(max_h, panel_h)

    local list = VerticalGroup:new{align = "center"}
    if has_title then
        list[#list + 1] = TextBoxWidget:new{
            text = tostring(self.opts.title),
            face = UiScale.face("cfont", 12.8, 18.5, 11.2),
            bold = true,
            width = inner_w,
            height = title_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    if has_subtitle then
        list[#list + 1] = TextBoxWidget:new{
            text = tostring(self.opts.subtitle),
            face = UiScale.face("smallinfofont", 8.2, 12, 7.4),
            width = inner_w,
            height = subtitle_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    if header_h > 0 and count > 0 then list[#list + 1] = VerticalSpan:new{height = gap} end

    local index = 1
    for row = 1, rows do
        local row_group = HorizontalGroup:new{align = "center"}
        for col = 1, columns do
            local action = actions[index]
            if action then
                row_group[#row_group + 1] = self:_card(action, card_w, card_h, index * 3 + row)
            else
                row_group[#row_group + 1] = Widget:new{dimen = Geom:new{w = card_w, h = card_h}}
            end
            if col < columns then row_group[#row_group + 1] = HorizontalSpan:new{width = gap} end
            index = index + 1
        end
        list[#list + 1] = row_group
        if row < rows then list[#list + 1] = VerticalSpan:new{height = gap} end
    end
    if footer_h > 0 then
        list[#list + 1] = VerticalSpan:new{height = gap}
        list[#list + 1] = self:_footer(footer_action, inner_w, footer_h)
    end

    local panel = fixed_frame(panel_w, panel_h, {
        bordersize = UiScale.line("thick"),
        padding = pad,
        radius = UiScale.radius(13, 10, 22),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
    }, list)

    local anchor = normalized_anchor(self.opts.anchor)
    local x = math.floor((sw - panel_w) / 2)
    local y = math.floor((sh - panel_h) / 2)
    local pointer_direction, pointer_x, pointer_y
    if anchor then
        local center_x = anchor.x + anchor.w / 2
        x = math.floor(clamp(center_x - panel_w / 2, outer_margin, sw - outer_margin - panel_w) + .5)
        local below_y = anchor.y + anchor.h
        local below_space = sh - outer_margin - below_y
        local above_space = anchor.y - outer_margin
        local prefer = tostring(self.opts.preferred_direction or "")
        local place_below = (prefer ~= "above" and below_space >= panel_h + pointer_h - pointer_overlap)
            or (above_space < panel_h + pointer_h and below_space >= panel_h + pointer_h - pointer_overlap)
        local place_above = not place_below and above_space >= panel_h + pointer_h - pointer_overlap
        if place_below then
            pointer_direction = "up"
            pointer_y = below_y
            y = pointer_y + pointer_h - pointer_overlap
        elseif place_above then
            pointer_direction = "down"
            y = anchor.y - panel_h - pointer_h + pointer_overlap
            pointer_y = y + panel_h - pointer_overlap
        else
            y = math.floor(clamp(anchor.y + anchor.h / 2 - panel_h / 2, outer_margin, sh - outer_margin - panel_h) + .5)
        end
        if pointer_direction then
            pointer_x = math.floor(clamp(center_x - pointer_w / 2,
                x + UiScale.dp(18, 14, 28),
                x + panel_w - pointer_w - UiScale.dp(18, 14, 28)) + .5)
        end
    else
        x = math.floor(clamp(x, outer_margin, sw - outer_margin - panel_w) + .5)
        y = math.floor(clamp(y, outer_margin, sh - outer_margin - panel_h) + .5)
    end

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = x, y = y, w = panel_w, h = panel_h}
    self.bubble_dimen = self.panel_dimen:copy()
    if pointer_direction then
        self.bubble_dimen = self.bubble_dimen:combine(Geom:new{x = pointer_x, y = pointer_y, w = pointer_w, h = pointer_h})
    end
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    local layers = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    layers[#layers + 1] = OffsetContainer:new{x_off = x, y_off = y, panel}
    if pointer_direction then
        layers[#layers + 1] = OffsetContainer:new{
            x_off = pointer_x,
            y_off = pointer_y,
            BubblePointer:new{width = pointer_w, height = pointer_h, direction = pointer_direction, overlap = pointer_overlap},
        }
    end
    self[1] = layers
    logger.info("[MiuRead][ActionSheet] built", "actions=", tostring(count), "ms=", tostring(clock_ms() - self._build_started_ms))
end

function SheetWidget:init() self:_build() end
function SheetWidget:paintTo(bb, x, y)
    local started = self._first_paint_logged and nil or clock_ms()
    InputContainer.paintTo(self, bb, x, y)
    if started then
        self._first_paint_logged = true
        logger.info("[MiuRead][ActionSheet] first paint", "ms=", tostring(clock_ms() - started))
    end
end
function SheetWidget:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if not pos then return false end
    local d = self.bubble_dimen or self.panel_dimen
    local inside = d and pos.x >= d.x and pos.x <= d.x + d.w and pos.y >= d.y and pos.y <= d.y + d.h
    if not inside then return self:_close() end
    return false
end
function SheetWidget:onSwipeDismiss(_, ges)
    if ges and (ges.direction == "south" or ges.direction == "east") then return self:_close() end
    return false
end
function SheetWidget:onBack() return self:_close() end
function SheetWidget:onScreenResize() return self:_close() end
function SheetWidget:onRotation() return self:_close() end
function SheetWidget:onShow()
    UIManager:setDirty(self, function() return "ui", self.bubble_dimen or self.panel_dimen end)
end
function SheetWidget:onCloseWidget()
    local region = self.bubble_dimen and self.bubble_dimen:copy() or (self.panel_dimen and self.panel_dimen:copy() or nil)
    local action = self.pending_action
    self.pending_action = nil
    if live_sheet == self then live_sheet = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ActionSheet] action failed", tostring(err)) end
        end)
    end
end

local function show_fallback(opts, reason)
    local actions = {}
    for _, action in ipairs(type(opts.actions) == "table" and opts.actions or {}) do
        if type(action) == "table" and action.hidden ~= true then
            actions[#actions + 1] = action
            if #actions >= MAX_PRIMARY_ACTIONS then break end
        end
    end
    local buttons = {}
    local dialog
    for _, action in ipairs(actions) do
        buttons[#buttons + 1] = {{
            text = tostring(action.label or action.text or "操作"),
            enabled = action.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                if action.enabled ~= false and action.callback then
                    UIManager:scheduleIn(.04, function()
                        local ok, err = pcall(action.callback)
                        if not ok then logger.warn("[MiuRead][ActionSheet] fallback action failed", tostring(err)) end
                    end)
                end
            end,
        }}
    end
    local footer = type(opts.footer_action) == "table" and opts.footer_action or nil
    if footer then
        buttons[#buttons + 1] = {{
            text = tostring(footer.label or footer.text or "更多操作"),
            enabled = footer.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                if footer.enabled ~= false and footer.callback then
                    UIManager:scheduleIn(.04, function()
                        local ok, err = pcall(footer.callback)
                        if not ok then logger.warn("[MiuRead][ActionSheet] fallback footer failed", tostring(err)) end
                    end)
                end
            end,
        }}
    end
    buttons[#buttons + 1] = {{text = "关闭", callback = function() UIManager:close(dialog) end}}
    local title = tostring(opts.title or "操作")
    local subtitle = tostring(opts.subtitle or "")
    if subtitle ~= "" then title = title .. "\n\n" .. subtitle end
    dialog = ButtonDialog:new{title = title, title_align = "left", buttons = buttons}
    dialog._miuread_transient = true
    dialog._miuread_modal_surface = true
    logger.warn("[MiuRead][ActionSheet] using fallback", tostring(reason or "unknown"))
    UIManager:show(dialog)
    return dialog
end

local ActionSheet = {}
function ActionSheet.close()
    if live_sheet and not live_sheet._closed then live_sheet:_close() end
    live_sheet = nil
end
function ActionSheet.show(opts)
    TransientGuard.close_all()
    ActionSheet.close()
    opts = opts or {}
    local ok, sheet = pcall(SheetWidget.new, SheetWidget, {opts = opts})
    if not ok or not sheet then
        return show_fallback(opts, sheet)
    end
    live_sheet = sheet
    local shown, show_err = pcall(UIManager.show, UIManager, sheet, "ui", sheet.bubble_dimen or sheet.panel_dimen)
    if not shown then
        live_sheet = nil
        return show_fallback(opts, show_err)
    end
    return sheet
end
return ActionSheet
