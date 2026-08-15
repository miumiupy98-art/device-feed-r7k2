local Config=require("miuread.config")
local U=require("miuread.util")
local logger=require("logger")

local RuntimePressure={}
local KEY="__MIUREAD_RUNTIME_PRESSURE"
local state=rawget(_G,KEY)
if type(state)~="table" then
    state={until_at=0,reason=nil,last_memory=nil,last_memory_at=0,last_log_at=0,manual_enabled=false}
    rawset(_G,KEY,state)
end

local function now()
    return os.time()
end

local function lightweight_flag()
    return tostring(Config.LIGHTWEIGHT_MODE_FLAG or "/tmp/miuread-lightweight-mode.flag")
end

local function sync_flag(manual_enabled)
    state.manual_enabled=manual_enabled==true
    local active=(tonumber(state.until_at) or 0)>now()
    if state.manual_enabled or active then
        U.atomic_write(lightweight_flag(),"1",true)
    else
        os.remove(lightweight_flag())
    end
    return state.manual_enabled or active
end

local function parse_meminfo(raw)
    if type(raw)~="string" or raw=="" then return nil end
    local values={}
    for key,value in raw:gmatch("([%w_]+):%s*(%d+)%s*kB") do
        values[key]=tonumber(value)
    end
    local available=values.MemAvailable
    if not available then
        available=(values.MemFree or 0)+(values.Buffers or 0)+(values.Cached or 0)
    end
    if not available or available<=0 then return nil end
    return {
        available_kb=available,
        free_kb=values.MemFree,
        cached_kb=values.Cached,
        total_kb=values.MemTotal,
    }
end

function RuntimePressure.active()
    if (tonumber(state.until_at) or 0)<=now() then
        if state.until_at and state.until_at~=0 then
            state.until_at=0
            state.reason=nil
            sync_flag(state.manual_enabled==true)
        end
        return false
    end
    return true
end

function RuntimePressure.status()
    return {
        active=RuntimePressure.active(),
        until_at=tonumber(state.until_at) or 0,
        reason=state.reason,
        memory=state.last_memory,
    }
end

function RuntimePressure.activate(reason,seconds)
    local duration=math.max(60,tonumber(seconds) or tonumber(Config.PERFORMANCE_AUTO_PROTECT_SECONDS) or 15*60)
    local target=now()+duration
    local was_active=RuntimePressure.active()
    if target>(tonumber(state.until_at) or 0) then state.until_at=target end
    if reason and tostring(reason)~="" then state.reason=tostring(reason) end
    sync_flag(state.manual_enabled==true)
    local current=now()
    if not was_active or current-(tonumber(state.last_log_at) or 0)>=30 then
        state.last_log_at=current
        logger.warn("[MiuRead][RuntimePressure] temporary protection active",
            "reason=",tostring(state.reason or "performance"),
            "seconds=",tostring(math.max(0,(tonumber(state.until_at) or current)-current)))
    end
    return true
end

function RuntimePressure.clear(reason,manual_enabled)
    state.until_at=0
    state.reason=nil
    sync_flag(manual_enabled==true)
    logger.info("[MiuRead][RuntimePressure] temporary protection cleared",tostring(reason or "manual"))
    return true
end

function RuntimePressure.sync_flag(manual_enabled)
    return sync_flag(manual_enabled==true)
end

function RuntimePressure.memory_snapshot(force)
    local current=now()
    local interval=math.max(1,tonumber(Config.BACKGROUND_MEMORY_CHECK_SECONDS) or 3)
    if force~=true and type(state.last_memory)=="table"
        and current-(tonumber(state.last_memory_at) or 0)<interval then
        return state.last_memory
    end
    local raw=U.read_file("/proc/meminfo",true)
    local memory=parse_meminfo(raw)
    state.last_memory_at=current
    if not memory then
        state.last_memory=nil
        return nil
    end
    local soft=math.max(1,tonumber(Config.BACKGROUND_MEMORY_SOFT_KB) or 48*1024)
    local critical=math.max(1,tonumber(Config.BACKGROUND_MEMORY_CRITICAL_KB) or 28*1024)
    if critical>soft then critical=soft end
    memory.level=memory.available_kb<=critical and "critical"
        or (memory.available_kb<=soft and "low" or "normal")
    state.last_memory=memory
    if memory.level=="critical" then
        RuntimePressure.activate("memory_critical",tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60)
    elseif memory.level=="low" then
        RuntimePressure.activate("memory_low",tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60)
    end
    return memory
end

function RuntimePressure.note_worker_failure(label,err)
    local text=tostring(err or ""):lower()
    if text:find("cannot allocate memory",1,true)
        or text:find("not enough memory",1,true)
        or text:find("out of memory",1,true)
        or text:find("enomem",1,true) then
        RuntimePressure.activate("worker_memory:"..tostring(label or "unknown"),
            tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60)
        RuntimePressure.memory_snapshot(true)
        logger.warn("[MiuRead][RuntimePressure] worker allocation failed",
            "label=",tostring(label or "unknown"),"error=",tostring(err or "unknown"))
        return true
    end
    return false
end

return RuntimePressure
