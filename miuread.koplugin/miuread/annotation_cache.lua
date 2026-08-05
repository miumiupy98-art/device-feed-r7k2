local Json = require("miuread.json")
local U = require("miuread.util")

local Cache = {}

local function account_hash(value)
    local hash=5381
    value=tostring(value or "")
    for index=1,#value do hash=(hash*33+value:byte(index))%2147483647 end
    return string.format("a%08x",hash)
end

function Cache.account_key(store)
    local auth=store and store:auth() or {}
    local account=type(auth.account)=="table" and auth.account or {}
    local vid=tostring(account.vid or "")
    return vid~="" and account_hash(vid) or "anonymous"
end

local function path_for(root,uid,account_key)
    return tostring(root).."/chapters/"..U.id_name(uid).."/annotations/"..U.id_name(account_key)..".json"
end

function Cache.load(root,uid,account_key,annotations)
    local path=path_for(root,uid,account_key)
    local raw=U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    if not ok or type(value)~="table" or tostring(value.account_key or "")~=tostring(account_key) then return nil end
    local restored=annotations:from_cache(value)
    if type(restored)=="table" then restored.cache_path=path; restored.saved_at=tonumber(value.saved_at or 0) or 0 end
    return restored
end

function Cache.save(root,uid,account_key,annotations,data)
    local snapshot=annotations:to_cache(data)
    snapshot.account_key=tostring(account_key)
    snapshot.saved_at=os.time()
    local ok,encoded=pcall(Json.encode,snapshot)
    if not ok then return nil,encoded end
    return U.atomic_write(path_for(root,uid,account_key),encoded,true)
end

return Cache
