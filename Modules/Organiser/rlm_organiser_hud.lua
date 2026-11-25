-- Docked side panel for the Chest Organiser.
-- Polls active chest state on the game thread and docks a native-styled WBP_Panel
-- beside the open storage window, keeping both chest and backpack interactive.

local engine = require("rlm_engine")
local log = require("rlm_log")
local organiser = ...

local M = { VERSION = "0.1.0" }

local PANEL_PKG = "/Game/UI/Panels/WBP_Panel"
local TEXT_PKG = "/Game/UI/Common/WBP_DomTextBlock"
local BUTTON_PKG = "/Game/UI/Common/WBP_DomAllCapsButton"
local HOST_CLASSES = { "WBP_WorldActorInventory_MainPanel_C", "WBP_Inventory_MainPanel_C" }
local STATION_CLASS = "WBP_ProcessingStation_MainPanel_C"

local DEFAULT_X = 1380
local DEFAULT_Y = 57
local PANEL_WIDTH = 430
local PANEL_HEIGHT = 650
local CONTENT_WIDTH = PANEL_WIDTH - 52
local ROLE_PRESETS = {
    { text = "ALL: ORE", label = "All: Ore" },
    { text = "ALL: WOOD", label = "All: Wood" },
    { text = "ALL: EQUIPMENT", label = "All: Equipment" },
    { text = "ALL: FOOD", label = "All: Food" },
    { text = "ALL: POTION", label = "All: Potion" },
    { text = "ALL: COMPONENT", label = "All: Component" },
    { text = "MISC (MIXED)", label = "Misc" },
    { text = "CLEAR LABEL", label = "CLEAR" },
}

local GOLD = { R = 0.91, G = 0.77, B = 0.48, A = 1.0 }
local CREAM = { R = 0.92, G = 0.89, B = 0.82, A = 1.0 }
local MUTED = { R = 0.66, G = 0.64, B = 0.58, A = 1.0 }
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
    session_key = nil,
    status_message = "Ready.",
    action_map = {},
    label_values = {},
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

