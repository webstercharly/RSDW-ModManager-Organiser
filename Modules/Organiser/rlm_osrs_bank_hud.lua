-- OSRS Bank Chest UI Revamp (CE-04).
-- Faithful Old School RuneScape Bank window mounted directly onto the chest
-- CanvasPanel (zero WBP_Panel filigree bloat), preserving the player's
-- left-side backpack and top-right minimap.

local engine = require("rlm_engine")
local log = require("rlm_log")
local ui_kit = require("rlm_ui_kit")
local row_icons = require("rlm_row_icons")

local M = { VERSION = "0.5.2" }

local TEXT_PKG = "/Game/UI/Common/WBP_DomTextBlock"
local BUTTON_PKG = "/Game/UI/Common/WBP_DomAllCapsButton"

local BANK_W = 540
local BANK_H = 574
local FALLBACK_X = 760
local FALLBACK_Y = 120

local TABS_PER_PAGE = 7
local GRID_COLS = 8
local GRID_ROWS = 7
local GRID_SLOTS = GRID_COLS * GRID_ROWS

-- Authentic OSRS stone-brown, crimson, and gold palette
local OSRS = {
    rim_dark = { R = 0.086, G = 0.071, B = 0.055, A = 0.99 },     -- #16120E crisp 1px outer outline
    bevel_hi = { R = 0.435, G = 0.380, B = 0.310, A = 0.98 },     -- #6F614F top/left highlight
    bevel_lo = { R = 0.165, G = 0.137, B = 0.106, A = 0.98 },     -- #2A231B bottom/right groove
    bg_stone = { R = 0.286, G = 0.251, B = 0.204, A = 0.99 },     -- #494034 main OSRS bank backdrop
    tab_idle = { R = 0.227, G = 0.196, B = 0.157, A = 0.98 },     -- #3A3228 inactive folder tab
    tab_empty = { R = 0.192, G = 0.165, B = 0.133, A = 0.92 },    -- #312A22 unused tab placeholder
    tab_active = { R = 0.286, G = 0.251, B = 0.204, A = 0.99 },   -- #494034 blends seamlessly into grid
    slot_hot = { R = 0.376, G = 0.322, B = 0.251, A = 0.90 },     -- #605240 warm hover cell
    slot_sel = { R = 0.486, G = 0.196, B = 0.165, A = 0.90 },     -- #7C322A selected cell
    recess = { R = 0.157, G = 0.133, B = 0.106, A = 0.98 },       -- #28221B dark stone box / track
    btn_idle = { R = 0.255, G = 0.220, B = 0.176, A = 0.98 },     -- #41382D OSRS stone button
    red_active = { R = 0.580, G = 0.125, B = 0.098, A = 1.0 },    -- #942019 active red pill
    thumb = { R = 0.365, G = 0.318, B = 0.259, A = 0.98 },        -- #5D5142 scroll thumb
    gold = { R = 1.0, G = 0.596, B = 0.122, A = 1.0 },            -- #FF981F OSRS orange-gold
    yellow = { R = 1.0, G = 1.0, B = 0.0, A = 1.0 },              -- #FFFF00 OSRS stack yellow
    cream = { R = 0.941, G = 0.902, B = 0.820, A = 1.0 },         -- #F0E6D1 warm cream
    muted = { R = 0.745, G = 0.690, B = 0.590, A = 1.0 },         -- #BEB096 secondary text
    transparent = { R = 0, G = 0, B = 0, A = 0 },
    white = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    black = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 },
}

local obj_seq = 0
local bank_state = {
    ui = nil,
    stage = "idle",
    host_name = nil,
    selected_tab_key = nil,
    tab_page = 1,
    grid_page = 1,
    qty_mode = 1, -- 1, 5, 10, or 0 (= All)
    search_open = false,
    search_query = "",
    status_text = "Click an item to withdraw.",
    selected_entry_key = nil,
    tex_cache = {},
    hidden_vert_nav = nil,
    saved_vert_nav_vis = 4,
    last_render_key = nil,
    art = {},
    art_loaded = false,
    tab_targets = {},
    grid_entries = {},
    hovered_slot = nil,
    hovered_tab = nil,
    icon_miss = false,
    was_index_ready = false,
    tab_prev = false,
    tab_next = false,
    grid_pages = 1,
    view_model = nil,
    physical_actor = nil,
    physical_inv = nil,
    keep_actors = {},
    tab_order = {},
    initial_sync_done = false,
    pinned_key = nil,
    drag_tile = nil,
    drag_entry = nil,
    drag_hover_tab = nil,
    drag_press_mp = nil,
    drag_press_local = nil,
    drag_release_mp = nil,
    drag_started_at = 0,
}

local function valid(obj) return engine.is_valid(obj) end
local function full_name(obj) return valid(obj) and (engine.full_name(obj) or "") or "" end
local function safe_call(fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    return fallback
end

local function load_class(pkg)
    if type(StaticFindObject) ~= "function" then return nil end
    local leaf = pkg:match("([^/]+)$")
    if type(LoadAsset) == "function" then pcall(LoadAsset, pkg) end
    local cls = safe_call(function() return StaticFindObject(pkg .. "." .. leaf .. "_C") end)
    return valid(cls) and cls or nil
end

local function construct(tree, umg_name)
    if type(StaticFindObject) ~= "function" or type(StaticConstructObject) ~= "function" then return nil end
    local cls = safe_call(function() return StaticFindObject("/Script/UMG." .. umg_name) end)
    if not valid(cls) then return nil end
    local next_id = (tonumber(rawget(_G, "__RLM_OSRS_SEQ")) or 0) + 1
    rawset(_G, "__RLM_OSRS_SEQ", next_id)
    obj_seq = next_id
    return safe_call(function() return StaticConstructObject(cls, tree, FName("RLM_OSRS_" .. tostring(next_id))) end)
end

local function later(ui, fn)
    ui.queue[#ui.queue + 1] = fn
end

local function flush_later(ui)
    for _, fn in ipairs(ui.queue) do pcall(fn) end
    ui.queue = {}
end

local function find_canvas(root, depth)
    depth = depth or 0
    if depth > 6 or not valid(root) then return nil end
    local cls = safe_call(function() return root:GetClass():GetFName():ToString() end, "")
    if cls == "CanvasPanel" then return root end
    local n = tonumber(safe_call(function() return root:GetChildrenCount() end, 0)) or 0
    for i = 0, n - 1 do
        local found = find_canvas(safe_call(function() return root:GetChildAt(i) end), depth + 1)
        if found then return found end
    end
    return nil
end

local function load_tex(path)
    if type(path) ~= "string" or path == "" or type(row_icons.load) ~= "function" then return nil end
    local cached = bank_state.tex_cache[path]
    if valid(cached) then return cached end
    local tex = row_icons.load(path, true)
    if valid(tex) then
        bank_state.tex_cache[path] = tex
        return tex
    end
    return nil
end

local ART_FILES = {
    stone_bg = "osrs_bank_stone_bg.png",
    btn_stone = "osrs_bank_btn_stone.png",
    btn_red = "osrs_bank_btn_red.png",
    infinity = "osrs_bank_infinity.png",
    deposit = "osrs_bank_deposit.png",
    search = "osrs_bank_search.png",
    wrench = "osrs_bank_wrench.png",
    pin = "osrs_bank_pin.png",
    close = "osrs_bank_close.png",
    fallback_chest = "icon_chest_opened.png",
}

local function art_tex(pc, key)
    local cached = bank_state.art[key]
    if valid(cached) then return cached end
    if bank_state.art_loaded and cached ~= nil then
        bank_state.art_loaded = false
    end
    if bank_state.art_loaded then return nil end
    local src = debug.getinfo(1, "S").source or ""
    local root = src:match("^@?(.*)[/\\][^/\\]+$")
    if not (root and valid(pc)) then return nil end
    local krl = safe_call(function() return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end)
    if not valid(krl) then return nil end
    for k, fname in pairs(ART_FILES) do
        if not valid(bank_state.art[k]) then
            local tex = safe_call(function() return krl:ImportFileAsTexture2D(pc, root .. "\\art\\" .. fname) end)
            if valid(tex) then bank_state.art[k] = tex end
        end
    end
    bank_state.art_loaded = true
    local res = bank_state.art[key]
    return valid(res) and res or nil
end

local function apply_osrs_shadow(tb)
    if not valid(tb) then return end
    ui_kit.style_button_label(tb)
    pcall(function()
        tb:SetShadowOffset({ X = 1, Y = 1 })
        tb:SetShadowColorAndOpacity(OSRS.black)
    end)
end

-- Uses RoundedBox (DrawAs = 4, sharp 0px corner radius) via SetBrush so newly
-- constructed UBorder widgets always render solid OSRS stone fills reliably.
local function set_border_box(border, fill_color, edge_color, edge_width)
    if not valid(border) then return end
    pcall(function()
        border:SetBrushColor(fill_color or OSRS.bg_stone)
    end)
    pcall(function()
        local brush = border.Background
        if not brush then return end
        local outline = brush.OutlineSettings
        if outline then
            outline.CornerRadii = { X = 0, Y = 0, Z = 0, W = 0 }
            outline.Width = edge_width or 0
            outline.RoundingType = 0
            outline.bUseBrushTransparency = false
            local ec = edge_color or OSRS.rim_dark
            outline.Color = { SpecifiedColor = ec, ColorUseRule = 0 }
            brush.OutlineSettings = outline
        end
        brush.DrawAs = 4 -- RoundedBox
        border:SetBrush(brush)
    end)
end

local function set_border_tex(border, tex, fallback_color)
    if not valid(border) then return end
    if valid(tex) then
        pcall(function()
            border:SetBrushFromTexture(tex)
            border:SetBrushColor(OSRS.white)
        end)
    else
        set_border_box(border, fallback_color, OSRS.rim_dark, 1)
    end
end

local function add_bevel_divider(ui, col, top_pad, bottom_pad)
    local wrap = construct(ui.tree, "VerticalBox")
    local wslot = valid(wrap) and safe_call(function() return col:AddChildToVerticalBox(wrap) end) or nil
    if not valid(wrap) then return end
    local s1 = construct(ui.tree, "SizeBox")
    local l1 = valid(s1) and construct(ui.tree, "Border") or nil
    local s2 = construct(ui.tree, "SizeBox")
    local l2 = valid(s2) and construct(ui.tree, "Border") or nil
    safe_call(function()
        if valid(s1) and valid(l1) then s1:AddChild(l1); wrap:AddChildToVerticalBox(s1) end
        if valid(s2) and valid(l2) then s2:AddChild(l2); wrap:AddChildToVerticalBox(s2) end
    end)
    later(ui, function()
        if valid(s1) then pcall(function() s1:SetHeightOverride(1) end) end
        if valid(s2) then pcall(function() s2:SetHeightOverride(1) end) end
        if valid(l1) then set_border_box(l1, OSRS.rim_dark, OSRS.rim_dark, 0) end
        if valid(l2) then set_border_box(l2, OSRS.bevel_hi, OSRS.bevel_hi, 0) end
        if valid(wslot) then pcall(function() wslot:SetPadding({ Left = 0, Top = top_pad or 2, Right = 0, Bottom = bottom_pad or 2 }) end) end
    end)
end

local function add_text(ui, parent, kind, initial, size, color)
    local tb = safe_call(function() return StaticConstructObject(ui.text_cls, ui.tree) end)
    if not valid(tb) then return nil, nil end
    local slot = kind == "v"
        and safe_call(function() return parent:AddChildToVerticalBox(tb) end)
        or safe_call(function() return parent:AddChildToHorizontalBox(tb) end)
    later(ui, function()
        pcall(function()
            local f = tb.Font
            f.Size = size
            tb:SetFont(f)
            tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
            tb:SetText(FText(initial or ""))
            tb:SetVisibility(3)
        end)
        apply_osrs_shadow(tb)
    end)
    return tb, slot
end

local function find_button_style()
    if type(FindFirstOf) ~= "function" then return nil end
    for _, cls in ipairs({ "WBP_PauseMenuScreen_C", "WBP_PauseMenu_Main_C" }) do
        local p = safe_call(function() return FindFirstOf(cls) end)
        if valid(p) and valid(p.SettingsButton) then return p.SettingsButton end
    end
    return nil
end

local function make_btn(ui, parent, kind, label, action_id, w, h, text_size, bg_color, fg_color, action_map, use_stone_tex)
    local holder = construct(ui.tree, "SizeBox")
    if not valid(holder) then return nil end
    local pslot = kind == "v"
        and safe_call(function() return parent:AddChildToVerticalBox(holder) end)
        or safe_call(function() return parent:AddChildToHorizontalBox(holder) end)
    local bg = construct(ui.tree, "Border")
    local overlay = valid(bg) and construct(ui.tree, "Overlay") or nil
    if not valid(overlay) then return nil end
    safe_call(function() holder:AddChild(bg); bg:AddChild(overlay) end)
    local txt = construct(ui.tree, "TextBlock") or safe_call(function() return StaticConstructObject(ui.text_cls, ui.tree) end)
    local tslot = valid(txt) and safe_call(function() return overlay:AddChildToOverlay(txt) end) or nil
    local btn = safe_call(function() return ui.wbl:Create(ui.pc, ui.btn_cls, ui.pc) end)
    if not valid(btn) then return nil end
    local bslot = safe_call(function() return overlay:AddChildToOverlay(btn) end)

    local bname = full_name(btn)
    if bname ~= "" and type(action_map) == "table" then
        action_map[bname] = action_id
    end
    local like = find_button_style()
    later(ui, function()
        if w then pcall(function() holder:SetWidthOverride(w) end) end
        if h then pcall(function() holder:SetHeightOverride(h) end) end
        pcall(function() holder:SetClipping(1); holder:SetVisibility(4) end)
        pcall(function()
            -- SelfHitTestInvisible (4) on bg keeps child overlay/btn clickable!
            -- HitTestInvisible (3) previously disabled hit-testing for the entire button subtree.
            bg:SetVisibility(4); bg:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 })
            if use_stone_tex == true then
                local btex = (bg_color == OSRS.red_active) and art_tex(ui.pc, "btn_red") or art_tex(ui.pc, "btn_stone")
                set_border_tex(bg, btex, bg_color or OSRS.btn_idle)
            else
                set_border_box(bg, bg_color or OSRS.btn_idle, OSRS.rim_dark, 1)
            end
        end)
        pcall(function() overlay:SetVisibility(4) end)
        if valid(like) then pcall(function() btn:SetStyle(like.Style) end) end
        pcall(function()
            btn:SetVisibility(0)
            btn:SetRenderOpacity(0.01)
            btn:SetIsSelectable(false)
            btn:SetShouldSelectUponReceivingFocus(false)
            btn:SetIsFocusable(false)
            btn:SetLabelText(FText(""))
        end)
        if valid(bslot) then pcall(function() bslot:SetHorizontalAlignment(0); bslot:SetVerticalAlignment(0) end) end
        if valid(txt) then
            pcall(function()
                local f = txt.Font; f.Size = text_size or 9; txt:SetFont(f)
                txt:SetColorAndOpacity({ SpecifiedColor = fg_color or OSRS.cream, ColorUseRule = 0 })
                txt:SetText(FText(label or ""))
                txt:SetVisibility(3)
            end)
            apply_osrs_shadow(txt)
            if valid(tslot) then pcall(function() tslot:SetHorizontalAlignment(2); tslot:SetVerticalAlignment(2) end) end
        end
    end)
    return { holder = holder, slot = pslot, bg = bg, overlay = overlay, btn = btn, label = txt }
