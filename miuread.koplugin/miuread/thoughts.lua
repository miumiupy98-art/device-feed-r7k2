local Json = require("miuread.json")
local U = require("miuread.util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Thoughts = {}

local CHAPTER_CACHE_LIMIT = 1
local INDEX_CACHE_LIMIT = 2
local POPUP_CACHE_LIMIT = 8
local INDEX_VERSION = 1
local INDEX_COMPLETE_MARKER = "thought-index-v1.complete"
local chapter_cache = {}
local chapter_cache_order = {}
local index_cache = {}
local index_cache_order = {}
local popup_cache = {}
local popup_cache_order = {}

local function cache_touch(order, key)
    for i = #order, 1, -1 do
        if order[i] == key then table.remove(order, i); break end
    end
    order[#order + 1] = key
end

local function cache_trim(cache, order, limit)
    while #order > limit do
        local expired = table.remove(order, 1)
        cache[expired] = nil
    end
end

local compact_group

local function file_signature(path)
    local attr = lfs.attributes(path)
    if type(attr) ~= "table" then return nil end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

local function thought_index_paths(source_path)
    local root, name = tostring(source_path or ""):match("^(.*)/thoughts/([^/]+)%.json$")
    if not root or not name then return nil end
    local dir = root .. "/thought-index"
    U.mkdir(dir)
    return dir .. "/" .. name .. ".json", dir .. "/" .. name .. ".data"
end

local function invalidate_index_path(source_path)
    local index_path = thought_index_paths(source_path)
    if not index_path then return end
    index_cache[index_path] = nil
    for i = #index_cache_order, 1, -1 do
        if index_cache_order[i] == index_path then table.remove(index_cache_order, i) end
    end
end

local function remove_index_files(source_path)
    local index_path, data_path = thought_index_paths(source_path)
    if not index_path then return end
    invalidate_index_path(source_path)
    os.remove(index_path)
    os.remove(index_path .. ".tmp")
    os.remove(data_path)
    os.remove(data_path .. ".tmp")
end

local function build_index_from_rows(source_path, rows)
    local index_path, data_path = thought_index_paths(source_path)
    if not index_path then return nil, "想法缓存路径无效" end
    local source_signature = file_signature(source_path)
    if not source_signature then return nil, "想法缓存不存在" end

    local chunks, entries, offset = {}, {}, 0
    for _, group in ipairs(rows or {}) do
        local item = compact_group(group)
        local range = item and tostring(item.range or "") or ""
        if item and range ~= "" and entries[range] == nil then
            local encoded = Json.encode(item)
            entries[range] = {offset=offset, length=#encoded}
            chunks[#chunks + 1] = encoded
            chunks[#chunks + 1] = "\n"
            offset = offset + #encoded + 1
        end
    end

    local data = table.concat(chunks)
    local wrote_data, data_error = U.atomic_write(data_path, data, true)
    if not wrote_data then return nil, "想法索引数据写入失败：" .. tostring(data_error) end
    local index = {
        version=INDEX_VERSION,
        source_signature=source_signature,
        generated_at=os.time(),
        count=0,
        entries=entries,
    }
    for _ in pairs(entries) do index.count = index.count + 1 end
    local wrote_index, index_error = U.atomic_write(index_path, Json.encode(index), true)
    if not wrote_index then
        os.remove(data_path)
        return nil, "想法索引写入失败：" .. tostring(index_error)
    end
    invalidate_index_path(source_path)
    return index.count, index_path
end

local function load_compact_index(source_path)
    local source_signature = file_signature(source_path)
    if not source_signature then return nil, "想法缓存不存在" end
    local index_path, data_path = thought_index_paths(source_path)
    if not index_path or not file_signature(index_path) or not file_signature(data_path) then
        return nil, "想法索引不存在"
    end
    local index_signature = file_signature(index_path)
    local cached = index_cache[index_path]
    if cached and cached.index_signature == index_signature
        and cached.source_signature == source_signature then
        cache_touch(index_cache_order, index_path)
        return cached.index, nil, data_path, true
    end
    local raw = U.read_file(index_path, true)
    if not raw then return nil, "想法索引不存在" end
    local ok, index = pcall(Json.decode, raw)
    if not ok or type(index) ~= "table" or tonumber(index.version) ~= INDEX_VERSION
        or tostring(index.source_signature or "") ~= tostring(source_signature)
        or type(index.entries) ~= "table" then
        return nil, "想法索引已过期"
    end
    index_cache[index_path] = {
        index=index,
        index_signature=index_signature,
        source_signature=source_signature,
    }
    cache_touch(index_cache_order, index_path)
    cache_trim(index_cache, index_cache_order, INDEX_CACHE_LIMIT)
    return index, nil, data_path, false
end

local function find_indexed(source_path, range)
    local index, err, data_path, cache_hit = load_compact_index(source_path)
    if not index then return nil, err end
    local entry = index.entries[tostring(range or "")]
    if type(entry) ~= "table" then return nil, "没有找到该划线对应的想法" end
    local offset, length = tonumber(entry.offset), tonumber(entry.length)
    if not offset or not length or offset < 0 or length <= 0 then return nil, "想法索引损坏" end
    local file = io.open(data_path, "rb")
    if not file then return nil, "想法索引数据不存在" end
    local sought = file:seek("set", offset)
    local raw = sought and file:read(length) or nil
    file:close()
    if not raw or #raw ~= length then return nil, "想法索引数据不完整" end
    local ok, group = pcall(Json.decode, raw)
    if not ok or type(group) ~= "table" then return nil, "想法索引数据损坏" end
    return group, nil, {
        path=source_path,
        signature=file_signature(source_path),
        cache_hit=cache_hit,
        index_hit=true,
    }
end

local function invalidate_path(path)
    chapter_cache[path] = nil
    for i = #chapter_cache_order, 1, -1 do
        if chapter_cache_order[i] == path then table.remove(chapter_cache_order, i) end
    end
    local prefix = tostring(path) .. "|"
    for key in pairs(popup_cache) do
        if key:sub(1, #prefix) == prefix then popup_cache[key] = nil end
    end
    for i = #popup_cache_order, 1, -1 do
        if popup_cache_order[i]:sub(1, #prefix) == prefix then table.remove(popup_cache_order, i) end
    end
end

local function hex_encode(value)
    return (tostring(value or ""):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
end

local function hex_decode(value)
    if type(value) ~= "string" or value == "" or value:find("[^0-9a-fA-F]") or #value % 2 ~= 0 then
        return nil
    end
    return (value:gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function codepoint_len(value)
    local text = tostring(value or "")
    local count, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        count = count + 1
    end
    return count
end

-- Approximate the rendered width in CJK em units. This is used only to size
-- the fixed source area before MuPDF lays it out: CJK characters occupy about
-- one em, while Latin letters, digits, spaces and punctuation are narrower.
local function display_units(value)
    local text = tostring(value or "")
    local units, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if b < 0x80 then
            local ch = text:sub(i, i)
            if ch:match("%s") then
                units = units + 0.32
            elseif ch:match("[%w]") then
                units = units + 0.56
            else
                units = units + 0.48
            end
            i = i + 1
        elseif b < 0xE0 then
            units = units + 0.78
            i = i + 2
        elseif b < 0xF0 then
            units = units + 1.00
            i = i + 3
        else
            units = units + 1.12
            i = i + 4
        end
    end
    return units
end

local function utf8_slice(value, first, last)
    local text = tostring(value or "")
    local out, index, i = {}, 0, 1
    while i <= #text do
        local b = text:byte(i)
        local n = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        index = index + 1
        if index >= first and (not last or index <= last) then out[#out + 1] = text:sub(i, i + n - 1) end
        if last and index >= last then break end
        i = i + n
    end
    return table.concat(out)
end

function Thoughts.anchor(book_id, chapter_uid, range)
    return "miuthought-" .. hex_encode(book_id) .. "." .. hex_encode(chapter_uid) .. "." .. hex_encode(range)
end

function Thoughts.href(book_id, chapter_uid, range)
    return "#" .. Thoughts.anchor(book_id, chapter_uid, range)
end

function Thoughts.mark_class(range)
    return "miu-mark-" .. hex_encode(range)
end

function Thoughts.parse_href(href)
    local anchor = tostring(href or ""):match("#?(miuthought%-[%x%.]+)")
    if not anchor then return nil end
    local b, c, r = anchor:match("^miuthought%-([%x]+)%.([%x]+)%.([%x]+)$")
    if not b then return nil end
    local book_id, chapter_uid, range = hex_decode(b), hex_decode(c), hex_decode(r)
    if not book_id or not chapter_uid or not range then return nil end
    return {book_id = book_id, chapter_uid = chapter_uid, range = range, anchor = anchor}
end

function Thoughts.cache_dir(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    U.mkdir(dir)
    return dir
end

function Thoughts.cache_path(store, book_id, chapter_uid)
    return Thoughts.cache_dir(store, book_id) .. "/" .. U.id_name(chapter_uid) .. ".json"
end

compact_group = function(group)
    if type(group) ~= "table" then return nil end
    local range = tostring(group.range or "")
    local texts = {}
    for _, row in ipairs(group.texts or {}) do
        if type(row) == "table" and tostring(row.content or "") ~= "" then
            texts[#texts + 1] = {
                content = tostring(row.content or ""),
                abstract = tostring(row.abstract or ""),
                author = tostring(row.author or ""),
                likes = tonumber(row.likes or 0) or 0,
                created = tonumber(row.created or 0) or 0,
                review_id = tostring(row.review_id or ""),
            }
        end
    end
    if range == "" or #texts == 0 then return nil end
    return {range = range, texts = texts}
end

function Thoughts.save(store, book_id, chapter_uid, groups)
    local rows = {}
    for _, group in ipairs(groups or {}) do
        local item = compact_group(group)
        if item then rows[#rows + 1] = item end
    end
    local path = Thoughts.cache_path(store, book_id, chapter_uid)
    invalidate_path(path)
    if #rows == 0 then
        os.remove(path)
        remove_index_files(path)
        return 0, path
    end
    local wrote, write_error = U.atomic_write(path, Json.encode(rows), true)
    if not wrote then return nil, tostring(write_error or "想法缓存写入失败") end
    local indexed, index_error = build_index_from_rows(path, rows)
    if not indexed then
        if store and store.data_dir then os.remove(store.data_dir .. "/" .. INDEX_COMPLETE_MARKER) end
        logger.warn("[MiuRead][Thoughts] compact index build failed",
            "book=", tostring(book_id), "chapter=", tostring(chapter_uid),
            "error=", tostring(index_error))
    end
    logger.info("[MiuRead][Thoughts] cache saved", "book=", tostring(book_id),
        "chapter=", tostring(chapter_uid), "groups=", tostring(#rows),
        "indexed=", tostring(indexed or 0))
    return #rows, path
end

function Thoughts.load(store, book_id, chapter_uid)
    local path = Thoughts.cache_path(store, book_id, chapter_uid)
    local signature = file_signature(path)
    if not signature then return nil, "想法缓存不存在" end

    local cached = chapter_cache[path]
    if cached and cached.signature == signature then
        cache_touch(chapter_cache_order, path)
        return cached.rows, nil, cached, true
    end

    local raw = U.read_file(path, true)
    if not raw then return nil, "想法缓存不存在" end
    local ok, rows = pcall(Json.decode, raw)
    if not ok or type(rows) ~= "table" then return nil, "想法缓存损坏" end

    local index = {}
    for _, row in ipairs(rows) do
        local key = tostring(type(row) == "table" and row.range or "")
        if key ~= "" and index[key] == nil then index[key] = row end
    end
    cached = {rows = rows, index = index, signature = signature, path = path}
    chapter_cache[path] = cached
    cache_touch(chapter_cache_order, path)
    cache_trim(chapter_cache, chapter_cache_order, CHAPTER_CACHE_LIMIT)
    return rows, nil, cached, false
end

function Thoughts.find(store, book_id, chapter_uid, range)
    local source_path = Thoughts.cache_path(store, book_id, chapter_uid)
    local indexed, index_error, index_token = find_indexed(source_path, range)
    if indexed then return indexed, nil, index_token end
    if store and store.data_dir then os.remove(store.data_dir .. "/" .. INDEX_COMPLETE_MARKER) end

    local _, err, cached, cache_hit = Thoughts.load(store, book_id, chapter_uid)
    if not cached then return nil, err or index_error end
    local key = tostring(range or "")
    local group = cached.index[key]
    if group then
        return group, nil, {path=cached.path, signature=cached.signature, cache_hit=cache_hit, index_hit=false}
    end
    return nil, "没有找到该划线对应的想法"
end

local function clean(value)
    return U.trim(tostring(value or ""):gsub("[%z\1-\8\11\12\14-\31]", " "):gsub("%s+", " "))
end

local function preview(value, max_chars)
    local text = clean(value)
    max_chars = tonumber(max_chars) or 84
    if codepoint_len(text) <= max_chars then return text end
    return utf8_slice(text, 1, max_chars) .. "……"
end

local function split_entry(item, chunk_chars)
    local author = clean(item.author)
    if author == "" then author = "微信读书用户" end
    local content = clean(item.content)
    local abstract = clean(item.abstract)
    local base = {
        author = author,
        likes = tonumber(item.likes or 0) or 0,
        abstract = abstract,
        review_id = tostring(item.review_id or ""),
    }
    local total = math.max(1, math.ceil(codepoint_len(content) / chunk_chars))
    local rows = {}
    if content == "" then
        local row = U.copy(base); row.content = "（无正文）"; row.part = 1; row.parts = 1; rows[1] = row
        return rows
    end
    for part = 1, total do
        local row = U.copy(base)
        row.content = utf8_slice(content, (part - 1) * chunk_chars + 1, part * chunk_chars)
        row.part, row.parts = part, total
        if part > 1 then row.abstract = "" end
        rows[#rows + 1] = row
    end
    return rows
end

local FONT_PROFILE = {
    standard = {font_size = 19, page_budget = 600, chunk_chars = 170},
    large = {font_size = 22, page_budget = 520, chunk_chars = 150},
    xlarge = {font_size = 25, page_budget = 430, chunk_chars = 125},
}

function Thoughts.font_profile(level)
    return FONT_PROFILE[tostring(level or "standard")] or FONT_PROFILE.standard
end

function Thoughts.paginate(group, level)
    if type(group) ~= "table" then return {} end
    local profile = Thoughts.font_profile(level)
    local entries = {}
    for _, item in ipairs(group.texts or {}) do
        for _, part in ipairs(split_entry(item, profile.chunk_chars)) do entries[#entries + 1] = part end
    end
    local pages, page, weight = {}, {}, 0
    local function flush()
        if #page > 0 then pages[#pages + 1] = page; page = {}; weight = 0 end
    end
    for _, item in ipairs(entries) do
        local item_weight = codepoint_len(item.content) + math.floor(codepoint_len(item.abstract) * 0.45) + 32
        local max_entries = 4
        local minimum_before_wrap = 3
        if #page >= max_entries or (#page >= minimum_before_wrap and weight + item_weight > profile.page_budget) then flush() end
        page[#page + 1] = item
        weight = weight + item_weight
        if weight > profile.page_budget and #page >= 3 then flush() end
    end
    flush()
    if #pages >= 2 and #pages[#pages] < 3 and #pages[#pages - 1] > 3 then
        while #pages[#pages] < 3 and #pages[#pages - 1] > 3 do
            table.insert(pages[#pages], 1, table.remove(pages[#pages - 1]))
        end
    end
    return pages
end

local function panel_head_html(title)
    return '<div class="miu-panel-head">' .. U.xml(title or "评论") .. '</div>'
end

local function source_box_html(text)
    return '<div class="miu-source"><div class="miu-source-box">' .. U.xml(text or "") .. '</div></div>'
end

local function entry_html(item)
    local author = U.xml(item.author or "微信读书用户")
    local likes = tonumber(item.likes or 0) or 0
    local likes_text = likes > 0 and ("赞 " .. tostring(likes)) or ""
    local html = {
        '<div class="miu-comment">',
        '<div class="miu-meta">',
        '<span class="miu-author">', author, '</span>',
    }
    if likes_text ~= "" then
        -- Use non-breaking spaces plus a middle dot so the like count can
        -- never be mistaken for part of the author's name, even when MuPDF
        -- ignores margins between adjacent inline spans.
        html[#html + 1] = '<span class="miu-likes">&#160;·&#160;'
        html[#html + 1] = U.xml(likes_text)
        html[#html + 1] = '</span>'
    end
    html[#html + 1] = '</div>'
    html[#html + 1] = '<div class="miu-content">'
    html[#html + 1] = U.xml(item.content or "")
    html[#html + 1] = '</div>'
    html[#html + 1] = '</div>'
    return table.concat(html)
end

function Thoughts.group_abstract(group)
    for _, item in ipairs((group and group.texts) or {}) do
        local abstract = clean(item.abstract)
        if abstract ~= "" then return abstract end
    end
    return ""
end

function Thoughts.page_html(page, page_index, page_count, abstract)
    local rows = {}
    local has_source = tostring(abstract or "") ~= ""
    rows[#rows + 1] = panel_head_html(has_source and "正文" or "评论")
    if has_source then
        rows[#rows + 1] = source_box_html(preview(abstract, 72))
    end
    for _, item in ipairs(page or {}) do
        if clean(item.content) ~= "" then rows[#rows + 1] = entry_html(item) end
    end
    return table.concat(rows)
end

function Thoughts.popup_parts(group)
    if type(group) ~= "table" then
        return "", "", {source_chars=0, source_units=0, comment_count=0, comment_chars={}, comment_units={}}
    end

    local fixed, body = {}, {}
    local metrics = {source_chars=0, source_units=0, comment_count=0, comment_chars={}, comment_units={}}
    local abstract = Thoughts.group_abstract(group)
    if abstract ~= "" then
        local source = preview(abstract, 240)
        metrics.source_chars = codepoint_len(source)
        metrics.source_units = display_units(source)
        fixed[#fixed + 1] = panel_head_html("正文")
        fixed[#fixed + 1] = source_box_html(source)
    else
        body[#body + 1] = panel_head_html("评论")
    end

    local seen = {}
    for _, item in ipairs(group.texts or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                metrics.comment_count = metrics.comment_count + 1
                metrics.comment_chars[#metrics.comment_chars + 1] = codepoint_len(content)
                metrics.comment_units[#metrics.comment_units + 1] = display_units(content)
                body[#body + 1] = entry_html{
                    author = author,
                    content = content,
                    likes = tonumber(item.likes or 0) or 0,
                }
            end
        end
    end
    return table.concat(fixed), table.concat(body), metrics
end

function Thoughts.popup_parts_cached(store, book_id, chapter_uid, range, group, token)
    token = type(token) == "table" and token or {}
    local path = tostring(token.path or Thoughts.cache_path(store, book_id, chapter_uid))
    local signature = tostring(token.signature or file_signature(path) or "missing")
    local key = table.concat({path, signature, tostring(range or "")}, "|")
    local cached = popup_cache[key]
    if cached then
        cache_touch(popup_cache_order, key)
        return cached.source_html, cached.html, cached.metrics, true
    end
    local source_html, html, metrics = Thoughts.popup_parts(group)
    popup_cache[key] = {source_html=source_html, html=html, metrics=metrics}
    cache_touch(popup_cache_order, key)
    cache_trim(popup_cache, popup_cache_order, POPUP_CACHE_LIMIT)
    return source_html, html, metrics, false
end




function Thoughts.native_parts(group)
    if type(group) ~= "table" then return "", {}, 0 end
    local source = preview(Thoughts.group_abstract(group), 240)
    local comments, seen = {}, {}
    for _, item in ipairs(group.texts or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                comments[#comments + 1] = {
                    author = author,
                    content = content,
                    likes = tonumber(item.likes or 0) or 0,
                    review_id = review_id,
                }
            end
        end
    end
    return source, comments, #comments
end

function Thoughts.native_parts_cached(store, book_id, chapter_uid, range, group, token)
    token = type(token) == "table" and token or {}
    local path = tostring(token.path or Thoughts.cache_path(store, book_id, chapter_uid))
    local signature = tostring(token.signature or file_signature(path) or "missing")
    local key = table.concat({"native", path, signature, tostring(range or "")}, "|")
    local cached = popup_cache[key]
    if cached and cached.native == true then
        cache_touch(popup_cache_order, key)
        return cached.source, cached.comments, cached.count, true
    end
    local source, comments, count = Thoughts.native_parts(group)
    popup_cache[key] = {native=true, source=source, comments=comments, count=count}
    cache_touch(popup_cache_order, key)
    cache_trim(popup_cache, popup_cache_order, POPUP_CACHE_LIMIT)
    return source, comments, count, false
end

function Thoughts.plain_text(group)
    if type(group) ~= "table" then return "没有想法内容" end
    local lines = {}
    local abstract = Thoughts.group_abstract(group)
    if abstract ~= "" then
        lines[#lines + 1] = "正文"
        lines[#lines + 1] = abstract
        lines[#lines + 1] = ""
    end

    local seen = {}
    local count = 0
    for _, item in ipairs(group.texts or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                count = count + 1
                local likes = tonumber(item.likes or 0) or 0
                local heading = author
                if likes > 0 then heading = heading .. " · 赞 " .. tostring(likes) end
                lines[#lines + 1] = heading
                lines[#lines + 1] = content
                lines[#lines + 1] = ""
            end
        end
    end
    if count == 0 then lines[#lines + 1] = "没有想法内容" end
    return table.concat(lines, "\n"):gsub("\n+$", "")
end


function Thoughts.build_index(store, book_id, chapter_uid)
    local source_path = Thoughts.cache_path(store, book_id, chapter_uid)
    local raw = U.read_file(source_path, true)
    if not raw then return nil, "想法缓存不存在" end
    local ok, rows = pcall(Json.decode, raw)
    if not ok or type(rows) ~= "table" then return nil, "想法缓存损坏" end
    return build_index_from_rows(source_path, rows)
end

local function acquire_maintenance_lock(lock_path)
    local attr = lfs.attributes(lock_path)
    if attr and os.time() - (tonumber(attr.modification or 0) or 0) > 3600 then
        U.remove_tree(lock_path)
        attr = nil
    end
    if attr then return false end
    return lfs.mkdir(lock_path) == true
end

function Thoughts.build_missing_indexes(data_dir, pause_path, limit)
    data_dir=tostring(data_dir or "")
    local root = data_dir .. "/books"
    local complete_path = data_dir .. "/" .. INDEX_COMPLETE_MARKER
    if lfs.attributes(complete_path, "mode") == "file" then
        return {ok=true, complete=true, built=0, checked=0, failed=0, paused=false}
    end
    local lock_path = data_dir .. "/temp/thought-index-maintenance.lock"
    if not acquire_maintenance_lock(lock_path) then return {ok=true, busy=true, built=0, checked=0} end
    local result = {ok=true, built=0, checked=0, failed=0, paused=false}
    local maximum = math.max(1, tonumber(limit) or 100000)
    local function paused()
        return tostring(pause_path or "") ~= "" and lfs.attributes(pause_path) ~= nil
    end
    local function visit_source(source_path)
        if result.checked >= maximum or paused() then return false end
        result.checked = result.checked + 1
        local source_signature = file_signature(source_path)
        local index = load_compact_index(source_path)
        if index then return true end
        local raw = U.read_file(source_path, true)
        local after_read = file_signature(source_path)
        if not raw or source_signature ~= after_read then
            result.failed = result.failed + 1
            return true
        end
        local ok, rows = pcall(Json.decode, raw)
        if not ok or type(rows) ~= "table" then
            result.failed = result.failed + 1
            return true
        end
        local built = build_index_from_rows(source_path, rows)
        if built then result.built = result.built + 1 else result.failed = result.failed + 1 end
        return true
    end
    local ok, unexpected = xpcall(function()
        if lfs.attributes(root, "mode") ~= "directory" then return end
        local books = {}
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." and lfs.attributes(root .. "/" .. name, "mode") == "directory" then
                books[#books + 1] = name
            end
        end
        table.sort(books)
        for _, book_name in ipairs(books) do
            if paused() or result.checked >= maximum then break end
            local dir = root .. "/" .. book_name .. "/thoughts"
            if lfs.attributes(dir, "mode") == "directory" then
                local files = {}
                for name in lfs.dir(dir) do
                    if name:match("%.json$") then files[#files + 1] = name end
                end
                table.sort(files)
                for _, name in ipairs(files) do
                    if not visit_source(dir .. "/" .. name) then break end
                end
            end
        end
    end, debug.traceback)
    result.paused = paused()
    if not ok then result.ok=false; result.error=tostring(unexpected) end
    if result.ok and not result.paused and result.failed==0 and result.checked<maximum then
        U.atomic_write(complete_path, tostring(os.time()), true)
        result.complete=true
    end
    U.remove_tree(lock_path)
    return result
end

function Thoughts.comment_count(group)
    local seen, count = {}, 0
    for _, item in ipairs((group and group.texts) or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then seen[key] = true; count = count + 1 end
        end
    end
    return count
end



local function thought_sources_for_book(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    if lfs.attributes(dir, "mode") ~= "directory" then return {}, dir end
    local files = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:match("%.json$") then
            files[#files + 1] = dir .. "/" .. name
        end
    end
    table.sort(files)
    return files, dir
end

function Thoughts.inspect_book_indexes(store, book_id, limit)
    local files = thought_sources_for_book(store, book_id)
    local report = {book_id=tostring(book_id or ""), sources=0, valid=0, missing=0, errors={}}
    local maximum = math.max(1, tonumber(limit) or 100000)
    for _, source_path in ipairs(files) do
        if report.sources >= maximum then report.truncated = true; break end
        report.sources = report.sources + 1
        local index, err = load_compact_index(source_path)
        if index then
            report.valid = report.valid + 1
        else
            report.missing = report.missing + 1
            if #report.errors < 5 then report.errors[#report.errors + 1] = tostring(err or "索引不可用") end
        end
    end
    report.issue = report.sources > 0 and report.missing > 0
    return report
end

function Thoughts.repair_book_indexes(store, book_id, force)
    local files = thought_sources_for_book(store, book_id)
    local result = {book_id=tostring(book_id or ""), checked=0, rebuilt=0, kept=0, failed=0, errors={}}
    for _, source_path in ipairs(files) do
        result.checked = result.checked + 1
        local index = not force and load_compact_index(source_path) or nil
        if index then
            result.kept = result.kept + 1
        else
            if force then remove_index_files(source_path) end
            local raw = U.read_file(source_path, true)
            local ok, rows = false, nil
            if raw then ok, rows = pcall(Json.decode, raw) end
            if ok and type(rows) == "table" then
                local built, err = build_index_from_rows(source_path, rows)
                if built then result.rebuilt = result.rebuilt + 1
                else
                    result.failed = result.failed + 1
                    if #result.errors < 5 then result.errors[#result.errors + 1] = tostring(err or "索引写入失败") end
                end
            else
                result.failed = result.failed + 1
                if #result.errors < 5 then result.errors[#result.errors + 1] = "想法缓存损坏" end
            end
        end
    end
    Thoughts.clear_memory_cache()
    result.ok = result.failed == 0
    return result
end

function Thoughts.remove_invalid_indexes(store, book_id)
    local files = thought_sources_for_book(store, book_id)
    local removed = 0
    for _, source_path in ipairs(files) do
        local index = load_compact_index(source_path)
        if not index then remove_index_files(source_path); removed = removed + 1 end
    end
    Thoughts.clear_memory_cache()
    return removed
end

function Thoughts.clear_memory_cache()
    chapter_cache = {}
    chapter_cache_order = {}
    index_cache = {}
    index_cache_order = {}
    popup_cache = {}
    popup_cache_order = {}
end

function Thoughts.full_html(group)
    local fixed, body, metrics = Thoughts.popup_parts(group)
    return fixed .. body, metrics
end

function Thoughts.popup_css()
    return [[
@page{margin:0}
html{margin:0!important;padding:0!important}
body{margin:0!important;padding:.18em .26em .20em .26em!important;line-height:1.18;color:#000;background:#fff}
.miu-panel-head{font-size:.52em;font-weight:normal;line-height:1.02;color:#555;margin:0 1.9em .16em 0;padding:0}
.miu-source{margin:0;padding:0}
.miu-source-box{font-size:.68em;line-height:1.15;color:#444;margin:0;padding:.17em .23em;border:1px solid #aaa}
.miu-comment{margin:0;padding:.10em 0 .09em 0;border:0;page-break-inside:avoid;break-inside:avoid-page}
.miu-comment+.miu-comment{margin-top:.09em;padding-top:.13em;border-top:1px solid #c8c8c8}
.miu-meta{margin:0;padding:0;line-height:1.02;page-break-after:avoid}
.miu-author{font-size:.47em;font-weight:normal;color:#666;line-height:1.02}
.miu-likes{font-size:.45em;font-weight:normal;color:#777;line-height:1.02;white-space:nowrap}
.miu-content{font-size:.80em;line-height:1.20;margin:.07em 0 0 0;padding:0 0 .08em 0;page-break-before:avoid;orphans:2;widows:2}
.miu-empty{font-size:.70em;color:#666;margin:.45em 0;text-align:center}
]]
end
return Thoughts
