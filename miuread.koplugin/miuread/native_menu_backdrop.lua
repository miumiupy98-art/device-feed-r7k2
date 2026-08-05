-- Compatibility shim retained for older call sites.
--
-- beta.4 used a fullscreen white widget below KOReader's native menus. When a
-- settings submenu replaced the original menu, that widget could outlive the
-- menu and leave the device on a permanent white screen. The MiuRead home is
-- now the safe background, so this module deliberately never adds a window.
local marker = {_miuread_native_backdrop = true, _closed = false}
local active = false

local Backdrop = {}
function Backdrop.current() return active and marker or nil end
function Backdrop.is_shown() return false end
function Backdrop.close()
    active = false
    marker._closed = true
end
function Backdrop.show()
    active = true
    marker._closed = false
    return marker
end

return Backdrop
