local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local live_guard

local Guard = WidgetContainer:extend{
    name = "miuread_reader_transition_guard",
    _miuread_transition_guard = true,
    covers_fullscreen = false,
    modal = false,
    stop_events_propagation = false,
}

function Guard:init()
    self.dimen = Geom:new{x = 0, y = 0, w = 0, h = 0}
end

function Guard:getSize()
    return self.dimen
end

function Guard:paintTo()
    -- Intentionally invisible. This widget only keeps UIManager's stack alive
    -- while ReaderUI hands control back to FileManager/MiuRead.
end

function Guard:handleEvent()
    return false
end

function Guard:onCloseWidget()
    if live_guard == self then live_guard = nil end
end

local M = {}

local function place_below_reader(readerui)
    if not live_guard or not readerui then return false end
    local stack = UIManager._window_stack or {}
    local guard_index, reader_index
    for i, window in ipairs(stack) do
        local widget = window and window.widget or nil
        if widget == live_guard then guard_index = i end
        if widget == readerui then reader_index = i end
    end
    if not guard_index or not reader_index then return false end
    if guard_index == reader_index - 1 then return true end
    local window = table.remove(stack, guard_index)
    if guard_index < reader_index then reader_index = reader_index - 1 end
    table.insert(stack, math.max(1, reader_index), window)
    return true
end

function M.is_shown()
    return live_guard ~= nil and UIManager:isWidgetShown(live_guard)
end

function M.ensure(readerui, reason)
    if not M.is_shown() then
        live_guard = Guard:new{}
        UIManager:show(live_guard)
        logger.info("[MiuRead][ReaderGuard] installed", tostring(reason or "transition"))
    end
    place_below_reader(readerui)
    return true
end

function M.close(reason)
    local guard = live_guard
    live_guard = nil
    if guard and UIManager:isWidgetShown(guard) then
        UIManager:close(guard)
        logger.info("[MiuRead][ReaderGuard] released", tostring(reason or "surface ready"))
        return true
    end
    return false
end

return M
