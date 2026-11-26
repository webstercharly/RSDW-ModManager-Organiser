-- Docked side panel for the Chest Organiser.
-- Polls active chest state on the game thread and docks a native-styled WBP_Panel
-- beside the open storage window, keeping both chest and backpack interactive.

local engine = require("rlm_engine")
local log = require("rlm_log")
local organiser = require("rlm_organiser")
local glass = require("rlm_glass")
local themes = require("rlm_ui_theme")
local ui_kit = require("rlm_ui_kit")

local M = { VERSION = "0.1.0" }

local PANEL_PKG = "/Game/UI/Panels/WBP_Panel"
local TEXT_PKG = "/Game/UI/Common/WBP_DomTextBlock"
local BUTTON_PKG = "/Game/UI/Common/WBP_DomAllCapsButton"
local HOST_CLASSES = { "WBP_WorldActorInventory_MainPanel_C", "WBP_Inventory_MainPanel_C" }
local STATION_CLASS = "WBP_ProcessingStation_MainPanel_C"

local DEFAULT_X = 1410
local DEFAULT_Y = 235
local PANEL_WIDTH = 456
local PANEL_HEIGHT = 540
local CONTENT_WIDTH = PANEL_WIDTH - 80

local GOLD, CREAM, MUTED
local ACCENT = { R = 0.35, G = 0.80, B = 0.50, A = 1.0 }

local state = {
    started = false,
    stage = "idle",
    ui = nil,
    host = nil,
    host_name = nil,
    station = nil,
    next_host_scan = 0,
    pending_click = nil,
    pending_open_menu = false,
    session_key = nil,
    action_status = nil,
    sug_labels = {},
    action_map = {},
    config = nil,
}

local function valid(obj)
    return engine.is_valid(obj)
end

local function full_name(obj)
    return engine.full_name(obj) or ""
end

local function safe_call(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function is_template(obj)
    local name = full_name(obj)
    return name == "" or name:find("Default__", 1, true) ~= nil or name:find(":WidgetTree.", 1, true) ~= nil
end

local function live_widget(cls)
    if type(FindFirstOf) ~= "function" then return nil end
    local w = safe_call(function() return FindFirstOf(cls) end)
    if not valid(w) or is_template(w) then return nil end
    return w
end

local function load_class(pkg)
    if type(StaticFindObject) ~= "function" then return nil end
    local asset = pkg:match("([^/]+)$")
    if type(LoadAsset) == "function" then pcall(function() LoadAsset(pkg) end) end
    local c = safe_call(function() return StaticFindObject(pkg .. "." .. asset .. "_C") end)
    return valid(c) and c or nil
end

local function find_button_style()
    local pm = live_widget("WBP_PauseMenuScreen_C")
    if pm then
        local sb = safe_call(function() return pm.SettingsButton end)
        if valid(sb) then return sb end
    end
    return nil
end

local function find_canvas(root)
    if not valid(root) then return nil end
    local cname = safe_call(function() return root:GetClass():GetFName():ToString() end, "")
    if cname == "CanvasPanel" then return root end
    local inner = safe_call(function() return root:GetContent() end)
    if valid(inner) then
        local ic = safe_call(function() return inner:GetClass():GetFName():ToString() end, "")
        if ic == "CanvasPanel" then return inner end
    end
    local count = tonumber(safe_call(function() return root:GetChildrenCount() end, 0)) or 0
    for i = 0, count - 1 do
        local child = safe_call(function() return root:GetChildAt(i) end)
        if valid(child) then
            local cc = safe_call(function() return child:GetClass():GetFName():ToString() end, "")
            if cc == "CanvasPanel" then return child end
        end
    end
    return nil
end

local function widget_is_active_or_visible(w)
    if not valid(w) then return false end
    local active = safe_call(function() return w:IsActivated() end)
    if active == nil then
        active = safe_call(function() return w.bIsActive end)
    end
    if active ~= nil then return active == true end
    return safe_call(function() return w:IsVisible() end, false) == true
end

local function refresh_hosts(preferred_panel)
    if valid(preferred_panel) then
        local tree = safe_call(function() return preferred_panel.WidgetTree end)
        local root = valid(tree) and safe_call(function() return tree.RootWidget end) or nil
        if find_canvas(root) then
            state.host = preferred_panel
            return state.host
        end
    end

    local now = os.clock()
    if valid(state.host) and widget_is_active_or_visible(state.host) and valid(state.station) then
        return state.host
    end
    if now < state.next_host_scan and valid(state.host) then return state.host end
    state.next_host_scan = now + 1.5

    if not valid(state.station) then
        state.station = live_widget(STATION_CLASS)
    end
    local picked = nil
    for _, cls in ipairs(HOST_CLASSES) do
        local candidate = live_widget(cls)
        if valid(candidate) and widget_is_active_or_visible(candidate) then
            local tree = safe_call(function() return candidate.WidgetTree end)
            local root = valid(tree) and safe_call(function() return tree.RootWidget end) or nil
            if find_canvas(root) then
                picked = candidate
                break
            end
        end
    end
    if valid(picked) then
        state.host = picked
    elseif not valid(state.host) then
        for _, cls in ipairs(HOST_CLASSES) do
            local candidate = live_widget(cls)
            if valid(candidate) then
                local tree = safe_call(function() return candidate.WidgetTree end)
                local root = valid(tree) and safe_call(function() return tree.RootWidget end) or nil
                if find_canvas(root) then
                    state.host = candidate
                    break
                end
            end
        end
    end
    return state.host
end

local function station_is_visible()
    if not valid(state.station) then
        state.station = live_widget(STATION_CLASS)
    end
    return widget_is_active_or_visible(state.station)
end

local function hide_embers(frame)
    local function walk(w, depth)
        if depth > 8 or not valid(w) then return end
        local cls = safe_call(function() return w:GetClass():GetFName():ToString() end, "")
        if cls == "NiagaraSystemWidget" then
            pcall(function() w:SetVisibility(1) end)
            return
        end
        local n = tonumber(safe_call(function() return w:GetChildrenCount() end, 0)) or 0
        for i = 0, n - 1 do
            walk(safe_call(function() return w:GetChildAt(i) end), depth + 1)
        end
    end
    pcall(function() walk(frame.WidgetTree.RootWidget, 0) end)
end

local function later(ui, fn)
    ui.queue[#ui.queue + 1] = fn
end

local function construct(tree, umg_name)
    if type(StaticFindObject) ~= "function" or type(StaticConstructObject) ~= "function" then return nil end
    local cls = safe_call(function() return StaticFindObject("/Script/UMG." .. umg_name) end)
    if not valid(cls) then return nil end
    return safe_call(function() return StaticConstructObject(cls, tree) end)
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
        end)
        pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        pcall(function() tb:SetText(FText(initial or "")) end)
        pcall(function() tb:SetVisibility(3) end)
    end)
    return tb, slot
