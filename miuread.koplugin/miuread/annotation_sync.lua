local logger = require("logger")
local U = require("miuread.util")
local Codec = require("miuread.codec")
local Http = require("miuread.http")
local Coord = require("miuread.annotation_coord")
local PosMap = require("miuread.annotations.posmap")
local Range = require("miuread.annotations.range")
local LocalDB = require("miuread.local_annotation_database")

local AnnotationSync = {}
AnnotationSync.__index = AnnotationSync

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return tostring(value) end
    return ""
end

local function clean_text(value)
    return tostring(value or ""):gsub("%s", ""):gsub("%*", "")
end

local function collect_records(value, out, seen, depth)
    out = out or {}
    seen = seen or {}
    depth = depth or 0
    if type(value) ~= "table" or seen[value] or depth > 7 then return out end
    seen[value] = true
    local has_identity = scalar(value.bookmarkId) ~= "" or scalar(value.reviewId) ~= ""
        or scalar(value.range or value.markRange or value.bookmarkRange) ~= ""
    if has_identity then out[#out + 1] = value end
    for _, child in pairs(value) do
        if type(child) == "table" then collect_records(child, out, seen, depth + 1) end
    end
    return out
end

local function record_range(row)
    return scalar(row and (row.range or row.markRange or row.bookmarkRange))
end

local function bookmark_remote_id(row)
    return scalar(row and (row.bookmarkId or row.bookmarkID or row.id))
end

local function review_remote_id(row)
    return scalar(row and (row.reviewId or row.reviewID or row.id))
end

local function find_bookmark_match(records, range_key, expected_type, remote_id)
    range_key = tostring(range_key or "")
    remote_id = tostring(remote_id or "")
    for _, row in ipairs(records or {}) do
        local rid = bookmark_remote_id(row)
        if remote_id ~= "" and rid == remote_id then return row, rid end
        if range_key ~= "" and record_range(row) == range_key then
            local row_type = tonumber(row.type or row.bookmarkType or row.markType)
            if row_type == nil or tonumber(expected_type) == nil or row_type == tonumber(expected_type) then
                return row, rid
            end
        end
    end
end

local function find_review_match(records, range_key, content, remote_id)
    range_key = tostring(range_key or "")
    remote_id = tostring(remote_id or "")
    local clean_content = U.trim(tostring(content or ""))
    for _, row in ipairs(records or {}) do
        local rid = review_remote_id(row)
        if remote_id ~= "" and rid == remote_id then return row, rid end
        if range_key ~= "" and record_range(row) == range_key then
            local text = U.trim(tostring(row.content or row.review or row.text or ""))
            if clean_content == "" or text == "" or text == clean_content then return row, rid end
        end
    end
end

local function find_number(value, keys, seen, depth)
    if type(value) ~= "table" or (depth or 0) > 6 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, key in ipairs(keys) do
        local n = tonumber(value[key])
        if n then return n end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local n = find_number(child, keys, seen, (depth or 0) + 1)
            if n then return n end
        end
    end
end

local function find_id(value, keys, seen, depth)
    if type(value) ~= "table" or (depth or 0) > 6 then return "" end
    seen = seen or {}
    if seen[value] then return "" end
    seen[value] = true
    for _, key in ipairs(keys) do
        local v = scalar(value[key])
        if v ~= "" then return v end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local v = find_id(child, keys, seen, (depth or 0) + 1)
            if v ~= "" then return v end
        end
    end
    return ""
end

local function chapter_from(book, record, uid, idx)
    uid = tostring(uid or "")
    idx = tonumber(idx)
    local sources = {
        type(record) == "table" and record.chapter_map or nil,
        type(book) == "table" and book.catalog or nil,
    }
    for _, source in ipairs(sources) do
        if type(source) == "table" then
            if idx and type(source[idx]) == "table" then
                local row = source[idx]
                if uid == "" or tostring(row.uid or row.chapterUid or row.chapter_uid or "") == uid then
                    return U.copy(row)
                end
            end
            for _, row in ipairs(source) do
                if type(row) == "table" and uid ~= ""
                    and tostring(row.uid or row.chapterUid or row.chapter_uid or "") == uid then
                    return U.copy(row)
                end
            end
        end
    end
    if uid ~= "" then return {uid=uid, chapterUid=uid, index=idx} end
end

local function visible_slice(map, text_start, count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if not map or not text_start or count <= 0 then return "" end
    local last = math.min(#(map.text_runes or {}), text_start + count - 1)
    if last < text_start then return "" end
    return table.concat(map.text_runes, "", text_start, last)
end

local function verification_matches(map, range_key, expected)
    local resolved = Coord.resolveRangeOnMap(map, range_key)
    if not resolved then return false end
    return clean_text(resolved.text) == clean_text(expected)
end

function AnnotationSync:new(api, reader, store)
    return setmetatable({api=api, reader=reader, store=store}, self)
end

function AnnotationSync:_book_version(book_id, book, record)
    for _, source in ipairs({record, book}) do
        if type(source) == "table" then
            local n = tonumber(source.bookVersion or source.book_version or source.version)
            if n then return n end
        end
    end
    local ok, info = pcall(self.api.book, self.api, book_id)
    if ok and type(info) == "table" then
        local n = find_number(info, {"bookVersion", "book_version", "version"})
        if n then return n end
    end
    -- The web review endpoint accepts 0 in observed requests. For bookmark writes
    -- this remains an experimental fallback; a server rejection is kept local.
    return 0
end

function AnnotationSync:_coord_map(book, record, row, cache)
    local uid = tostring(row.chapter_uid or "")
    if uid == "" then return nil, "chapter_missing" end
    if cache[uid] then return cache[uid] end
    local chapter = chapter_from(book, record, uid, row.chapter_idx)
    if not chapter then return nil, "chapter_metadata_missing" end
    chapter.chapterUid = chapter.chapterUid or chapter.uid or uid
    chapter.uid = chapter.uid or chapter.chapterUid
    chapter.title = chapter.title or ""
    local book_arg = {
        bookId=tostring(book.book_id or book.bookId or row.book_id or ""),
        book_id=tostring(book.book_id or book.bookId or row.book_id or ""),
        title=book.title, author=book.author,
    }
    local ok, downloaded, style, assets, state = pcall(self.reader.chapter, self.reader,
        book_arg, chapter, "epub", {images=false})
    if not ok then return nil, tostring(downloaded) end
    local coord_html = type(state) == "table" and tostring(state.coord_html or "") or ""
    if coord_html == "" then return nil, "coord_html_missing" end
    local built_ok, map = pcall(Coord.build, coord_html)
    if not built_ok or type(map) ~= "table" then return nil, tostring(map or "coord_build_failed") end
    cache[uid] = {map=map, html=coord_html, chapter=chapter}
    return cache[uid]
end

function AnnotationSync:_locate(row, chapter_ctx)
    local map = chapter_ctx.map
    if row.kind == "bookmark" then
        -- KOReader's bookmark `text` is normally only a chapter label. The
        -- snapshot stores a real excerpt beginning at the bookmark XPointer.
        local anchor = U.trim(tostring(row.anchor_text or ""))
        if anchor == "" then return nil, "bookmark_anchor_missing" end

        -- Near a chapter boundary the extracted KOReader excerpt may run into the
        -- next XHTML spine item. Try progressively shorter prefixes, but never
        -- choose an ambiguous hit.
        local html_start, last_error
        local seen = {}
        for _, limit in ipairs({96, 80, 64, 48, 32, 24, 16}) do
            local candidate = U.trim(U.utf8_truncate(anchor, limit, ""))
            if candidate ~= "" and not seen[candidate] then
                seen[candidate] = true
                local range_key, start_or_error = PosMap.locate(map, candidate)
                if range_key then
                    html_start = start_or_error
                    break
                end
                last_error = tostring(start_or_error or "bookmark_not_found")
                if last_error == "ambiguous" then break end
            end
        end
        if not html_start then return nil, last_error or "bookmark_not_found" end
        local text_start = map.html_to_text and map.html_to_text[html_start]
        if not text_start then return nil, "bookmark_text_map_failed" end
        local point = Range.encode(html_start, html_start + 1, true)
        if not point then return nil, "bookmark_encode_failed" end
        local mark_text = visible_slice(map, text_start, 140)
        if mark_text == "" then return nil, "bookmark_preview_empty" end
        return {range=point, mark_text=mark_text, html_start=html_start, text_start=text_start, point=true}
    end

    local mark_text = U.trim(tostring(row.text or ""))
    if mark_text == "" then return nil, "mark_text_missing" end
    local range_key, html_start, html_end_pos = PosMap.locate(map, mark_text)
    if not range_key then return nil, tostring(html_start or "not_found") end
    if not verification_matches(map, range_key, mark_text) then return nil, "range_verify_failed" end
    local round = Coord.roundTrip(chapter_ctx.html, range_key)
    if not (round and round.ok) then return nil, "range_roundtrip_failed" end
    return {range=range_key, mark_text=mark_text, html_start=html_start,
        html_end_pos=html_end_pos, point=false}
end

function AnnotationSync:_visibility_fields(mode)
    mode = tostring(mode or "private")
    if mode == "public" then return {} end
    if mode == "friendship" then return {friendship=1} end
    if mode == "friends_hidden" then return {notVisibleToFriends=1} end
    if mode == "one_book" then return {onlyVisibleToOneBook=1} end
    return {isPrivate=1}
end

function AnnotationSync:_bookmark_payload(row, located, version, prefs)
    local is_bookmark = row.kind == "bookmark"
    return {
        bookId=tostring(row.book_id or ""),
        chapterUid=tostring(row.chapter_uid or ""),
        chapterIdx=tonumber(row.chapter_idx) or 0,
        bookVersion=tonumber(version) or 0,
        type=is_bookmark and 0 or 1,
        style=is_bookmark and 0 or tonumber(prefs.highlight_style) or 0,
        colorStyle=is_bookmark and 0 or tonumber(prefs.highlight_color) or 0,
        range=tostring(located.range or ""),
        markText=Codec.b64encode(located.mark_text or ""),
    }
end

function AnnotationSync:_review_payload(row, located, version, prefs)
    local payload = {
        type=1,
        bookId=tostring(row.book_id or ""),
        chapterUid=tostring(row.chapter_uid or ""),
        chapterIdx=tonumber(row.chapter_idx) or 0,
        bookVersion=tonumber(version) or 0,
        range=tostring(located.range or ""),
        abstract=tostring(located.mark_text or ""),
        content=tostring(row.note or ""),
    }
    for key, value in pairs(self:_visibility_fields(prefs.review_visibility)) do payload[key] = value end
    return payload
end

local function fetch_cloud_bookmarks(api, book_id)
    local ok, value = pcall(api.bookmark_list, api, book_id)
    if not ok then return nil, tostring(value) end
    return collect_records(value), nil
end

local function fetch_cloud_reviews(api, book_id)
    local ok, value = pcall(api.review_list_mine, api, book_id, 0, 200)
    if not ok then return nil, tostring(value) end
    return collect_records(value), nil
end

function AnnotationSync:sync_book(book, record, options)
    options = options or {}
    local book_id = tostring((book and (book.book_id or book.bookId)) or (record and record.book_id) or "")
    if book_id == "" then return {ok=false, error="bookId missing"} end
    local prefs = options.preferences or {}
    local rows, rows_error = LocalDB.pending(self.store, book_id, options.limit or 200)
    if not rows then return {ok=false, error=rows_error} end
    local result = {ok=true,total=#rows,synced=0,deleted=0,failed=0,locate_failed=0,
        unknown=0,skipped=0,reconciled=0,errors={}}
    if #rows == 0 then return result end

    local need_bookmarks, need_reviews = false, false
    for _, row in ipairs(rows) do
        if row.kind == "thought" then need_reviews = true else need_bookmarks = true end
    end
    local cloud_bookmarks, bookmark_error = {}, nil
    local cloud_reviews, review_error = {}, nil
    if need_bookmarks then cloud_bookmarks, bookmark_error = fetch_cloud_bookmarks(self.api, book_id) end
    if need_reviews then cloud_reviews, review_error = fetch_cloud_reviews(self.api, book_id) end
    if need_bookmarks and not cloud_bookmarks then bookmark_error = bookmark_error or "bookmark reconciliation failed" end
    if need_reviews and not cloud_reviews then review_error = review_error or "review reconciliation failed" end

    local version = self:_book_version(book_id, book or {}, record or {})
    local coord_cache = {}

    local function remember_error(row, state, message, fields)
        fields = fields or {}
        fields.last_error = tostring(message or "")
        fields.last_attempt_at = os.time()
        LocalDB.mark_state(self.store, book_id, row.local_id, state, fields)
        result.failed = result.failed + 1
        if state == "locate_failed" then result.locate_failed = result.locate_failed + 1 end
        if state == "unknown" or state == "delete_unknown" then result.unknown = result.unknown + 1 end
        if #result.errors < 12 then
            result.errors[#result.errors + 1] = tostring(row.kind) .. ": " .. tostring(message or state)
        end
    end

    for _, row in ipairs(rows) do
        local is_review = row.kind == "thought"
        local cloud_rows = is_review and cloud_reviews or cloud_bookmarks
        local cloud_error = is_review and review_error or bookmark_error
        local expected_type = row.kind == "bookmark" and 0 or 1
        local match, matched_id
        if cloud_rows then
            if is_review then
                match, matched_id = find_review_match(cloud_rows, row.range_key, row.note, row.remote_id)
            else
                match, matched_id = find_bookmark_match(cloud_rows, row.range_key, expected_type, row.remote_id)
            end
        end

        if row.sync_state == "delete_pending" or row.sync_state == "delete_unknown" then
            if is_review then
                -- The review delete endpoint has not been verified yet. Keep the
                -- tombstone so a future version can remove the cloud review safely.
                remember_error(row, "delete_pending", "想法云端删除接口尚未接入")
            elseif not cloud_rows then
                remember_error(row, row.sync_state, "删除前云端对账失败：" .. tostring(cloud_error or "unknown"))
            else
                if row.remote_id ~= "" and not match then
                    LocalDB.delete_row(self.store, book_id, row.local_id)
                    result.deleted = result.deleted + 1
                else
                    local remote_id = row.remote_id ~= "" and row.remote_id or matched_id
                    if remote_id == "" then
                        remember_error(row, "delete_pending", "缺少 bookmarkId，无法安全删除")
                    else
                        local ok, value = pcall(self.api.remove_bookmark, self.api, remote_id, {
                            bookId=book_id, chapterUid=row.chapter_uid,
                        })
                        if ok then
                            LocalDB.delete_row(self.store, book_id, row.local_id)
                            result.deleted = result.deleted + 1
                        elseif Http.is_network_error(value) then
                            remember_error(row, "delete_unknown", value, {remote_id=remote_id})
                        else
                            remember_error(row, "delete_pending", value, {remote_id=remote_id})
                        end
                    end
                end
            end
        elseif row.sync_state == "unknown" then
            if cloud_rows and match then
                local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                LocalDB.mark_synced(self.store, book_id, row.local_id, rid, row.range_key, version)
                result.synced = result.synced + 1
                result.reconciled = result.reconciled + 1
            else
                -- A previous POST may already have committed. Never blindly resend
                -- an unknown mutation when reconciliation cannot prove absence.
                remember_error(row, "unknown", cloud_error and ("云端对账失败："..cloud_error)
                    or "上次请求结果未知，未自动重复上传")
            end
        else
            local chapter_ctx, coord_error = self:_coord_map(book or {}, record or {}, row, coord_cache)
            if not chapter_ctx then
                remember_error(row, "locate_failed", coord_error)
            else
                local located, locate_error = self:_locate(row, chapter_ctx)
                if not located then
                    remember_error(row, "locate_failed", locate_error)
                else
                    LocalDB.mark_state(self.store, book_id, row.local_id, "local_only", {
                        range_key=located.range, book_version=version, last_error="", last_attempt_at=os.time(),
                    })
                    row.range_key = located.range
                    -- Adopt an existing same-range cloud record instead of creating a duplicate.
                    if cloud_rows then
                        if is_review then
                            match, matched_id = find_review_match(cloud_rows, located.range, row.note, row.remote_id)
                        else
                            match, matched_id = find_bookmark_match(cloud_rows, located.range, expected_type, row.remote_id)
                        end
                    end
                    if match then
                        local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                        LocalDB.mark_synced(self.store, book_id, row.local_id, rid, located.range, version)
                        result.synced = result.synced + 1
                        result.reconciled = result.reconciled + 1
                    else
                        local payload = is_review
                            and self:_review_payload(row, located, version, prefs)
                            or self:_bookmark_payload(row, located, version, prefs)
                        local ok, value = pcall(is_review and self.api.add_review or self.api.add_bookmark,
                            self.api, payload)
                        if ok then
                            local remote_id = is_review
                                and find_id(value, {"reviewId", "reviewID"})
                                or find_id(value, {"bookmarkId", "bookmarkID"})
                            if not is_review and remote_id == "" then
                                -- Without bookmarkId we cannot later delete safely. Treat
                                -- success-without-id as unresolved and reconcile next time.
                                remember_error(row, "unknown", "服务器未返回 bookmarkId", {
                                    range_key=located.range, book_version=version,
                                })
                            else
                                LocalDB.mark_synced(self.store, book_id, row.local_id,
                                    remote_id, located.range, version)
                                result.synced = result.synced + 1
                            end
                        elseif Http.is_network_error(value) then
                            remember_error(row, "unknown", value, {
                                range_key=located.range, book_version=version,
                            })
                        else
                            remember_error(row, "local_only", value, {
                                range_key=located.range, book_version=version,
                            })
                        end
                    end
                end
            end
        end
    end

    logger.info("[MiuRead][AnnotationSync] completed",
        "book=",book_id,"total=",tostring(result.total),"synced=",tostring(result.synced),
        "deleted=",tostring(result.deleted),"locate_failed=",tostring(result.locate_failed),
        "unknown=",tostring(result.unknown),"failed=",tostring(result.failed))
    return result
end

return AnnotationSync
