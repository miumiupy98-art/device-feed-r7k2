local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local U = require("miuread.util")

local Size = require("ui/size")

local Screen = Device.screen
local live_popup

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize()
    return self[1]:getSize()
end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local CloseButton = InputContainer:extend{dimen = nil, callback = nil}
function CloseButton:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapClose = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
end
function CloseButton:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end
function CloseButton:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function CloseButton:onTapClose()
    if self.callback then return self.callback() end
    return true
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function clean(value)
    local text = U.clean_utf8 and U.clean_utf8(value) or tostring(value or "")
    return tostring(text or "")
        :gsub("\239\191\189", "")
        :gsub("[%c]+", " ")
        :gsub("%s+", " ")
        :match("^%s*(.-)%s*$") or ""
end

local function display_units(value)
    value = clean(value)
    local units, index, length = 0, 1, #value
    while index <= length do
        local byte = value:byte(index)
        if not byte then break end
        if byte < 0x80 then
            if byte == 0x20 or byte == 0x09 then
                units = units + 0.35
            elseif byte >= 0x30 and byte <= 0x39 then
                units = units + 0.55
            else
                units = units + 0.60
            end
            index = index + 1
        elseif byte < 0xE0 then
            units = units + 1
            index = index + 2
        elseif byte < 0xF0 then
            units = units + 1
            index = index + 3
        else
            units = units + 1
            index = index + 4
        end
    end
    return math.max(1, units)
end

local function make_face(name, size, fallback)
    local requested = clean(name)
    local ok, value
    if requested ~= "" then
        ok, value = pcall(function() return Font:getFace(requested, size) end)
        if ok and value then return value end
    end
    return Font:getFace(fallback or "cfont", size)
end

local NativePopup = InputContainer:extend{
    name = "miuread_thought_native_popup",
    _miuread_transient = true,
    -- This is a transparent full-screen input layer around a smaller popup.
    -- Marking it as opaque prevents ReaderUI from repainting areas exposed when
    -- a dynamically sized page becomes shorter.
    covers_fullscreen = false,
    stop_events_propagation = true,
    source_text = "",
    comments = nil,
    font_size = nil,
    font_name = nil,
    width_ratio = 0.92,
    height_ratio = 0.55,
    on_close_callback = nil,
    on_interact_callback = nil,
    on_error_callback = nil,
    closing = false,
    page_index = 1,
    pages = nil,
    page_changing = false,
    paint_failed = false,
    comments_dimen = nil,
    page_refresh_count = 0,
}

function NativePopup:handleEvent(event)
    if not self.closing and event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and self.on_interact_callback and (ges.ges == "tap" or ges.ges == "swipe") then
            pcall(self.on_interact_callback)
        end
    end
    return InputContainer.handleEvent(self, event)
end

function NativePopup:_fail(stage, err)
    if self.paint_failed or self.closing then return end
    self.paint_failed = true
    logger.err("[MiuRead][ThoughtPopup] native renderer failed", "stage=", tostring(stage or "unknown"), tostring(err or ""))
    UIManager:nextTick(function()
        if self.closing then return end
        local callback = self.on_error_callback
        self.on_error_callback = nil
        self:_close()
        if callback then pcall(callback, tostring(stage or "unknown"), tostring(err or "")) end
    end)
end

function NativePopup:paintTo(bb, x, y)
    local ok, err = xpcall(function()
        InputContainer.paintTo(self, bb, x, y)
    end, debug.traceback)
    if not ok then self:_fail("paint", err) end
end

function NativePopup:_close()
    if self.closing then return true end
    self.closing = true
    UIManager:close(self)
    return true
end

function NativePopup:_text_box(text, face, width, opts)
    opts = opts or {}
    local box = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        width = math.max(1, width),
        alignment = opts.alignment or "left",
        justified = false,
        auto_para_direction = true,
        line_height = opts.line_height or 0.16,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
        height_adjust = true,
    }
    if opts.height then
        box.height = opts.height
        box.height_adjust = false
        box.height_overflow_show_ellipsis = opts.ellipsis ~= false
    end
    return box
end