end

local function add_divider(ui, col, top_pad, bottom_pad)
    local box = construct(ui.tree, "SizeBox")
    if not valid(box) then return end
    local slot = safe_call(function() return col:AddChildToVerticalBox(box) end)
    local line = construct(ui.tree, "Border")
    if valid(line) then safe_call(function() box:AddChild(line) end) end
    later(ui, function()
        pcall(function() box:SetHeightOverride(1) end)
        if valid(slot) then
            pcall(function() slot:SetPadding({ Left = 0, Top = top_pad or 6, Right = 0, Bottom = bottom_pad or 8 }) end)
        end
        if valid(line) then
            pcall(function() line:SetBrushColor({ R = 0.79, G = 0.85, B = 0.94, A = 0.14 }) end)
        end
    end)
end

local function add_button(ui, parent, kind, label, action_id, width, height, scheme)
    local holder = construct(ui.tree, "SizeBox")
    if not valid(holder) then return nil end
    local pslot = kind == "v"
        and safe_call(function() return parent:AddChildToVerticalBox(holder) end)
        or safe_call(function() return parent:AddChildToHorizontalBox(holder) end)

    local overlay = construct(ui.tree, "Overlay")
    if not valid(overlay) then return nil end
    safe_call(function() holder:AddChild(overlay) end)

    local surface_bg = construct(ui.tree, "Border")
    local sslot = valid(surface_bg) and safe_call(function() return overlay:AddChildToOverlay(surface_bg) end) or nil

    local btn = safe_call(function() return ui.wbl:Create(ui.pc, ui.btn_cls, ui.pc) end)
    if not valid(btn) then return nil end
    local bslot = safe_call(function() return overlay:AddChildToOverlay(btn) end)

    local txt = construct(ui.tree, "TextBlock")
    if not valid(txt) then
        txt = safe_call(function() return StaticConstructObject(ui.text_cls, ui.tree) end)
    end
    local tslot = valid(txt) and safe_call(function() return overlay:AddChildToOverlay(txt) end) or nil

    local bname = full_name(btn)
    if bname ~= "" then
        state.action_map[bname] = action_id
    end

    local text_color = (scheme == "primary") and GOLD or CREAM
    local like = find_button_style()
    later(ui, function()
        if width then pcall(function() holder:SetWidthOverride(width) end) end
        if height then pcall(function() holder:SetHeightOverride(height) end) end
        pcall(function() overlay:SetVisibility(4) end)
        if valid(surface_bg) then
            if valid(sslot) then
                pcall(function() sslot:SetHorizontalAlignment(0); sslot:SetVerticalAlignment(0) end)
            end
            pcall(function() surface_bg:SetVisibility(3) end)
            glass.apply(surface_bg, scheme or "inset", themes.active(), 8)
        end
        if valid(like) then
            pcall(function() btn:SetStyle(like.Style) end)
        end
        pcall(function() btn:SetVisibility(0) end)
        pcall(function() btn:SetIsSelectable(false) end)
        pcall(function() btn:SetShouldSelectUponReceivingFocus(false) end)
        pcall(function() btn:SetIsFocusable(false) end)
        pcall(function() btn:SetLabelText(FText("")) end)
        if valid(bslot) then
            pcall(function() bslot:SetHorizontalAlignment(0); bslot:SetVerticalAlignment(0) end)
        end
        if valid(txt) then
            pcall(function() local f = txt.Font; f.Size = 12; txt:SetFont(f) end)
            pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = text_color, ColorUseRule = 0 }) end)
            pcall(function() txt:SetText(FText(label or "")) end)
            ui_kit.style_button_label(txt)
        end
        if valid(tslot) then
            pcall(function()
                tslot:SetHorizontalAlignment(2)
                tslot:SetVerticalAlignment(2)
                tslot:SetPadding({ Left = 8, Top = 0, Right = 8, Bottom = 0 })
            end)
        end
    end)

    return { holder = holder, slot = pslot, btn = btn, label = txt, bg = surface_bg, base_scheme = scheme or "inset" }
end

local function panel_coords()
    local cfg = state.config
    local x = tonumber(cfg and cfg.OrganiserPanelX) or DEFAULT_X
    local y = tonumber(cfg and cfg.OrganiserPanelY) or DEFAULT_Y
    return x, y
end