local function add_button(ui, parent, kind, label, action_id, width, height)
    local holder = construct(ui.tree, "SizeBox")
    if not valid(holder) then return nil end
    local pslot = kind == "v"
        and safe_call(function() return parent:AddChildToVerticalBox(holder) end)
        or safe_call(function() return parent:AddChildToHorizontalBox(holder) end)

    local overlay = construct(ui.tree, "Overlay")
    if not valid(overlay) then return nil end
    safe_call(function() holder:AddChild(overlay) end)

    local btn = safe_call(function() return ui.wbl:Create(ui.pc, ui.btn_cls, ui.pc) end)
    if not valid(btn) then return nil end
    local bslot = safe_call(function() return overlay:AddChildToOverlay(btn) end)

    local txt = safe_call(function() return StaticConstructObject(ui.text_cls, ui.tree) end)
    local tslot = valid(txt) and safe_call(function() return overlay:AddChildToOverlay(txt) end) or nil

    local bname = full_name(btn)
    if bname ~= "" then
        state.action_map[bname] = action_id
    end

    local like = find_button_style()
    later(ui, function()
        if width then pcall(function() holder:SetWidthOverride(width) end) end
        if height then pcall(function() holder:SetHeightOverride(height) end) end
        pcall(function() overlay:SetVisibility(4) end)
        if valid(like) then
            pcall(function() btn:SetStyle(like.Style) end)
        end
        pcall(function() btn:SetIsSelectable(false) end)
        pcall(function() btn:SetShouldSelectUponReceivingFocus(false) end)
        pcall(function() btn:SetIsFocusable(false) end)
        pcall(function() btn:SetLabelText(FText("")) end)
        if valid(bslot) then
            pcall(function() bslot:SetHorizontalAlignment(0); bslot:SetVerticalAlignment(0) end)
        end
        if valid(txt) then
            pcall(function() local f = txt.Font; f.Size = 13; txt:SetFont(f) end)
            pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = CREAM, ColorUseRule = 0 }) end)
            pcall(function() txt:SetText(FText(label or "")) end)
            pcall(function() txt:SetAutoWrapText(false) end)
            pcall(function() txt:SetVisibility(3) end)
            pcall(function() txt:SetShadowOffset({ X = 1, Y = 1 }) end)
            pcall(function() txt:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
        end
        if valid(tslot) then
            pcall(function()
                tslot:SetHorizontalAlignment(2)
                tslot:SetVerticalAlignment(2)
                tslot:SetPadding({ Left = 6, Top = 0, Right = 6, Bottom = 0 })
            end)
        end
    end)

    return { holder = holder, slot = pslot, btn = btn, label = txt }
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
    pcall(function()
        local bg = frame.BackgroundPanel
        if valid(bg) then bg:SetRenderOpacity(0.86) end
    end)

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
        label_btns = {},
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
        ui.col:ForceLayoutPrepass()
        local ds = ui.col:GetDesiredSize()
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
    local col = construct(ui.tree, "VerticalBox")
    if not valid(col) then return false end
    if not pcall(function() ui.frame.PanelContent:AddChild(col) end) then return false end
    ui.col = col

    ui.title = add_text(ui, col, "v", "CHEST ORGANISER", 20, GOLD)
    local _, cap_slot = add_text(ui, col, "v", "", 13, CREAM)
    ui.caption = _
    later(ui, function()
        if valid(cap_slot) then pcall(function() cap_slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 8 }) end) end
        if valid(ui.caption) then pcall(function() ui.caption:SetAutoWrapText(true); ui.caption:SetWrapTextAt(CONTENT_WIDTH) end) end
    end)

    local half_w = math.floor((CONTENT_WIDTH - 8) / 2)
    local function two_row(l1, a1, l2, a2, bottom_pad)
        local row = construct(ui.tree, "HorizontalBox")
        if not valid(row) then return end
        local rslot = safe_call(function() return col:AddChildToVerticalBox(row) end)
        local b1 = add_button(ui, row, "h", l1, a1, half_w, 38)
        local b2 = add_button(ui, row, "h", l2, a2, half_w, 38)
        later(ui, function()
            if valid(rslot) then pcall(function() rslot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = bottom_pad or 6 }) end) end
            if b1 and valid(b1.slot) then pcall(function() b1.slot:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end) end
        end)
        return b1, b2
    end

    two_row("DEPOSIT BACKPACK", "deposit", "SORT THIS CHEST", "sort", 6)
    two_row("RESORT NEARBY", "resort", "ORGANISE BASE", "auto_organise", 6)
    local fill_btn, trash_btn = two_row("FILL NEW ONLY", "fill_unlabelled", "TOGGLE TRASH", "toggle_trash", 6)
    ui.replan_btn = fill_btn
    ui.trash_btn = trash_btn
    local lbl_hdr, lbl_hdr_slot = add_text(ui, col, "v", "SET CHEST BANK ROLE", 12, GOLD)
    ui.label_header = lbl_hdr
    later(ui, function()
        if valid(lbl_hdr_slot) then pcall(function() lbl_hdr_slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 5 }) end) end
    end)

    ui.rec_btn = add_button(ui, col, "v", "RECOMMENDED ROLE", "role_rec", CONTENT_WIDTH, 34)
    if ui.rec_btn then
        later(ui, function()
            if valid(ui.rec_btn.slot) then pcall(function() ui.rec_btn.slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 6 }) end) end
        end)
    end

    for idx = 1, #ROLE_PRESETS, 2 do
        local p1, p2 = ROLE_PRESETS[idx], ROLE_PRESETS[idx + 1]
        local b1, b2 = two_row(p1.text, "role:" .. tostring(idx),
            p2 and p2.text or "", p2 and ("role:" .. tostring(idx + 1)) or "", 5)
        if b1 then
            pcall(function() b1.holder:SetHeightOverride(32) end)
            ui.label_btns[idx] = b1
        end
        if b2 then
            pcall(function() b2.holder:SetHeightOverride(32) end)
            ui.label_btns[idx + 1] = b2
        end
    end

    local status_tb, status_slot = add_text(ui, col, "v", "Ready.", 13, MUTED)
    ui.status = status_tb
    later(ui, function()
        if valid(status_slot) then pcall(function() status_slot:SetPadding({ Left = 0, Top = 8, Right = 0, Bottom = 0 }) end) end
        if valid(ui.status) then pcall(function() ui.status:SetAutoWrapText(true); ui.status:SetWrapTextAt(CONTENT_WIDTH) end) end
    end)

    return true
end

local function flush_later(ui)
    for _, fn in ipairs(ui.queue) do
        pcall(fn)
    end
    ui.queue = {}
end

