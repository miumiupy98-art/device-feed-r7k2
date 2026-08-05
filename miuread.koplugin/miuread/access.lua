local U=require("miuread.util")

local Access={}
Access.__index=Access
local LOCK_SUFFIX=".miuread-locked"

local function ends_with(value,suffix)
    value=tostring(value or "")
    return suffix~="" and value:sub(-#suffix)==suffix
end

local function record_scope(record,kind)
    local scope=tostring(record and record.access_scope or "")
    if scope=="preview" or scope=="full" then return scope end
    kind=tostring(kind or record and record.variant or "")
    return kind:sub(1,8)=="preview_" and "preview" or "full"
end

local function clear_access_fields(record)
    if type(record)~="table" then return end
    record.locked=nil
    record.lock_reason=nil
    record.locked_at=nil
    record.original_file=nil
    record.access_status=nil
    record.access_policy_version=nil
    record.ownership=nil
    record.ownership_source=nil
    record.access_ownership=nil
    record.access_ownership_source=nil
    record.account_vid=nil
    record.verified_at=nil
    record.valid_until=nil
    record.last_access_check=nil
end

local function restore_path(record)
    if type(record)~="table" then return nil,false end
    local path=tostring(record.file or "")
    local original=tostring(record.original_file or "")
    if original=="" and ends_with(path,LOCK_SUFFIX) then
        original=path:sub(1,#path-#LOCK_SUFFIX)
    end
    local changed=false
    if original~="" and path~="" and path~=original then
        if U.file_exists(original) then
            if U.file_exists(path) and ends_with(path,LOCK_SUFFIX) then os.remove(path) end
            record.file=original
            changed=true
        elseif U.file_exists(path) then
            local ok=os.rename(path,original)
            if ok then record.file=original; changed=true end
        end
    elseif path~="" and ends_with(path,LOCK_SUFFIX) then
        local target=path:sub(1,#path-#LOCK_SUFFIX)
        if U.file_exists(target) then
            if U.file_exists(path) then os.remove(path) end
            record.file=target
            changed=true
        elseif U.file_exists(path) then
            local ok=os.rename(path,target)
            if ok then record.file=target; changed=true end
        end
    end
    clear_access_fields(record)
    return tostring(record.file or original or path),changed
end

function Access:new(_library,_api,_reader,store)
    return setmetatable({store=store},self)
end

function Access:lock_suffix() return LOCK_SUFFIX end
function Access._record_scope(record,kind) return record_scope(record,kind) end
function Access._record_locked(_record) return false end

function Access:_save_book(book_id,book)
    if self.store and type(self.store.save_book)=="function" and type(book)=="table" then
        book.access=nil
        self.store:save_book(book_id,book)
        if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book_id) end
    end
end

function Access:unlock_record(book_id,target)
    if type(target)~="table" then return false end
    local wanted_file=tostring(target.file or "")
    local wanted_original=tostring(target.original_file or "")
    local book=self.store and self.store:book(book_id) or nil
    local changed=false
    if type(book)=="table" then
        local function visit(record)
            if type(record)~="table" then return end
            local same=record==target
                or (wanted_file~="" and (tostring(record.file or "")==wanted_file or tostring(record.original_file or "")==wanted_file))
                or (wanted_original~="" and (tostring(record.file or "")==wanted_original or tostring(record.original_file or "")==wanted_original))
            if same then local _,c=restore_path(record); changed=changed or c; target=record end
        end
        for _,record in pairs(book.variants or {}) do visit(record) end
        for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do visit(record) end end
        book.access=nil
        self:_save_book(book_id,book)
    else
        local _,c=restore_path(target); changed=changed or c
    end
    clear_access_fields(target)
    return changed,target
end

function Access:unlock_book(book_id,_wanted_scope)
    local book=self.store and self.store:book(book_id) or nil
    if type(book)~="table" then return false end
    local changed=false
    local function visit(record)
        local _,c=restore_path(record)
        changed=changed or c
    end
    for _,record in pairs(book.variants or {}) do visit(record) end
    for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do visit(record) end end
    book.access=nil
    self:_save_book(book_id,book)
    return changed
end

function Access:resolve_path(book_id,path)
    path=tostring(path or "")
    if path=="" then return nil end
    if U.file_exists(path) and not ends_with(path,LOCK_SUFFIX) then return path end
    if ends_with(path,LOCK_SUFFIX) or U.file_exists(path..LOCK_SUFFIX) then
        self:unlock_book(book_id,"all")
        local target=ends_with(path,LOCK_SUFFIX) and path:sub(1,#path-#LOCK_SUFFIX) or path
        if U.file_exists(target) then return target end
    end
    local book=self.store and self.store:book(book_id) or nil
    if type(book)=="table" then
        local function find(record)
            if type(record)~="table" then return nil end
            local f=tostring(record.file or "")
            local o=tostring(record.original_file or "")
            if f==path or o==path or (ends_with(path,LOCK_SUFFIX) and o==path:sub(1,#path-#LOCK_SUFFIX)) then
                local resolved=restore_path(record)
                return resolved
            end
        end
        for _,record in pairs(book.variants or {}) do local v=find(record); if v and U.file_exists(v) then return v end end
        for _,row in pairs(book.chapters or {}) do
            for _,record in pairs(row or {}) do local v=find(record); if v and U.file_exists(v) then return v end end
        end
    end
    return U.file_exists(path) and path or nil
end

function Access:first_record(book_or_id,wanted_scope,_locked_only)
    local book=type(book_or_id)=="table" and book_or_id
        or (self.store and self.store:book(tostring(book_or_id or "")))
    if type(book)~="table" then return nil end
    local preferred={"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}
    for _,kind in ipairs(preferred) do
        local record=book.variants and book.variants[kind]
        if record and (not wanted_scope or wanted_scope=="all" or record_scope(record,kind)==wanted_scope) then return record end
    end
    for _,row in pairs(book.chapters or {}) do
        for _,kind in ipairs(preferred) do
            local record=row and row[kind]
            if record and (not wanted_scope or wanted_scope=="all" or record_scope(record,kind)==wanted_scope) then return record end
        end
    end
    return nil
end

function Access:is_record_locked(record)
    if type(record)=="table" then restore_path(record) end
    return false
end
function Access:is_locked(book_or_id)
    local id=type(book_or_id)=="table" and (book_or_id.book_id or book_or_id.bookId) or book_or_id
    if id then self:unlock_book(tostring(id),"all") end
    return false
end
function Access:lock_record(book_id,record,_reason) return self:unlock_record(book_id,record) end
function Access:lock_book(book_id,_reason,_scope) return self:unlock_book(book_id,"all") end
function Access:stamp_record(book_id,record,_state) return self:unlock_record(book_id,record) end
function Access:stamp_records(book_id,_scope,_state) return self:unlock_book(book_id,"all") end
function Access:needs_verification(_book_id,_record) return false end
function Access:verify_open(book_id,_force,record)
    if record then self:unlock_record(book_id,record) else self:unlock_book(book_id,"all") end
    return true,{status="allowed",verification_disabled=true}
end
function Access:prepare_download(book)
    return book,{status="allowed",verification_disabled=true}
end
function Access:status_text(_book) return nil end

return Access
