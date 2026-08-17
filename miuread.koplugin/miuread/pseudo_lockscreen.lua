local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local SuspendWorkLease = require("miuread.suspend_work_lease")

local ok_pluginshare, PluginShare = pcall(require, "pluginshare")
if not ok_pluginshare then PluginShare = nil end

local M = {}

local KEY = "__MIUREAD_PSEUDO_LOCK_V1"

local function state()
    local value = rawget(_G, KEY)
    if type(value) ~= "table" then
        value = {
            active = false,
            platform = "other",
            system_active = false,
            internal_resume_pending = false,
            exit_requested = false,
            commit_pending = false,
            entered_at = 0,
            generation = 0,
            wake_attempts = 0,
            download_active = false,
            autosuspend_pause_previous = nil,
            autosuspend_pause_owned = false,
            last_power_kind = nil,
            last_power_source = nil,
            last_power_source_name = nil,
            last_power_event_at = 0,
            last_power_self_injected = false,
            injected_expected_kind = nil,
            injected_reason = nil,
            injected_until = 0,
            pending_user_sleep_origin = nil,
            pending_user_sleep_at = 0,
        }
        rawset(_G, KEY, value)
    end
    return value
end

local KINDLE_POWER_SOURCES = {
    [1] = "BUTTON_WAKEUP",
    [2] = "BUTTON_SUSPEND",
    [4] = "HALL_SUSPEND",
    [6] = "HALL_WAKEUP",
}

local function power_source_name(source, kind)
    local numeric = tonumber(source)
    if numeric and KINDLE_POWER_SOURCES[numeric] then return KINDLE_POWER_SOURCES[numeric] end
    return string.format("UNKNOWN_%s(%s)", tostring(kind or "POWER"):upper(), tostring(source or "nil"))
end

local function pause_kindle_autosuspend()
    local s = state()
    if s.autosuspend_pause_owned or not PluginShare then return false end
    s.autosuspend_pause_previous = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    s.autosuspend_pause_owned = true
    logger.info("[MiuRead][PseudoLock] Kindle AutoSuspend paused",
        "previous=", tostring(s.autosuspend_pause_previous))
    return true
end

local function restore_kindle_autosuspend(reason)
    local s = state()
    if not s.autosuspend_pause_owned or not PluginShare then return false end
    PluginShare.pause_auto_suspend = s.autosuspend_pause_previous
    logger.info("[MiuRead][PseudoLock] Kindle AutoSuspend restored",
        "value=", tostring(s.autosuspend_pause_previous),
        "reason=", tostring(reason or "unknown"))
    s.autosuspend_pause_previous = nil
    s.autosuspend_pause_owned = false
    return true
end

local function recent_power_event(kind, max_age)
    local s = state()
    local age = os.time() - (tonumber(s.last_power_event_at) or 0)
    if age < 0 then age = 999 end
    if kind and s.last_power_kind ~= kind then return nil end
    if age > (tonumber(max_age) or 3) then return nil end
    return {
        kind = s.last_power_kind,
        source = tonumber(s.last_power_source),
        name = tostring(s.last_power_source_name or "unknown"),
        self_injected = s.last_power_self_injected == true,
        age = age,
    }
end

local function record_kindle_power_event(kind, source)
    local s = state()
    local now = os.time()
    local numeric = tonumber(source)
    local self_injected = false
    if s.injected_expected_kind == kind and now <= (tonumber(s.injected_until) or 0) then
        self_injected = true
        s.injected_expected_kind = nil
        s.injected_until = 0
    end
    s.last_power_kind = tostring(kind or "unknown")
    s.last_power_source = numeric
    s.last_power_source_name = power_source_name(numeric, kind)
    s.last_power_event_at = now
    s.last_power_self_injected = self_injected
    logger.info("[MiuRead][PseudoLock][PowerEvent]",
        "kind=", tostring(kind or "unknown"),
        "source=", tostring(s.last_power_source_name),
        "self_injected=", tostring(self_injected),
        "active=", tostring(s.active == true),
        "system_active=", tostring(s.system_active == true),
        "generation=", tostring(s.generation or 0),
        "injected_reason=", tostring(s.injected_reason or "none"))
    if self_injected then s.injected_reason = nil end
    return self_injected
end

