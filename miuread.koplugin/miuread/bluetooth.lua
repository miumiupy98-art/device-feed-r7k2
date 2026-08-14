local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Bluetooth = {}

local cache = {
    known = false,
    supported = false,
    enabled = false,
    updated_at = 0,
}
local primed = false
local STATE_TTL = 2

local function copy_state()
    return {
        known = cache.known == true,
        supported = cache.supported == true,
        enabled = cache.enabled == true,
        updated_at = tonumber(cache.updated_at) or 0,
    }
end

local function is_kindle()
    return type(Device.isKindle) == "function" and Device:isKindle() == true
end

local function read_kindle_state()
    if not is_kindle() then return false, false end
    local handle = io.popen("lipc-get-prop com.lab126.btfd BTstate 2>/dev/null")
    if not handle then return false, false end
    local raw = handle:read("*all") or ""
    handle:close()
    local value = tonumber(raw:match("%-?%d+"))
    if value == nil then return false, false end
    return true, value > 0
end

function Bluetooth.peek()
    return copy_state()
end

function Bluetooth.refresh(force)
    local now = os.time()
    if not force and cache.known and now - (tonumber(cache.updated_at) or 0) < STATE_TTL then
        return copy_state()
    end
    local supported, enabled = read_kindle_state()
    cache.known = true
    cache.supported = supported == true
    cache.enabled = supported == true and enabled == true or false
    cache.updated_at = now
    return copy_state()
end

function Bluetooth.prime(delay)
    if primed then return false end
    primed = true
    UIManager:scheduleIn(tonumber(delay) or .75, function()
        local ok, err = pcall(Bluetooth.refresh, true)
        if not ok then logger.warn("[MiuRead][Bluetooth] capability probe failed", tostring(err)) end
    end)
    return true
end

function Bluetooth.set_enabled(enabled)
    local state = Bluetooth.refresh(false)
    if not state.supported then return false, "unsupported" end
    local value = enabled == true and 0 or 1
    local result = os.execute("lipc-set-prop com.lab126.btfd BTflightMode " .. tostring(value) .. " >/dev/null 2>&1")
    local succeeded = result == 0 or result == true
    if not succeeded then
        cache.updated_at = 0
        return false, "command_failed"
    end
    -- Keep the UI responsive: update optimistically, then let the caller verify
    -- after the Kindle service has had a moment to apply the new state.
    cache.enabled = enabled == true
    cache.updated_at = os.time()
    return true
end

return Bluetooth
