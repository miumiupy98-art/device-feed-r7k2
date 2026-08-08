local DataStorage=require("datastorage")
local PluginLoader=require("pluginloader")

local M={}

local BUILTIN={
    archiveviewer=true,autodim=true,autostandby=true,autosuspend=true,autoturn=true,
    autowarmth=true,batterystat=true,bookshortcuts=true,calibre=true,cloudstorage=true,
    coverbrowser=true,coverimage=true,docsettingtweak=true,exporter=true,externalkeyboard=true,
    gestures=true,hello=true,hotkeys=true,httpinspector=true,japanese=true,keepalive=true,
    kosync=true,movetoarchive=true,newsdownloader=true,opds=true,perceptionexpander=true,
    profiles=true,qrclipboard=true,readtimer=true,SSH=true,statistics=true,systemstat=true,
    terminal=true,texteditor=true,timesync=true,vocabbuilder=true,wallabag=true,
}

local ID_MARKERS={
    "home","desktop","launcher","theme","skin","startmenu","start_menu","filemanager",
    "bookshelf","homescreen","home_screen","fusion","shell","ui",
}

local TEXT_MARKERS={
    "home screen","home page","homescreen","desktop","launcher","theme","skin",
    "file manager","main interface","replace interface","replace home","custom interface",
    "界面","桌面","美化","主页","首页","启动器","文件管理器","书架界面",
}

local function normalize(value)
    return tostring(value or ""):lower()
end

local function path_is_external(path)
    path=tostring(path or "")
    local data_dir=tostring(DataStorage:getDataDir() or "")
    if data_dir=="" or data_dir=="." then return false end
    local prefix=(data_dir:gsub("/+$","")).."/plugins/"
    return path:sub(1,#prefix)==prefix
end

local function id_looks_like_ui(name)
    name=normalize(name)
    if name=="" then return false end
    if name=="ui" or name:match("[_%-]ui$") or name:match("^ui[_%-]") then return true end
    for _,marker in ipairs(ID_MARKERS) do
        if marker~="ui" and name:find(marker,1,true) then return true end
    end
    return false
end

local function text_looks_like_ui(plugin)
    local text=normalize((plugin.fullname or "").." "..(plugin.description or ""))
    for _,marker in ipairs(TEXT_MARKERS) do
        if text:find(marker,1,true) then return true end
    end
    return false
end

local function is_candidate(plugin)
    local name=tostring(plugin and plugin.name or "")
    if name=="" or name=="miuread" or name=="weread" or BUILTIN[name] then return false end
    if plugin.miuread_ui_conflict==true or plugin.ui_takeover==true or plugin.desktop_takeover==true then return true end
    if not path_is_external(plugin.path) and plugin.external~=true then return false end
    return id_looks_like_ui(name) or text_looks_like_ui(plugin)
end

function M.scan()
    local enabled=PluginLoader.enabled_plugins
    if type(enabled)~="table" then
        local ok,rows=pcall(function()
            local active=PluginLoader:loadPlugins()
            return active
        end)
        enabled=ok and rows or {}
    end
    local conflicts={}
    for _,plugin in ipairs(type(enabled)=="table" and enabled or {}) do
        if is_candidate(plugin) then
            conflicts[#conflicts+1]={
                name=tostring(plugin.name or ""),
                label=tostring(plugin.fullname or plugin.name or "其他界面插件"),
                path=tostring(plugin.path or ""),
            }
        end
    end
    table.sort(conflicts,function(a,b) return a.name<b.name end)
    local ids={}
    for _,row in ipairs(conflicts) do ids[#ids+1]=row.name end
    return {conflicts=conflicts,signature=#ids>0 and table.concat(ids,",") or "none"}
end

function M.labels(environment,limit)
    local rows={}
    limit=math.max(1,tonumber(limit) or 3)
    for index,item in ipairs((environment and environment.conflicts) or {}) do
        if index>limit then break end
        rows[#rows+1]=tostring(item.label or item.name or "其他界面插件")
    end
    local extra=#((environment and environment.conflicts) or {})-#rows
    if extra>0 then rows[#rows+1]="另有 "..tostring(extra).." 个" end
    return table.concat(rows,"、")
end

return M
