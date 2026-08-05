-- Shared visual calibration for character-based icons.
-- KOReader's bundled fonts give Unicode glyphs very different apparent sizes.
-- These small per-glyph adjustments keep icons on one visual baseline without
-- adding bitmap assets or heavier drawing work on e-ink devices.
local IconStyle = {}

local GLYPH = {
    ["Aa"] = {scale = .70, y = 1},
    ["☰"] = {scale = .78, y = 1},
    ["◴"] = {scale = .82, y = 1},
    ["☼"] = {scale = .76, y = 1},
    ["⇅"] = {scale = .74, y = 0},
    ["▦"] = {scale = .73, y = 1},
    ["↻"] = {scale = .80, y = 0},
    ["⌕"] = {scale = .76, y = 1},
    ["⇩"] = {scale = .78, y = 0},
    ["⇧"] = {scale = .78, y = 0},
    ["⚙"] = {scale = .72, y = 1},
    ["◷"] = {scale = .82, y = 1},
    ["▤"] = {scale = .74, y = 1},
    ["▣"] = {scale = .72, y = 1},
    ["▧"] = {scale = .72, y = 1},
    ["⌂"] = {scale = .76, y = 1},
    ["□"] = {scale = .70, y = 1},
    ["▯"] = {scale = .72, y = 1},
    ["◐"] = {scale = .80, y = 1},
    ["☾"] = {scale = .78, y = 1},
    ["→"] = {scale = .78, y = 0},
    ["↶"] = {scale = .78, y = 1},
    ["≡"] = {scale = .76, y = 1},
    ["T"] = {scale = .70, y = 1},
    ["◉"] = {scale = .76, y = 1},
    ["✚"] = {scale = .72, y = 1},
    ["⋯"] = {scale = .80, y = -1},
    ["i"] = {scale = .72, y = 1},
    ["!"] = {scale = .72, y = 1},
    ["−"] = {scale = .78, y = 0},
    ["▶"] = {scale = .74, y = 1},
    ["←"] = {scale = .78, y = 0},
    ["⏻"] = {scale = .75, y = 1},
    ["↺"] = {scale = .80, y = 0},
}

local CONTEXT = {
    reader_quick = 1.00,
    reader_list = .92,
    reader_recent = .88,
    home_action = .92,
    home_category = .90,
}

function IconStyle.metrics(icon, context)
    local base = GLYPH[tostring(icon or "")] or {}
    local context_scale = CONTEXT[tostring(context or "")] or 1
    return {
        scale = (tonumber(base.scale) or .80) * context_scale,
        x = tonumber(base.x) or 0,
        y = tonumber(base.y) or 0,
        bold = base.bold ~= false,
    }
end

function IconStyle.size(nominal, maximum, minimum, icon, context)
    local m = IconStyle.metrics(icon, context)
    return (tonumber(nominal) or 10) * m.scale,
        (tonumber(maximum) or nominal or 10) * m.scale,
        math.max(1, (tonumber(minimum) or nominal or 10) * m.scale)
end

return IconStyle
