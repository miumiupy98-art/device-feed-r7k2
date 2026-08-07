local logger = require("logger")

local TimeZone = {}

local ZONES = {
    {id="Asia/Tokyo", label="日本 · 东京", tz="JST-9"},
    {id="Asia/Shanghai", label="中国大陆 · 北京", tz="CST-8"},
    {id="Asia/Seoul", label="韩国 · 首尔", tz="KST-9"},
    {id="Asia/Taipei", label="台湾 · 台北", tz="CST-8"},
    {id="Asia/Hong_Kong", label="香港", tz="HKT-8"},
    {id="Asia/Singapore", label="新加坡", tz="SGT-8"},
    {id="Europe/Berlin", label="德国 · 柏林", tz="CET-1CEST,M3.5.0/2,M10.5.0/3"},
    {id="Europe/London", label="英国 · 伦敦", tz="GMT0BST,M3.5.0/1,M10.5.0/2"},
    {id="Europe/Helsinki", label="芬兰 · 赫尔辛基", tz="EET-2EEST,M3.5.0/3,M10.5.0/4"},
    {id="America/New_York", label="美国 · 纽约", tz="EST5EDT,M3.2.0/2,M11.1.0/2"},
    {id="America/Chicago", label="美国 · 芝加哥", tz="CST6CDT,M3.2.0/2,M11.1.0/2"},
    {id="America/Denver", label="美国 · 丹佛", tz="MST7MDT,M3.2.0/2,M11.1.0/2"},
    {id="America/Los_Angeles", label="美国 · 洛杉矶", tz="PST8PDT,M3.2.0/2,M11.1.0/2"},
}

local by_id = {}
for _, row in ipairs(ZONES) do by_id[row.id] = row end

local ffi_ok, ffi = pcall(require, "ffi")
local libc
local original_captured = false
local original_tz
local applied_signature

local function load_libc()
    if not ffi_ok or not ffi then return nil end
    if libc then return libc end
    -- Some KOReader modules may already have declared one of these libc
    -- functions. Duplicate cdefs are harmless for us, so ignore that error and
    -- still use ffi.C; individual calls remain protected by pcall.
    pcall(function()
        ffi.cdef[[
            char *getenv(const char *name);
            int setenv(const char *name, const char *value, int overwrite);
            int unsetenv(const char *name);
            void tzset(void);
        ]]
    end)
    libc = ffi.C
    return libc
end

local function capture_original()
    if original_captured then return end
    original_captured = true
    local c = load_libc()
    if not c then return end
    local ok, value = pcall(function()
        local ptr = c.getenv("TZ")
        if ptr == nil then return nil end
        return ffi.string(ptr)
    end)
    if ok then original_tz = value end
end

local function set_tz(value)
    local c = load_libc()
    if not c then return false, "libc timezone functions unavailable" end
    capture_original()
    local ok, err = pcall(function()
        if value == nil or value == "" then c.unsetenv("TZ")
        else c.setenv("TZ", tostring(value), 1) end
        c.tzset()
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function fixed_tz(minutes)
    minutes = math.max(-14 * 60, math.min(14 * 60, math.floor(tonumber(minutes) or 0)))
    local sign = minutes >= 0 and "-" or "+" -- POSIX TZ signs are reversed.
    local absolute = math.abs(minutes)
    local hours = math.floor(absolute / 60)
    local mins = absolute % 60
    if mins > 0 then return string.format("MRT%s%d:%02d", sign, hours, mins) end
    return string.format("MRT%s%d", sign, hours)
end

function TimeZone.zones()
    return ZONES
end

function TimeZone.zone(id)
    return by_id[tostring(id or "")]
end

function TimeZone.normalize(settings)
    settings = type(settings) == "table" and settings or {}
    local mode = tostring(settings.mode or "device")
    if mode ~= "device" and mode ~= "zone" and mode ~= "fixed" then mode = "device" end
    local zone = tostring(settings.zone or "Asia/Tokyo")
    if not by_id[zone] then zone = "Asia/Tokyo" end
    local offset = math.max(-14 * 60, math.min(14 * 60, math.floor(tonumber(settings.offset_minutes) or 540)))
    return {mode=mode, zone=zone, offset_minutes=offset}
end

function TimeZone.apply(settings)
    local normalized = TimeZone.normalize(settings)
    local signature = normalized.mode .. ":" .. normalized.zone .. ":" .. tostring(normalized.offset_minutes)
    if applied_signature == signature then return true end
    local target
    if normalized.mode == "zone" then
        target = by_id[normalized.zone].tz
    elseif normalized.mode == "fixed" then
        target = fixed_tz(normalized.offset_minutes)
    else
        capture_original()
        target = original_tz
    end
    local ok, err = set_tz(target)
    if ok then
        applied_signature = signature
        logger.info("[MiuRead][TimeZone] applied", signature, "TZ=", tostring(target or "device-default"))
        return true
    end
    logger.warn("[MiuRead][TimeZone] apply failed", signature, tostring(err))
    return false, err
end

function TimeZone.label(settings)
    local normalized = TimeZone.normalize(settings)
    if normalized.mode == "device" then return "跟随设备" end
    if normalized.mode == "zone" then return by_id[normalized.zone].label end
    local minutes = normalized.offset_minutes
    local sign = minutes >= 0 and "+" or "-"
    minutes = math.abs(minutes)
    return string.format("UTC%s%02d:%02d", sign, math.floor(minutes / 60), minutes % 60)
end

function TimeZone.parse_offset(text)
    text = tostring(text or ""):gsub("%s+", ""):upper():gsub("^UTC", "")
    local sign, hours, mins = text:match("^([+-]?)(%d%d?):(%d%d)$")
    if not hours then
        sign, hours = text:match("^([+-]?)(%d%d?)$")
        mins = "0"
    end
    if not hours then return nil end
    hours, mins = tonumber(hours), tonumber(mins or 0) or 0
    if not hours or hours > 14 or mins > 59 then return nil end
    local value = hours * 60 + mins
    if sign == "-" then value = -value end
    if value < -14 * 60 or value > 14 * 60 then return nil end
    return value
end

function TimeZone.offset_text(minutes)
    minutes = math.floor(tonumber(minutes) or 0)
    local sign = minutes >= 0 and "+" or "-"
    minutes = math.abs(minutes)
    return string.format("UTC%s%02d:%02d", sign, math.floor(minutes / 60), minutes % 60)
end

return TimeZone