local function platform_name()
    if type(Device.isKindle) == "function" then
        local ok, yes = pcall(Device.isKindle, Device)
        if ok and yes == true then return "kindle" end
    end
    if type(Device.isKobo) == "function" then
        local ok, yes = pcall(Device.isKobo, Device)
        if ok and yes == true then return "kobo" end
    end
    return "other"
end

local function set_frontlight_hw_off()
    local powerd = Device and Device.powerd
    if not powerd then return false end
    -- Do not alter KOReader's logical brightness setting. A normal Resume will
    -- restore the previously requested level; only the panel LEDs are darkened
    -- while the pseudo lock screen is active.
    if type(powerd.turnOffFrontlightHW) == "function" then
        local ok = pcall(powerd.turnOffFrontlightHW, powerd)
        return ok
    end
    return false
end

local function inhibit_non_power_input()
    if Device and Device.input and type(Device.input.inhibitInput) == "function" then
        pcall(Device.input.inhibitInput, Device.input, true)
    end
end

local function kindle_power_button(reason)
    local s = state()
    local why = tostring(reason or "unknown")
    if why == "download_complete_real_suspend" then
        s.injected_expected_kind = "suspend"
    else
        s.injected_expected_kind = "wake"
    end
    s.injected_reason = why
    s.injected_until = os.time() + 3
    local issued = false
    local backend = "none"
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if ok_lipc and lipc and type(lipc.init) == "function" then
        local ok_handle, handle = pcall(lipc.init, "com.github.koreader.miuread.pseudolock")
        if ok_handle and handle then
            local ok = pcall(handle.set_int_property, handle, "com.lab126.powerd", "powerButton", 1)
            pcall(handle.close, handle)
            issued = ok == true
            backend = "lipc"
        end
    end
    if not issued then
        local ok = os.execute("lipc-set-prop -i com.lab126.powerd powerButton 1 >/dev/null 2>&1")
        issued = ok == true or ok == 0
        backend = "lipc-cli"
    end
    logger.info("[MiuRead][PseudoLock] kindle power transition requested",
        "reason=", why, "backend=", backend,
        "issued=", tostring(issued))
    if not issued then
        s.injected_expected_kind = nil
        s.injected_reason = nil
        s.injected_until = 0
    end
    return issued
end

local function cancel_kobo_real_suspend()
    if type(Device.suspend) == "function" then
        pcall(UIManager.unschedule, UIManager, Device.suspend)
    end
    -- Kobo may have calculated an extended screensaver wait because of extra
    -- anti-ghosting flashes. The pseudo lock owns the screen now, so no delayed
    -- real suspend should remain armed.
    Device.screensaver_suspend_wait_timeout = nil
    logger.info("[MiuRead][PseudoLock] kobo real suspend cancelled")
    return true
end

local function release_pseudo_lease(reason)
    SuspendWorkLease.release("pseudo_lockscreen")
    logger.info("[MiuRead][PseudoLock] lease released", "reason=", tostring(reason or "unknown"))
end

local function clear_runtime(reason)
    local s = state()
    restore_kindle_autosuspend(reason)
    s.active = false
    s.system_active = false
    s.internal_resume_pending = false
    s.exit_requested = false
    s.commit_pending = false
    s.wake_attempts = 0
    s.last_power_kind = nil
    s.last_power_source = nil
    s.last_power_source_name = nil
    s.last_power_event_at = 0
    s.last_power_self_injected = false
    s.injected_expected_kind = nil
    s.injected_reason = nil
    s.injected_until = 0
    s.last_reason = tostring(reason or "clear")
    s.generation = (tonumber(s.generation) or 0) + 1
    release_pseudo_lease(reason)
end

function M.active()
    return state().active == true
end

function M.platform()
    return tostring(state().platform or "other")
end

function M.system_active()
    return state().system_active == true
end

function M.commit_pending()
    return state().commit_pending == true
end

function M.snapshot()
    local s = state()
    return {
        active = s.active == true,
        platform = tostring(s.platform or "other"),
        system_active = s.system_active == true,
        internal_resume_pending = s.internal_resume_pending == true,
        exit_requested = s.exit_requested == true,
        commit_pending = s.commit_pending == true,
        entered_at = tonumber(s.entered_at or 0) or 0,
        generation = tonumber(s.generation or 0) or 0,
        wake_attempts = tonumber(s.wake_attempts or 0) or 0,
        download_active = s.download_active == true,
        last_power_kind = s.last_power_kind,
        last_power_source = tonumber(s.last_power_source),
        last_power_source_name = s.last_power_source_name,
        last_power_self_injected = s.last_power_self_injected == true,
        pending_user_sleep_origin = s.pending_user_sleep_origin,
    }