end

local function attach_btn_icon(ui, btn_obj, tex_key, sz)
    if not (btn_obj and valid(btn_obj.overlay)) then return end
    local img = construct(ui.tree, "Image")
    local islot = valid(img) and safe_call(function() return btn_obj.overlay:AddChildToOverlay(img) end) or nil
    later(ui, function()
        local tex = art_tex(ui.pc, tex_key)
        if valid(img) and valid(tex) then
            pcall(function()
                img:SetBrushFromTexture(tex, false)
                img:SetDesiredSizeOverride({ X = sz or 20, Y = sz or 20 })
                img:SetVisibility(3)
                islot:SetHorizontalAlignment(2)
                islot:SetVerticalAlignment(2)
                if valid(btn_obj.label) then btn_obj.label:SetVisibility(1) end
            end)
        end
    end)
end

local function compute_dock_position(open_panel)
    if not valid(open_panel) then return FALLBACK_X, FALLBACK_Y end
    local vnav = safe_call(function() return open_panel.VerticalNavigation end)
    if valid(vnav) and valid(vnav.Slot) then
        local ok_p, pos = pcall(function() return vnav.Slot:GetPosition() end)
        local ok_s, sz = pcall(function() return vnav.Slot:GetSize() end)
        if ok_p and pos then
            local vx = tonumber(pos.X) or 635
            local vy = tonumber(pos.Y) or 48
            local vw = (ok_s and sz and tonumber(sz.X)) or 630
            local vh = (ok_s and sz and tonumber(sz.Y)) or 619
            local x = math.floor(vx + (vw - BANK_W) * 0.5)
            local y = math.floor(vy + (vh - BANK_H) * 0.5)
            return math.max(580, x), math.max(12, y)
        end
    end
    return 660, 48
end

local function build_frame(pc, open_panel)
    local wbl = safe_call(function() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end)
    local text_cls = load_class(TEXT_PKG)
    local btn_cls = load_class(BUTTON_PKG)
    if not (valid(wbl) and text_cls and btn_cls) then
        return nil, "UMG classes unavailable"
    end

    local htree = valid(open_panel) and safe_call(function() return open_panel.WidgetTree end) or nil
    local hroot = valid(htree) and safe_call(function() return htree.RootWidget end) or nil
    local canvas = find_canvas(hroot)
    if not (valid(htree) and valid(canvas)) then
        return nil, "chest CanvasPanel unavailable"
    end

    local root_box = construct(htree, "SizeBox")
    if not valid(root_box) then return nil, "failed to create root SizeBox" end
    local docked_slot = safe_call(function() return canvas:AddChildToCanvas(root_box) end)
    if not valid(docked_slot) then return nil, "failed to add OSRS Bank to chest canvas" end

    local dx, dy = compute_dock_position(open_panel)
    pcall(function()
        root_box:SetWidthOverride(BANK_W)
        root_box:SetHeightOverride(BANK_H)
        root_box:SetClipping(1)
        root_box:SetVisibility(1)
        docked_slot:SetAutoSize(false)
        docked_slot:SetZOrder(120)
        docked_slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        docked_slot:SetAlignment({ X = 0, Y = 0 })
        docked_slot:SetPosition({ X = dx, Y = dy })
        docked_slot:SetSize({ X = BANK_W, Y = BANK_H })
    end)

    return {
        frame = root_box, slot = docked_slot, viewport = false,
        tree = htree, pc = pc, wbl = wbl, text_cls = text_cls, btn_cls = btn_cls,
        queue = {}, tabs = {}, tiles = {}, qty_btns = {}, dock_x = dx, dock_y = dy,
    }
end

