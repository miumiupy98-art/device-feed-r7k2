local SQLiteStore = require("miuread.sqlite_store")
local Digests = require("miuread.digests")
local lfs = require("libs/libkoreader-lfs")

local LocalAnnotationDatabase = {}

LocalAnnotationDatabase.SCHEMA_VERSION = 2
LocalAnnotationDatabase.FILE_NAME = "local_annotations.sqlite3"

local function database_path(store, book_id)
    return store:book_dir(book_id) .. "/" .. LocalAnnotationDatabase.FILE_NAME
end

local function safe_alter(conn, sql)
    pcall(conn.exec, conn, sql)
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
            anchor_text TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            datetime TEXT NOT NULL DEFAULT '',
            drawer TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            present INTEGER NOT NULL DEFAULT 1,
            sync_state TEXT NOT NULL DEFAULT 'local_only',
            range_key TEXT NOT NULL DEFAULT '',
            remote_id TEXT NOT NULL DEFAULT '',
            chapter_uid TEXT NOT NULL DEFAULT '',
            chapter_idx INTEGER,
            book_version INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '',
            last_attempt_at INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
    ]])
    -- Upgrade beta.5 databases in place.
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN anchor_text TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN chapter_uid TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN chapter_idx INTEGER;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN book_version INTEGER NOT NULL DEFAULT 0;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN last_error TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN last_attempt_at INTEGER NOT NULL DEFAULT 0;")
    conn:exec([[
        CREATE INDEX IF NOT EXISTS idx_local_annotation_book
            ON local_annotations(book_id, present, kind);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_sync
            ON local_annotations(book_id, sync_state, updated_at);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_remote
            ON local_annotations(remote_id);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_chapter
            ON local_annotations(book_id, chapter_uid, chapter_idx);
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

local function compact(book_id, item, source_path, resolver)
    if type(item) ~= "table" then return nil end
    local kind = annotation_kind(item)
    if not kind then return nil end
    local resolved = {}
    if type(resolver) == "function" then
        local ok, value = pcall(resolver, item, kind)
        if ok and type(value) == "table" then resolved = value end
    end
    local page_value = item.page or item.pageno
    local xpointer = item.xpointer
    if (xpointer == nil or xpointer == "") and kind == "bookmark"
        and type(page_value) == "string" and tonumber(page_value) == nil then
        xpointer = page_value
    end
    return {
        local_id = stable_id(book_id, item, kind),
        book_id = tostring(book_id or ""),
        kind = kind,
        pos0 = scalar(item.pos0 or item.start),
        pos1 = scalar(item.pos1 or item["end"]),
        xpointer = scalar(xpointer),
        page = tonumber(page_value),
        text = scalar(item.text or item.notes),
        anchor_text = tostring(resolved.anchor_text or ""),
        note = scalar(item.note),
        datetime = scalar(item.datetime or item.date),
        drawer = scalar(item.drawer),
        source_path = tostring(source_path or ""),
        chapter_uid = tostring(resolved.chapter_uid or resolved.uid or ""),
        chapter_idx = tonumber(resolved.chapter_idx or resolved.index),
    }
end

function LocalAnnotationDatabase.path(store, book_id)
    return database_path(store, book_id)
end

function LocalAnnotationDatabase.exists(store, book_id)
    return lfs.attributes(database_path(store, book_id), "mode") == "file"
end

--- Replace the current KOReader annotation snapshot without doing network work.
-- resolver(item, kind) may add chapter_uid/chapter_idx while the document is open.
function LocalAnnotationDatabase.snapshot(store, book_id, annotations, source_path, resolver)
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
                    text, anchor_text, note, datetime, drawer, source_path,
                    chapter_uid, chapter_idx,
                    present, sync_state, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'local_only', ?, ?)
            ]])
            local update = conn:prepare([[
                UPDATE local_annotations
                   SET book_id = ?, kind = ?, pos0 = ?, pos1 = ?, xpointer = ?, page = ?,
                       text = ?, anchor_text = CASE WHEN ? <> '' THEN ? ELSE anchor_text END,
                       note = ?, datetime = ?, drawer = ?, source_path = ?,
                       chapter_uid = CASE WHEN ? <> '' THEN ? ELSE chapter_uid END,
                       chapter_idx = COALESCE(?, chapter_idx),
                       present = 1, updated_at = ?
                 WHERE local_id = ?
            ]])

            local count = 0
            for _, item in ipairs(annotations) do
                local row = compact(book_id, item, source_path, resolver)
                if row then
                    insert:bind(
                        row.local_id, row.book_id, row.kind, row.pos0, row.pos1,
                        row.xpointer, row.page, row.text, row.anchor_text, row.note, row.datetime,
                        row.drawer, row.source_path, row.chapter_uid, row.chapter_idx,
                        now, now
                    ):step()
                    insert:clearbind():reset()
                    update:bind(
                        row.book_id, row.kind, row.pos0, row.pos1, row.xpointer, row.page,
                        row.text, row.anchor_text, row.anchor_text, row.note, row.datetime, row.drawer, row.source_path,
                        row.chapter_uid, row.chapter_uid, row.chapter_idx,
                        now, row.local_id
                    ):step()
                    update:clearbind():reset()
                    count = count + 1
                end
            end
            insert:close()
            update:close()

            -- Records never seen by the server can disappear locally without a tombstone.
            conn:exec([[
                DELETE FROM local_annotations
                 WHERE present = 0 AND remote_id = ''
                   AND sync_state IN ('local_only','locate_failed');
            ]])
            -- Anything already known/possibly known by the server is retained until
            -- the cloud side is confirmed gone.
            conn:exec([[
                UPDATE local_annotations
                   SET sync_state = 'delete_pending'
                 WHERE present = 0
                   AND sync_state IN ('synced','unknown','delete_unknown');
            ]])
            return {count=count, updated_at=now}
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