end

function M.mark_user_sleep(origin)
    local s = state()
    s.pending_user_sleep_origin = tostring(origin or "miuread")
    s.pending_user_sleep_at = os.time()
    logger.info("[MiuRead][PowerEvent] user sleep requested",
        "origin=", s.pending_user_sleep_origin)
    return true
end

function M.consume_user_sleep_origin()
    local s = state()
    local origin = s.pending_user_sleep_origin
    local age = os.time() - (tonumber(s.pending_user_sleep_at) or 0)
    s.pending_user_sleep_origin = nil
    s.pending_user_sleep_at = 0
    if origin and age >= 0 and age <= 5 then return tostring(origin) end
    return nil
end

function M.set_download_active(value)
    local s = state()
    s.download_active = value == true
    if not s.download_active and not s.active then
        s.commit_pending = false
    end
    return true
end

function M.download_active()
    return state().download_active == true
end

-- Keep the raw Amazon powerd source before KOReader turns it into generic
-- Suspend/Resume callbacks. BUTTON_* and HALL_* are materially different for
-- a pseudo lock: opening a magnetic cover is a real user-visible wake, while
-- the BUTTON_WAKEUP generated by MiuRead's own powerButton write is private.
local function install_kindle_power_source_guard()
    local is_kindle = false
    if type(Device.isKindle) == "function" then
        local ok, value = pcall(Device.isKindle, Device)
        is_kindle = ok and value == true
    end
    if not is_kindle then return false end

    if type(Device.intoScreenSaver) == "function"
        and Device.__miuread_pseudo_into_ss_guard ~= true then
        local original_into = Device.intoScreenSaver
        Device.intoScreenSaver = function(self, source, ...)
            record_kindle_power_event("suspend", source)
            return original_into(self, source, ...)
        end
        Device.__miuread_pseudo_into_ss_guard = true
    end

    if type(Device.outofScreenSaver) == "function"
        and Device.__miuread_pseudo_out_ss_guard ~= true then
        local original_out = Device.outofScreenSaver
        Device.outofScreenSaver = function(self, source, ...)
            local self_injected = record_kindle_power_event("wake", source)
            local s = state()
            local numeric = tonumber(source)
            if s.active and not s.commit_pending then
                if numeric == 6 then
                    -- HALL_WAKEUP is an explicit cover-open action. It must
                    -- always escape the pseudo screen or flip-cover users can
                    -- become stuck behind a perfectly healthy background job.
                    s.exit_requested = true
                    logger.info("[MiuRead][PseudoLock] Kindle cover open requests visible wake")
                elseif numeric == 1 and not self_injected and not s.internal_resume_pending then
                    -- Compatibility fallback for a genuine wake that arrives
                    -- while powerd was no longer in our private wake phase.
                    s.exit_requested = true
                    logger.info("[MiuRead][PseudoLock] external Kindle button wake requests visible wake")
                end
            end
            return original_out(self, source, ...)
        end
        Device.__miuread_pseudo_out_ss_guard = true
    end
    return true
end

install_kindle_power_source_guard()

