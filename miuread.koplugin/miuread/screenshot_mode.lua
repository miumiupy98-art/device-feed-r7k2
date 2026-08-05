local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local ActionSheet = require("miuread.action_sheet")

local ScreenshotMode = {}
local generation = 0
local armed = false

local function screenshot_directory()
    local root
    if type(DataStorage.getFullDataDir) == "function" then
        local ok, value = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok then root = value end
    end
    if not root and type(DataStorage.getDataDir) == "function" then
        local ok, value = pcall(DataStorage.getDataDir, DataStorage)
        if ok then root = value end
    end
    root = tostring(root or ".")
    local dir = root:gsub("/$", "") .. "/screenshots"
    U.mkdir(dir)
    return dir
end

local function capture(host, token)
    if not armed or token ~= generation then return false end
    armed = false
    local path = screenshot_directory() .. "/miuread-" .. os.date("%Y%m%d-%H%M%S") .. ".png"
    local screen = Device.screen
    local ok, result = false, "当前设备不支持截图"
    if screen and type(screen.shot) == "function" then
        ok, result = pcall(screen.shot, screen, path)
    elseif screen and type(screen.saveScreenshot) == "function" then
        ok, result = pcall(screen.saveScreenshot, screen, path)
    end
    if ok and result ~= false and U.file_exists(path) then
        logger.info("[MiuRead][Screenshot] saved", path)
        if host and host.toast then host:toast("截图已保存", 1.6) end
        UIManager:setDirty(nil, "full")
        return true
    end
    local err = ok and "设备没有生成截图文件" or result
    logger.warn("[MiuRead][Screenshot] failed", tostring(err))
    if host and host.info then host:info("截图失败：\n" .. tostring(err or "当前设备不支持截图")) end
    return false
end

local function arm(host, seconds)
    generation = generation + 1
    local token = generation
    armed = true
    seconds = math.max(2, tonumber(seconds) or 8)
    if host and host.toast then
        host:toast(tostring(seconds) .. " 秒后截图，可继续操作页面", 2.2)
    end
    UIManager:scheduleIn(seconds, function() capture(host, token) end)
    return true
end

function ScreenshotMode.start(host, anchor)
    local actions = {
        {icon = "5", label = "5 秒后截图", detail = "适合切换一两个页面", callback = function() arm(host, 5) end},
        {icon = "10", label = "10 秒后截图", detail = "适合进入菜单或翻页", callback = function() arm(host, 10) end},
        {icon = "15", label = "15 秒后截图", detail = "留出更多操作时间", callback = function() arm(host, 15) end},
    }
    if armed then
        actions[#actions + 1] = {icon = "×", label = "取消待截图任务", detail = "当前计时将停止", danger = true, callback = function()
            ScreenshotMode.cancel()
            if host and host.toast then host:toast("已取消截图", 1.3) end
        end}
    end
    ActionSheet.show{
        anchor = anchor,
        preferred_direction = "below",
        title = "延时截图",
        subtitle = "选择时间后面板会关闭，期间可以正常操作设备",
        show_close = false,
        actions = actions,
    }
    return true
end

function ScreenshotMode.cancel()
    generation = generation + 1
    armed = false
end

function ScreenshotMode.isArmed()
    return armed == true
end

return ScreenshotMode