local SELECT_COLUMNS = [[
    local_id, book_id, kind, pos0, pos1, xpointer, page, text, anchor_text, note,
    datetime, drawer, source_path, present, sync_state, range_key,
    remote_id, chapter_uid, chapter_idx, book_version, last_error,
    last_attempt_at, created_at, updated_at
]]

local function row_from_sql(row)
    if not row then return nil end
    return {
        local_id=tostring(row[1] or ""), book_id=tostring(row[2] or ""),
        kind=tostring(row[3] or ""), pos0=tostring(row[4] or ""), pos1=tostring(row[5] or ""),
        xpointer=tostring(row[6] or ""), page=tonumber(row[7]), text=tostring(row[8] or ""),
        anchor_text=tostring(row[9] or ""), note=tostring(row[10] or ""),
        datetime=tostring(row[11] or ""), drawer=tostring(row[12] or ""),
        source_path=tostring(row[13] or ""), present=tonumber(row[14] or 0)==1,
        sync_state=tostring(row[15] or ""), range_key=tostring(row[16] or ""),
        remote_id=tostring(row[17] or ""), chapter_uid=tostring(row[18] or ""),
        chapter_idx=tonumber(row[19]), book_version=tonumber(row[20] or 0) or 0,
        last_error=tostring(row[21] or ""), last_attempt_at=tonumber(row[22] or 0) or 0,
        created_at=tonumber(row[23] or 0) or 0, updated_at=tonumber(row[24] or 0) or 0,
    }
end

function LocalAnnotationDatabase.pending(store, book_id, limit)
    if not LocalAnnotationDatabase.exists(store, book_id) then return {} end
    local conn = open(store, book_id, false)
    local out = {}
    local ok, err = xpcall(function()
        local statement = conn:prepare("SELECT " .. SELECT_COLUMNS .. [[
            FROM local_annotations
            WHERE book_id = ? AND sync_state IN
                ('local_only','locate_failed','unknown','delete_pending','delete_unknown')
            ORDER BY updated_at ASC LIMIT ?
        ]])
        statement:bind(tostring(book_id or ""), math.max(1, tonumber(limit) or 200))
        while true do
            local row = statement:step()
            if not row then break end
            out[#out + 1] = row_from_sql(row)
        end
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return out
end

local function update_state(store, book_id, local_id, state, fields)
    fields = fields or {}
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_state = ?, range_key = CASE WHEN ? IS NULL THEN range_key ELSE ? END,
                   remote_id = CASE WHEN ? IS NULL THEN remote_id ELSE ? END,
                   book_version = CASE WHEN ? IS NULL THEN book_version ELSE ? END,
                   last_error = ?, last_attempt_at = ?, updated_at = ?
             WHERE local_id = ?
        ]])
        local range = fields.range_key
        local remote = fields.remote_id
        local version = fields.book_version
        local now = os.time()
        statement:bind(
            tostring(state or "local_only"),
            range, range, remote, remote,
            version, version,
            tostring(fields.last_error or ""),
            tonumber(fields.last_attempt_at) or now, now,
            tostring(local_id or "")
        ):step()
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function LocalAnnotationDatabase.mark_synced(store, book_id, local_id, remote_id, range_key, book_version)
    return update_state(store, book_id, local_id, "synced", {
        remote_id=tostring(remote_id or ""), range_key=tostring(range_key or ""),
        book_version=tonumber(book_version) or 0, last_error="",
    })
end

function LocalAnnotationDatabase.mark_state(store, book_id, local_id, state, fields)
    return update_state(store, book_id, local_id, state, fields)
end

function LocalAnnotationDatabase.delete_row(store, book_id, local_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return true end
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        local statement = conn:prepare("DELETE FROM local_annotations WHERE local_id = ?")
        statement:bind(tostring(local_id or "")):step()
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function LocalAnnotationDatabase.summary(store, book_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then
        return {total=0, bookmark=0, highlight=0, thought=0, pending=0, synced=0,
            delete_pending=0, locate_failed=0, unknown=0}
    end
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        local out = {total=0, bookmark=0, highlight=0, thought=0, pending=0, synced=0,
            delete_pending=0, locate_failed=0, unknown=0}
        local statement = conn:prepare([[
            SELECT kind, sync_state, COUNT(*) FROM local_annotations
             WHERE book_id = ? AND (present = 1 OR sync_state IN ('delete_pending','delete_unknown'))
             GROUP BY kind, sync_state
        ]])
        statement:bind(tostring(book_id or ""))
        while true do
            local row = statement:step()
            if not row then break end
            local kind = tostring(row[1] or "")
            local state = tostring(row[2] or "")
            local count = tonumber(row[3] or 0) or 0
            out.total = out.total + count
            if out[kind] ~= nil then out[kind] = out[kind] + count end
            if state == "synced" then out.synced = out.synced + count
            elseif state == "delete_pending" or state == "delete_unknown" then
                out.delete_pending = out.delete_pending + count
            elseif state == "locate_failed" then
                out.locate_failed = out.locate_failed + count; out.pending = out.pending + count
            elseif state == "unknown" then
                out.unknown = out.unknown + count; out.pending = out.pending + count
            else
                out.pending = out.pending + count
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