-- Kobo's generic KOReader power path normally disables Wi-Fi before it emits
-- Suspend. For a live MiuRead download that would break the very connection we
-- are trying to preserve. Intercept only that first Power/Suspend edge, paint
-- KOReader's normal sleep screen, run the normal beforeSuspend callbacks, but
-- deliberately skip Wi-Fi shutdown and the kernel-suspend timer. If MiuRead's
-- Suspend callback fails to establish the pseudo lock, fall back to KOReader's
-- normal safe Wi-Fi-off + delayed suspend behavior.
local function install_kobo_power_guard()
    local is_kobo = false
    if type(Device.isKobo) == "function" then
        local ok, value = pcall(Device.isKobo, Device)
        is_kobo = ok and value == true
    end
    if not is_kobo or type(Device.onPowerEvent) ~= "function" then return false end
    if Device.__miuread_pseudo_power_guard == true then return true end
    local original = Device.onPowerEvent
    Device.onPowerEvent = function(self, ev)
        local shared = state()
        -- The pseudo Kobo screen is visual only; no kernel suspend actually
        -- happened. Handle the next Power/Resume as a pure UI unlock instead of
        -- calling the hardware resume path on a device that never slept.
        if shared.active == true and shared.platform == "kobo"
            and self.screen_saver_mode == true and (ev == "Power" or ev == "Resume") then
            if self.is_cover_closed then
                logger.info("[MiuRead][PseudoLock] Kobo wake ignored while sleep cover remains closed")
                return
            end
            local Screensaver = require("ui/screensaver")
            pcall(UIManager.unschedule, UIManager, self.suspend)
            Screensaver:close()
            self.powerd:afterResume()
            logger.info("[MiuRead][PseudoLock] Kobo pseudo screen unlocked without hardware resume")
            return
        end
        if shared.download_active == true and self.screen_saver_mode ~= true
            and (ev == "Power" or ev == "Suspend") then
            local Screensaver = require("ui/screensaver")
            logger.info("[MiuRead][PseudoLock] Kobo pre-suspend intercepted", "event=", tostring(ev))
            Screensaver:setup()
            Screensaver:show()
            if type(self.needsScreenRefreshAfterResume) == "function" and self:needsScreenRefreshAfterResume() then
                self.screen:refreshFull(0, 0, self.screen:getWidth(), self.screen:getHeight())
            end
            UIManager:forceRePaint()
            self.powerd:beforeSuspend()
            if state().active then
                logger.info("[MiuRead][PseudoLock] Kobo kept ACTIVE with native sleep screen")
                return
            end
            logger.warn("[MiuRead][PseudoLock] Kobo pseudo lock unavailable; falling back to real suspend")
            local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
            if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn) == "function"
                and type(NetworkMgr.disableWifi) == "function" then
                local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
                if ok_on and on == true then pcall(NetworkMgr.disableWifi, NetworkMgr) end
            end
            if type(self.rescheduleSuspend) == "function" then
                self:rescheduleSuspend(self.screensaver_suspend_wait_timeout)
            end
            return
        end
        return original(self, ev)
    end
    Device.__miuread_pseudo_power_guard = true
    return true
end

install_kobo_power_guard()

-- Called from MiuRead's Suspend callback after KOReader has already painted the
-- native sleep screen. On Kobo we can cancel the scheduled kernel suspend and
-- simply keep that screen visible. On Kindle Amazon powerd has already entered
-- screenSaver, so beta.11 immediately bounces powerd back to ACTIVE while
-- deliberately keeping KOReader's sleep-screen widget on top.
function M.begin(reason)
    local s = state()
    if s.active then return true, "already_active" end
    local platform = platform_name()
    if platform ~= "kindle" and platform ~= "kobo" then
        return false, "unsupported_platform"
    end
    local lease_ok = SuspendWorkLease.acquire("pseudo_lockscreen")
    if lease_ok ~= true then return false, "lease_failed" end

    s.active = true
    s.platform = platform
    s.system_active = platform == "kobo"
    s.internal_resume_pending = platform == "kindle"
    s.exit_requested = false
    s.commit_pending = false
    s.entered_at = os.time()
    s.wake_attempts = 0
    s.last_reason = tostring(reason or "download")
    s.generation = (tonumber(s.generation) or 0) + 1

    set_frontlight_hw_off()
    if platform == "kobo" then
        cancel_kobo_real_suspend()
    elseif platform == "kindle" then
        -- KOReader restarts AutoSuspend after every Resume. The private wake
        -- used by PseudoLock is not a user interaction, so letting that timer
        -- run can manufacture another Suspend a few minutes later. Keep the
        -- user's original setting and restore it when the pseudo lock ends.
        pause_kindle_autosuspend()
    end
    logger.info("[MiuRead][PseudoLock] entered",
        "platform=", platform, "reason=", tostring(reason or "download"),
        "generation=", tostring(s.generation))
    return true, platform
end