local function build_frame(pc, host)
    local wbl = safe_call(function() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end)
    local panel_cls = load_class(PANEL_PKG)
    local text_cls = load_class(TEXT_PKG)
    local btn_cls = load_class(BUTTON_PKG)
    if not (valid(wbl) and panel_cls and text_cls and btn_cls) then
        return nil, "game panel classes unavailable"
    end

    local frame = safe_call(function() return wbl:Create(pc, panel_cls, pc) end)
    if not valid(frame) then return nil, "could not construct WBP_Panel" end

    hide_embers(frame)

    local tree = safe_call(function() return frame.WidgetTree end)
    if not valid(tree) then return nil, "frame widget tree unavailable" end

    local docked_slot = nil
    local docked_to_viewport = false

    if valid(host) then
        local htree = safe_call(function() return host.WidgetTree end)
        local root = valid(htree) and safe_call(function() return htree.RootWidget end) or nil
        local canvas = find_canvas(root)
        if valid(canvas) then
            docked_slot = safe_call(function() return canvas:AddChildToCanvas(frame) end)
        end
    end

    if valid(docked_slot) then
        local x, y = panel_coords()
        pcall(function() frame:SetVisibility(1) end)
        pcall(function() docked_slot:SetAutoSize(false) end)
        pcall(function() docked_slot:SetZOrder(100) end)
        pcall(function() docked_slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
        pcall(function() docked_slot:SetAlignment({ X = 0, Y = 0 }) end)
        pcall(function() docked_slot:SetPosition({ X = x, Y = y }) end)
        pcall(function() docked_slot:SetSize({ X = PANEL_WIDTH, Y = PANEL_HEIGHT }) end)
    else
        docked_to_viewport = true
        local x, y = panel_coords()
        pcall(function() frame:SetVisibility(1) end)
        local added = pcall(function() frame:AddToViewport(8500) end)
        if not added then return nil, "could not attach panel to chest or viewport" end
        pcall(function() frame:SetPositionInViewport({ X = x, Y = y }, false) end)
        pcall(function() frame:SetDesiredSizeInViewport({ X = PANEL_WIDTH, Y = PANEL_HEIGHT }) end)
    end

    return {
        frame = frame,
        slot = docked_slot,
        viewport = docked_to_viewport,
        tree = tree,
        pc = pc,
        wbl = wbl,
        text_cls = text_cls,
        btn_cls = btn_cls,
        queue = {},
        sug_btns = {},
        last_h = PANEL_HEIGHT,
    }
end

local function fit_panel_height(ui)
    if not (ui and valid(ui.frame) and valid(ui.col)) then return end
    local viewport_h = 1080
    pcall(function()
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if valid(layout) and valid(ui.pc) then
            local vp = layout:GetViewportSize(ui.pc)
            local scale = layout:GetViewportScale(ui.pc)
            if vp and type(vp.Y) == "number" and type(scale) == "number" and scale > 0 then
                viewport_h = vp.Y / scale
            end
        end
    end)
    local _, y = panel_coords()
    local max_h = math.max(360, math.floor(viewport_h - y - 24))
    local measured_h = nil
    pcall(function()
        local target = valid(ui.wrap) and ui.wrap or ui.col
        target:ForceLayoutPrepass()
        local ds = target:GetDesiredSize()
        if ds and type(ds.Y) == "number" and ds.Y > 40 and ds.Y < 4000 then
            measured_h = math.ceil(ds.Y) + 70
        end
    end)
    if not measured_h then return end
    local target_h = math.max(320, math.min(max_h, measured_h))
    if math.abs((ui.last_h or 0) - target_h) < 1 then return end
    ui.last_h = target_h
    if ui.viewport then
        pcall(function() ui.frame:SetDesiredSizeInViewport({ X = PANEL_WIDTH, Y = target_h }) end)
    elseif valid(ui.slot) then
        pcall(function() ui.slot:SetSize({ X = PANEL_WIDTH, Y = target_h }) end)
    end
end

local function build_content(ui)
    local colors = themes.active().colors
    GOLD, CREAM, MUTED = colors.gold, colors.cream, colors.muted

    local wrap = construct(ui.tree, "Border")
    local col = construct(ui.tree, "VerticalBox")
    if not valid(wrap) or not valid(col) then return false end
    safe_call(function() wrap:AddChild(col) end)
    if not glass.mount_panel(ui.frame, wrap, valid) then return false end
    ui.wrap = wrap
    ui.col = col
    later(ui, function()
        pcall(function() wrap:SetBrushColor({ R = 0, G = 0, B = 0, A = 0 }) end)
        pcall(function() wrap:SetPadding({ Left = 14, Top = 10, Right = 14, Bottom = 14 }) end)
    end)

    ui.title = add_text(ui, col, "v", "CHEST ORGANISER", 20, GOLD)
    local cap_tb, cap_slot = add_text(ui, col, "v", "", 13, CREAM)
    ui.caption = cap_tb
    later(ui, function()
        if valid(cap_slot) then pcall(function() cap_slot:SetPadding({ Left = 0, Top = 4, Right = 0, Bottom = 2 }) end) end
        if valid(ui.caption) then pcall(function() ui.caption:SetAutoWrapText(true); ui.caption:SetWrapTextAt(CONTENT_WIDTH) end) end
    end)

    add_divider(ui, col, 8, 8)

    local tabs_hdr, tabs_hdr_slot = add_text(ui, col, "v", "NEARBY CHESTS", 11, GOLD)
    ui.tabs_header = tabs_hdr
    ui.tab_btns = {}
    local tab_row = construct(ui.tree, "HorizontalBox")
    local tab_row_slot = valid(tab_row) and safe_call(function() return col:AddChildToVerticalBox(tab_row) end) or nil
    if valid(tab_row) then
        local gap = 8
        local prev_btn = add_button(ui, tab_row, "h", "<", "tab:prev", 40, 34, "inset")
        local tab1 = add_button(ui, tab_row, "h", "CHEST 1", "tab:slot:1", 136, 34, "inset")
        local tab2 = add_button(ui, tab_row, "h", "CHEST 2", "tab:slot:2", 136, 34, "inset")
        local next_btn = add_button(ui, tab_row, "h", ">", "tab:next", 40, 34, "inset")
        ui.tab_prev = prev_btn
        ui.tab_next = next_btn
        ui.tab_btns = { tab1, tab2 }
        later(ui, function()
            if valid(tabs_hdr_slot) then pcall(function() tabs_hdr_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end) end
            if valid(tab_row_slot) then pcall(function() tab_row_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end) end
            if prev_btn and valid(prev_btn.slot) then pcall(function() prev_btn.slot:SetPadding({ Left = 0, Top = 0, Right = gap, Bottom = 0 }) end) end
            if tab1 and valid(tab1.slot) then pcall(function() tab1.slot:SetPadding({ Left = 0, Top = 0, Right = gap, Bottom = 0 }) end) end
            if tab2 and valid(tab2.slot) then pcall(function() tab2.slot:SetPadding({ Left = 0, Top = 0, Right = gap, Bottom = 0 }) end) end
        end)
    end

    add_divider(ui, col, 8, 8)

    local col_gap = 10
    local half_w = math.floor((CONTENT_WIDTH - col_gap) / 2)
    local function two_row(l1, a1, l2, a2, bottom_pad, s1, s2, h)
        local row = construct(ui.tree, "HorizontalBox")
        if not valid(row) then return end
        local rslot = safe_call(function() return col:AddChildToVerticalBox(row) end)
        local row_h = h or 38
        local b1 = add_button(ui, row, "h", l1, a1, half_w, row_h, s1)
        local b2 = add_button(ui, row, "h", l2, a2, half_w, row_h, s2)
        later(ui, function()
            if valid(rslot) then pcall(function() rslot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = bottom_pad or 8 }) end) end
            if b1 and valid(b1.slot) then pcall(function() b1.slot:SetPadding({ Left = 0, Top = 0, Right = col_gap, Bottom = 0 }) end) end
        end)
        return b1, b2
    end

    two_row("DEPOSIT ITEMS", "deposit", "SORT CHEST", "sort", 8, "inset", "inset")
    two_row("RESORT NEARBY", "resort", "ORGANISE BASE", "auto_organise", 8, "inset", "primary")
    local fill_btn, full_btn = two_row("FILL NEW ONLY", "fill_unlabelled", "FULL MENU", "open_full", 8, "inset", "inset")
    ui.replan_btn = fill_btn
    ui.full_btn = full_btn
    local osrs_btn = add_button(ui, col, "v", "OSRS BANK VIEW", "switch_osrs", CONTENT_WIDTH, 34, "primary")
    later(ui, function()
        if osrs_btn and valid(osrs_btn.slot) then pcall(function() osrs_btn.slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end) end
    end)

    add_divider(ui, col, 10, 10)

    local lbl_hdr, lbl_hdr_slot = add_text(ui, col, "v", "SUGGESTED CHEST NAMES", 11, GOLD)
    ui.label_header = lbl_hdr
    local sug_hint, sug_hint_slot = add_text(ui, col, "v", "", 11, MUTED)
    ui.sug_hint = sug_hint
    later(ui, function()
        if valid(lbl_hdr_slot) then pcall(function() lbl_hdr_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end) end
        if valid(sug_hint_slot) then pcall(function() sug_hint_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 8 }) end) end
        if valid(ui.sug_hint) then pcall(function() ui.sug_hint:SetAutoWrapText(true); ui.sug_hint:SetWrapTextAt(CONTENT_WIDTH) end) end
    end)

    local s1_btn, s2_btn = two_row("SUGGESTION 1", "sug:1", "SUGGESTION 2", "sug:2", 2, "inset", "inset", 40)
    ui.sug_btns[1] = s1_btn
    ui.sug_btns[2] = s2_btn

    add_divider(ui, col, 10, 10)

    local status_card = construct(ui.tree, "Border")
    local sc_slot = valid(status_card) and safe_call(function() return col:AddChildToVerticalBox(status_card) end) or nil
    local status_box = construct(ui.tree, "VerticalBox")
    if valid(status_card) and valid(status_box) then
        safe_call(function() status_card:AddChild(status_box) end)
    end
    local st_hdr = valid(status_box) and add_text(ui, status_box, "v", "STATUS", 10, MUTED) or nil
    local st_body, st_body_slot = nil, nil
    if valid(status_box) then
        st_body, st_body_slot = add_text(ui, status_box, "v", "", 12, CREAM)
    end
    ui.status_card = status_card
    ui.status_title = st_hdr
    ui.status = st_body
    later(ui, function()
        if valid(status_card) then
            glass.apply(status_card, "stats", themes.active(), 10)
            pcall(function() status_card:SetPadding({ Left = 12, Top = 9, Right = 12, Bottom = 9 }) end)
        end
        if valid(sc_slot) then pcall(function() sc_slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end) end
        if valid(st_body_slot) then pcall(function() st_body_slot:SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 0 }) end) end
        if valid(ui.status) then
            pcall(function()
                ui.status:SetAutoWrapText(true)
                ui.status:SetWrapTextAt(CONTENT_WIDTH - 24)
            end)
        end
    end)

    return true
