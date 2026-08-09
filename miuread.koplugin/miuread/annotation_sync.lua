local logger = require("logger")
local U = require("miuread.util")
local Http = require("miuread.http")
local Coord = require("miuread.annotation_coord")
local PosMap = require("miuread.annotations.posmap")
local Range = require("miuread.annotations.range")
local LocalDB = require("miuread.local_annotation_database")
local ThoughtDatabase = require("miuread.thought_database")
local Json = require("miuread.json")
local Config = require("miuread.config")

local AnnotationSync = {}
AnnotationSync.__index = AnnotationSync

local COORD_VERSION = 2
local COORD_SOURCE = "raw_xhtml"

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

local function chapter_uid(chapter)
    return tostring(type(chapter) == "table" and
        (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
end

local function chapter_idx(chapter, fallback)
    return tonumber(type(chapter) == "table" and
        (chapter.index or chapter.chapterIdx or chapter.chapter_idx) or nil) or tonumber(fallback)
end

local function chapter_source(book, record)
    if type(record) == "table" and type(record.chapter_map) == "table" and #record.chapter_map > 0 then
        return record.chapter_map
    end
    if type(book) == "table" and type(book.catalog) == "table" and #book.catalog > 0 then
        return book.catalog
    end
    return {}
end

--- Primary chapter plus its immediate neighbours. We never scan the whole book.
local function chapter_candidates(book, record, row)
    local source = chapter_source(book, record)
    local wanted_uid = tostring(row.chapter_uid or "")
    local wanted_idx = tonumber(row.chapter_idx)
    local primary_pos

    for pos, chapter in ipairs(source) do
        if wanted_uid ~= "" and chapter_uid(chapter) == wanted_uid then
            primary_pos = pos
            break
        end
    end
    if not primary_pos and wanted_idx then
        for pos, chapter in ipairs(source) do
            if chapter_idx(chapter, pos) == wanted_idx then
                primary_pos = pos
                break
            end
        end
        if not primary_pos and source[wanted_idx] then primary_pos = wanted_idx end
    end

    local out, seen = {}, {}
    local function add(chapter, pos, primary)
        if type(chapter) ~= "table" then return end
        local uid = chapter_uid(chapter)
        local idx = chapter_idx(chapter, pos)
        local key = uid ~= "" and ("u:" .. uid) or ("i:" .. tostring(idx or pos or ""))
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = {chapter=U.copy(chapter), pos=pos, primary=primary == true,
            uid=uid, idx=idx}
    end

    if primary_pos then
        add(source[primary_pos], primary_pos, true)
        add(source[primary_pos - 1], primary_pos - 1, false)
        add(source[primary_pos + 1], primary_pos + 1, false)
    elseif wanted_uid ~= "" then
        add({uid=wanted_uid, chapterUid=wanted_uid, index=wanted_idx}, wanted_idx, true)
    elseif wanted_idx and source[wanted_idx] then
        add(source[wanted_idx], wanted_idx, true)
        add(source[wanted_idx - 1], wanted_idx - 1, false)
        add(source[wanted_idx + 1], wanted_idx + 1, false)
    end
    return out
end

local function visible_slice(map, text_start, count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if not map or not text_start or count <= 0 then return "" end
    local last = math.min(#(map.text_runes or {}), text_start + count - 1)
    if last < text_start then return "" end
    return table.concat(map.text_runes, "", text_start, last)
end

local function stage_log(row, stage, ok, detail)
    logger.info("[MiuRead][AnnotationSync]",
        "kind=", tostring(row and row.kind or ""),
        "local=", tostring(row and row.local_id or ""),
        "stage=", tostring(stage or ""),
        "ok=", ok and "true" or "false",
        detail and ("detail=" .. tostring(detail)) or "")
end

local function diagnostic_root(store, book_id)
    return store:book_dir(book_id) .. "/annotation-coordinate-diagnostics"
end

local function diagnostic_chapter_dir(store, book_id, chapter_uid_value)
    return diagnostic_root(store, book_id) .. "/" .. U.id_name(tostring(chapter_uid_value or "unknown"))
end

local function first_abstract(group)
    for _, item in ipairs(type(group) == "table" and group.texts or {}) do
        local abstract = U.trim(tostring(item.abstract or ""))
        if abstract ~= "" then return abstract, tostring(item.review_id or "") end
    end
    return "", ""
end

local function official_anchor_rows(store, book_id, chapter_uid_value)
    local groups = ThoughtDatabase.load_chapter(store, book_id, chapter_uid_value)
    if type(groups) ~= "table" then return {} end
    local out = {}
    for _, group in ipairs(groups) do
        local abstract, review_id = first_abstract(group)
        if tostring(group.range or "") ~= "" then
            out[#out + 1] = {
                range=tostring(group.range or ""),
                abstract=abstract,
                review_id=review_id,
                comment_count=#(group.texts or {}),
            }
        end
    end
    return out
end


local function distributed_anchor_rows(rows, max_count)
    rows = type(rows) == "table" and rows or {}
    max_count = math.max(1, math.floor(tonumber(max_count) or 8))
    if #rows <= max_count then return rows end
    local out, seen = {}, {}
    for i = 0, max_count - 1 do
        local pos = math.floor((i * (#rows - 1)) / (max_count - 1) + 0.5) + 1
        if not seen[pos] and rows[pos] then
            seen[pos] = true
            out[#out + 1] = rows[pos]
        end
    end
    return out
end

--- Use existing WeRead range+abstract pairs as an external coordinate-basis check.
-- Some review groups use an abstract that is only a subquote of the shared range,
-- so beta.11 samples anchors across the chapter and uses a conservative match ratio
-- instead of demanding every historical group be byte-identical.
function AnnotationSync:_verify_coordinate_basis(book_id, chapter_ctx)
    if type(chapter_ctx) ~= "table" or type(chapter_ctx.map) ~= "table" then
        return {status="mismatch", checked=0, matched=0, total=0, error="coord_map_missing"}
    end
    if type(chapter_ctx.coord_verification) == "table" then
        return chapter_ctx.coord_verification
    end

    local anchors = official_anchor_rows(self.store, book_id, chapter_ctx.chapter_uid)
    local sampled = distributed_anchor_rows(anchors, 8)
    local checked, matched = 0, 0
    for _, anchor in ipairs(sampled) do
        local expected = clean_text(anchor.abstract)
        if expected ~= "" and tostring(anchor.range or "") ~= "" then
            local resolved = Coord.resolveRangeOnMap(chapter_ctx.map, tostring(anchor.range))
            if resolved and clean_text(resolved.text) ~= "" then
                checked = checked + 1
                if clean_text(resolved.text) == expected then matched = matched + 1 end
            end
        end
    end

    local result = {
        status="local_verified",
        checked=checked,
        matched=matched,
        total=#anchors,
        source=COORD_SOURCE,
        version=COORD_VERSION,
    }
    if checked >= 3 then
        local ratio = matched / checked
        result.ratio = ratio
        if matched >= 3 and ratio >= 0.60 then
            result.status = "official_verified"
        else
            result.status = "mismatch"
            result.error = string.format("official_anchor_mismatch:%d/%d", matched, checked)
        end
    elseif #anchors > 0 then
        result.note = "official_anchors_inconclusive"
    else
        result.note = "no_official_anchors"
    end

    chapter_ctx.coord_verification = result
    logger.info("[MiuRead][AnnotationSync] coordinate basis",
        "book=", tostring(book_id), "chapter=", tostring(chapter_ctx.chapter_uid or ""),
        "source=", COORD_SOURCE, "version=", tostring(COORD_VERSION),
        "status=", tostring(result.status), "anchors=", tostring(result.total),
        "checked=", tostring(result.checked), "matched=", tostring(result.matched))
    return result
end

local function diagnostic_local_row(row, located, locate_error, locate_stage)
    return {
        local_id=tostring(row.local_id or ""), kind=tostring(row.kind or ""),
        sync_state=tostring(row.sync_state or ""), remote_id=tostring(row.remote_id or ""),
        stored_range=tostring(row.range_key or ""), calculated_range=located and tostring(located.range or "") or "",
        selected_text=tostring(row.selected_text or row.text or ""), note=tostring(row.note or ""),
        context_before=tostring(row.context_before or ""), context_after=tostring(row.context_after or ""),
        pos0=tostring(row.pos0 or ""), pos1=tostring(row.pos1 or ""), xpointer=tostring(row.xpointer or ""),
        chapter_uid=tostring(row.chapter_uid or ""), chapter_idx=tonumber(row.chapter_idx),
        locate_ok=located ~= nil, locate_stage=tostring(locate_stage or ""),
        locate_error=tostring(locate_error or ""),
        coord_version=located and tonumber(located.coord_version) or tonumber(row.coord_version or 0) or 0,
        coord_source=located and tostring(located.coord_source or "") or tostring(row.coord_source or ""),
        coord_verify=located and tostring(located.coord_verify or "") or tostring(row.coord_verify or ""),
        anchor_checked=located and tonumber(located.anchor_checked or 0) or 0,
        anchor_matched=located and tonumber(located.anchor_matched or 0) or 0,
    }
end

local function copy_diagnostic_file(source, target, max_bytes)
    source = tostring(source or "")
    if source == "" then return false, "source_missing" end
    local size = U.file_size(source)
    if not size then return false, "source_not_found" end
    if max_bytes and size > max_bytes then return false, "source_too_large:" .. tostring(size) end
    local data, read_error = U.read_file(source, true)
    if data == nil then return false, read_error or "read_failed" end
    return U.atomic_write(target, data, true)
end

function AnnotationSync:_save_coordinate_diagnostics(book_id, chapters)
    local root = diagnostic_root(self.store, book_id)
    U.mkdir(root)
    local copied = {}
    local thoughts_path = ThoughtDatabase.path(self.store, book_id)
    local local_db_path = LocalDB.path(self.store, book_id)
    copied.thoughts = copy_diagnostic_file(thoughts_path, root .. "/thoughts.sqlite3", 64 * 1024 * 1024) == true
    copied.local_annotations = copy_diagnostic_file(local_db_path, root .. "/local_annotations.sqlite3", 64 * 1024 * 1024) == true
    local exported = 0
    for uid, diag in pairs(chapters or {}) do
        local dir = diagnostic_chapter_dir(self.store, book_id, uid)
        U.mkdir(dir)
        if tostring(diag.raw_html or "") ~= "" then
            local ok, err = U.atomic_write(dir .. "/raw.xhtml", diag.raw_html, true)
            if not ok then logger.warn("[MiuRead][AnnotationCoordDiag] raw write failed", "chapter=", uid, "error=", tostring(err)) end
        end
        if tostring(diag.coord_html or "") ~= "" then
            local ok, err = U.atomic_write(dir .. "/coord.xhtml", diag.coord_html, true)
            if not ok then logger.warn("[MiuRead][AnnotationCoordDiag] coord write failed", "chapter=", uid, "error=", tostring(err)) end
        end
        local payload = {
            format="miuread-annotation-coordinate-diagnostic-v2",
            version=Config.VERSION,
            generated_at=os.time(),
            book_id=tostring(book_id or ""),
            chapter_uid=tostring(uid or ""),
            chapter_idx=diag.chapter_idx,
            chapter_title=tostring(diag.chapter_title or ""),
            raw_bytes=#tostring(diag.raw_html or ""),
            coord_bytes=#tostring(diag.coord_html or ""),
            source_epub=tostring(diag.source_epub or ""),
            thoughts_database=ThoughtDatabase.path(self.store, book_id),
            local_annotations_database=LocalDB.path(self.store, book_id),
            local_annotations=diag.local_annotations or {},
            official_anchors=official_anchor_rows(self.store, book_id, uid),
            notes={
                "raw.xhtml is the complete decrypted chapter before MiuRead body extraction or image rewriting.",
                "coord.xhtml is the exact coordinate source currently used by MiuRead; beta.11 keeps the full XHTML.",
                "official_anchors are existing WeRead ranges from thoughts.sqlite3 and are the external reference.",
                "A diagnostic export never performs cloud annotation writes.",
            },
        }
        local ok_json, encoded = pcall(Json.encode, payload)
        if ok_json then
            local ok, err = U.atomic_write(dir .. "/range-debug.json", encoded, false)
            if not ok then logger.warn("[MiuRead][AnnotationCoordDiag] json write failed", "chapter=", uid, "error=", tostring(err)) end
        else
            logger.warn("[MiuRead][AnnotationCoordDiag] json encode failed", "chapter=", uid, "error=", tostring(encoded))
        end
        local readme = table.concat({
            "MiuRead annotation coordinate diagnostic",
            "bookId=" .. tostring(book_id or ""),
            "chapterUid=" .. tostring(uid or ""),
            "raw.xhtml = complete decrypted XHTML",
            "coord.xhtml = current MiuRead range coordinate source",
            "range-debug.json = local ranges + official WeRead range anchors",
            "Also provide thoughts.sqlite3, local_annotations.sqlite3 and the generated EPUB to AI.",
        }, "\n")
        U.atomic_write(dir .. "/README.txt", readme, false)
        logger.info("[MiuRead][AnnotationCoordDiag] exported",
            "book=", tostring(book_id), "chapter=", tostring(uid),
            "raw_bytes=", tostring(payload.raw_bytes), "coord_bytes=", tostring(payload.coord_bytes),
            "local_rows=", tostring(#payload.local_annotations),
            "official_anchors=", tostring(#payload.official_anchors), "dir=", dir)
        if not copied.epub and tostring(diag.source_epub or "") ~= "" then
            local ok, reason = copy_diagnostic_file(diag.source_epub, root .. "/generated.epub", 64 * 1024 * 1024)
            if ok then copied.epub = true else copied.epub_error = tostring(reason or "copy_failed") end
        end
        exported = exported + 1
    end
    local bundle_readme = table.concat({
        "MiuRead beta.11 coordinate diagnostic bundle",
        "Upload this annotation-coordinate-diagnostics folder to AI.",
        "Included when available: thoughts.sqlite3, local_annotations.sqlite3, generated.epub.",
        "Each chapter folder contains raw.xhtml, coord.xhtml and range-debug.json.",
        "Diagnostic export does not perform cloud annotation writes.",
        "bookId=" .. tostring(book_id or ""),
        "thoughts_copy=" .. tostring(copied.thoughts == true),
        "local_annotations_copy=" .. tostring(copied.local_annotations == true),
        "generated_epub_copy=" .. tostring(copied.epub == true),
        copied.epub_error and ("generated_epub_copy_error=" .. copied.epub_error) or "",
    }, "\n")
    U.atomic_write(root .. "/README.txt", bundle_readme, false)
    return root, exported
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
    -- Observed web requests allow a zero fallback. The payload is still gated by
    -- range/text verification, and any business rejection remains local.
    return 0
end

function AnnotationSync:_coord_map_for_chapter(book, row, candidate, cache)
    local chapter = U.copy(candidate and candidate.chapter or {})
    local uid = chapter_uid(chapter)
    if uid == "" then uid = tostring(candidate and candidate.uid or row.chapter_uid or "") end
    local idx = chapter_idx(chapter, candidate and candidate.idx or row.chapter_idx)
    if uid == "" then return nil, "chapter_uid_missing" end
    local cache_key = uid .. ":" .. tostring(idx or "")
    if cache[cache_key] then return cache[cache_key] end

    chapter.chapterUid = chapter.chapterUid or chapter.uid or uid
    chapter.uid = chapter.uid or chapter.chapterUid
    chapter.index = chapter.index or idx
    chapter.title = chapter.title or ""
    local book_arg = {
        bookId=tostring(book.book_id or book.bookId or row.book_id or ""),
        book_id=tostring(book.book_id or book.bookId or row.book_id or ""),
        title=book.title, author=book.author,
    }
    local ok, downloaded, style, assets, state = pcall(self.reader.chapter, self.reader,
        book_arg, chapter, "epub", {images=false})
    if not ok then return nil, "coord_fetch_failed:" .. tostring(downloaded) end
    local coord_html = type(state) == "table" and tostring(state.coord_html or "") or ""
    if coord_html == "" then return nil, "coord_html_missing" end

    -- The current reader injects only tags into the visible text. We still use
    -- the official bridge path with an empty star list so the sync path stays
    -- compatible with future visible star injection.
    local stars = type(state) == "table" and type(state.annotation_stars) == "table"
        and state.annotation_stars or {}
    local built_ok, bridge = pcall(PosMap.buildBridge, coord_html, stars)
    if not built_ok or type(bridge) ~= "table" or type(bridge.coord) ~= "table" then
        return nil, tostring(bridge or "coord_bridge_failed")
    end
    local raw_html = type(state) == "table" and tostring(state.raw_xhtml or "") or ""
    if raw_html == "" then raw_html = tostring(downloaded or "") end
    local ctx = {map=bridge.coord, bridge=bridge, html=coord_html, raw_html=raw_html, chapter=chapter,
        chapter_uid=uid, chapter_idx=idx}
    cache[cache_key] = ctx
    return ctx
end

function AnnotationSync:_locate(row, chapter_ctx)
    local map = chapter_ctx.map
    local bridge = chapter_ctx.bridge
    local opts = {
        context_before=tostring(row.context_before or ""),
        context_after=tostring(row.context_after or ""),
    }

    if row.kind == "bookmark" then
        local anchor = U.trim(tostring(row.anchor_text or ""))
        if anchor == "" then return nil, "bookmark_anchor_missing" end
        local html_start, last_error
        local seen = {}
        for _, limit in ipairs({96, 80, 64, 48, 32, 24, 16}) do
            local candidate = U.trim(U.utf8_truncate(anchor, limit, ""))
            if candidate ~= "" and not seen[candidate] then
                seen[candidate] = true
                local range_key, start_or_error = PosMap.locateInjected(bridge, candidate)
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
        return {range=point, mark_text=mark_text, html_start=html_start,
            text_start=text_start, point=true, coord_version=COORD_VERSION, coord_source=COORD_SOURCE}
    end

    local mark_text = U.trim(tostring(row.selected_text or ""))
    if mark_text == "" then mark_text = U.trim(tostring(row.text or "")) end
    if mark_text == "" then return nil, "mark_text_missing" end

    local range_key, html_start, html_end_pos = PosMap.locateInjected(bridge, mark_text, opts)
    if not range_key then return nil, tostring(html_start or "not_found") end
    local resolved = Coord.resolveRangeOnMap(map, range_key)
    if not resolved or clean_text(resolved.text) ~= clean_text(mark_text) then
        return nil, "range_verify_failed"
    end
    local round = Coord.roundTrip(chapter_ctx.html, range_key)
    if not (round and round.ok) then return nil, "range_roundtrip_failed" end
    -- Upload the text re-extracted from coord_html, not the injected KOReader
    -- selection. This keeps markText/abstract free of local display markers.
    return {range=range_key, mark_text=resolved.text, html_start=html_start,
        html_end_pos=html_end_pos, point=false, coord_version=COORD_VERSION, coord_source=COORD_SOURCE}
end

local function can_try_neighbour(error_code)
    error_code = tostring(error_code or "")
    return error_code == "not_found" or error_code == "bad_align"
        or error_code == "range_verify_failed" or error_code == "range_roundtrip_failed"
        or error_code == "bookmark_not_found"
end

function AnnotationSync:_locate_with_chapter_candidates(book, record, row, cache)
    local candidates = chapter_candidates(book, record, row)
    if #candidates == 0 then return nil, nil, "chapter_metadata_missing", "chapter" end

    local primary = candidates[1]
    local primary_ctx, primary_ctx_error = self:_coord_map_for_chapter(book, row, primary, cache)
    if not primary_ctx then return nil, nil, primary_ctx_error, "chapter" end
    local located, locate_error = self:_locate(row, primary_ctx)
    if located then return located, primary_ctx end
    if not can_try_neighbour(locate_error) then return nil, primary_ctx, locate_error, "locate" end

    local successes = {}
    for index=2,#candidates do
        local ctx = self:_coord_map_for_chapter(book, row, candidates[index], cache)
        if ctx then
            local candidate_located = self:_locate(row, ctx)
            if candidate_located then
                successes[#successes + 1] = {located=candidate_located, ctx=ctx}
            end
        end
    end
    if #successes == 1 then return successes[1].located, successes[1].ctx end
    if #successes > 1 then return nil, nil, "chapter_ambiguous", "chapter" end
    return nil, primary_ctx, locate_error, "locate"
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
    local chapter_uid = tonumber(row.chapter_uid) or tostring(row.chapter_uid or "")
    local payload = {
        bookId=tostring(row.book_id or ""),
        -- chapterInfos/currentChapter uses a numeric chapterUid in the Web reader.
        -- Preserve a non-numeric fallback only for unusual content variants.
        chapterUid=chapter_uid,
        chapterIdx=tonumber(row.chapter_idx) or 0,
        bookVersion=tonumber(version) or 0,
        type=is_bookmark and 0 or 1,
        style=is_bookmark and 0 or tonumber(prefs.highlight_style) or 1,
        range=tostring(located.range or ""),
        -- WeRead Web passes the selected UTF-8 text verbatim into ADD_BOOKMARK.
        markText=tostring(located.mark_text or ""),
    }
    -- The Web corner-bookmark request has no colorStyle field. Highlight
    -- requests do, and their default is color 0 with underline style 1.
    if not is_bookmark then payload.colorStyle=tonumber(prefs.highlight_color) or 0 end
    return payload
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

local function validate_payload(row, payload)
    if tostring(payload.bookId or "") == "" then return nil, "bookId_missing" end
    if tostring(payload.chapterUid or "") == "" then return nil, "chapterUid_missing" end
    if tostring(payload.range or "") == "" then return nil, "range_missing" end
    local start, ending, point = Range.parse(tostring(payload.range))
    if not start or not ending then return nil, "range_invalid" end
    if row.kind == "bookmark" then
        if not point then return nil, "bookmark_range_not_point" end
        if tonumber(payload.type) ~= 0 then return nil, "bookmark_type_invalid" end
        if tostring(payload.markText or "") == "" then return nil, "bookmark_markText_missing" end
    elseif row.kind == "highlight" then
        if point then return nil, "highlight_range_is_point" end
        if tonumber(payload.type) ~= 1 then return nil, "highlight_type_invalid" end
        if tostring(payload.markText or "") == "" then return nil, "highlight_markText_missing" end
    elseif row.kind == "thought" then
        if point then return nil, "review_range_is_point" end
        if U.trim(tostring(payload.abstract or "")) == "" then return nil, "review_abstract_missing" end
        if U.trim(tostring(payload.content or "")) == "" then return nil, "review_content_missing" end
    else
        return nil, "annotation_kind_invalid"
    end
    return true
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
    local diagnostic_only = options.diagnostic_only == true or Config.ANNOTATION_COORD_DIAGNOSTIC_ONLY == true
    local rows, rows_error
    if diagnostic_only then
        rows, rows_error = LocalDB.list(self.store, book_id, options.limit or 200)
    else
        rows, rows_error = LocalDB.pending(self.store, book_id, options.limit or 200)
    end
    if not rows then return {ok=false, error=rows_error} end
    local summary = LocalDB.summary(self.store, book_id) or {}
    local result = {ok=true,total=#rows,synced=0,deleted=0,failed=0,locate_failed=0,
        metadata_failed=0,coord_failed=0,unknown=0,skipped=0,reconciled=0,errors={}, diagnostic_only=diagnostic_only,
        diagnostic_exported=0, diagnostic_root=diagnostic_root(self.store, book_id),
        legacy_synced=tonumber(summary.legacy_synced or 0) or 0}
    if #rows == 0 then return result end

    local need_bookmarks, need_reviews = false, false
    for _, row in ipairs(rows) do
        if row.kind == "thought" then need_reviews = true else need_bookmarks = true end
    end
    local cloud_bookmarks, bookmark_error = {}, nil
    local cloud_reviews, review_error = {}, nil
    if not diagnostic_only then
        if need_bookmarks then cloud_bookmarks, bookmark_error = fetch_cloud_bookmarks(self.api, book_id) end
        if need_reviews then cloud_reviews, review_error = fetch_cloud_reviews(self.api, book_id) end
    else
        cloud_bookmarks, cloud_reviews = nil, nil
    end
    if not diagnostic_only then
        if need_bookmarks and not cloud_bookmarks then bookmark_error = bookmark_error or "bookmark reconciliation failed" end
        if need_reviews and not cloud_reviews then review_error = review_error or "review reconciliation failed" end
    end

    local version = diagnostic_only and 0 or self:_book_version(book_id, book or {}, record or {})
    local coord_cache = {}
    local diagnostic_chapters = {}

    local function remember_error(row, state, message, stage, fields)
        fields = fields or {}
        fields.last_stage = tostring(stage or "unknown")
        fields.last_error = tostring(message or "")
        fields.last_attempt_at = os.time()
        LocalDB.mark_state(self.store, book_id, row.local_id, state, fields)
        result.failed = result.failed + 1
        if state == "locate_failed" then result.locate_failed = result.locate_failed + 1 end
        if state == "metadata_failed" then result.metadata_failed = result.metadata_failed + 1 end
        if state == "coord_failed" then result.coord_failed = result.coord_failed + 1 end
        if state == "unknown" or state == "delete_unknown" then result.unknown = result.unknown + 1 end
        if #result.errors < 12 then
            result.errors[#result.errors + 1] = {
                kind=tostring(row.kind or ""), stage=tostring(stage or "unknown"),
                error=tostring(message or state),
            }
        end
        stage_log(row, stage, false, message)
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

        if diagnostic_only then
            stage_log(row, "diagnostic", true, "coordinate_export")
            local located, chapter_ctx, locate_error, locate_stage =
                self:_locate_with_chapter_candidates(book or {}, record or {}, row, coord_cache)
            local ctx = chapter_ctx
            local uid = tostring(ctx and ctx.chapter_uid or row.chapter_uid or "unknown")
            local diag = diagnostic_chapters[uid]
            if not diag then
                diag = {
                    raw_html=ctx and tostring(ctx.raw_html or "") or "",
                    coord_html=ctx and tostring(ctx.html or "") or "",
                    chapter_idx=ctx and ctx.chapter_idx or row.chapter_idx,
                    chapter_title=ctx and ctx.chapter and tostring(ctx.chapter.title or "") or "",
                    source_epub=tostring(row.source_path or ""),
                    local_annotations={},
                }
                diagnostic_chapters[uid] = diag
            end
            if located then
                local verification = self:_verify_coordinate_basis(book_id, chapter_ctx)
                located.coord_verify = tostring(verification.status or "local_verified")
                located.anchor_checked = tonumber(verification.checked or 0) or 0
                located.anchor_matched = tonumber(verification.matched or 0) or 0
                diag.local_annotations[#diag.local_annotations + 1] =
                    diagnostic_local_row(row, located, locate_error, locate_stage)
                stage_log(row, "diagnostic", true, "range=" .. tostring(located.range or ""))
                logger.info("[MiuRead][AnnotationCoordDiag] range",
                    "book=", tostring(book_id), "chapter=", tostring(uid),
                    "local=", tostring(row.local_id or ""), "kind=", tostring(row.kind or ""),
                    "stored=", tostring(row.range_key or ""), "calculated=", tostring(located.range or ""),
                    "coord=", tostring(verification.status or ""),
                    "anchors=", tostring(verification.matched or 0) .. "/" .. tostring(verification.checked or 0),
                    "text=", U.utf8_truncate(tostring(row.selected_text or row.text or ""), 48, "…"))
            else
                diag.local_annotations[#diag.local_annotations + 1] =
                    diagnostic_local_row(row, located, locate_error, locate_stage)
                result.failed = result.failed + 1
                if #result.errors < 12 then
                    result.errors[#result.errors + 1] = {kind=tostring(row.kind or ""),
                        stage=tostring(locate_stage or "locate"), error=tostring(locate_error or "diagnostic locate failed")}
                end
                stage_log(row, "diagnostic", false, locate_error or "locate_failed")
            end
            result.skipped = result.skipped + 1
        elseif row.sync_state == "delete_pending" or row.sync_state == "delete_unknown" then
            -- A local tombstone is only removed after cloud reconciliation proves
            -- the remote item is already absent or a delete request returns
            -- successfully. Network-unknown writes remain retry-blocked until the
            -- next reconciliation pass, exactly like create writes.
            if not cloud_rows then
                remember_error(row, row.sync_state, "删除前云端对账失败：" .. tostring(cloud_error or "unknown"), "reconcile")
            elseif row.remote_id ~= "" and not match then
                LocalDB.delete_row(self.store, book_id, row.local_id)
                result.deleted = result.deleted + 1
                stage_log(row, "delete", true, "already_absent")
            else
                local remote_id = row.remote_id ~= "" and row.remote_id or matched_id
                if remote_id == "" then
                    remember_error(row, "delete_pending",
                        is_review and "缺少 reviewId，无法安全删除" or "缺少 bookmarkId，无法安全删除", "delete")
                else
                    local ok, value
                    if is_review then
                        -- WeRead's reader dispatches FETCH_BOOK_REVIEW_DELETE with
                        -- reviewId plus the current book/chapter/range context.
                        -- Keep the full context when available instead of reducing
                        -- the request to reviewId only.
                        local delete_payload = {
                            reviewId=remote_id,
                            bookId=book_id,
                            chapterUid=tostring(row.chapter_uid or ""),
                            range=tostring(row.range_key or ""),
                            bookVersion=tonumber(row.book_version) or tonumber(version) or 0,
                        }
                        stage_log(row, "delete", true, "post review/delete")
                        ok, value = pcall(self.api.remove_review, self.api, delete_payload)
                    else
                        stage_log(row, "delete", true, "post book/removeBookmark")
                        ok, value = pcall(self.api.remove_bookmark, self.api, remote_id, {
                            bookId=book_id, chapterUid=row.chapter_uid,
                        })
                    end
                    if ok then
                        LocalDB.delete_row(self.store, book_id, row.local_id)
                        result.deleted = result.deleted + 1
                        stage_log(row, "delete", true, "remote_deleted")
                    elseif Http.is_network_error(value) then
                        remember_error(row, "delete_unknown", value, "delete", {remote_id=remote_id})
                    else
                        remember_error(row, "delete_pending", value, "delete", {remote_id=remote_id})
                    end
                end
            end
        elseif row.sync_state == "unknown" then
            if cloud_rows and match then
                local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                LocalDB.mark_synced(self.store, book_id, row.local_id, rid, row.range_key, version)
                result.synced = result.synced + 1
                result.reconciled = result.reconciled + 1
                stage_log(row, "reconcile", true, "existing_remote")
            else
                remember_error(row, "unknown", cloud_error and ("云端对账失败："..cloud_error)
                    or "上次请求结果未知，未自动重复上传", "reconcile")
            end
        else
            stage_log(row, "chapter", true, "resolve")
            local located, chapter_ctx, locate_error, locate_stage =
                self:_locate_with_chapter_candidates(book or {}, record or {}, row, coord_cache)
            if not located then
                local state = locate_stage == "chapter" and "metadata_failed" or "locate_failed"
                remember_error(row, state, locate_error, locate_stage or "locate")
            else
                row.chapter_uid = tostring(chapter_ctx.chapter_uid or chapter_uid(chapter_ctx.chapter) or row.chapter_uid or "")
                row.chapter_idx = tonumber(chapter_ctx.chapter_idx or chapter_idx(chapter_ctx.chapter) or row.chapter_idx)
                local verification = self:_verify_coordinate_basis(book_id, chapter_ctx)
                located.coord_verify = tostring(verification.status or "local_verified")
                located.anchor_checked = tonumber(verification.checked or 0) or 0
                located.anchor_matched = tonumber(verification.matched or 0) or 0
                if verification.status == "mismatch" then
                    remember_error(row, "coord_failed", verification.error or "coord_basis_mismatch", "coord_basis", {
                        range_key=located.range, book_version=version,
                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                        coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify="mismatch",
                    })
                else
                    stage_log(row, "verify", true, string.format("%s coord=%s anchors=%d/%d",
                        tostring(located.range), tostring(verification.status),
                        tonumber(verification.matched or 0) or 0, tonumber(verification.checked or 0) or 0))
                    LocalDB.mark_state(self.store, book_id, row.local_id, "local_only", {
                        range_key=located.range, book_version=version,
                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                        coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                        last_stage="verify", last_error="", last_attempt_at=os.time(),
                    })
                    row.range_key = located.range
                    row.coord_version = COORD_VERSION
                    row.coord_source = COORD_SOURCE
                    row.coord_verify = verification.status

                    if cloud_rows then
                        if is_review then
                            match, matched_id = find_review_match(cloud_rows, located.range, row.note, row.remote_id)
                        else
                            match, matched_id = find_bookmark_match(cloud_rows, located.range, expected_type, row.remote_id)
                        end
                    end
                    if match then
                        local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                        LocalDB.mark_synced(self.store, book_id, row.local_id, rid, located.range, version, {
                            chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                            coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                        })
                        result.synced = result.synced + 1
                        result.reconciled = result.reconciled + 1
                        stage_log(row, "reconcile", true, "existing_remote")
                    else
                        -- A brand-new local record has never been POSTed by MiuRead, so a
                        -- temporary failure to read the cloud list must not block its first
                        -- upload forever. We still use the list for de-duplication whenever
                        -- it is available. Only `unknown` records require reconciliation
                        -- before another POST, because their previous write may have reached
                        -- the server despite a lost response.
                        if not cloud_rows then
                            stage_log(row, "reconcile", true,
                                "preflight_unavailable_first_post:" .. tostring(cloud_error or "unknown"))
                        end
                        local payload = is_review
                            and self:_review_payload(row, located, version, prefs)
                            or self:_bookmark_payload(row, located, version, prefs)
                        if not is_review then
                            stage_log(row, "payload", true, string.format(
                                "book/addBookmark type=%d style=%d color=%s chapterIdx=%d bookVersion=%d markText=plain chars=%d",
                                tonumber(payload.type) or -1, tonumber(payload.style) or -1,
                                payload.colorStyle==nil and "none" or tostring(tonumber(payload.colorStyle) or 0),
                                tonumber(payload.chapterIdx) or -1, tonumber(payload.bookVersion) or 0,
                                U.utf8_len(tostring(payload.markText or ""))))
                        end
                        local payload_ok, payload_error = validate_payload(row, payload)
                        if not payload_ok then
                            remember_error(row, "metadata_failed", payload_error, "payload", {
                                range_key=located.range, book_version=version,
                                chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                            })
                        else
                            stage_log(row, "post", true, is_review and "review/add" or "book/addBookmark")
                            local ok, value = pcall(is_review and self.api.add_review or self.api.add_bookmark,
                                self.api, payload)
                            if ok then
                                local remote_id = is_review
                                    and find_id(value, {"reviewId", "reviewID"})
                                    or find_id(value, {"bookmarkId", "bookmarkID"})
                                if not is_review and remote_id == "" then
                                    remember_error(row, "unknown", "服务器未返回 bookmarkId", "post", {
                                        range_key=located.range, book_version=version,
                                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                        coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                                    })
                                else
                                    LocalDB.mark_synced(self.store, book_id, row.local_id,
                                        remote_id, located.range, version, {
                                            chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                            coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                                        })
                                    result.synced = result.synced + 1
                                    stage_log(row, "post", true, remote_id ~= "" and "remote_id_saved" or "review_saved")
                                end
                            elseif Http.is_network_error(value) then
                                remember_error(row, "unknown", value, "post", {
                                    range_key=located.range, book_version=version,
                                    chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                    coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                                })
                            else
                                remember_error(row, "local_only", value, "post", {
                                    range_key=located.range, book_version=version,
                                    chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                    coord_version=COORD_VERSION, coord_source=COORD_SOURCE, coord_verify=verification.status,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    if diagnostic_only then
        local root, exported = self:_save_coordinate_diagnostics(book_id, diagnostic_chapters)
        result.diagnostic_root = root
        result.diagnostic_exported = exported
        logger.info("[MiuRead][AnnotationCoordDiag] cloud writes paused", "book=", book_id,
            "chapters=", tostring(exported), "root=", tostring(root))
    end

    logger.info("[MiuRead][AnnotationSync] completed",
        "book=",book_id,"total=",tostring(result.total),"synced=",tostring(result.synced),
        "deleted=",tostring(result.deleted),"locate_failed=",tostring(result.locate_failed),
        "metadata_failed=",tostring(result.metadata_failed),
        "coord_failed=",tostring(result.coord_failed),
        "legacy_synced=",tostring(result.legacy_synced),
        "unknown=",tostring(result.unknown),"failed=",tostring(result.failed))
    return result
end

return AnnotationSync