local function build_content(ui, action_map)
    local rim_outer = construct(ui.tree, "Border")
    local rim_hi = valid(rim_outer) and construct(ui.tree, "Border") or nil
    local inner = valid(rim_hi) and construct(ui.tree, "Border") or nil
    local col = valid(inner) and construct(ui.tree, "VerticalBox") or nil
    if not (valid(rim_outer) and valid(rim_hi) and valid(inner) and valid(col)) then
        return false
    end
    local mounted = pcall(function()
        ui.frame:AddChild(rim_outer)
        rim_outer:AddChild(rim_hi)
        rim_hi:AddChild(inner)
        inner:AddChild(col)
    end) == true
    if not mounted then return false end

    later(ui, function()
        pcall(function()
            set_border_box(rim_outer, OSRS.rim_dark, OSRS.rim_dark, 1)
            rim_outer:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 })
            set_border_box(rim_hi, OSRS.bevel_hi, OSRS.bevel_lo, 1)
            rim_hi:SetPadding({ Left = 2, Top = 2, Right = 2, Bottom = 2 })
            local sbg = art_tex(ui.pc, "stone_bg")
            set_border_tex(inner, sbg, OSRS.bg_stone)
            inner:SetPadding({ Left = 10, Top = 7, Right = 10, Bottom = 7 })
        end)
    end)

    -- 1. Header bar: stacked used/max counter | centered OSRS orange title | [Nat] [Wrench] [X]
    local hdr = construct(ui.tree, "HorizontalBox")
    local hdr_slot = valid(hdr) and safe_call(function() return col:AddChildToVerticalBox(hdr) end) or nil
    if valid(hdr) then
        local cap_size = construct(ui.tree, "SizeBox")
        local cap_bg = cap_size and construct(ui.tree, "Border") or nil
        local cap_col = valid(cap_bg) and construct(ui.tree, "VerticalBox") or nil
        local cap_top, cap_bot, cap_line = nil, nil, nil
        if valid(cap_size) and valid(cap_bg) and valid(cap_col) then
            safe_call(function() cap_size:AddChild(cap_bg); cap_bg:AddChild(cap_col) end)
            local cs = safe_call(function() return hdr:AddChildToHorizontalBox(cap_size) end)
            local ct_slot, cb_slot
            cap_top, ct_slot = add_text(ui, cap_col, "v", "0", 8, OSRS.cream)
            cap_line = construct(ui.tree, "Border")
            local lbox = cap_line and construct(ui.tree, "SizeBox") or nil
            if valid(lbox) then
                safe_call(function() lbox:AddChild(cap_line); cap_col:AddChildToVerticalBox(lbox) end)
            end
            cap_bot, cb_slot = add_text(ui, cap_col, "v", "0", 8, OSRS.cream)
            later(ui, function()
                pcall(function()
                    cap_size:SetWidthOverride(46); cap_size:SetHeightOverride(32); cap_size:SetClipping(1)
                    set_border_box(cap_bg, OSRS.recess, OSRS.rim_dark, 1)
                    cap_bg:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 0 })
                end)
                if valid(lbox) then pcall(function() lbox:SetHeightOverride(1) end) end
                if valid(cap_line) then set_border_box(cap_line, OSRS.bevel_hi, OSRS.bevel_hi, 0) end
                if valid(ct_slot) then pcall(function() ct_slot:SetHorizontalAlignment(2); ct_slot:SetPadding({ Left = 0, Top = -1, Right = 0, Bottom = -1 }) end) end
                if valid(cb_slot) then pcall(function() cb_slot:SetHorizontalAlignment(2); cb_slot:SetPadding({ Left = 0, Top = -1, Right = 0, Bottom = -1 }) end) end
                if valid(cs) then pcall(function() cs:SetVerticalAlignment(2); cs:SetPadding({ Left = 0, Top = 0, Right = 6, Bottom = 0 }) end) end
            end)
        end
        ui.cap_top, ui.cap_bot = cap_top, cap_bot

        local title_tb, title_slot = add_text(ui, hdr, "h", "The Bank of Dragonwilds", 13, OSRS.gold)
        ui.title = title_tb
        local nat_btn = make_btn(ui, hdr, "h", "Dock", "bank:toggle_native", 32, 22, 8, OSRS.btn_idle, OSRS.muted, action_map, true)
        local org_btn = make_btn(ui, hdr, "h", "O", "bank:open_menu", 22, 22, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        attach_btn_icon(ui, org_btn, "wrench", 15)
        local cls_btn = make_btn(ui, hdr, "h", "X", "bank:close", 22, 22, 9, OSRS.btn_idle, OSRS.cream, action_map, true)
        attach_btn_icon(ui, cls_btn, "close", 14)
        later(ui, function()
            if valid(hdr_slot) then pcall(function() hdr_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end) end
            if valid(title_slot) then
                pcall(function()
                    title_slot:SetSize({ Value = 1, SizeRule = 1 })
                    title_slot:SetVerticalAlignment(2)
                    title_slot:SetHorizontalAlignment(2)
                end)
            end
            if nat_btn and valid(nat_btn.slot) then pcall(function() nat_btn.slot:SetVerticalAlignment(2); nat_btn.slot:SetPadding({ Left = 4, Top = 0, Right = 2, Bottom = 0 }) end) end
            if org_btn and valid(org_btn.slot) then pcall(function() org_btn.slot:SetVerticalAlignment(2); org_btn.slot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 }) end) end
            if cls_btn and valid(cls_btn.slot) then pcall(function() cls_btn.slot:SetVerticalAlignment(2) end) end
        end)
    end
    add_bevel_divider(ui, col, 1, 3)

    -- 2. Seamless OSRS Folder Tab Strip: [<] [∞] [Tab1..Tab7] [>] (strictly <= 506 px)
    local tab_bar = construct(ui.tree, "HorizontalBox")
    local tab_bar_slot = valid(tab_bar) and safe_call(function() return col:AddChildToVerticalBox(tab_bar) end) or nil
    local like = find_button_style()
    if valid(tab_bar) then
        local pbtn = make_btn(ui, tab_bar, "h", "<", "bank:tab_prev", 16, 36, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        ui.tab_prev = pbtn
        later(ui, function()
            if valid(tab_bar_slot) then pcall(function() tab_bar_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end) end
            if pbtn and valid(pbtn.slot) then pcall(function() pbtn.slot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 }) end) end
        end)

        for t_idx = 0, TABS_PER_PAGE do
            local box = construct(ui.tree, "SizeBox")
            local tslot = valid(box) and safe_call(function() return tab_bar:AddChildToHorizontalBox(box) end) or nil
            local bg = valid(box) and construct(ui.tree, "Border") or nil
            local seam = valid(bg) and construct(ui.tree, "VerticalBox") or nil
            local ov = valid(seam) and construct(ui.tree, "Overlay") or nil
            local bot_line = valid(seam) and construct(ui.tree, "SizeBox") or nil
            local bot_bdr = valid(bot_line) and construct(ui.tree, "Border") or nil
            local ov_slot = valid(ov) and safe_call(function() return seam:AddChildToVerticalBox(ov) end) or nil
            if valid(box) and valid(bg) and valid(seam) and valid(bot_line) and valid(bot_bdr) then
                safe_call(function()
                    box:AddChild(bg)
                    bg:AddChild(seam)
                    bot_line:AddChild(bot_bdr)
                    seam:AddChildToVerticalBox(bot_line)
                end)
            end
            local img = valid(ov) and construct(ui.tree, "Image") or nil
            local imgs = valid(img) and safe_call(function() return ov:AddChildToOverlay(img) end) or nil
            local cap = valid(ov) and construct(ui.tree, "TextBlock") or nil
            local caps = valid(cap) and safe_call(function() return ov:AddChildToOverlay(cap) end) or nil
            local hit = valid(ov) and safe_call(function() return ui.wbl:Create(ui.pc, ui.btn_cls, ui.pc) end) or nil
            local hits = valid(hit) and safe_call(function() return ov:AddChildToOverlay(hit) end) or nil
            if valid(hit) then
                local bname = full_name(hit)
                if bname ~= "" then action_map[bname] = "bank:tab:" .. tostring(t_idx) end
            end
            later(ui, function()
                if valid(box) then pcall(function() box:SetWidthOverride(57); box:SetHeightOverride(36); box:SetClipping(1) end) end
                if valid(tslot) then pcall(function() tslot:SetPadding({ Left = 0, Top = 0, Right = (t_idx < TABS_PER_PAGE) and 2 or 0, Bottom = 0 }) end) end
                if valid(bg) then set_border_box(bg, OSRS.tab_idle, OSRS.rim_dark, 1); pcall(function() bg:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 0 }) end) end
                if valid(ov) then pcall(function() ov:SetVisibility(4) end) end
                if valid(ov_slot) then pcall(function() ov_slot:SetSize({ Value = 1, SizeRule = 1 }) end) end
                if valid(bot_line) then pcall(function() bot_line:SetHeightOverride(1) end) end
                if valid(bot_bdr) then set_border_box(bot_bdr, OSRS.rim_dark, OSRS.rim_dark, 0) end
                if valid(img) and valid(imgs) then
                    pcall(function()
                        imgs:SetHorizontalAlignment(2); imgs:SetVerticalAlignment(2)
                        img:SetDesiredSizeOverride({ X = 26, Y = 26 }); img:SetVisibility(1)
                    end)
                end
                if valid(cap) and valid(caps) then
                    pcall(function()
                        local f = cap.Font; f.Size = 7; cap:SetFont(f)
                        cap:SetColorAndOpacity({ SpecifiedColor = OSRS.muted, ColorUseRule = 0 })
                        cap:SetText(FText(""))
                        cap:SetVisibility(1)
                        caps:SetHorizontalAlignment(3); caps:SetVerticalAlignment(3)
                        caps:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 1 })
                    end)
                    apply_osrs_shadow(cap)
                end
                if valid(hit) and valid(hits) then
                    if valid(like) then pcall(function() hit:SetStyle(like.Style) end) end
                    pcall(function()
                        hit:SetVisibility(0)
                        hit:SetRenderOpacity(0.01); hit:SetIsSelectable(false)
                        hit:SetShouldSelectUponReceivingFocus(false); hit:SetIsFocusable(false); hit:SetLabelText(FText(""))
                        hits:SetHorizontalAlignment(0); hits:SetVerticalAlignment(0)
                    end)
                end
            end)
            ui.tabs[t_idx] = { box = box, bg = bg, seam_line = bot_bdr, img = img, cap = cap, hit = hit }
        end

        local nbtn = make_btn(ui, tab_bar, "h", ">", "bank:tab_next", 16, 36, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        ui.tab_next = nbtn
        later(ui, function()
            if nbtn and valid(nbtn.slot) then pcall(function() nbtn.slot:SetPadding({ Left = 2, Top = 0, Right = 0, Bottom = 0 }) end) end
        end)
    end

    -- 3. Dense 8x7 OSRS Flat-Stone Item Grid + Proportional OSRS Scrollbar Rail
    local grid_wrap = construct(ui.tree, "HorizontalBox")
    local gw_slot = valid(grid_wrap) and safe_call(function() return col:AddChildToVerticalBox(grid_wrap) end) or nil
    local grid_box = valid(grid_wrap) and construct(ui.tree, "SizeBox") or nil
    local gp_slot = valid(grid_box) and safe_call(function() return grid_wrap:AddChildToHorizontalBox(grid_box) end) or nil
    local grid_panel = valid(grid_box) and construct(ui.tree, "Border") or nil
    local grid = valid(grid_panel) and construct(ui.tree, "UniformGridPanel") or nil
    if valid(grid_box) and valid(grid_panel) and valid(grid) then
        safe_call(function() grid_box:AddChild(grid_panel); grid_panel:AddChild(grid) end)
        later(ui, function()
            pcall(function()
                grid_box:SetWidthOverride(488)
                grid_box:SetHeightOverride(374)
                grid_box:SetClipping(1)
                -- Transparent container so the textured OSRS stone backdrop flows seamlessly under the active tab
                set_border_box(grid_panel, OSRS.transparent, OSRS.transparent, 0)
                grid_panel:SetPadding({ Left = 4, Top = 5, Right = 4, Bottom = 5 })
            end)
            if valid(gp_slot) then pcall(function() gp_slot:SetSize({ Value = 1, SizeRule = 1 }) end) end
            if valid(gw_slot) then pcall(function() gw_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end) end
        end)
        for idx = 1, GRID_SLOTS do
            local r = math.floor((idx - 1) / GRID_COLS)
            local c = (idx - 1) % GRID_COLS
            local box = construct(ui.tree, "SizeBox")
            local gslot = valid(box) and safe_call(function() return grid:AddChildToUniformGrid(box, r, c) end) or nil
            local ov = valid(box) and construct(ui.tree, "Overlay") or nil
            if valid(box) and valid(ov) then safe_call(function() box:AddChild(ov) end) end
            local bg = valid(ov) and construct(ui.tree, "Border") or nil
            local bgs = valid(bg) and safe_call(function() return ov:AddChildToOverlay(bg) end) or nil
            local img = valid(ov) and construct(ui.tree, "Image") or nil
            local imgs = valid(img) and safe_call(function() return ov:AddChildToOverlay(img) end) or nil
            local mono = valid(ov) and construct(ui.tree, "TextBlock") or nil
            local monos = valid(mono) and safe_call(function() return ov:AddChildToOverlay(mono) end) or nil
            local cnt = valid(ov) and construct(ui.tree, "TextBlock") or nil
            local cnts = valid(cnt) and safe_call(function() return ov:AddChildToOverlay(cnt) end) or nil
            local hit = valid(ov) and safe_call(function() return ui.wbl:Create(ui.pc, ui.btn_cls, ui.pc) end) or nil
            local hits = valid(hit) and safe_call(function() return ov:AddChildToOverlay(hit) end) or nil
            if valid(hit) then
                local bname = full_name(hit)
                if bname ~= "" then action_map[bname] = "bank:tile:" .. tostring(idx) end
            end
            later(ui, function()
                if valid(box) then pcall(function() box:SetWidthOverride(60); box:SetHeightOverride(52); box:SetClipping(1) end) end
                if valid(gslot) then pcall(function() gslot:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 }) end) end
                if valid(ov) then pcall(function() ov:SetVisibility(4) end) end
                if valid(bg) and valid(bgs) then
                    pcall(function()
                        bgs:SetHorizontalAlignment(0); bgs:SetVerticalAlignment(0)
                        bg:SetVisibility(1)
                        set_border_box(bg, OSRS.slot_hot, OSRS.bevel_hi, 1)
                    end)
                end
                if valid(img) and valid(imgs) then
                    pcall(function()
                        imgs:SetHorizontalAlignment(2); imgs:SetVerticalAlignment(2)
                        img:SetDesiredSizeOverride({ X = 38, Y = 38 }); img:SetVisibility(1)
                    end)
                end
                if valid(mono) and valid(monos) then
                    pcall(function()
                        local f = mono.Font; f.Size = 10; mono:SetFont(f)
                        mono:SetColorAndOpacity({ SpecifiedColor = OSRS.cream, ColorUseRule = 0 })
                        mono:SetVisibility(1)
                        monos:SetHorizontalAlignment(2); monos:SetVerticalAlignment(2)
                    end)
                    apply_osrs_shadow(mono)
                end
                if valid(cnt) and valid(cnts) then
                    pcall(function()
                        local f = cnt.Font; f.Size = 9; cnt:SetFont(f)
                        cnt:SetColorAndOpacity({ SpecifiedColor = OSRS.yellow, ColorUseRule = 0 })
                        cnt:SetVisibility(1)
                        cnts:SetHorizontalAlignment(1); cnts:SetVerticalAlignment(1)
                        cnts:SetPadding({ Left = 2, Top = 0, Right = 0, Bottom = 0 })
                    end)
                    apply_osrs_shadow(cnt)
                end
                if valid(hit) and valid(hits) then
                    if valid(like) then pcall(function() hit:SetStyle(like.Style) end) end
                    pcall(function()
                        hit:SetVisibility(0)
                        hit:SetRenderOpacity(0.01); hit:SetIsSelectable(false)
                        hit:SetShouldSelectUponReceivingFocus(false); hit:SetIsFocusable(false); hit:SetLabelText(FText(""))
                        hits:SetHorizontalAlignment(0); hits:SetVerticalAlignment(0)
                    end)
                end
            end)
            ui.tiles[idx] = { box = box, bg = bg, img = img, mono = mono, cnt = cnt, hit = hit }
        end
    end
    if valid(grid_wrap) then
        local rail_wrap = construct(ui.tree, "SizeBox")
        local rail_slot = valid(rail_wrap) and safe_call(function() return grid_wrap:AddChildToHorizontalBox(rail_wrap) end) or nil
        local rail = valid(rail_wrap) and construct(ui.tree, "VerticalBox") or nil
        if valid(rail) then
            safe_call(function() rail_wrap:AddChild(rail) end)
            local up_b = make_btn(ui, rail, "v", "^", "bank:grid_prev", 20, 20, 10, OSRS.btn_idle, OSRS.gold, action_map, true)
            local tr_box = construct(ui.tree, "SizeBox")
            local tr_slot = valid(tr_box) and safe_call(function() return rail:AddChildToVerticalBox(tr_box) end) or nil
            local tr_bg = valid(tr_box) and construct(ui.tree, "Border") or nil
            local tr_col = valid(tr_bg) and construct(ui.tree, "VerticalBox") or nil
            local th_sp1 = valid(tr_col) and construct(ui.tree, "SizeBox") or nil
            local th_hi = valid(tr_col) and construct(ui.tree, "Border") or nil
            local th_sp2 = valid(tr_col) and construct(ui.tree, "SizeBox") or nil
            if valid(tr_col) and valid(th_sp1) and valid(th_hi) and valid(th_sp2) then
                safe_call(function()
                    tr_box:AddChild(tr_bg); tr_bg:AddChild(tr_col)
                    tr_col:AddChildToVerticalBox(th_sp1)
                    tr_col:AddChildToVerticalBox(th_hi)
                    tr_col:AddChildToVerticalBox(th_sp2)
                end)
                ui.scroll_sp1 = th_sp1
                ui.scroll_th = th_hi
                ui.scroll_sp2 = th_sp2
            end
            local dn_b = make_btn(ui, rail, "v", "v", "bank:grid_next", 20, 20, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
            ui.grid_prev_btn, ui.grid_next_btn = up_b, dn_b
            later(ui, function()
                if valid(rail_wrap) then pcall(function() rail_wrap:SetWidthOverride(20); rail_wrap:SetHeightOverride(374); rail_wrap:SetClipping(1) end) end
                if valid(rail_slot) then pcall(function() rail_slot:SetPadding({ Left = 4, Top = 0, Right = 0, Bottom = 0 }) end) end
                if valid(tr_box) then pcall(function() tr_box:SetWidthOverride(20); tr_box:SetHeightOverride(330); tr_box:SetClipping(1) end) end
                if valid(tr_slot) then pcall(function() tr_slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 2 }) end) end
                if valid(tr_bg) then set_border_box(tr_bg, OSRS.recess, OSRS.rim_dark, 1); pcall(function() tr_bg:SetPadding({ Left = 2, Top = 2, Right = 2, Bottom = 2 }) end) end
                if valid(th_hi) then set_border_box(th_hi, OSRS.thumb, OSRS.bevel_hi, 1) end
            end)
        end
    end

    add_bevel_divider(ui, col, 2, 2)

    -- 4. Hover / Status line
    local st_tb, st_slot = add_text(ui, col, "v", "Click an item to withdraw.", 9, OSRS.cream)
    ui.status_line = st_tb
    later(ui, function()
        if valid(st_slot) then pcall(function() st_slot:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 2 }) end) end
    end)

    -- 5. Toggleable Search Filter Bar (only visible when Search icon is toggled or query active)
    local srow = construct(ui.tree, "HorizontalBox")
    local srow_slot = valid(srow) and safe_call(function() return col:AddChildToVerticalBox(srow) end) or nil
    if valid(srow) then
        local sbox = construct(ui.tree, "EditableTextBox")
        local sbox_holder = sbox and construct(ui.tree, "SizeBox") or nil
        if valid(sbox) and valid(sbox_holder) then
            safe_call(function() sbox_holder:AddChild(sbox) end)
            local ss = safe_call(function() return srow:AddChildToHorizontalBox(sbox_holder) end)
            ui.search_box = sbox
            later(ui, function()
                pcall(function()
                    srow:SetVisibility(1)
                    sbox_holder:SetHeightOverride(24)
                    sbox_holder:SetWidthOverride(420)
                    sbox_holder:SetClipping(1)
                    sbox:SetHintText(FText("Type item name to filter across all chests..."))
                end)
                pcall(function()
                    local st = sbox.WidgetStyle
                    local fg = { SpecifiedColor = OSRS.cream, ColorUseRule = 0 }
                    local bgc = { SpecifiedColor = OSRS.recess, ColorUseRule = 0 }
                    st.BackgroundColor = bgc
                    st.ForegroundColor = fg
                    st.FocusedForegroundColor = fg
                    pcall(function()
                        local ts = st.TextStyle
                        local f = ts.Font
                        f.Size = 9
                        ts.Font = f
                        st.TextStyle = ts
                    end)
                    sbox.WidgetStyle = st
                end)
                if valid(ss) then pcall(function() ss:SetPadding({ Left = 0, Top = 0, Right = 4, Bottom = 0 }) end) end
            end)
        end
        local abtn = make_btn(ui, srow, "h", "Apply", "bank:search_apply", 48, 24, 9, OSRS.red_active, OSRS.cream, action_map, true)
        local cbtn = make_btn(ui, srow, "h", "Clr", "bank:search_clear", 34, 24, 9, OSRS.btn_idle, OSRS.cream, action_map, true)
        later(ui, function()
            if valid(srow_slot) then pcall(function() srow_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end) end
            if abtn and valid(abtn.slot) then pcall(function() abtn.slot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 }) end) end
        end)
        ui.search_row = srow
    end

    -- 6. Single Iconic OSRS Bottom Control Bar: Organiser pills | Quantity pills | [Pin][Search][Deposit]
    local bar1 = construct(ui.tree, "HorizontalBox")
    local bar1_slot = valid(bar1) and safe_call(function() return col:AddChildToVerticalBox(bar1) end) or nil
    if valid(bar1) then
        local org_col = construct(ui.tree, "VerticalBox")
        local ocs = valid(org_col) and safe_call(function() return bar1:AddChildToHorizontalBox(org_col) end) or nil
        if valid(org_col) then
            local o_lbl, ols = add_text(ui, org_col, "v", "Organiser:", 8, OSRS.gold)
            local orow = construct(ui.tree, "HorizontalBox")
            if valid(orow) then safe_call(function() org_col:AddChildToVerticalBox(orow) end) end
            local acts = {
                { "Sort", "bank:sort", 44, OSRS.cream },
                { "Resort", "bank:resort", 52, OSRS.cream },
                { "Org", "bank:organise", 42, OSRS.cream },
                { "Role", "bank:apply_role", 78, OSRS.gold },
            }
            for idx, def in ipairs(acts) do
                local b = make_btn(ui, orow, "h", def[1], def[2], def[3], 24, 8, OSRS.btn_idle, def[4], action_map, true)
                if def[2] == "bank:apply_role" then ui.role_btn = b end
                if b and valid(b.slot) and idx < #acts then
                    later(ui, function() pcall(function() b.slot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 }) end) end)
                end
            end
            later(ui, function()
                if valid(ols) then pcall(function() ols:SetHorizontalAlignment(2); ols:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 1 }) end) end
                if valid(ocs) then pcall(function() ocs:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end) end
            end)
        end

        local qty_col = construct(ui.tree, "VerticalBox")
        local qcs = valid(qty_col) and safe_call(function() return bar1:AddChildToHorizontalBox(qty_col) end) or nil
        if valid(qty_col) then
            local q_lbl, qls = add_text(ui, qty_col, "v", "Quantity:", 8, OSRS.gold)
            local qrow = construct(ui.tree, "HorizontalBox")
            if valid(qrow) then safe_call(function() qty_col:AddChildToVerticalBox(qrow) end) end
            local qtys = { { "1", 1 }, { "5", 5 }, { "10", 10 }, { "All", 0 } }
            for idx, pair in ipairs(qtys) do
                local qb = make_btn(ui, qrow, "h", pair[1], "bank:qty:" .. tostring(pair[2]), 32, 24, 9, OSRS.btn_idle, OSRS.cream, action_map, true)
                ui.qty_btns[pair[2]] = qb
                if qb and valid(qb.slot) and idx < #qtys then
                    later(ui, function() pcall(function() qb.slot:SetPadding({ Left = 0, Top = 0, Right = 2, Bottom = 0 }) end) end)
                end
            end
            later(ui, function()
                if valid(qls) then pcall(function() qls:SetHorizontalAlignment(2); qls:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 1 }) end) end
                if valid(qcs) then pcall(function() qcs:SetPadding({ Left = 0, Top = 0, Right = 14, Bottom = 0 }) end) end
            end)
        end

        local pin_btn = make_btn(ui, bar1, "h", "P", "bank:pin", 36, 36, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        attach_btn_icon(ui, pin_btn, "pin", 22)
        ui.pin_btn = pin_btn
        local srch_btn = make_btn(ui, bar1, "h", "F", "bank:search_toggle", 36, 36, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        attach_btn_icon(ui, srch_btn, "search", 22)
        ui.search_btn = srch_btn
        local dep_btn = make_btn(ui, bar1, "h", "D", "bank:deposit", 38, 36, 9, OSRS.btn_idle, OSRS.gold, action_map, true)
        attach_btn_icon(ui, dep_btn, "deposit", 25)
        later(ui, function()
            if valid(bar1_slot) then pcall(function() bar1_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end) end
            if pin_btn and valid(pin_btn.slot) then pcall(function() pin_btn.slot:SetVerticalAlignment(3); pin_btn.slot:SetPadding({ Left = 0, Top = 0, Right = 3, Bottom = 0 }) end) end
            if srch_btn and valid(srch_btn.slot) then pcall(function() srch_btn.slot:SetVerticalAlignment(3); srch_btn.slot:SetPadding({ Left = 0, Top = 0, Right = 3, Bottom = 0 }) end) end
            if dep_btn and valid(dep_btn.slot) then pcall(function() dep_btn.slot:SetVerticalAlignment(3) end) end
        end)
    end

    return true
end

local function restore_vertical_navigation()
    if valid(bank_state.hidden_vert_nav) then
        pcall(function() bank_state.hidden_vert_nav:SetVisibility(bank_state.saved_vert_nav_vis or 4) end)
    end
    bank_state.hidden_vert_nav = nil
end

local function hide_vertical_navigation(open_panel)
    if not valid(open_panel) then return end
    local vnav = safe_call(function() return open_panel.VerticalNavigation end)
    if valid(vnav) then
        if bank_state.hidden_vert_nav ~= vnav then
            restore_vertical_navigation()
            local vis = tonumber(safe_call(function() return vnav:GetVisibility() end, 4))
            if vis ~= 1 then bank_state.saved_vert_nav_vis = vis end
            bank_state.hidden_vert_nav = vnav
        end
        pcall(function() vnav:SetVisibility(1) end)
    end
end

function M.hide()
    restore_vertical_navigation()
    if bank_state.ui and valid(bank_state.ui.frame) then
        pcall(function() bank_state.ui.frame:SetVisibility(1) end)
    end
    bank_state.selected_tab_key = nil
    bank_state.selected_entry_key = nil
    bank_state.grid_page = 1
    bank_state.tab_page = 1
    bank_state.search_open = false
    bank_state.last_render_key = nil
    bank_state.physical_actor = nil
    bank_state.physical_inv = nil
    bank_state.keep_actors = {}
    bank_state.tab_order = {}
    bank_state.initial_sync_done = false
    bank_state.drag_tile = nil
    bank_state.drag_entry = nil
    bank_state.drag_hover_tab = nil
    bank_state.drag_press_mp = nil
    bank_state.drag_press_local = nil
    bank_state.drag_release_mp = nil
    bank_state.drag_started_at = 0
end

function M.stop()
    M.hide()
    if bank_state.ui and valid(bank_state.ui.frame) then
        pcall(function() bank_state.ui.frame:RemoveFromParent() end)
    end
    bank_state.ui = nil
    bank_state.stage = "idle"
    bank_state.host_name = nil
    bank_state.tex_cache = {}
    bank_state.art = {}
    bank_state.art_loaded = false
end

local function refresh(ui, pc, organiser, ce, inv, actor)
    if not ui then return end
    if valid(inv) and not valid(bank_state.physical_inv) then
        bank_state.physical_inv = inv
    end
    if valid(actor) then
        if not valid(bank_state.physical_actor) then
            bank_state.physical_actor = actor
        end
        local already = false
        for _, ka in ipairs(bank_state.keep_actors) do
            if ce.same_object(ka, actor) then already = true; break end
        end
        if not already then bank_state.keep_actors[#bank_state.keep_actors + 1] = actor end
    end
    local chests = ce.nearby_chests({
        range_meters = 120,
        keep_actor = bank_state.physical_actor,
        keep_actors = bank_state.keep_actors,
    }) or {}
    if not bank_state.selected_tab_key then
        for _, c in ipairs(chests) do
            if ce.same_object(c.inv, inv) or ce.same_object(c.actor, actor) then
                bank_state.selected_tab_key = c.key
                break
            end
        end
        if not bank_state.selected_tab_key then bank_state.selected_tab_key = "__all__" end
    end

    local vm = ce.build_bank_view_model(chests, bank_state.selected_tab_key, bank_state.search_query, {
        order_map = bank_state.tab_order,
    })
    bank_state.view_model = vm
    if not bank_state.initial_sync_done then
        bank_state.initial_sync_done = true
        if vm.active_tab_index and vm.active_tab_index > 0 then
            bank_state.tab_page = math.max(1, math.ceil(vm.active_tab_index / TABS_PER_PAGE))
        end
    end

    if valid(ui.cap_top) then pcall(function() ui.cap_top:SetText(FText(tostring(vm.used_slots or 0))) end) end
    if valid(ui.cap_bot) then pcall(function() ui.cap_bot:SetText(FText(tostring(vm.max_slots or 0))) end) end
    if valid(ui.title) then
        local hdr_txt
        if vm.active_key == "__all__" then
            hdr_txt = ("The Bank of Dragonwilds (%d chests)"):format(#vm.tabs)
        else
            hdr_txt = ("Tab %d/%d ~ %s"):format(vm.active_tab_index or 1, math.max(1, #vm.tabs), tostring(vm.title))
        end
        pcall(function() ui.title:SetText(FText(hdr_txt)) end)
    end

    -- Search drawer visibility + active button highlight
    local show_search = bank_state.search_open or (bank_state.search_query ~= "")
    if valid(ui.search_row) then pcall(function() ui.search_row:SetVisibility(show_search and 4 or 1) end) end
    local btn_red_tex = art_tex(pc, "btn_red")
    local btn_stone_tex = art_tex(pc, "btn_stone")
    if ui.search_btn and valid(ui.search_btn.bg) then
        set_border_tex(ui.search_btn.bg, show_search and btn_red_tex or btn_stone_tex, show_search and OSRS.red_active or OSRS.btn_idle)
    end

    -- Tabs 0..7
    local tab_pages = math.max(1, math.ceil(#vm.tabs / TABS_PER_PAGE))
    bank_state.tab_page = math.max(1, math.min(tab_pages, bank_state.tab_page))
    bank_state.tab_prev = bank_state.tab_page > 1
    bank_state.tab_next = bank_state.tab_page < tab_pages
    local show_nav = tab_pages > 1
    if ui.tab_prev and valid(ui.tab_prev.holder) then
        pcall(function()
            ui.tab_prev.holder:SetVisibility(show_nav and 4 or 1)
            if valid(ui.tab_prev.label) then
                ui.tab_prev.label:SetColorAndOpacity({
                    SpecifiedColor = bank_state.tab_prev and OSRS.gold or OSRS.bevel_hi,
                    ColorUseRule = 0,
                })
            end
        end)
    end
    if ui.tab_next and valid(ui.tab_next.holder) then
        pcall(function()
            ui.tab_next.holder:SetVisibility(show_nav and 4 or 1)
            if valid(ui.tab_next.label) then
                ui.tab_next.label:SetColorAndOpacity({
                    SpecifiedColor = bank_state.tab_next and OSRS.gold or OSRS.bevel_hi,
                    ColorUseRule = 0,
                })
            end
        end)
    end

    bank_state.tab_targets = {}
    local function style_tab(tw, is_active, is_present)
        if not tw then return end
        local seam_col = is_active and OSRS.transparent or OSRS.rim_dark
        pcall(function()
            if is_active then
                local sbg = art_tex(pc, "stone_bg")
                set_border_tex(tw.bg, sbg, OSRS.tab_active)
            else
                local bg_col = not is_present and OSRS.tab_empty or OSRS.tab_idle
                set_border_box(tw.bg, bg_col, is_present and OSRS.rim_dark or OSRS.bevel_lo, 1)
            end
            set_border_box(tw.seam_line, seam_col, seam_col, 0)
        end)
    end

    local all_tab = ui.tabs[0]
    if all_tab then
        local is_sel = vm.active_key == "__all__"
        style_tab(all_tab, is_sel, true)
        pcall(function()
            all_tab.cap:SetVisibility(1)
            local tex = art_tex(pc, "infinity") or art_tex(pc, "fallback_chest")
            if valid(tex) then
                all_tab.img:SetBrushFromTexture(tex, false)
                all_tab.img:SetVisibility(3)
            end
        end)
    end

    local t_first = (bank_state.tab_page - 1) * TABS_PER_PAGE + 1
    for slot_idx = 1, TABS_PER_PAGE do
        local tab_idx = t_first + slot_idx - 1
        local tab_data = vm.tabs[tab_idx]
        bank_state.tab_targets[slot_idx] = tab_data
        local tw = ui.tabs[slot_idx]
        if tw and valid(tw.box) then
            if tab_data then
                pcall(function() tw.box:SetVisibility(0) end)
                local is_sel = (vm.active_key == tab_data.key)
                local is_drop = (bank_state.drag_entry ~= nil and bank_state.drag_hover_tab == slot_idx)
                style_tab(tw, is_sel or is_drop, true)
                if is_drop and valid(tw.bg) then
                    set_border_box(tw.bg, OSRS.slot_hot, OSRS.gold, 2)
                end
                pcall(function()
                    local badge = tab_data.role and tab_data.role ~= ""
                        and tostring(tab_data.role):gsub("^[Aa][Ll][Ll]:%s*", ""):sub(1, 5)
                        or tostring(tab_idx)
                    tw.cap:SetText(FText(badge))
                    tw.cap:SetColorAndOpacity({ SpecifiedColor = is_sel and OSRS.gold or OSRS.muted, ColorUseRule = 0 })
                    tw.cap:SetVisibility(3)
                end)
                local tex = tab_data.lead_icon and load_tex(tab_data.lead_icon) or nil
                if valid(tex) then
                    pcall(function() tw.img:SetBrushFromTexture(tex, false); tw.img:SetVisibility(3) end)
                else
                    local fallback = art_tex(pc, "fallback_chest")
                    pcall(function()
                        if valid(fallback) then tw.img:SetBrushFromTexture(fallback, false); tw.img:SetVisibility(3)
                        else tw.img:SetVisibility(1) end
                    end)
                end
            else
                pcall(function()
                    tw.box:SetVisibility(1)
                    tw.img:SetVisibility(1)
                    tw.cap:SetText(FText(""))
                    tw.cap:SetVisibility(1)
                end)
            end
        end
    end

    -- 8x7 Grid
    local grid_pages = math.max(1, math.ceil(#vm.entries / GRID_SLOTS))
    bank_state.grid_page = math.max(1, math.min(grid_pages, bank_state.grid_page))
    bank_state.grid_pages = grid_pages
    bank_state.grid_entries = {}
    local g_first = (bank_state.grid_page - 1) * GRID_SLOTS + 1
    local any_miss = false
    for i = 1, GRID_SLOTS do
        local entry = vm.entries[g_first + i - 1]
        bank_state.grid_entries[i] = entry
        local tile = ui.tiles[i]
        if tile and valid(tile.box) then
            if not entry then
                pcall(function()
                    tile.bg:SetVisibility(1)
                    tile.img:SetVisibility(1)
                    tile.mono:SetVisibility(1)
                    tile.cnt:SetVisibility(1)
                end)
            else
                local tex = entry.icon and load_tex(entry.icon) or nil
                if not tex and type(row_icons.index_ready) == "function" and not row_icons.index_ready() then
                    any_miss = true
                end
                local sel = bank_state.selected_entry_key == entry.key or bank_state.drag_tile == i
                local hov = bank_state.hovered_slot == i
                pcall(function()
                    if sel or hov then
                        tile.bg:SetVisibility(3)
                        set_border_box(tile.bg, sel and OSRS.slot_sel or OSRS.slot_hot, OSRS.gold, 1)
                    else
                        tile.bg:SetVisibility(1)
                    end
                    if valid(tex) then
                        tile.img:SetBrushFromTexture(tex, false)
                        tile.img:SetVisibility(3)
                        tile.mono:SetVisibility(1)
                    else
                        tile.img:SetVisibility(1)
                        tile.mono:SetText(FText(entry.monogram or "?"))
                        tile.mono:SetVisibility(3)
                    end
                    if entry.count_text ~= "" and (tonumber(entry.count) or 0) > 1 then
                        tile.cnt:SetText(FText(entry.count_text))
                        tile.cnt:SetColorAndOpacity({ SpecifiedColor = entry.count_color, ColorUseRule = 0 })
                        tile.cnt:SetVisibility(3)
                    else
                        tile.cnt:SetVisibility(1)
                    end
                end)
            end
        end
    end
    bank_state.icon_miss = any_miss

    -- Proportional OSRS scrollbar thumb sizing
    if ui.scroll_sp1 and ui.scroll_th and ui.scroll_sp2 then
        local track_h = 324
        local frac = 1 / grid_pages
        local th = math.max(36, math.floor(track_h * frac))
        local remain = math.max(0, track_h - th)
        local top_h = grid_pages > 1 and math.floor(remain * (bank_state.grid_page - 1) / (grid_pages - 1)) or 0
        local bot_h = math.max(0, remain - top_h)
        pcall(function()
            ui.scroll_sp1:SetHeightOverride(top_h)
            ui.scroll_sp1:SetVisibility(top_h > 0 and 0 or 1)
            ui.scroll_sp2:SetHeightOverride(bot_h)
            ui.scroll_sp2:SetVisibility(bot_h > 0 and 0 or 1)
            local s = ui.scroll_th.Slot
            if s then s:SetSize({ Value = th, SizeRule = 0 }) end
        end)
    end

    -- Hover tooltip & status line
    local qty_lbl = bank_state.qty_mode == 0 and "All" or tostring(bank_state.qty_mode)
    if valid(ui.status_line) then
        local info_txt = tostring(bank_state.status_text or "")
        local hov_entry = bank_state.hovered_slot and bank_state.grid_entries[bank_state.hovered_slot] or nil
        local hov_tab = bank_state.hovered_tab
        if hov_entry then
            info_txt = string.format("%s x%d (%s, %.1f m)  •  Click withdraws %s",
                tostring(hov_entry.item_name or "?"), tonumber(hov_entry.count) or 1,
                tostring(hov_entry.chest_title or "Chest"), tonumber(hov_entry.chest_distance) or 0, qty_lbl)
        elseif hov_tab == 0 then
            info_txt = string.format("Tab 0: All Nearby Chests (%d/%d used across %d chests)",
                tonumber(vm.used_slots) or 0, tonumber(vm.max_slots) or 0, #vm.tabs)
        elseif hov_tab then
            local ht = bank_state.tab_targets[hov_tab]
            if ht then
                info_txt = string.format("Tab %d: %s (%d/%d used, %.1f m)",
                    tonumber(ht.index) or hov_tab, tostring(ht.title or "Chest"),
                    tonumber(ht.used_slots) or 0, tonumber(ht.max_slots) or 0, tonumber(ht.distance) or 0)
            end
        end
        local st = string.format("Page %d/%d  •  %s", bank_state.grid_page, grid_pages, info_txt)
        pcall(function() ui.status_line:SetText(FText(st)) end)
    end
    for mode, qb in pairs(ui.qty_btns or {}) do
        if qb and valid(qb.bg) then
            local active = (bank_state.qty_mode == mode)
            pcall(function()
                set_border_tex(qb.bg, active and btn_red_tex or btn_stone_tex, active and OSRS.red_active or OSRS.btn_idle)
                qb.label:SetColorAndOpacity({ SpecifiedColor = active and OSRS.yellow or OSRS.cream, ColorUseRule = 0 })
            end)
        end
    end
    if ui.role_btn and valid(ui.role_btn.label) then
        local target_actor = vm.active_chest and vm.active_chest.actor or actor
        local cur_role = valid(target_actor) and organiser.label_of(target_actor) or nil
        local rtxt = cur_role and cur_role:gsub("^[Aa][Ll][Ll]:%s*", "") or "Set Role"
        if #rtxt > 11 then rtxt = rtxt:sub(1, 10) .. "." end
        pcall(function() ui.role_btn.label:SetText(FText(rtxt)) end)
    end
    if ui.pin_btn and valid(ui.pin_btn.bg) then
        local pin_target = vm.active_chest or nil
        if not pin_target and vm.tabs then
            for _, t in ipairs(vm.tabs) do
                if t.chest and (ce.same_object(t.chest.inv, inv) or ce.same_object(t.chest.actor, actor)) then
                    pin_target = t.chest; break
                end
            end
        end
        local is_pinned = bank_state.pinned_key ~= nil and pin_target and (pin_target.key == bank_state.pinned_key)
        set_border_tex(ui.pin_btn.bg, is_pinned and btn_red_tex or btn_stone_tex, is_pinned and OSRS.red_active or OSRS.btn_idle)
    end
end

function M.handle_click(action_id, inv, actor, api, organiser, ce)
    if type(action_id) ~= "string" then return false end
    if action_id == "bank:toggle_native" then
        organiser.set_setting("osrsBankMode", false)
        M.hide()
        return true
    elseif action_id == "bank:close" then
        local restore_inv = bank_state.physical_inv
        M.hide()
        if valid(api) then
            if valid(restore_inv) then pcall(function() api:SetInventory(restore_inv) end) end
            pcall(function() api:CloseCurrentInventory() end)
        end
        return true
    elseif action_id == "bank:open_menu" then
        local restore_inv = bank_state.physical_inv
        M.hide()
        if valid(api) then
            if valid(restore_inv) then pcall(function() api:SetInventory(restore_inv) end) end
            pcall(function() api:CloseCurrentInventory() end)
        end
        return "open_menu"
    elseif action_id == "bank:tab_prev" then
        if bank_state.tab_prev then
            bank_state.tab_page = bank_state.tab_page - 1
            if bank_state.view_model and type(bank_state.view_model.tabs) == "table" then
                local tf = (bank_state.tab_page - 1) * TABS_PER_PAGE + 1
                bank_state.tab_targets = {}
                for s = 1, TABS_PER_PAGE do bank_state.tab_targets[s] = bank_state.view_model.tabs[tf + s - 1] end
            end
        end
    elseif action_id == "bank:tab_next" then
        if bank_state.tab_next then
            bank_state.tab_page = bank_state.tab_page + 1
            if bank_state.view_model and type(bank_state.view_model.tabs) == "table" then
                local tf = (bank_state.tab_page - 1) * TABS_PER_PAGE + 1
                bank_state.tab_targets = {}
                for s = 1, TABS_PER_PAGE do bank_state.tab_targets[s] = bank_state.view_model.tabs[tf + s - 1] end
            end
        end
    elseif action_id == "bank:grid_prev" then
        bank_state.grid_page = math.max(1, bank_state.grid_page - 1)
    elseif action_id == "bank:grid_next" then
        bank_state.grid_page = math.min(bank_state.grid_pages or 1, bank_state.grid_page + 1)
    elseif action_id == "bank:search_toggle" then
        bank_state.search_open = not bank_state.search_open
        if not bank_state.search_open and bank_state.search_query ~= "" then
            bank_state.search_query = ""
            bank_state.grid_page = 1
            if bank_state.ui and valid(bank_state.ui.search_box) then
                pcall(function() bank_state.ui.search_box:SetText(FText("")) end)
            end
        end
    elseif action_id == "bank:search_apply" then
        if bank_state.ui and valid(bank_state.ui.search_box) then
            local raw = safe_call(function() return bank_state.ui.search_box:GetText():ToString() end, "")
            bank_state.search_query = tostring(raw or "")
            bank_state.grid_page = 1
            bank_state.status_text = bank_state.search_query ~= ""
                and ('Filtering "' .. bank_state.search_query .. '"') or "Showing current tab."
        end
    elseif action_id == "bank:search_clear" then
        bank_state.search_query = ""
        bank_state.search_open = false
        bank_state.grid_page = 1
        if bank_state.ui and valid(bank_state.ui.search_box) then
            pcall(function() bank_state.ui.search_box:SetText(FText("")) end)
        end
        bank_state.status_text = "Filter cleared."
    elseif action_id:match("^bank:qty:%d+$") then
        local mode = tonumber(action_id:match("^bank:qty:(%d+)$")) or 1
        bank_state.qty_mode = mode
        bank_state.status_text = "Withdraw quantity: " .. (mode == 0 and "All" or tostring(mode)) .. "."
    elseif action_id:match("^bank:tab:%d+$") then
        local idx = tonumber(action_id:match("^bank:tab:(%d+)$"))
        if idx == 0 then
            bank_state.selected_tab_key = "__all__"
            bank_state.grid_page = 1
            bank_state.status_text = "Viewing all nearby chests."
        else
            local tab = idx and bank_state.tab_targets[idx] or nil
            if tab and tab.chest then
                bank_state.selected_tab_key = tab.key
                bank_state.grid_page = 1
                if valid(tab.chest.actor) then
                    local seen = false
                    for _, ka in ipairs(bank_state.keep_actors) do
                        if ce.same_object(ka, tab.chest.actor) then seen = true; break end
                    end
                    if not seen then bank_state.keep_actors[#bank_state.keep_actors + 1] = tab.chest.actor end
                end
                ce.switch_open_chest(api, tab.chest.inv)
                bank_state.status_text = "Tab " .. tostring(tab.index or idx) .. ": " .. (tab.title or "Chest")
            end
        end
    elseif action_id:match("^bank:tile:%d+$") then
        local idx = tonumber(action_id:match("^bank:tile:(%d+)$"))
        local entry = idx and bank_state.grid_entries[idx] or nil
        if entry then
            bank_state.selected_entry_key = entry.key
            local amt = bank_state.qty_mode == 0 and nil or bank_state.qty_mode
            local ok, msg = ce.withdraw_to_backpack(entry, amt, function(done_ok, done_err)
                bank_state.status_text = done_ok and ("Withdrew " .. entry.item_name) or tostring(done_err or "Failed")
                log.info("Bank withdraw done: ok=" .. tostring(done_ok) .. " msg=" .. tostring(bank_state.status_text))
                bank_state.last_render_key = nil
            end)
            bank_state.status_text = tostring(msg or (ok and "Withdrawn." or "Failed."))
            log.info("Bank withdraw result: ok=" .. tostring(ok) .. " msg=" .. tostring(bank_state.status_text))
        end
    elseif action_id == "bank:deposit" then
        local active = bank_state.view_model and bank_state.view_model.active_chest or nil
        local ok_d, msg
        if type(ce.deposit_from_bank) == "function" then
            ok_d, msg = ce.deposit_from_bank(active, organiser)
        else
            ok_d, msg = organiser.deposit_backpack()
        end
        bank_state.status_text = tostring(msg or (ok_d and "Deposited." or "Deposit failed."))
    elseif action_id == "bank:sort" then
        local target_inv = (bank_state.view_model and bank_state.view_model.active_chest and bank_state.view_model.active_chest.inv) or inv
        local ctrl = engine.local_controller()
        local ok_s, msg = false, nil
        if valid(target_inv) and valid(ctrl) and type(organiser.sort_storage) == "function" then
            ok_s, msg = organiser.sort_storage(target_inv, ctrl)
        else
            ok_s, msg = organiser.sort_open_storage()
        end
        bank_state.status_text = tostring(msg or (ok_s and "Sorted." or "Sort failed."))
    elseif action_id == "bank:resort" then
        local _, msg = organiser.resort_nearby_storage()
        bank_state.status_text = tostring(msg or "Resorted.")
    elseif action_id == "bank:organise" then
        local _, msg = organiser.auto_organise_base()
        bank_state.status_text = tostring(msg or "Organised.")
    elseif action_id == "bank:pin" then
        local vm = bank_state.view_model
        local target = vm and vm.active_chest or nil
        if not target and vm and vm.tabs then
            for _, t in ipairs(vm.tabs) do
                if t.chest and (ce.same_object(t.chest.inv, inv) or ce.same_object(t.chest.actor, actor)) then
                    target = t.chest; break
                end
            end
        end
        if not target and valid(actor) then
            target = { actor = actor, inv = inv, key = full_name(actor), title = "Open Chest" }
        end
        if target and bank_state.pinned_key == target.key and type(ce.clear_pin) == "function" then
            ce.clear_pin()
            bank_state.pinned_key = nil
            bank_state.status_text = "Cleared chest minimap pin."
        else
            local ok_p, msg = ce.pin_chest(target)
            if ok_p and target then bank_state.pinned_key = target.key end
            bank_state.status_text = tostring(msg or "Pinned.")
        end
    elseif action_id == "bank:apply_role" then
        local vm = bank_state.view_model
        local target = vm and vm.active_chest or nil
        local target_actor = (target and target.actor) or bank_state.physical_actor or actor
        local target_inv = (target and target.inv) or bank_state.physical_inv or inv
        local cur_role = valid(target_actor) and type(organiser.label_of) == "function" and organiser.label_of(target_actor) or nil
        local choices, seen = {}, {}
        local function add_role(r)
            if type(r) == "string" and r ~= "" and not seen[r] then
                seen[r] = true
                choices[#choices + 1] = r
            end
        end
        if valid(target_inv) and type(organiser.top_label_suggestions) == "function" then
            for _, s in ipairs(organiser.top_label_suggestions(target_inv, target_actor, 6) or {}) do
                add_role(s.label)
            end
        end
        for _, fb in ipairs({ "All: Misc", "All: Mineral", "All: Ore", "All: Consumable", "All: Material", "All: Equipment" }) do
            add_role(fb)
        end
        local chosen = choices[1]
        if cur_role and #choices > 1 then
            for i, c in ipairs(choices) do
                if c == cur_role then
                    chosen = choices[(i % #choices) + 1]
                    break
                end
            end
        end
        if chosen and valid(target_actor) then
            organiser.set_label(engine.local_controller(), target_actor, chosen)
            bank_state.status_text = "Role set: " .. tostring(chosen)
        else
            local restore_inv = bank_state.physical_inv
            M.hide()
            if valid(api) then
                if valid(restore_inv) then pcall(function() api:SetInventory(restore_inv) end) end
                pcall(function() api:CloseCurrentInventory() end)
            end
            return "open_menu"
        end
    else
        return false
    end
    bank_state.last_render_key = nil
    return true
end

local function scan_hover(ui)
    local h_slot, h_tab = nil, nil
    for i = 1, GRID_SLOTS do
        local tile = ui.tiles and ui.tiles[i]
        if tile and bank_state.grid_entries[i] and valid(tile.hit)
            and safe_call(function() return tile.hit:IsHovered() end, false) == true then
            h_slot = i
            break
        end
    end
    if not h_slot then
        for t = 0, TABS_PER_PAGE do
            local tw = ui.tabs and ui.tabs[t]
            local present = (t == 0) or (bank_state.tab_targets[t] ~= nil)
            if tw and present and valid(tw.hit)
                and safe_call(function() return tw.hit:IsHovered() end, false) == true then
                h_tab = t
                break
            end
        end
    end
    return h_slot, h_tab
end

function M.render(pc, open_panel, inv, actor, api, organiser, ce, action_map)
    local hn = valid(open_panel) and full_name(open_panel) or "__none__"
    hide_vertical_navigation(open_panel)

    if bank_state.host_name ~= hn or not (bank_state.ui and valid(bank_state.ui.frame)) then
        if bank_state.ui and valid(bank_state.ui.frame) then
            pcall(function() bank_state.ui.frame:RemoveFromParent() end)
        end
        bank_state.ui = nil
        local ui, err = build_frame(pc, open_panel)
        bank_state.host_name = hn
        if not ui then
            restore_vertical_navigation()
            return false, err
        end
        bank_state.ui = ui
        bank_state.stage = "frame"
        return true
    end
    if bank_state.stage == "frame" then
        if not build_content(bank_state.ui, action_map) then
            bank_state.stage = "broken"
            restore_vertical_navigation()
            log.warn("OSRS Bank content build failed")
            return false, "OSRS Bank content build failed"
        end
        bank_state.stage = "content"
        return true
    end
    if bank_state.stage == "content" then
        flush_later(bank_state.ui)
        pcall(function() bank_state.ui.frame:SetVisibility(0) end)
        bank_state.stage = "ready"
        bank_state.last_render_key = nil
        log.info(("OSRS Bank HUD v%s ready at (%d,%d)"):format(M.VERSION, bank_state.ui.dock_x, bank_state.ui.dock_y))
        return true
    end
    if bank_state.stage == "broken" then return false end

    pcall(function() bank_state.ui.frame:SetVisibility(0) end)
    if bank_state.search_open and bank_state.ui and valid(bank_state.ui.search_box) then
        local typed = safe_call(function() return bank_state.ui.search_box:GetText():ToString() end, nil)
        if type(typed) == "string" and typed ~= bank_state.search_query then
            bank_state.search_query = typed
            bank_state.grid_page = 1
        end
    end
    if bank_state.icon_miss and type(row_icons.index_step) == "function" then
        local ready = pcall(row_icons.index_step) and type(row_icons.index_ready) == "function" and row_icons.index_ready()
        if ready and not bank_state.was_index_ready then
            bank_state.was_index_ready = true
            bank_state.last_render_key = nil
        end
    end
    local function get_mouse_pos(pc)
        if not valid(pc) or type(StaticFindObject) ~= "function" then return nil end
        local layout = safe_call(function() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end)
        local mp = valid(layout) and safe_call(function() return layout:GetMousePositionOnViewport(pc) end) or nil
        if mp and type(mp.X) == "number" and type(mp.Y) == "number" then
            return { X = mp.X, Y = mp.Y }
        end
        return nil
    end

    local function cursor_hovered_tab(ui, pc, mp_override)
        if not ui then return nil end
        for t = 1, TABS_PER_PAGE do
            local tw = ui.tabs and ui.tabs[t]
            if tw and bank_state.tab_targets[t] and valid(tw.hit)
                and safe_call(function() return tw.hit:IsHovered() end, false) == true then
                return t
            end
        end
        local mp = mp_override or get_mouse_pos(pc)
        if mp then
            local show_nav = ui.tab_prev and valid(ui.tab_prev.holder)
                and safe_call(function() return ui.tab_prev.holder:GetVisibility() end, 1) ~= 1
            local nav_off = show_nav and 18 or 0
            if bank_state.drag_press_mp and bank_state.drag_press_local then
                local rx = mp.X - (bank_state.drag_press_mp.X - bank_state.drag_press_local.x)
                local ry = mp.Y - (bank_state.drag_press_mp.Y - bank_state.drag_press_local.y)
                if ry >= 30 and ry <= 98 then
                    for t = 1, TABS_PER_PAGE do
                        if bank_state.tab_targets[t] then
                            local tx = 13 + nav_off + t * 59
                            if rx >= (tx - 1) and rx <= (tx + 58) then return t end
                        end
                    end
                end
            end
            local dx = tonumber(ui.dock_x) or FALLBACK_X
            local dy = tonumber(ui.dock_y) or FALLBACK_Y
            local x0 = dx + 13 + nav_off
            if mp.Y >= (dy + 34) and mp.Y <= (dy + 96) then
                for t = 1, TABS_PER_PAGE do
                    if bank_state.tab_targets[t] then
                        local tx = x0 + t * 59
                        if mp.X >= (tx - 1) and mp.X <= (tx + 58) then return t end
                    end
                end
            end
        end
        return nil
    end

    function M.handle_press(action_id)
        if type(action_id) ~= "string" then return false end
        local idx = tonumber(action_id:match("^bank:tile:(%d+)$"))
        local entry = idx and bank_state.grid_entries[idx] or nil
        if idx and entry then
            if bank_state.drag_tile == idx and bank_state.drag_entry == entry then return true end
            local row = math.floor((idx - 1) / GRID_COLS)
            local col = (idx - 1) % GRID_COLS
            local pc = (bank_state.ui and bank_state.ui.pc) or engine.local_controller()
            bank_state.drag_tile = idx
            bank_state.drag_entry = entry
            bank_state.drag_hover_tab = nil
            bank_state.drag_press_mp = get_mouse_pos(pc)
            bank_state.drag_press_local = { x = 17 + col * 60 + 30, y = 92 + row * 52 + 26 }
            bank_state.drag_release_mp = nil
            bank_state.drag_started_at = os.clock()
            bank_state.status_text = "Dragging " .. tostring(entry.item_name or "item") .. " (drop on a chest tab to move)"
            bank_state.last_render_key = nil
            return true
        end
        return false
    end

    function M.capture_release()
        if not bank_state.drag_entry then return false end
        local ui = bank_state.ui
        local pc = (ui and ui.pc) or engine.local_controller()
        bank_state.drag_release_mp = get_mouse_pos(pc)
        local t = cursor_hovered_tab(ui, pc, bank_state.drag_release_mp)
        if t then bank_state.drag_hover_tab = t end
        return true
    end

    function M.handle_release(action_id, inv, actor, api, organiser, ce)
        local entry = bank_state.drag_entry
        if not entry then return false end
        local ui = bank_state.ui
        local pc = (ui and ui.pc) or engine.local_controller()
        local drop_tab = cursor_hovered_tab(ui, pc, bank_state.drag_release_mp) or bank_state.drag_hover_tab
        if not drop_tab and type(action_id) == "string" then
            local direct = tonumber(action_id:match("^bank:tab:(%d+)$"))
            if direct and direct >= 1 then drop_tab = direct end
        end
        local rel_mp = bank_state.drag_release_mp
        bank_state.drag_tile = nil
        bank_state.drag_entry = nil
        bank_state.drag_hover_tab = nil
        bank_state.drag_press_mp = nil
        bank_state.drag_press_local = nil
        bank_state.drag_release_mp = nil
        bank_state.drag_started_at = 0
        bank_state.last_render_key = nil
        if drop_tab and drop_tab >= 1 then
            local target = bank_state.tab_targets[drop_tab]
            if target and target.chest and type(ce.move_entry_to_chest) == "function" then
                local ok_m, msg = ce.move_entry_to_chest(entry, target.chest, nil, function(done_ok, done_err)
                    bank_state.status_text = done_ok
                        and ("Moved " .. tostring(entry.item_name or "item") .. " -> " .. tostring(target.title or "chest"))
                        or tostring(done_err or "Move failed.")
                    log.info("Bank drag done: ok=" .. tostring(done_ok) .. " msg=" .. tostring(bank_state.status_text))
                    bank_state.last_render_key = nil
                end, organiser)
                bank_state.status_text = tostring(msg or (ok_m and "Moved." or "Move failed."))
                log.info("Bank drag drop: tab=" .. tostring(drop_tab) .. " ok=" .. tostring(ok_m) .. " msg=" .. tostring(bank_state.status_text))
                return true
            end
        end
        log.info("Bank drag cancelled: drop_tab=" .. tostring(drop_tab) .. " mp=" .. tostring(rel_mp and (tostring(rel_mp.X) .. "," .. tostring(rel_mp.Y)) or "nil"))
        bank_state.status_text = "Click an item to withdraw."
        return false
    end

    local h_slot, h_tab = scan_hover(bank_state.ui)
    bank_state.hovered_slot, bank_state.hovered_tab = h_slot, h_tab
    if not bank_state.drag_entry and bank_state.ui and bank_state.ui.tiles then
        for i = 1, GRID_SLOTS do
            local t = bank_state.ui.tiles[i]
            if t and bank_state.grid_entries[i] and valid(t.hit)
                and safe_call(function() return t.hit:IsPressed() end, false) == true then
                M.handle_press("bank:tile:" .. tostring(i))
                break
            end
        end
    end
    if bank_state.drag_entry then
        bank_state.drag_hover_tab = cursor_hovered_tab(bank_state.ui, pc) or (h_tab and h_tab >= 1 and h_tab or nil)
        if bank_state.drag_started_at > 0 and (os.clock() - bank_state.drag_started_at) > 8.0 then
            M.handle_release(nil, inv, actor, api, organiser, ce)
        end
    end
    local busy = type(organiser.is_busy) == "function" and organiser.is_busy() or false
    local pulse = math.floor(os.clock())
    local render_key = hn .. "|" .. tostring(bank_state.selected_tab_key or "") .. "|"
        .. tostring(bank_state.tab_page) .. "|" .. tostring(bank_state.grid_page) .. "|"
        .. tostring(bank_state.qty_mode) .. "|" .. tostring(bank_state.search_open) .. "|"
        .. tostring(bank_state.search_query) .. "|" .. tostring(bank_state.status_text) .. "|"
        .. tostring(bank_state.drag_tile or "") .. "|" .. tostring(bank_state.drag_hover_tab or "") .. "|"
        .. tostring(busy) .. "|" .. full_name(inv) .. "|" .. tostring(h_slot or "") .. "|"
        .. tostring(h_tab or "") .. "|" .. tostring(pulse)
    if bank_state.last_render_key ~= render_key then
        bank_state.last_render_key = render_key
        local ok_ref, err_ref = pcall(refresh, bank_state.ui, pc, organiser, ce, inv, actor)
        if not ok_ref then log.warn("OSRS Bank refresh failed: " .. tostring(err_ref)) end
    end
    return true
end

function M.state() return bank_state end

return M