function M.after_suspend()
    local s = state()
    if not s.active or s.platform ~= "kindle" or not s.internal_resume_pending then return false end
    s.wake_attempts = (tonumber(s.wake_attempts) or 0) + 1
    local issued = kindle_power_button("enter_active_pseudo_lock")
    if issued and s.wake_attempts < 2 then
        -- Some firmware ignores a power transition while it is still finishing
        -- the original goingToScreenSaver event. Retry once only if Resume has
        -- not arrived; this is not a periodic wake loop.
        UIManager:scheduleIn(0.8, function()
            local current = state()
            if current.active and current.internal_resume_pending
                and not current.exit_requested and not current.commit_pending then
                current.wake_attempts = (tonumber(current.wake_attempts) or 0) + 1
                kindle_power_button("enter_active_pseudo_lock_retry")
            end
        end)
    end
    return issued
end

-- Kindle's Device:outofScreenSaver normally closes the KOReader sleep-screen
-- widget before broadcasting Resume. During the private wake used to return
-- powerd to ACTIVE, keep that widget in place. This guard is deliberately
-- Kindle-only; Kobo's next Power press must be able to close its native screen.
local function install_screensaver_close_guard()
    local ok, Screensaver = pcall(require, "ui/screensaver")
    if not ok or type(Screensaver) ~= "table" or type(Screensaver.close) ~= "function" then return false end
    if Screensaver.__miuread_pseudo_close_guard == true then return true end
    local original = Screensaver.close
    Screensaver.close = function(self, ...)
        local s = state()
        if s.active and s.platform == "kindle" and s.internal_resume_pending
            and not s.exit_requested and not s.commit_pending then
            logger.info("[MiuRead][PseudoLock] kept sleep-screen widget during internal Kindle wake")
            return false
        end
        return original(self, ...)
    end
    Screensaver.__miuread_pseudo_close_guard = true
    return true
end

install_screensaver_close_guard()