end

local function flush_later(ui)
    for _, fn in ipairs(ui.queue) do
        pcall(fn)
    end
    ui.queue = {}
end

local function format_chest_caption(actor_name, current_label, slot_count, max_slots)
    local has_name = type(actor_name) == "string" and actor_name ~= "" and actor_name ~= "Storage Container"
    if current_label and current_label ~= "" then
        if not has_name or actor_name:lower() == current_label:lower() then
            return string.format("Role: [%s]  •  %d/%d slots", current_label, slot_count, max_slots)
        end
        return string.format("%s  •  Role: [%s]  •  %d/%d slots", actor_name, current_label, slot_count, max_slots)
    end
    if has_name then
        return string.format("%s  •  Unlabelled  •  %d/%d slots", actor_name, slot_count, max_slots)
    end
    return string.format("Unlabelled chest  •  %d/%d slots", slot_count, max_slots)
end

local function live_status_info(current_label)
    local busy = type(organiser.is_busy) == "function" and organiser.is_busy()
    local job_msg = type(organiser.job_status) == "function" and organiser.job_status() or nil

    if busy then
        return "REORGANISATION IN PROGRESS",
            (job_msg and job_msg ~= "" and job_msg or "Reorganising storage..."),
            GOLD
    end
    if state.action_status and state.action_status ~= "" then
        return "STATUS", state.action_status, ACCENT
    end
    if job_msg and job_msg ~= "" then
        return "LAST REORGANISATION", job_msg, ACCENT
    end
    if current_label then
        return "STATUS", "Idle  •  Synced with base bank sorting", MUTED
    end
    return "STATUS", "Idle  •  Pick a name above to include in base sorting", MUTED
