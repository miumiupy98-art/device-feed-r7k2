local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local SuspendWorkLease = require("miuread.suspend_work_lease")

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
        }
        rawset(_G, KEY, value)
    end
    return value
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
        "reason=", tostring(reason or "unknown"), "backend=", backend,
        "issued=", tostring(issued))
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
    s.active = false
    s.system_active = false
    s.internal_resume_pending = false
    s.exit_requested = false
    s.commit_pending = false
    s.wake_attempts = 0
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
    }
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
    if platform == "kobo" then cancel_kobo_real_suspend() end
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

    logger.info("[MiuRead][PseudoLock] user-visible resume",
        "platform=", tostring(s.platform), "exit_requested=", tostring(s.exit_requested))
    clear_runtime("user_resume")
    return "exit"
end

-- Called before ordinary duplicate-Suspend handling. A second Kindle Suspend
-- while the system is ACTIVE behind the pseudo screen is normally the user's
-- next power-key press. Let powerd enter screenSaver, then immediately bounce
-- it out again, this time allowing Screensaver:close so the real UI is shown.
-- A commit request instead means the download has finished and this Suspend
-- must be allowed to continue into real sleep.
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
        s.exit_requested = true
        s.internal_resume_pending = true
        s.system_active = false
        logger.info("[MiuRead][PseudoLock] Kindle power press requests pseudo unlock")
        UIManager:scheduleIn(0.15, function()
            local current = state()
            if current.active and current.exit_requested and current.internal_resume_pending then
                kindle_power_button("user_unlock")
            end
        end)
        return "unlock"
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