function NativePopup:_layout_metrics(base_size)
    -- font_size already contains KOReader's device scaling. Preserve the four
    -- user-visible levels instead of squeezing every device into 16–22 px.
    local body_size = math.max(12, math.floor((tonumber(base_size) or 15) + .5))
    local meta_size = math.max(10, math.floor(body_size * .72 + .5))
    local source_size = math.max(11, math.floor(body_size * .82 + .5))
    return {
        body_size = body_size,
        meta_size = meta_size,
        source_size = source_size,
        body_face = make_face(self.font_name, body_size, "cfont"),
        meta_face = make_face(self.font_name, meta_size, "smallinfofont"),
        source_face = make_face(self.font_name, source_size, "smallinfofont"),
        meta_body_gap = math.max(5, math.floor(body_size * .22)),
        entry_gap = math.max(11, math.floor(body_size * .42)),
        body_line_height = 0.20,
        frame_guard = math.max(6, math.floor(body_size * .22)),
    }
end

function NativePopup:_piece_widget(piece, width, metrics)
    local group = VerticalGroup:new{align = "left"}
    local author = clean(piece.author)
    if author == "" then author = "微信读书用户" end
    local likes = tonumber(piece.likes or 0) or 0
    local meta
    if piece.continuation then
        meta = author .. " · 续"
    elseif likes > 0 then
        meta = author .. " · 赞 " .. tostring(likes)
    else
        meta = author
    end
    local content = clean(piece.content)
    if content == "" then content = " " end

    -- Let KOReader measure the author row with the same face it will paint.
    -- A forced height clipped or completely hid author names on later pages on
    -- some Kindle font metrics. Keep it natural and dark enough to remain
    -- visible on e-ink.
    group[#group + 1] = self:_text_box(meta, metrics.meta_face, width, {
        line_height = 0.10,
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    group[#group + 1] = VerticalSpan:new{height = metrics.meta_body_gap}
    group[#group + 1] = self:_text_box(content, metrics.body_face, width, {
        line_height = metrics.body_line_height,
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    return group, math.max(1, group:getSize().h)
end

function NativePopup:_fit_prefix(item, content, maximum_height, width, metrics, continuation)
    local length = math.max(1, U.utf8_len(content))
    local low, high, best, best_height = 1, length, 0, nil
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local prefix = U.utf8_sub(content, 1, middle)
        local _, measured = self:_piece_widget({
            author = item.author,
            likes = item.likes,
            content = prefix,
            continuation = continuation,
            comment_index = item.comment_index,
        }, width, metrics)
        if measured <= maximum_height then
            best, best_height = middle, measured
            low = middle + 1
        else
            high = middle - 1
        end
    end
    if best < 1 then
        best = 1
        local _, measured = self:_piece_widget({
            author = item.author,
            likes = item.likes,
            content = U.utf8_sub(content, 1, 1),
            continuation = continuation,
            comment_index = item.comment_index,
        }, width, metrics)
        best_height = measured
    end
    local prefix = U.utf8_sub(content, 1, best)
    local remainder = U.utf8_sub(content, best + 1, length)
    return prefix, remainder, math.max(1, best_height or maximum_height)
end

function NativePopup:_paginate_comments(width, maximum_height, metrics)
    local comments = type(self.comments) == "table" and self.comments or {}
    if #comments == 0 then return {{}}, {0} end

    local pages, heights = {}, {}
    local page, used = {}, 0
    local function page_height(items)
        local total = 0
        for index, piece in ipairs(items or {}) do
            if index > 1 then total = total + metrics.entry_gap end
            local _, measured = self:_piece_widget(piece, width, metrics)
            total = total + measured
        end
        return total
    end
    local function flush()
        if #page > 0 then
            pages[#pages + 1] = page
            heights[#heights + 1] = used
            page, used = {}, 0
        end
    end
    local function add(piece, height)
        local gap = #page > 0 and metrics.entry_gap or 0
        page[#page + 1] = piece
        used = used + gap + height
    end

    for comment_index, raw in ipairs(comments) do
        local item = {
            author = clean(raw.author),
            likes = tonumber(raw.likes or 0) or 0,
            content = clean(raw.content),
            comment_index = comment_index,
        }
        if item.author == "" then item.author = "微信读书用户" end
        if item.content ~= "" then
            local remaining_content = item.content
            local continuation = false
            while remaining_content ~= "" do
                local gap = #page > 0 and metrics.entry_gap or 0
                local available = math.max(1, maximum_height - used - gap)
                local whole_piece = {
                    author = item.author,
                    likes = item.likes,
                    content = remaining_content,
                    continuation = continuation,
                    comment_index = item.comment_index,
                }
                local _, whole_height = self:_piece_widget(whole_piece, width, metrics)

                if whole_height <= available then
                    add(whole_piece, whole_height)
                    remaining_content = ""
                else
                    -- Do not abandon a large empty area merely because the next
                    -- comment is long. Fit as much of that comment as possible
                    -- into the current page, then continue it on the next page.
                    -- This keeps ordinary pages visually full without enlarging
                    -- the popup.
                    local prefix, remainder, piece_height = self:_fit_prefix(
                        item, remaining_content, available, width, metrics, continuation
                    )
                    if prefix ~= "" and piece_height <= available then
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = prefix,
                            continuation = continuation,
                            comment_index = item.comment_index,
                        }, piece_height)
                        remaining_content = remainder
                        continuation = true
                        if remaining_content ~= "" then flush() end
                    elseif #page > 0 then
                        flush()
                    else
                        -- A single glyph must always make progress, even with
                        -- unusual device font metrics.
                        local forced_prefix, forced_remainder, forced_height = self:_fit_prefix(
                            item, remaining_content, maximum_height, width, metrics, continuation
                        )
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = forced_prefix,
                            continuation = continuation,
                            comment_index = item.comment_index,
                        }, math.min(maximum_height, forced_height))
                        remaining_content = forced_remainder
                        continuation = true
                        if remaining_content ~= "" then flush() end
                    end
                end
            end
        end
    end
    flush()
    if #pages == 0 then return {{}}, {0} end

    -- Balance the last two pages when the final page would otherwise contain
    -- only a tiny amount of text. Moving complete trailing pieces preserves
    -- reading order and avoids a large, unnecessary blank block.
    if #pages >= 2 then
        local previous = pages[#pages - 1]
        local last = pages[#pages]
        local previous_h = page_height(previous)
        local last_h = page_height(last)
        local target = math.floor(maximum_height * 0.62)
        while last_h < target and #previous > 1 do
            local candidate = previous[#previous]
            table.remove(previous, #previous)
            table.insert(last, 1, candidate)
            local next_previous_h = page_height(previous)
            local next_last_h = page_height(last)
            if next_last_h > maximum_height or next_previous_h < maximum_height * 0.38 then
                table.remove(last, 1)
                previous[#previous + 1] = candidate
                break
            end
            previous_h, last_h = next_previous_h, next_last_h
        end
        heights[#heights - 1] = previous_h
        heights[#heights] = last_h
    end
    return pages, heights
end

function NativePopup:_build_source(width, metrics, close_size)
    local source = clean(self.source_text)
    if source == "" then
        local empty = VerticalGroup:new{align = "left"}
        empty[#empty + 1] = Widget:new{dimen = Geom:new{w = width, h = close_size}}
        return empty, close_size
    end

    local available_w = math.max(1, width - close_size - math.max(8, Screen:scaleBySize(6)))
    local line_h = math.max(metrics.source_size + 4, math.floor(metrics.source_size * 1.30))
    local units_per_line = math.max(6, available_w / math.max(1, metrics.source_size))
    local source_units = display_units(source)
    local lines = source_units > units_per_line * 1.35 and 2 or 1
    local source_h = lines * line_h
    local group = VerticalGroup:new{align = "left"}
    group[#group + 1] = self:_text_box("“" .. source .. "”", metrics.source_face, available_w, {
        height = source_h,
        ellipsis = true,
        line_height = 0.10,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    local total_h = math.max(close_size, source_h)
    local current_h = group:getSize().h
    if current_h < total_h then
        group[#group + 1] = VerticalSpan:new{height = total_h - current_h}
        if group.resetLayout then group:resetLayout() end
    end
    return group, total_h
end

function NativePopup:_build_comment_page(width, metrics)
    local page = (self.pages and self.pages[self.page_index]) or {}
    local group = VerticalGroup:new{align = "left"}
    if #page == 0 then
        local empty_h = math.max(metrics.body_size * 2, Screen:scaleBySize(38))
        group[#group + 1] = VerticalSpan:new{height = math.max(6, Screen:scaleBySize(5))}
        group[#group + 1] = self:_text_box("没有评论内容", metrics.meta_face, width, {
            height = empty_h,
            alignment = "center",
            line_height = 0.08,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    else
        for index, piece in ipairs(page) do
            if index > 1 then
                group[#group + 1] = VerticalSpan:new{height = metrics.entry_gap}
            end
            local widget = self:_piece_widget(piece, width, metrics)
            group[#group + 1] = widget
        end
    end

    -- The page border must follow the completed KOReader layout, not the
    -- separate measurements used while deciding pagination.
    if group.resetLayout then group:resetLayout() end
    local final_h = math.max(1, group:getSize().h)
    return group, final_h
end

function NativePopup:_build(reset_pages, anchor_comment)
    local previous_root = self[1]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local border = math.max(1, tonumber(Size.border.window) or 1)
    local radius = math.max(tonumber(Size.radius.window) or 0, Screen:scaleBySize(6))
    local padding = math.max(10, Screen:scaleBySize(8))
    local inset = border + padding
    local base_size = math.max(10, tonumber(self.font_size) or Screen:scaleBySize(15))
    local metrics = self:_layout_metrics(base_size)
    local close_size = math.max(28, math.min(40, math.floor(metrics.body_size * 1.55)))
    local close_inset = math.max(2, Screen:scaleBySize(2))

    local width_ratio = clamp(self.width_ratio, 0.88, 0.94)
    -- Preserve the reading context: dense pages stay around half-screen and
    -- short pages keep their natural height.
    local height_ratio = clamp(self.height_ratio, 0.42, 0.56)
    local side_margin = math.max(14, math.floor(sw * 0.02))
    local vertical_margin = math.max(18, math.floor(sh * 0.03))
    local width = math.min(math.floor(sw * width_ratio), sw - side_margin * 2)
    local maximum_height = math.min(math.floor(sh * height_ratio), sh - vertical_margin * 2)
    local inner_w = math.max(1, width - inset * 2)
    local frame_guard = math.max(4, tonumber(metrics.frame_guard) or 0)
    local comment_w = math.max(1, inner_w - frame_guard * 2)

    local source_group, source_h = self:_build_source(inner_w, metrics, close_size)
    local source_gap = clean(self.source_text) ~= "" and math.max(10, Screen:scaleBySize(7)) or 0
    local bottom_padding = math.max(4, Screen:scaleBySize(3))
    local maximum_comments_h = math.max(
        metrics.body_size * 3,
        maximum_height - inset * 2 - source_h - source_gap - bottom_padding
    )

    if reset_pages or not self.pages then
        self.pages, self.page_heights = self:_paginate_comments(comment_w, maximum_comments_h, metrics)
        self.page_index = clamp(self.page_index, 1, #self.pages)
        if tonumber(anchor_comment) then
            for page_index, page in ipairs(self.pages or {}) do
                local found = false
                for _, piece in ipairs(page or {}) do
                    if tonumber(piece.comment_index) == tonumber(anchor_comment) then
                        self.page_index = page_index
                        found = true
                        break
                    end
                end
                if found then break end
            end
        end
    end

    local comment_group, comments_h = self:_build_comment_page(comment_w, metrics)
    local guarded_comments = HorizontalGroup:new{
        HorizontalSpan:new{width = frame_guard},
        comment_group,
        HorizontalSpan:new{width = frame_guard},
    }

    local content_group = VerticalGroup:new{align = "left"}
    content_group[#content_group + 1] = source_group
    if source_gap > 0 then content_group[#content_group + 1] = VerticalSpan:new{height = source_gap} end
    content_group[#content_group + 1] = guarded_comments
    content_group[#content_group + 1] = VerticalSpan:new{height = bottom_padding}
    if content_group.resetLayout then content_group:resetLayout() end

    local surface = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = border,
        radius = radius,
        padding = padding,
        margin = 0,
        content_group,
    }
    local natural_size = surface:getSize()
    local height = math.max(natural_size.h, close_size + inset * 2)
    local popup_x = math.floor((sw - width) / 2)
    local popup_y = math.floor((sh - maximum_height) / 2)
    local close_x = width - close_size - inset + close_inset
    local close_y = inset - close_inset

    self.width, self.height = width, height
    self.popup_dimen = Geom:new{x = popup_x, y = popup_y, w = width, h = height}
    self.comments_dimen = Geom:new{
        x = popup_x + inset + frame_guard,
        y = popup_y + inset + source_h + source_gap,
        w = comment_w,
        h = math.max(1, comments_h),
    }
    self.close_dimen = Geom:new{
        x = popup_x + close_x,
        y = popup_y + close_y,
        w = close_size,
        h = close_size,
    }
    self.frame_style = {bordersize = border, radius = radius}

    local close = CloseButton:new{
        dimen = Geom:new{w = close_size, h = close_size},
        callback = function() return self:_close() end,
    }
    close[1] = CenterContainer:new{
        dimen = Geom:new{w = close_size, h = close_size},
        TextWidget:new{
            text = "×",
            face = Font:getFace("cfont", math.max(13, math.floor(metrics.meta_size * .92))),
            bold = false,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }

    local popup_group = OverlapGroup:new{
        dimen = Geom:new{w = width, h = height},
        allow_mirroring = false,
        surface,
        OffsetContainer:new{x_off = close_x, y_off = close_y, close},
    }
    local root_offset = OffsetContainer:new{x_off = popup_x, y_off = popup_y, popup_group}
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        root_offset,
    }

    self._layout = {
        inset = inset,
        close_size = close_size,
        width = width,
        comment_w = comment_w,
        metrics = metrics,
    }
    self.comment_group = comment_group
    self.guarded_comments = guarded_comments
    self.content_group = content_group
    self.surface = surface
    self.popup_group = popup_group
    self.close_button = close

    if previous_root and previous_root ~= self[1] and type(previous_root.free) == "function" then
        pcall(previous_root.free, previous_root)
    end
end

-- Keep the source, frame and close control alive across page turns. Only the
-- comment subtree is replaced, then the cached layout sizes are recalculated.
function NativePopup:_replace_comment_page()
    local layout = self._layout
    if not layout or not self.guarded_comments or not self.content_group or not self.surface then
        local previous = self.popup_dimen and self.popup_dimen:copy() or nil
        self:_build(false)
        return previous, self.popup_dimen and self.popup_dimen:copy() or nil
    end

    local previous_popup = self.popup_dimen and self.popup_dimen:copy() or nil
    local previous_group = self.comment_group
    local comment_group, comments_h = self:_build_comment_page(layout.comment_w, layout.metrics)

    self.guarded_comments[2] = comment_group
    self.comment_group = comment_group
    if self.guarded_comments.resetLayout then self.guarded_comments:resetLayout() end
    if self.content_group.resetLayout then self.content_group:resetLayout() end

    local natural_size = self.surface:getSize()
    local height = math.max(natural_size.h, layout.close_size + layout.inset * 2)
    self.height = height
    self.popup_dimen.h = height
    self.comments_dimen.h = math.max(1, comments_h)

    if self.surface.dimen then
        self.surface.dimen.w = natural_size.w
        self.surface.dimen.h = natural_size.h
    end
    if self.popup_group then
        self.popup_group.dimen.w = layout.width
        self.popup_group.dimen.h = height
        self.popup_group._size = self.popup_group._size or {}
        self.popup_group._size.w = layout.width
        self.popup_group._size.h = height
    end

    if previous_group and previous_group ~= comment_group and type(previous_group.free) == "function" then
        pcall(previous_group.free, previous_group)
    end
    return previous_popup, self.popup_dimen:copy()
end

function NativePopup:_change_page(delta)
    if self.closing or self.paint_failed or self.page_changing then return true end
    local pages = self.pages or {}
    local target = self.page_index + (tonumber(delta) or 0)
    if target < 1 or target > #pages or target == self.page_index then return true end

    self.page_changing = true
    local previous_index = self.page_index
    local ok, err = xpcall(function()
        self.page_index = target
        local previous_popup, current_popup = self:_replace_comment_page()
        self.page_refresh_count = (tonumber(self.page_refresh_count) or 0) + 1

        local dirty=current_popup or previous_popup
        if previous_popup and current_popup then
            local left=math.min(previous_popup.x,current_popup.x)
            local top=math.min(previous_popup.y,current_popup.y)
            local right=math.max(previous_popup.x+previous_popup.w,current_popup.x+current_popup.w)
            local bottom=math.max(previous_popup.y+previous_popup.h,current_popup.y+current_popup.h)
            dirty=Geom:new{x=left,y=top,w=right-left,h=bottom-top}
        end
        if previous_popup and current_popup
            and (previous_popup.x~=current_popup.x or previous_popup.y~=current_popup.y
                or previous_popup.w~=current_popup.w or previous_popup.h~=current_popup.h) then
            -- A size change exposes or covers ReaderUI pixels. Repaint the
            -- complete old/new union from bottom to top, then draw the new
            -- popup once. This preserves MiuRead's dynamic height without
            -- leaving the previous page below it.
            UIManager:setDirty("all",function() return "ui",dirty end)
        else
            UIManager:setDirty(self,function() return "ui",dirty end)
        end
    end, debug.traceback)
    if not ok then
        self.page_changing = false
        self.page_index = previous_index
        self:_fail("page", err)
    else
        if self.on_interact_callback then pcall(self.on_interact_callback) end
        UIManager:scheduleIn(.10, function()
            if not self.closing then self.page_changing = false end
            collectgarbage("step", 12)
        end)
    end
    return true
end

function NativePopup:updateFont(font_size, font_name)
    if self.closing then return false end
    local previous = self.popup_dimen and self.popup_dimen:copy() or nil
    local current_page = self.pages and self.pages[self.page_index] or nil
    local anchor_comment = current_page and current_page[1] and current_page[1].comment_index or nil
    self.font_size = tonumber(font_size) or self.font_size
    self.font_name = font_name
    self.page_index = 1
    self:_build(true, anchor_comment)
    local current = self.popup_dimen and self.popup_dimen:copy() or nil
    local dirty = current or previous
    if previous and current then
        local left = math.min(previous.x, current.x)
        local top = math.min(previous.y, current.y)
        local right = math.max(previous.x + previous.w, current.x + current.w)
        local bottom = math.max(previous.y + previous.h, current.y + current.h)
        dirty = Geom:new{x = left, y = top, w = right - left, h = bottom - top}
    end
    UIManager:setDirty("all", function() return "ui", dirty end)
    return true
end

function NativePopup:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPage = {GestureRange:new{ges = "tap", range = self.dimen}},
        }
    end
    if Device:hasKeys() and Device.input and Device.input.group then
        local group = Device.input.group
        self.key_events = {}
        if group.Back then self.key_events.Close = {{group.Back}} end
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.Previous = {{previous}} end
        if following then self.key_events.Next = {{following}} end
    end
    self:_build(true)
end

function NativePopup:onShow()
    UIManager:setDirty(self, function() return "partial", self.popup_dimen end)
end

function NativePopup:onTapPage(_, ges)
    local pos = ges and ges.pos
    if not pos then return false end
    if self.close_dimen and not pos:notIntersectWith(self.close_dimen) then return self:_close() end
    if pos:notIntersectWith(self.popup_dimen) then return self:_close() end
    if pos.x < self.popup_dimen.x + math.floor(self.popup_dimen.w / 2) then
        return self:_change_page(-1)
    end
    return self:_change_page(1)
end

function NativePopup:onPrevious() return self:_change_page(-1) end
function NativePopup:onNext() return self:_change_page(1) end
function NativePopup:onClose() return self:_close() end

function NativePopup:onCloseWidget()
    local region = self.popup_dimen and self.popup_dimen:copy() or nil
    self.closing = true
    if live_popup == self then live_popup = nil end
    self.page_changing = false
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    if region then UIManager:setDirty("all", function() return "partial", region end) end
end

local M = {}
function M.show(opts)
    opts = opts or {}
    local popup = NativePopup:new{
        source_text = opts.source_text,
        comments = opts.comments,
        font_size = opts.font_size,
        font_name = opts.font_name,
        width_ratio = opts.width_ratio,
        height_ratio = opts.height_ratio,
        on_close_callback = opts.on_close,
        on_interact_callback = opts.on_interact,
        on_error_callback = opts.on_error,
    }
    live_popup = popup
    UIManager:show(popup, "partial", popup.popup_dimen)
    return popup
end

function M.refresh_font(font_size, font_name)
    if not live_popup or live_popup.closing then return false end
    return live_popup:updateFont(font_size, font_name)
end

return M
