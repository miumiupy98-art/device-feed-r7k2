local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen
local M = {}

local state = rawget(_G, "__MIUREAD_ORIENTATION_SESSION")
if type(state) ~= "table" then
    state = {
        session_locked = false,
        locked_mode = nil,
        original_rotation = nil,
    }
    rawset(_G, "__MIUREAD_ORIENTATION_SESSION", state)
end
state.session_locked = state.session_locked == true

local function setting_true(key)
    return G_reader_settings and type(G_reader_settings.isTrue) == "function"
        and G_reader_settings:isTrue(key) or false
end

function M.has_gsensor()
    if not Device or type(Device.hasGSensor) ~= "function" then return false end
    local ok, value = pcall(Device.hasGSensor, Device)
    return ok and value == true
end

function M.rotation_mode()
    if not Screen or type(Screen.getRotationMode) ~= "function" then return nil end
    local ok, value = pcall(Screen.getRotationMode, Screen)
    return ok and value or nil
end

function M.rotation_label()
    local mode = M.rotation_mode()
    if not Screen then return "未知" end
    if mode == Screen.DEVICE_ROTATED_CLOCKWISE then return "向右横屏" end
    if mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN then return "倒置竖屏" end
    if mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then return "向左横屏" end
    return "竖屏"
end

function M.is_session_locked()
    return state.session_locked == true
end

function M.status_label()
    if not M.has_gsensor() then return M.rotation_label() end
    if state.session_locked then return "已锁定 · " .. M.rotation_label() end
    if setting_true("input_ignore_gsensor") then return "KOReader 已锁定" end
    if setting_true("input_lock_gsensor") then return "横竖已锁" end
    return "自动旋转"
end

function M.icon_key()
    if state.session_locked or setting_true("input_ignore_gsensor") then
        return "orientation-lock"
    end
    return "orientation-auto"
end

local function remember_original_rotation()
    if state.original_rotation == nil then
        state.original_rotation = M.rotation_mode()
    end
end

local function set_sensor_enabled(enabled)
    if not M.has_gsensor() or type(Device.toggleGSensor) ~= "function" then return true end
    local ok, err = pcall(Device.toggleGSensor, Device, enabled == true)
    if not ok then
        logger.warn("[MiuRead][Orientation] sensor toggle failed", tostring(err))
        return false
    end
    return true
end

function M.lock_current()
    if not M.has_gsensor() then
        return false, "当前设备没有自动旋转传感器"
    end
    remember_original_rotation()
    if not set_sensor_enabled(false) then
        return false, "方向锁定失败"
    end
    state.session_locked = true
    state.locked_mode = M.rotation_mode()
    logger.info("[MiuRead][Orientation] session locked", "mode=", tostring(state.locked_mode))
    return true, "已锁定当前方向"
end

function M.follow_koreader()
    state.session_locked = false
    state.locked_mode = nil
    state.original_rotation = nil
    if M.has_gsensor() then
        local enabled = not setting_true("input_ignore_gsensor")
        if not set_sensor_enabled(enabled) then return false, "恢复 KOReader 方向设置失败" end
        if enabled then return true, "已跟随 KOReader 自动旋转" end
        return true, "已跟随 KOReader；KOReader 当前关闭了自动旋转"
    end
    return true, "当前设备使用手动方向"
end

function M.enable_auto_rotation()
    state.session_locked = false
    state.locked_mode = nil
    state.original_rotation = nil
    if not M.has_gsensor() then
        return false, "当前设备没有自动旋转传感器"
    end
    if setting_true("input_lock_gsensor") then
        UIManager:broadcastEvent(Event:new("SetLockGSensor", false))
    end
    if setting_true("input_ignore_gsensor") then
        UIManager:broadcastEvent(Event:new("ToggleGSensor"))
    elseif not set_sensor_enabled(true) then
        return false, "恢复自动旋转失败"
    end
    logger.info("[MiuRead][Orientation] automatic rotation restored")
    return true, "已恢复自动旋转"
end

function M.set_fixed(mode)
    if mode == nil then return false, "无效的屏幕方向" end
    remember_original_rotation()
    if M.has_gsensor() and not set_sensor_enabled(false) then
        return false, "方向锁定失败"
    end
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    state.session_locked = M.has_gsensor()
    state.locked_mode = mode
    logger.info("[MiuRead][Orientation] fixed", "mode=", tostring(mode), "locked=", tostring(state.session_locked))
    return true, state.session_locked and "已固定屏幕方向" or "已切换屏幕方向"
end

function M.set_portrait()
    return M.set_fixed(Screen and Screen.DEVICE_ROTATED_UPRIGHT or 0)
end

function M.set_landscape()
    return M.set_fixed(Screen and Screen.DEVICE_ROTATED_CLOCKWISE or 1)
end

function M.toggle_session_lock()
    if state.session_locked then return M.follow_koreader() end
    if setting_true("input_ignore_gsensor") then
        return false, "KOReader 当前已关闭自动旋转；长按可选择“恢复自动旋转”"
    end
    return M.lock_current()
end

function M.release_session(reason)
    if not state.session_locked then return false end
    local original = state.original_rotation
    state.session_locked = false
    state.locked_mode = nil
    state.original_rotation = nil
    if M.has_gsensor() then
        set_sensor_enabled(not setting_true("input_ignore_gsensor"))
    end
    if original ~= nil and original ~= M.rotation_mode() then
        UIManager:broadcastEvent(Event:new("SetRotationMode", original))
    end
    logger.info("[MiuRead][Orientation] session released", tostring(reason or "leave MiuRead"))
    return true
end

return M
