local SQLiteStore = require("miuread.sqlite_store")
local Digests = require("miuread.digests")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local LocalAnnotationDatabase = {}

LocalAnnotationDatabase.SCHEMA_VERSION = 1
LocalAnnotationDatabase.FILE_NAME = "local_annotations.sqlite3"

local function database_path(store, book_id)
    return store:book_dir(book_id) .. "/" .. LocalAnnotationDatabase.FILE_NAME
end

local function initialize(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS local_annotations (
            local_id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            pos0 TEXT NOT NULL DEFAULT '',
            pos1 TEXT NOT NULL DEFAULT '',
            xpointer TEXT NOT NULL DEFAULT '',
            page INTEGER,
            text TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            datetime TEXT NOT NULL DEFAULT '',
            drawer TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            present INTEGER NOT NULL DEFAULT 1,
            sync_state TEXT NOT NULL DEFAULT 'local_only',
            range_key TEXT NOT NULL DEFAULT '',
            remote_id TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_local_annotation_book
            ON local_annotations(book_id, present, kind);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_sync
            ON local_annotations(book_id, sync_state, updated_at);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_remote
            ON local_annotations(remote_id);
    ]])
    SQLiteStore.set_text(conn, "local_annotation_schema_version",
        tostring(LocalAnnotationDatabase.SCHEMA_VERSION))
end

local function open(store, book_id, read_only)
    local conn = SQLiteStore.open(database_path(store, book_id), read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return tostring(value)
    end
    return ""
end

local function annotation_kind(item)
    if type(item) ~= "table" then return nil end
    if item.drawer then return item.note and "thought" or "highlight" end
    return "bookmark"
end

local function stable_id(book_id, item, kind)
    for _, key in ipairs({"id", "uuid", "annotation_id", "annotationId"}) do
        local value = scalar(item[key])
        if value ~= "" then return "ko:" .. value end
    end
    local pos0 = scalar(item.pos0 or item.start)
    local pos1 = scalar(item.pos1 or item["end"])
    local xpointer = scalar(item.xpointer)
    local page = scalar(item.page or item.pageno)
    local datetime = scalar(item.datetime or item.date)
    local base = table.concat({
        tostring(book_id or ""), tostring(kind or ""), pos0, pos1,
        xpointer, page, datetime,
    }, "\31")
    if pos0 == "" and pos1 == "" and xpointer == "" and page == "" then
        base = base .. "\31" .. scalar(item.text or item.notes)
            .. "\31" .. scalar(item.note)
    end
    return "miu:" .. Digests.md5(base):lower()
end

local function compact(book_id, item, source_path)
    if type(item) ~= "table" then return nil end
    local kind = annotation_kind(item)
    if not kind then return nil end
    return {
        local_id = stable_id(book_id, item, kind),
        book_id = tostring(book_id or ""),
        kind = kind,
        pos0 = scalar(item.pos0 or item.start),
        pos1 = scalar(item.pos1 or item["end"]),
        xpointer = scalar(item.xpointer),
        page = tonumber(item.page or item.pageno),
        text = scalar(item.text or item.notes),
        note = scalar(item.note),
        datetime = scalar(item.datetime or item.date),
        drawer = scalar(item.drawer),
        source_path = tostring(source_path or ""),
    }
end

local function bind_update(statement, row, now)
    statement:bind(
        row.book_id, row.kind, row.pos0, row.pos1, row.xpointer, row.page,
        row.text, row.note, row.datetime, row.drawer, row.source_path,
        now, row.local_id
    ):step()
    statement:clearbind():reset()
end

function LocalAnnotationDatabase.path(store, book_id)
    return database_path(store, book_id)
end

function LocalAnnotationDatabase.exists(store, book_id)
    return lfs.attributes(database_path(store, book_id), "mode") == "file"
end

--- Replace the current KOReader annotation snapshot without doing any network work.
-- The operation is one SQLite transaction and is intended to run only after a
-- short quiet period following onAnnotationsModified.
function LocalAnnotationDatabase.snapshot(store, book_id, annotations, source_path)
    book_id = tostring(book_id or "")
    if book_id == "" then return nil, "bookId missing" end
    annotations = type(annotations) == "table" and annotations or {}

    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            local now = os.time()
            local mark_missing = conn:prepare([[
                UPDATE local_annotations SET present = 0, updated_at = ? WHERE book_id = ?
            ]])
            mark_missing:bind(now, book_id):step()
            mark_missing:close()

            local insert = conn:prepare([[
                INSERT OR IGNORE INTO local_annotations(
                    local_id, book_id, kind, pos0, pos1, xpointer, page,
                    text, note, datetime, drawer, source_path,
                    present, sync_state, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'local_only', ?, ?)
            ]])
            local update = conn:prepare([[
                UPDATE local_annotations
                   SET book_id = ?, kind = ?, pos0 = ?, pos1 = ?, xpointer = ?, page = ?,
                       text = ?, note = ?, datetime = ?, drawer = ?, source_path = ?,
                       present = 1, updated_at = ?
                 WHERE local_id = ?
            ]])

            local count = 0
            for _, item in ipairs(annotations) do
                local row = compact(book_id, item, source_path)
                if row then
                    insert:bind(
                        row.local_id, row.book_id, row.kind, row.pos0, row.pos1,
                        row.xpointer, row.page, row.text, row.note, row.datetime,
                        row.drawer, row.source_path, now, now
                    ):step()
                    insert:clearbind():reset()
                    bind_update(update, row, now)
                    count = count + 1
                end
            end
            insert:close()
            update:close()

            -- Unsynced records removed locally need no tombstone. Synced rows are
            -- kept as delete_pending for the future cloud-sync phase.
            conn:exec([[
                DELETE FROM local_annotations
                 WHERE present = 0 AND remote_id = '' AND sync_state = 'local_only';
            ]])
            conn:exec([[
                UPDATE local_annotations
                   SET sync_state = 'delete_pending'
                 WHERE present = 0 AND remote_id <> '' AND sync_state = 'synced';
            ]])
            return {count=count, updated_at=now}
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function LocalAnnotationDatabase.summary(store, book_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then
        return {total=0, bookmark=0, highlight=0, thought=0, pending=0, delete_pending=0}
    end
    local conn = open(store, book_id, true)
    local ok, result = xpcall(function()
        local out = {total=0, bookmark=0, highlight=0, thought=0, pending=0, delete_pending=0}
        local statement = conn:prepare([[
            SELECT kind, sync_state, COUNT(*) FROM local_annotations
             WHERE book_id = ? AND (present = 1 OR sync_state = 'delete_pending')
             GROUP BY kind, sync_state
        ]])
        statement:bind(tostring(book_id or ""))
        while true do
            local row = statement:step()
            if not row then break end
            local kind, state, count = tostring(row[1] or ""), tostring(row[2] or ""), tonumber(row[3] or 0) or 0
            out.total = out.total + count
            if out[kind] ~= nil then out[kind] = out[kind] + count end
            if state == "local_only" or state == "unknown" or state == "locate_failed" then
                out.pending = out.pending + count
            elseif state == "delete_pending" then
                out.delete_pending = out.delete_pending + count
            end
        end
        statement:close()
        return out
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

return LocalAnnotationDatabase
