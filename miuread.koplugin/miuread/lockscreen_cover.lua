local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local M = {}

local function free(bb)
    if bb and type(bb.free) == "function" then pcall(bb.free, bb) end
end

local function load(path)
    if not path or path == "" then return nil end
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
    if not ok or not image then return nil end
    local w = tonumber(image:getWidth()) or 0
    local h = tonumber(image:getHeight()) or 0
    if w <= 0 or h <= 0 then free(image); return nil end
    return image, w, h
end

-- Decode all available sources and keep the source with the largest native
-- pixel area. This lets an embedded EPUB/custom cover win over a small shelf
-- thumbnail without changing normal shelf rendering.
function M.best_source(paths)
    local best_path, best_area
    for _, path in ipairs(paths or {}) do
        path = tostring(path or "")
        if path ~= "" then
            local image, w, h = load(path)
            if image then
                local area = w * h
                if not best_area or area > best_area then
                    best_path, best_area = path, area
                end
                free(image)
            end
        end
    end
    return best_path, best_area or 0
end

-- Render a true edge-to-edge screen image. We use "cover" geometry (scale by
-- max ratio, then center-crop) instead of ImageWidget's fit/contain behavior,
-- so the result never carries white margins into KOReader's screensaver.
function M.render_fill(source, target, width, height)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    if width <= 0 or height <= 0 then return nil, "invalid screen size" end
    local image, iw, ih = load(source)
    if not image then return nil, "cover decode failed" end

    local scaled, canvas
    local ok, err = xpcall(function()
        local scale = math.max(width / iw, height / ih)
        local sw = math.max(width, math.floor(iw * scale + 0.5))
        local sh = math.max(height, math.floor(ih * scale + 0.5))
        -- Keep ownership local: scaleBlitBuffer normally frees the source.
        scaled = RenderImage:scaleBlitBuffer(image, sw, sh, false)
        if not scaled then error("cover scale failed") end
        canvas = Blitbuffer.new(width, height, scaled:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        local sx = math.max(0, math.floor((sw - width) / 2))
        local sy = math.max(0, math.floor((sh - height) / 2))
        canvas:blitFrom(scaled, 0, 0, sx, sy, width, height)
        local written, write_err = pcall(canvas.writePNG, canvas, target)
        if not written then error(write_err or "lockscreen write failed") end
    end, debug.traceback)

    -- scaleBlitBuffer may return the original buffer when no resize is needed.
    if scaled == image then scaled = nil end
    free(image)
    free(scaled)
    free(canvas)
    if not ok then
        logger.warn("[MiuRead][LockscreenCover] render failed", tostring(err))
        return nil, err
    end
    return target
end

return M