end

local function truncate_tab_text(text, max_len)
    local s = tostring(text or "CHEST")
    if #s <= max_len then return s end
    return s:sub(1, math.max(1, max_len - 2)) .. ".."
end

local function update_chest_tabs(ui, inv, actor, theme)
    local ce = package.loaded.rlm_chest_explorer
    if not ce then
        local ok_ce, mod_ce = pcall(require, "rlm_chest_explorer")
        if ok_ce and type(mod_ce) == "table" then ce = mod_ce end
    end
    if not ce or type(ce.nearby_chests) ~= "function" then
        state.tab_chests = {}
        state.tab_targets = {}
        return
    end

    local chests = ce.nearby_chests({ range_meters = 80 }) or {}
    state.tab_chests = chests
    local count = #chests
    local active_idx = nil
    for i, c in ipairs(chests) do
        if ce.same_object(c.inv, inv) or ce.same_object(c.actor, actor) then
            active_idx = i
            break
        end
    end

    if ui.tabs_header and valid(ui.tabs_header) then
        local header_txt
        if count <= 1 then
            header_txt = "NEARBY CHESTS (1 IN REACH)"
        else
            local cur = active_idx and chests[active_idx] or chests[1]
            header_txt = string.format("NEARBY CHESTS (%d / %d  •  %.1f m)", active_idx or 1, count, cur and cur.distance or 0)
        end
        pcall(function() ui.tabs_header:SetText(FText(header_txt)) end)
    end

    local multi = count >= 2
    for _, nav_btn in ipairs({ ui.tab_prev, ui.tab_next }) do
        if nav_btn and valid(nav_btn.holder) then
            pcall(function() nav_btn.holder:SetVisibility(multi and 0 or 1) end)
        end
    end

    state.tab_prev_chest = multi and chests[((active_idx or 1) - 2) % count + 1] or nil
    state.tab_next_chest = multi and chests[(active_idx or 1) % count + 1] or nil

    local win_start = 1
    if active_idx and count >= 2 then
        win_start = math.max(1, math.min(count - 1, active_idx))
    end
    state.tab_targets = {}
    for slot_idx = 1, 2 do
        local entry = chests[win_start + slot_idx - 1]
        state.tab_targets[slot_idx] = entry
        local btn = ui.tab_btns and ui.tab_btns[slot_idx]
        if btn and valid(btn.holder) then
            pcall(function() btn.holder:SetVisibility(entry and 0 or 1) end)
            if entry and valid(btn.label) then
                local is_active = active_idx ~= nil and (win_start + slot_idx - 1) == active_idx
                local raw_name = tostring(entry.title or "Chest"):upper()
                local label = is_active and ("* " .. truncate_tab_text(raw_name, 11)) or truncate_tab_text(raw_name, 13)
                local col = is_active and ACCENT or CREAM
                pcall(function()
                    btn.label:SetText(FText(label))
                    btn.label:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                end)
                if valid(btn.bg) then
                    glass.apply(btn.bg, is_active and "selected" or "inset", theme, 8)
                end
            end
        end
    end
end

