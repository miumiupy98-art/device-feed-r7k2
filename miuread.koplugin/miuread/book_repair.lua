local Thoughts = require("miuread.thoughts")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local Repair = {}
Repair.__index = Repair

function Repair:new(store)
    return setmetatable({store = store}, self)
end

local function file_signature(path)
    local attr = lfs.attributes(tostring(path or ""))
    if type(attr) ~= "table" then return "missing" end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

local function wants_annotations(context)
    context = type(context) == "table" and context or {}
    local record = type(context.record) == "table" and context.record or {}
    local variant = tostring(context.variant or record.variant or "")
    return record.annotation_requested == true or variant:find("notes", 1, true) ~= nil
end

function Repair:signature(context)
    context = type(context) == "table" and context or {}
    local book = type(context.book) == "table" and context.book or {}
    local id = tostring(book.book_id or book.bookId or context.book_id or "")
    return table.concat({id, tostring(context.variant or ""), file_signature(context.path)}, "|")
end

function Repair:inspect(context)
    context = type(context) == "table" and context or {}
    local book = type(context.book) == "table" and context.book or {}
    local id = tostring(book.book_id or book.bookId or context.book_id or "")
    local report = {
        ok = true,
        book_id = id,
        title = tostring(book.title or context.title or "当前书籍"),
        signature = self:signature(context),
        issues = {},
    }
    if id == "" or not wants_annotations(context) then return report end
    local index_report = Thoughts.inspect_book_indexes(self.store, id)
    report.thought_indexes = index_report
    if index_report.issue then
        report.issues[#report.issues + 1] = {
            code = "thought_index",
            title = "评论索引需要修复",
            detail = "评论索引缺失或已失效，可能导致评论打开缓慢。",
        }
    end
    return report
end

function Repair:repair(context, report, force)
    context = type(context) == "table" and context or {}
    report = type(report) == "table" and report or self:inspect(context)
    local result = {
        ok = true,
        book_id = report.book_id,
        title = report.title,
        signature = report.signature or self:signature(context),
        repaired = {},
        failed = {},
    }
    local needs_thought = force == true
    for _, issue in ipairs(report.issues or {}) do
        if issue.code == "thought_index" then needs_thought = true end
    end
    if needs_thought and tostring(result.book_id or "") ~= "" then
        local stats = Thoughts.repair_book_indexes(self.store, result.book_id, force == true)
        result.thought_indexes = stats
        if stats.ok then
            result.repaired[#result.repaired + 1] = "评论索引"
        else
            result.ok = false
            result.failed[#result.failed + 1] = "评论索引"
        end
    end
    return result
end

function Repair:contexts_from_library()
    local rows = {}
    for id, book in pairs(self.store:library() or {}) do
        if type(book) == "table" then
            for variant, record in pairs(book.variants or {}) do
                if type(record) == "table" and (record.annotation_requested == true or tostring(variant):find("notes", 1, true)) then
                    rows[#rows + 1] = {
                        book = {book_id=tostring(id), title=book.title},
                        book_id = tostring(id),
                        record = {annotation_requested=record.annotation_requested, variant=record.variant, file=record.file},
                        variant = variant,
                        path = record.file,
                        title = book.title,
                    }
                    break
                end
            end
        end
    end
    table.sort(rows, function(a, b) return tostring(a.title or "") < tostring(b.title or "") end)
    return rows
end

function Repair:scan_downloaded()
    local result = {checked = 0, affected = 0, contexts = {}}
    for _, context in ipairs(self:contexts_from_library()) do
        local report = self:inspect(context)
        result.checked = result.checked + 1
        if #(report.issues or {}) > 0 then
            result.affected = result.affected + 1
            result.contexts[#result.contexts + 1] = {context = context, report = report}
        end
    end
    return result
end

function Repair:repair_scan(scan)
    local result = {checked = 0, repaired = 0, failed = 0, details = {}}
    for _, row in ipairs((scan and scan.contexts) or {}) do
        local repaired = self:repair(row.context, row.report, false)
        result.checked = result.checked + 1
        if repaired.ok then result.repaired = result.repaired + 1 else result.failed = result.failed + 1 end
        result.details[#result.details + 1] = repaired
    end
    result.ok = result.failed == 0
    return result
end

function Repair:clear_invalid_downloaded_indexes()
    local removed = 0
    for _, context in ipairs(self:contexts_from_library()) do
        local id = tostring((context.book or {}).book_id or context.book_id or "")
        if id ~= "" then removed = removed + Thoughts.remove_invalid_indexes(self.store, id) end
    end
    return removed
end

return Repair
