local Config = require("miuread.config")
local U = require("miuread.util")
local logger = require("logger")

local PerformanceMode = {}
PerformanceMode.__index = PerformanceMode

local RUNTIME_KEY = "__MIUREAD_PERFORMANCE_RUNTIME"
local runtime = rawget(_G, RUNTIME_KEY)
if type(runtime) ~= "table" then
    runtime = {samples = {}}
    rawset(_G, RUNTIME_KEY, runtime)
end

local function normalize_state(preferences)
    preferences.performance_mode = type(preferences.performance_mode) == "table"
        and preferences.performance_mode or {}
    local state = preferences.performance_mode
    if state.enabled == nil then state.enabled = false end
    if state.auto_detect == nil then state.auto_detect = true end
    state.last_prompt_at = tonumber(state.last_prompt_at or 0) or 0
    state.reminders_disabled = state.reminders_disabled == true
    return state
end

function PerformanceMode:new(store)
    local object = setmetatable({store = store}, self)
    object:_sync_runtime_flag()
    return object
end

function PerformanceMode:_preferences()
    local preferences = self.store:preferences()
    return preferences, normalize_state(preferences)
end

function PerformanceMode:_save(preferences)
    self.store:save_preferences(preferences)
    return true
end

function PerformanceMode:_sync_runtime_flag()
    local preferences, state = self:_preferences()
    local path = tostring(Config.LIGHTWEIGHT_MODE_FLAG or "/tmp/miuread-lightweight-mode.flag")
    if state.enabled then
        local ok = U.atomic_write(path, "1", true) == true
        if not ok then logger.warn("[MiuRead][PerformanceMode] runtime flag write failed", path) end
    else
        os.remove(path)
    end
    return state.enabled
end

function PerformanceMode:status()
    local _, state = self:_preferences()
    return {
        enabled = state.enabled == true,
        auto_detect = state.auto_detect ~= false,
        reminders_disabled = state.reminders_disabled == true,
        last_prompt_at = tonumber(state.last_prompt_at or 0) or 0,
    }
end

function PerformanceMode:enabled()
    return self:status().enabled
end

function PerformanceMode:set_enabled(enabled)
    local preferences, state = self:_preferences()
    state.enabled = enabled == true
    preferences.performance_mode = state
    self:_save(preferences)
    self:_sync_runtime_flag()
    runtime.samples = {}
    logger.info("[MiuRead][PerformanceMode]", state.enabled and "enabled" or "disabled")
    return true
end

function PerformanceMode:set_auto_detect(enabled)
    local preferences, state = self:_preferences()
    state.auto_detect = enabled ~= false
    if state.auto_detect then state.reminders_disabled = false end
    preferences.performance_mode = state
    self:_save(preferences)
    logger.info("[MiuRead][PerformanceMode] auto detect", tostring(state.auto_detect))
    return true
end

function PerformanceMode:disable_reminders()
    local preferences, state = self:_preferences()
    state.auto_detect = false
    state.reminders_disabled = true
    preferences.performance_mode = state
    self:_save(preferences)
    runtime.samples = {}
    logger.info("[MiuRead][PerformanceMode] reminders disabled")
    return true
end

function PerformanceMode:record(kind, elapsed_ms)
    local status = self:status()
    if status.enabled or not status.auto_detect or status.reminders_disabled then return nil end

    local elapsed = math.max(0, tonumber(elapsed_ms) or 0)
    local slow_ms = math.max(100, tonumber(Config.PERFORMANCE_SLOW_MS) or 1200)
    local extreme_ms = math.max(slow_ms, tonumber(Config.PERFORMANCE_EXTREME_MS) or 2500)
    if elapsed < slow_ms then return nil end

    local now = os.time()
    local window = math.max(60, tonumber(Config.PERFORMANCE_WINDOW_SECONDS) or 600)
    local repeat_count = math.max(2, tonumber(Config.PERFORMANCE_REPEAT_COUNT) or 2)
    local cooldown = math.max(3600, tonumber(Config.PERFORMANCE_PROMPT_COOLDOWN) or 7 * 24 * 60 * 60)

    local samples = runtime.samples or {}
    local retained = {}
    for _, sample in ipairs(samples) do
        if now - (tonumber(sample.at) or 0) <= window then retained[#retained + 1] = sample end
    end
    retained[#retained + 1] = {at = now, kind = tostring(kind or "interaction"), elapsed_ms = elapsed}
    runtime.samples = retained

    local extreme = elapsed >= extreme_ms
    if not extreme and #retained < repeat_count then return nil end
    if status.last_prompt_at > 0 and now - status.last_prompt_at < cooldown then return nil end

    local preferences, state = self:_preferences()
    state.last_prompt_at = now
    preferences.performance_mode = state
    self:_save(preferences)
    runtime.samples = {}

    logger.warn("[MiuRead][PerformanceMode] sustained lag detected",
        "kind=", tostring(kind or "interaction"), "elapsed_ms=", tostring(math.floor(elapsed + .5)),
        "extreme=", tostring(extreme))
    return {
        kind = tostring(kind or "interaction"),
        elapsed_ms = elapsed,
        extreme = extreme,
    }
end

PerformanceMode.FLAG_PATH = Config.LIGHTWEIGHT_MODE_FLAG or "/tmp/miuread-lightweight-mode.flag"

return PerformanceMode