local function refresh_contents(ui, inv, actor)
    if not ui or not valid(inv) or not valid(actor) then return end

    local current_label = organiser.label_of(actor)
    local actor_name = safe_call(function() return actor:GetCustomName():ToString() end)
    if type(actor_name) ~= "string" then actor_name = "" end

    local slots = organiser.read_slots(inv)
    local max_slots = tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or #slots
    if valid(ui.caption) then
        pcall(function()
            ui.caption:SetText(FText(format_chest_caption(actor_name, current_label, #slots, max_slots)))
        end)
    end

    local suggestions = (type(organiser.top_label_suggestions) == "function")
        and organiser.top_label_suggestions(inv, actor, 2)
        or {}
    state.sug_labels = {}
    if valid(ui.sug_hint) then
        local first = suggestions[1]
        local hint = first and first.reason
            and ("Top match: " .. tostring(first.reason))
            or "Pick a role for automatic sorting"
        pcall(function() ui.sug_hint:SetText(FText(hint)) end)
    end

    local theme = themes.active()
    pcall(update_chest_tabs, ui, inv, actor, theme)
    for i = 1, 2 do
        local entry = ui.sug_btns[i]
        local sug = suggestions[i]
        local lbl = sug and sug.label or nil
        state.sug_labels[i] = lbl
        if entry and valid(entry.holder) then
            pcall(function() entry.holder:SetVisibility(lbl and 0 or 1) end)
            if lbl and valid(entry.label) then
                local is_active = current_label and (current_label:lower() == lbl:lower())
                local txt = is_active and ("* " .. lbl:upper()) or lbl:upper()
                local col = is_active and ACCENT or CREAM
                pcall(function()
                    entry.label:SetText(FText(txt))
                    entry.label:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                end)
                if valid(entry.bg) then
                    glass.apply(entry.bg, is_active and "selected" or "inset", theme, 8)
                end
            end
        end
    end

    local st_hdr, st_body, st_col = live_status_info(current_label)
    if valid(ui.status_title) then
        pcall(function()
            ui.status_title:SetText(FText(st_hdr))
            ui.status_title:SetColorAndOpacity({ SpecifiedColor = st_col, ColorUseRule = 0 })
        end)
    end
    if valid(ui.status) then
        pcall(function() ui.status:SetText(FText(st_body)) end)
    end
end

local function osrs_bank_mod()
    local mod = package.loaded.rlm_osrs_bank_hud
    if type(mod) == "table" then return mod end
    local ok, loaded = pcall(require, "rlm_osrs_bank_hud")
    return (ok and type(loaded) == "table") and loaded or nil
end

local function hide_panel()
    local bank = osrs_bank_mod()
    if bank and type(bank.hide) == "function" then pcall(bank.hide) end
    if state.ui and valid(state.ui.frame) then
        pcall(function() state.ui.frame:SetVisibility(1) end)
    end
    state.session_key = nil
    state.auto_deposited_session = nil
end

local function set_status(msg)
    state.action_status = tostring(msg or "")
    if state.ui and valid(state.ui.status) then
        pcall(function() state.ui.status:SetText(FText(state.action_status)) end)
    end
end

local function run_click_action(action_id, inv, actor, api)
    if action_id == "deposit" then
        local _, msg = organiser.deposit_backpack()
        set_status(msg)
    elseif action_id == "sort" then
        local _, msg = organiser.sort_open_storage()
        set_status(msg)
    elseif action_id == "resort" then
        local _, msg = organiser.resort_nearby_storage()
        set_status(msg)
    elseif action_id == "auto_organise" then
        local _, msg = organiser.auto_organise_base()
        set_status(msg)
    elseif action_id == "fill_unlabelled" then
        local _, msg = organiser.auto_organise_base({ force_replan = false })
        set_status(msg)
    elseif action_id == "replan_organise" then
        local _, msg = organiser.replan_organise_base()
        set_status(msg)
    elseif action_id == "tab:prev" or action_id == "tab:next" or action_id:match("^tab:slot:%d+$") then
        local target = nil
        if action_id == "tab:prev" then
            target = state.tab_prev_chest
        elseif action_id == "tab:next" then
            target = state.tab_next_chest
        else
            local tab_idx = tonumber(action_id:match("^tab:slot:(%d+)$"))
            target = tab_idx and state.tab_targets and state.tab_targets[tab_idx] or nil
        end
        if not target or not valid(target.inv) then
            set_status("No other nearby chest available.")
        else
            local ce = package.loaded.rlm_chest_explorer or require("rlm_chest_explorer")
            local ok_sw, err_sw = ce.switch_open_chest(api, target.inv)
            if ok_sw then
                inv = target.inv
                actor = target.actor or actor
                state.session_key = full_name(actor)
                state.auto_deposited_session = true
                set_status("Viewing " .. (target.title or "chest") .. ".")
            else
                set_status(tostring(err_sw or "Failed to switch chest tab."))
            end
        end
    elseif action_id == "switch_osrs" then
        organiser.set_setting("osrsBankMode", true)
        if state.ui and valid(state.ui.frame) then
            pcall(function() state.ui.frame:SetVisibility(1) end)
        end
        state.last_render_key = nil
        set_status("Switching to OSRS Bank View...")
        return
    elseif action_id == "open_full" then
        hide_panel()
        if valid(api) then
            pcall(function() api:CloseCurrentInventory() end)
        end
        state.pending_open_menu = true
        return
    else
        local idx_str = tostring(action_id):match("^sug:(%d+)$")
        local idx = idx_str and tonumber(idx_str) or nil
        local chosen = idx and state.sug_labels[idx] or nil
        if chosen then
            local ctrl = engine.local_controller()
            organiser.set_label(ctrl, actor, chosen)
            set_status("Labelled container: " .. chosen)
        end
    end
    refresh_contents(state.ui, inv, actor)
end

local function diag_once(key, msg)
    if state.last_diag == key then return end
    state.last_diag = key
    if msg then log.info("Organiser HUD: " .. tostring(msg)) end
end

local function tick()
    if not state.started then return end
    local driver = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
    if type(driver) == "table" then driver.last_tick_at = os.clock() end

    if state.pending_open_menu then
        state.pending_open_menu = false
        local rlm_ui = package.loaded.rlm_ui
        if rlm_ui and type(rlm_ui.open_module) == "function" then
            pcall(rlm_ui.open_module, "organiser")
        end
        return
    end

    local settings = organiser.settings()
    if settings.autoOpenOnStorage == false then
        diag_once("disabled", "auto-open is OFF in settings")
        hide_panel()
        return
    end

    local pc = engine.local_controller()
    if not valid(pc) then
        hide_panel()
        return
    end

    if station_is_visible() then
        diag_once("station", "suppressed while crafting station screen is open")
        hide_panel()
        return
    end

    local inv, actor, api, open_panel = organiser.open_storage()
    if not valid(inv) or not valid(actor) then
        state.last_diag = nil
        hide_panel()
        return
    end

    if settings.osrsBankMode ~= false then
        if state.ui and valid(state.ui.frame) then
            pcall(function() state.ui.frame:SetVisibility(1) end)
        end
        local key = full_name(actor)
        if state.session_key ~= key then
            state.session_key = key
            if settings.autoDepositOnOpen == true and not state.auto_deposited_session then
                state.auto_deposited_session = true
                pcall(organiser.deposit_backpack)
            end
            state.auto_deposited_session = true
        end
        local bank = osrs_bank_mod()
        local ce = package.loaded.rlm_chest_explorer
        if not ce then
            local ok_ce, loaded_ce = pcall(require, "rlm_chest_explorer")
            if ok_ce and type(loaded_ce) == "table" then ce = loaded_ce end
        end
        if bank and ce then
            if state.pending_press then
                local pressed_name = state.pending_press
                state.pending_press = nil
                if state.action_map[pressed_name] and type(bank.handle_press) == "function" then
                    pcall(bank.handle_press, state.action_map[pressed_name])
                end
            end
            if state.pending_release then
                local rel_name = state.pending_release
                state.pending_release = nil
                if type(bank.handle_release) == "function" then
                    local ok_rel, dropped = pcall(bank.handle_release, state.action_map[rel_name], inv, actor, api, organiser, ce)
                    if ok_rel and dropped == true then
                        -- Suppress click-withdraw if releasing finished a drag onto a chest tab
                        if state.pending_click and state.action_map[state.pending_click]
                            and tostring(state.action_map[state.pending_click]):match("^bank:tile:") then
                            state.pending_click = nil
                        end
                    end
                end
            end
            local clicked = state.pending_click
            state.pending_click = nil
            if clicked and state.action_map[clicked] then
                local act = state.action_map[clicked]
                local ok_clk, clk_res = pcall(bank.handle_click, act, inv, actor, api, organiser, ce)
                if ok_clk and clk_res == "open_menu" then
                    hide_panel()
                    state.pending_open_menu = true
                    return
                end
            end
            local ok_ren, ren_res, ren_err = pcall(bank.render, pc, open_panel, inv, actor, api, organiser, ce, state.action_map)
            if ok_ren and ren_res ~= false then return end
            diag_once("osrs_fallback", "OSRS Bank render failed; using Compact Dock: " .. tostring(ok_ren and ren_err or ren_res))
            pcall(bank.hide)
        end
    else
        local bank = osrs_bank_mod()
        if bank and type(bank.hide) == "function" then pcall(bank.hide) end
    end

    local host = refresh_hosts(open_panel)
    local hn = valid(host) and full_name(host) or "__viewport__"

    if state.stage == "broken" and state.host_name == hn then
        return
    end

    if state.host_name ~= hn or not (state.ui and valid(state.ui.frame)) then
        if state.ui and valid(state.ui.frame) then
            pcall(function() state.ui.frame:RemoveFromParent() end)
        end
        state.action_map = {}
        state.ui = nil
        local ui, err = build_frame(pc, host)
        state.host_name = hn
        if not ui then
            state.stage = "broken"
            log.warn("Organiser chest dock disabled: " .. tostring(err))
            return
        end
        state.ui = ui
        state.stage = "frame"
        return
    end

    if state.stage == "frame" then
        local ok = build_content(state.ui)
        if not ok then
            state.stage = "broken"
            log.warn("Organiser chest dock content build failed")
            return
        end
        state.stage = "content"
        return
    end

    if state.stage == "content" then
        flush_later(state.ui)
        fit_panel_height(state.ui)
        state.stage = "ready"
        return
    end

    local key = full_name(actor)
    if state.session_key ~= key then
        state.session_key = key
        state.last_render_key = nil
        state.action_status = nil
        if settings.autoDepositOnOpen == true and not state.auto_deposited_session then
            state.auto_deposited_session = true
            local _, msg = organiser.deposit_backpack()
            if msg and msg ~= "" then state.action_status = msg end
        end
        state.auto_deposited_session = true
        fit_panel_height(state.ui)
        pcall(function() state.ui.frame:SetVisibility(0) end)
        diag_once("shown:" .. key, string.format("shown for %s (%s)",
            organiser.label_of(actor) or "Unlabelled chest",
            state.ui.viewport and "viewport" or ("docked:" .. tostring(hn))))
    end

    local clicked = state.pending_click
    state.pending_click = nil
    if clicked and state.action_map[clicked] then
        state.last_render_key = nil
        pcall(run_click_action, state.action_map[clicked], inv, actor, api)
        return
    end

    local busy_now = type(organiser.is_busy) == "function" and organiser.is_busy() or false
    local live_job_msg = type(organiser.job_status) == "function" and organiser.job_status() or nil
    if busy_now and live_job_msg and live_job_msg ~= "" then
        state.action_status = live_job_msg
    elseif not busy_now and live_job_msg and live_job_msg ~= ""
        and type(state.action_status) == "string" and state.action_status:find("...", 1, true) then
        state.action_status = live_job_msg
    end

    local current_label = organiser.label_of(actor) or ""
    local slots = organiser.read_slots(inv)
    local render_key = key .. "|" .. current_label .. "|" .. tostring(#slots) .. "|"
        .. tostring(busy_now) .. "|" .. tostring(live_job_msg or "") .. "|" .. tostring(state.action_status or "")
    if state.last_render_key ~= render_key then
        state.last_render_key = render_key
        refresh_contents(state.ui, inv, actor)
        fit_panel_height(state.ui)
    end
end

local function driver_table()
    local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
    if type(d) ~= "table" then
        d = { started = false, click_hook_reg = nil, tick = nil, on_click = nil }
        _G.__RLM_ORGANISER_HUD_DRIVER = d
    end
    return d
end

function M.on_storage_opened(api)
    -- When the docked panel is active in-game, tick() handles showing it beside the chest.
    if state.started and state.stage ~= "broken" then
        state.next_host_scan = 0
        return true
    end
    return false
end

function M.on_storage_closed(api)
    hide_panel()
end

function M.tick()
    return tick()
end

function M.state()
    return state
end

function M.start(bootstrap_state)
    local driver = driver_table()
    if type(driver.active_stop) == "function" and driver.active_stop ~= M.stop then
        pcall(driver.active_stop)
    end
    if state.started then return true end
    if type(bootstrap_state) == "table" then
        state.config = bootstrap_state.config
    end
    state.started = true
    state.stage = "idle"
    state.pending_click = nil
    state.pending_open_menu = false

    driver.active_stop = M.stop
    driver.tick = function()
        local ok, err = pcall(tick)
        if not ok then log.warn("Organiser HUD tick failed: " .. tostring(err)) end
    end
    driver.on_click = function(btn_name)
        if state.started and state.action_map[btn_name] then
            log.info("Bank click: " .. tostring(state.action_map[btn_name]))
            state.pending_click = btn_name
        end
    end
    driver.on_press = function(btn_name)
        if state.started and state.action_map[btn_name] then
            local act = state.action_map[btn_name]
            log.info("Bank press: " .. tostring(act))
            state.pending_press = btn_name
            local bank = osrs_bank_mod()
            if bank and type(bank.handle_press) == "function" and tostring(act):match("^bank:tile:") then
                pcall(bank.handle_press, act)
                state.pending_press = nil
            end
        end
    end
    driver.on_release = function(btn_name)
        if state.started and state.action_map[btn_name] then
            log.info("Bank release: " .. tostring(state.action_map[btn_name]))
            state.pending_release = btn_name
            local bank = osrs_bank_mod()
            if bank and type(bank.capture_release) == "function" then
                pcall(bank.capture_release)
            end
        end
    end

    if not driver.started and type(LoopInGameThreadWithDelay) == "function" then
        local ok, err = pcall(LoopInGameThreadWithDelay, 250, function()
            local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
            if d and type(d.tick) == "function" then d.tick() end
        end)
        if ok then
            driver.started = true
        else
            log.warn("Organiser HUD loop unavailable: " .. tostring(err))
        end
    end

    local async_mod = package.loaded.rlm_async
    if type(async_mod) == "table" and type(async_mod.after) == "function" then
        driver.async_gen = (driver.async_gen or 0) + 1
        local my_gen = driver.async_gen
        local function async_pump()
            local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
            if not d or d.async_gen ~= my_gen or type(d.tick) ~= "function" then return end
            -- Only step via rlm_async if the primary LoopInGameThreadWithDelay hasn't ticked recently
            if (os.clock() - (d.last_tick_at or 0)) >= 0.40 then
                d.tick()
            end
            async_mod.after(0.25, async_pump)
        end
        pcall(async_mod.after, 0.25, async_pump)
    end

    if type(RegisterHook) == "function" and driver.click_hook_reg ~= RegisterHook then
        local ok = pcall(RegisterHook, "/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
            local ok_n, name = pcall(function() return self:get():GetFullName() end)
            if ok_n and name then
                local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
                if d and type(d.on_click) == "function" then d.on_click(name) end
            end
        end)
        if ok then driver.click_hook_reg = RegisterHook end
    end
    if type(RegisterHook) == "function" and driver.drag_hooks_bp_reg ~= RegisterHook then
        local function hook_press(path)
            return pcall(RegisterHook, path, function(self)
                local ok_n, name = pcall(function() return self:get():GetFullName() end)
                if ok_n and name then
                    local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
                    if d and type(d.on_press) == "function" then d.on_press(name) end
                end
            end)
        end
        local function hook_release(path)
            return pcall(RegisterHook, path, function(self)
                local ok_n, name = pcall(function() return self:get():GetFullName() end)
                if ok_n and name then
                    local d = rawget(_G, "__RLM_ORGANISER_HUD_DRIVER")
                    if d and type(d.on_release) == "function" then d.on_release(name) end
                end
            end)
        end
        hook_press("/Script/CommonUI.CommonButtonBase:BP_OnPressed")
        hook_release("/Script/CommonUI.CommonButtonBase:BP_OnReleased")
        hook_press("/Script/CommonUI.CommonButtonBase:HandleButtonPressed")
        hook_release("/Script/CommonUI.CommonButtonBase:HandleButtonReleased")
        driver.drag_hooks_bp_reg = RegisterHook
    end

    log.info("Organiser docked chest HUD ready")
    return true
end

function M.stop()
    state.started = false
    local bank = osrs_bank_mod()
    if bank and type(bank.stop) == "function" then pcall(bank.stop) end
    hide_panel()
    if state.ui and valid(state.ui.frame) then
        pcall(function() state.ui.frame:RemoveFromParent() end)
    end
    state.ui = nil
    state.host = nil
    state.host_name = nil
    state.station = nil
    state.stage = "idle"
    state.action_map = {}
    state.pending_click = nil
    state.pending_press = nil
    state.pending_release = nil
    state.pending_open_menu = false

    local driver = driver_table()
    driver.tick = nil
    driver.on_click = nil
    driver.on_press = nil
    driver.on_release = nil
    if driver.active_stop == M.stop then
        driver.active_stop = nil
    end
    return true
end

return M
