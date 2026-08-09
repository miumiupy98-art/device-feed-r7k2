local CoverRender = require("miuread.cover_render")

local M = {}

function M.best_source(paths)
    return CoverRender.best_source(paths)
end

function M.render_fill(source, target, width, height)
    -- A slightly stronger e-ink boost than the home thumbnail keeps title
    -- strokes and illustration edges crisp without aggressive haloing.
    return CoverRender.render_fill(source, target, width, height, {ink_boost = .075})
end

return M