local function refresh_contents(ui, inv, actor)
    if not ui or not valid(inv) or not valid(actor) then return end

    local current_label = organiser.label_of(actor)
    local role_text = current_label and ("[" .. current_label .. "]") or "Unlabelled"
    local actor_name = safe_call(function() return actor:GetCustomName():ToString() end)
    if type(actor_name) ~= "string" or actor_name == "" then actor_name = "Storage Container" end

    local slots = organiser.read_slots(inv)
    local max_slots = tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or #slots
    if valid(ui.caption) then
        pcall(function()
            ui.caption:SetText(FText(string.format("%s  •  Role: %s  (%d/%d slots)", actor_name, role_text, #slots, max_slots)))
        end)
    end

    if ui.trash_btn and valid(ui.trash_btn.label) then
        local tlabel = (current_label == "Trash") and "UNMARK TRASH" or "MARK AS TRASH"
        pcall(function() ui.trash_btn.label:SetText(FText(tlabel)) end)
    end

    local rec_label, rec_reason = organiser.recommend_chest_label(inv, actor)
    state.rec_label = rec_label
    if ui.rec_btn and valid(ui.rec_btn.label) then
        local rec_text = string.format("SUGGESTED: %s (%s)", rec_label, rec_reason or "Best fit")
        local is_active = current_label and rec_label and current_label:lower() == rec_label:lower()
        pcall(function()
            ui.rec_btn.label:SetText(FText(rec_text))
            ui.rec_btn.label:SetColorAndOpacity({ SpecifiedColor = is_active and ACCENT or GOLD, ColorUseRule = 0 })
        end)
    end

    for i, preset in ipairs(ROLE_PRESETS) do
        local entry = ui.label_btns[i]
        if entry and valid(entry.label) then
            local is_active = current_label and current_label:lower() == preset.label:lower()
            local text = is_active and ("* " .. preset.text) or preset.text
            local color = is_active and ACCENT or (preset.label == "CLEAR" and MUTED or CREAM)
            pcall(function()
                entry.label:SetText(FText(text))
                entry.label:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
            end)
        end
    end

    if valid(ui.status) then
        pcall(function() ui.status:SetText(FText(state.status_message or "Ready.")) end)
    end
end

local function hide_panel()
    if state.ui and valid(state.ui.frame) then
        pcall(function() state.ui.frame:SetVisibility(1) end)
    end
    state.session_key = nil
end

local function set_status(msg)
    state.status_message = tostring(msg or "")
    if state.ui and valid(state.ui.status) then
        pcall(function() state.ui.status:SetText(FText(state.status_message)) end)
    end
end

local function run_click_action(action_id, inv, actor)
    if action_id == "deposit" then
        local ok, msg = organiser.deposit_backpack()
        set_status(msg)
    elseif action_id == "sort" then
        local ok, msg = organiser.sort_open_storage()
        set_status(msg)
    elseif action_id == "resort" then
        local ok, msg = organiser.resort_nearby_storage()
        set_status(msg)
    elseif action_id == "auto_organise" then
        local ok, msg = organiser.auto_organise_base()
        set_status(msg)
    elseif action_id == "fill_unlabelled" then
        local ok, msg = organiser.auto_organise_base({ force_replan = false })
        set_status(msg)
    elseif action_id == "replan_organise" then
        local ok, msg = organiser.replan_organise_base()
        set_status(msg)
    elseif action_id == "toggle_trash" then
        local current = organiser.label_of(actor)
        local ctrl = engine.local_controller()
        if current == "Trash" then
            organiser.set_label(ctrl, actor, nil)
            set_status("Removed Trash label.")
        else
            organiser.set_label(ctrl, actor, "Trash")
            set_status("Marked as Trash incinerator.")
        end
    elseif action_id == "role_rec" then
        local chosen = state.rec_label
        if chosen then
            local ctrl = engine.local_controller()
            organiser.set_label(ctrl, actor, chosen)
            set_status("Labelled container: " .. chosen)
        end
    else
        local idx_str = tostring(action_id):match("^role:(%d+)$")
        local idx = idx_str and tonumber(idx_str) or nil
        local preset = idx and ROLE_PRESETS[idx] or nil
        if preset then
            local ctrl = engine.local_controller()
            if preset.label == "CLEAR" then
                organiser.set_label(ctrl, actor, nil)
                set_status("Container label cleared.")
            else
                organiser.set_label(ctrl, actor, preset.label)
                set_status("Labelled container: " .. preset.label)
            end
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
    local driver = rawget(_G, "__RSDW_PUBLIC_ORGANISER_DOCK")
    if type(driver) == "table" then driver.last_tick_at = os.clock() end

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

    local inv, actor, _, open_panel = organiser.open_storage()
    if not valid(inv) or not valid(actor) then
        state.last_diag = nil
        hide_panel()
        return
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
        state.status_message = "Ready."
        if settings.autoDepositOnOpen == true then
            local ok, msg = organiser.deposit_backpack()
            if msg and msg ~= "" then state.status_message = msg end
        end
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
        pcall(run_click_action, state.action_map[clicked], inv, actor)
        return
    end

    if type(organiser.job_status) == "function" then
        local live_job_msg = organiser.job_status()
        if live_job_msg and live_job_msg ~= "" and (organiser.is_busy and organiser.is_busy() or state.status_message:find("...", 1, true)) then
            state.status_message = live_job_msg
        end
    end

    local current_label = organiser.label_of(actor) or ""
    local slots = organiser.read_slots(inv)
    local render_key = key .. "|" .. current_label .. "|" .. tostring(#slots) .. "|" .. tostring(state.status_message)
    if state.last_render_key ~= render_key then
        state.last_render_key = render_key
        refresh_contents(state.ui, inv, actor)
        fit_panel_height(state.ui)
    end
end

local function driver_table()
    local d = rawget(_G, "__RSDW_PUBLIC_ORGANISER_DOCK")
    if type(d) ~= "table" then
        d = { started = false, click_hook_reg = nil, tick = nil, on_click = nil }
        _G.__RSDW_PUBLIC_ORGANISER_DOCK = d
    end
    return d
end

function M.on_storage_opened()
    -- When the docked panel is active in-game, tick() handles showing it beside the chest.
    if state.started and state.stage ~= "broken" then
        state.next_host_scan = 0
        return true
    end
    return false
end

function M.on_storage_closed()
    hide_panel()
end

function M.tick()
    return tick()
end

function M.state()
    return state
end

function M.start(bootstrap_state)
    if state.started then return true end
    if type(bootstrap_state) == "table" then
        state.config = bootstrap_state.config
    end
    state.started = true
    state.stage = "idle"
    state.pending_click = nil
    state.last_diag = nil

    local driver = driver_table()
    driver.tick = function()
        local ok, err = pcall(tick)
        if not ok then log.warn("Organiser HUD tick failed: " .. tostring(err)) end
    end
    driver.on_click = function(btn_name)
        if state.started and state.action_map[btn_name] then
            state.pending_click = btn_name
        end
    end

    if not driver.started and type(LoopInGameThreadWithDelay) == "function" then
        local ok, err = pcall(LoopInGameThreadWithDelay, 250, function()
            local d = rawget(_G, "__RSDW_PUBLIC_ORGANISER_DOCK")
            if d and type(d.tick) == "function" then d.tick() end
        end)
        if ok then
            driver.started = true
        else
            log.warn("Organiser HUD loop unavailable: " .. tostring(err))
        end
    end

    local async_started = false
    local async_mod = package.loaded.rlm_async
    if type(async_mod) == "table" and type(async_mod.after) == "function" then
        driver.async_gen = (driver.async_gen or 0) + 1
        local my_gen = driver.async_gen
        local function async_pump()
            local d = rawget(_G, "__RSDW_PUBLIC_ORGANISER_DOCK")
            if not d or d.async_gen ~= my_gen or type(d.tick) ~= "function" then return end
            -- Only step via rlm_async if the primary LoopInGameThreadWithDelay hasn't ticked recently
            if (os.clock() - (d.last_tick_at or 0)) >= 0.40 then
                d.tick()
            end
            async_mod.after(0.25, async_pump)
        end
        async_started = pcall(async_mod.after, 0.25, async_pump)
    end

    if type(RegisterHook) == "function" and driver.click_hook_reg ~= RegisterHook then
        local ok = pcall(RegisterHook, "/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
            local ok_n, name = pcall(function() return self:get():GetFullName() end)
            if ok_n and name then
                local d = rawget(_G, "__RSDW_PUBLIC_ORGANISER_DOCK")
                if d and type(d.on_click) == "function" then d.on_click(name) end
            end
        end)
        if ok then driver.click_hook_reg = RegisterHook end
    end

    if not driver.started and not async_started then
        state.started = false
        driver.tick = nil
        driver.on_click = nil
        return false, "game-thread loop is unavailable"
    end
    log.info("Organiser docked chest HUD ready")
    return true
end

function M.stop()
    state.started = false
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

    local driver = driver_table()
    driver.tick = nil
    driver.on_click = nil
    return true
end

return M