-- Return values:
--   "hold"  = Kindle's private wake; do NOT run normal MiuRead Resume.
--   "exit"  = a real user-visible wake from pseudo lock; run normal Resume.
--   "normal"= pseudo lock is not involved.
function M.on_resume_event()
    local s = state()
    if not s.active then return "normal" end

    if s.platform == "kindle" and s.exit_requested then
        local ev = recent_power_event("wake", 4)
        logger.info("[MiuRead][PseudoLock] user-visible Kindle resume accepted",
            "source=", tostring(ev and ev.name or "explicit_unlock"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "generation=", tostring(s.generation))
        clear_runtime("user_resume")
        return "exit"
    end

    if s.platform == "kindle" and s.internal_resume_pending
        and not s.exit_requested and not s.commit_pending then
        s.internal_resume_pending = false
        s.system_active = true
        inhibit_non_power_input()
        set_frontlight_hw_off()
        logger.info("[MiuRead][PseudoLock] Kindle returned ACTIVE behind retained sleep screen",
            "generation=", tostring(s.generation))
        return "hold"
    end


    if s.platform == "kindle" and not s.commit_pending then
        -- A generic Resume with no authenticated BUTTON/HALL wake is not
        -- enough to expose the UI. Background networking, Amazon powerd and
        -- KOReader can all generate lifecycle Resume edges while the user has
        -- never asked to leave the sleep screen.
        local ev = recent_power_event("wake", 4)
        s.system_active = true
        inhibit_non_power_input()
        set_frontlight_hw_off()
        logger.info("[MiuRead][PseudoLock] unauthenticated Kindle resume held",
            "source=", tostring(ev and ev.name or "unknown"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "generation=", tostring(s.generation))
        return "hold"
    end

    logger.info("[MiuRead][PseudoLock] user-visible resume",
        "platform=", tostring(s.platform), "exit_requested=", tostring(s.exit_requested))
    clear_runtime("user_resume")
    return "exit"
end

-- Called before ordinary duplicate-Suspend handling. beta.11/12 assumed every
-- second Kindle Suspend was a physical power-key press. That is not safe:
-- KOReader AutoSuspend and other internal powerd edges can produce the same
-- generic callback. beta.13 only accepts a recent raw BUTTON_SUSPEND as the
-- user-key path, keeps HALL_SUSPEND/unknown edges locked, and separately lets
-- HALL_WAKEUP escape through on_resume_event.
function M.on_suspend_while_active()
    local s = state()
    if not s.active then return "none" end
    if s.commit_pending then
        logger.info("[MiuRead][PseudoLock] real suspend commit reached",
            "platform=", tostring(s.platform))
        clear_runtime("commit_suspend")
        return "commit"
    end
    if s.platform == "kindle" and s.system_active then
        local ev = recent_power_event("suspend", 3)
        if ev and ev.source == 2 and not ev.self_injected then
            -- AutoSuspend is paused for the lifetime of a Kindle pseudo lock,
            -- so a fresh BUTTON_SUSPEND here is the remaining deliberate
            -- power-button path. We still log the raw source instead of
            -- claiming the generic Suspend itself proves a physical key.
            s.exit_requested = true
            s.internal_resume_pending = true
            s.system_active = false
            logger.info("[MiuRead][PseudoLock] Kindle button suspend requests pseudo unlock",
                "source=", tostring(ev.name), "age=", tostring(ev.age))
            UIManager:scheduleIn(0.15, function()
                local current = state()
                if current.active and current.exit_requested and current.internal_resume_pending then
                    kindle_power_button("user_unlock")
                end
            end)
            return "unlock"
        end

        logger.info("[MiuRead][PseudoLock] internal/unknown Kindle suspend held",
            "source=", tostring(ev and ev.name or "none"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "age=", tostring(ev and ev.age or -1),
            "generation=", tostring(s.generation))
        if ev then
            -- A raw goingToScreenSaver edge really did move Amazon powerd away
            -- from ACTIVE. Bounce it back just like the initial pseudo-lock
            -- entry, but keep exit_requested false so the sleep screen stays
            -- visible and the Resume remains INTERNAL_WAKE. This is important
            -- for HALL_SUSPEND while a download is already locked.
            s.internal_resume_pending = true
            s.system_active = false
            UIManager:scheduleIn(0.15, function()
                local current = state()
                if current.active and current.internal_resume_pending
                    and not current.exit_requested and not current.commit_pending then
                    kindle_power_button("internal_suspend_hold")
                end
            end)
        end
        return "hold"
    end
    return "already_locked"
end

local function other_work_active()
    local snapshot = SuspendWorkLease.snapshot()
    for reason, enabled in pairs(snapshot.reasons or {}) do
        if enabled == true and reason ~= "pseudo_lockscreen" and reason ~= "download" then
            return true, tostring(reason)
        end
    end
    return false, nil
end

local function commit_if_idle()
    local s = state()
    if not s.active or s.commit_pending then return false end
    local busy, reason = other_work_active()
    if busy then
        logger.info("[MiuRead][PseudoLock] real suspend deferred",
            "reason=", tostring(reason or "background_work"))
        UIManager:scheduleIn(0.6, commit_if_idle)
        return false
    end

    s.commit_pending = true
    s.exit_requested = false
    s.internal_resume_pending = false
    if s.platform == "kindle" then
        s.system_active = false
        logger.info("[MiuRead][PseudoLock] download complete; requesting real Kindle suspend")
        kindle_power_button("download_complete_real_suspend")
        return true
    elseif s.platform == "kobo" then
        logger.info("[MiuRead][PseudoLock] download complete; resuming Kobo real suspend")
        -- KOReader deliberately suspends Kobo with Wi-Fi disabled because some
        -- boards can fail or deadlock otherwise. We skipped that shutdown only
        -- while pseudo-locked, so restore the native safety rule at commit.
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn) == "function"
            and type(NetworkMgr.disableWifi) == "function" then
            local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
            if ok_on and on == true then pcall(NetworkMgr.disableWifi, NetworkMgr) end
        end
        clear_runtime("kobo_download_complete")
        if type(Device.rescheduleSuspend) == "function" then
            pcall(Device.rescheduleSuspend, Device, 0.2)
            return true
        elseif type(Device.suspend) == "function" then
            UIManager:scheduleIn(0.2, Device.suspend, Device)
            return true
        end
    end
    return false
end

function M.background_task_done(reason)
    local s = state()
    if not s.active then return false end
    logger.info("[MiuRead][PseudoLock] background task finished",
        "reason=", tostring(reason or "unknown"), "platform=", tostring(s.platform))
    UIManager:scheduleIn(0.05, commit_if_idle)
    return true
end

function M.force_clear(reason)
    if not M.active() then return false end
    clear_runtime(reason or "force_clear")
    return true
end

return M
