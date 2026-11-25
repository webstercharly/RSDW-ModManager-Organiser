-- Standalone storage organiser service.
-- Labels storage containers, deposits backpack items into matching storage,
-- retains locked items, and manages optional trash container incineration.

local engine = require("rlm_engine")
local log = require("rlm_log")
local store = require("rlm_store")

local M = { VERSION = "0.3.4" }

local NAME_LIMIT = 16
local PAGE_ITEMS, PAGE_RUNES, PAGE_AMMO = 1, 2, 3
local CAST_MONTAGE = "/Game/Art/Animation/PlayerM/Sorcery/AM_PlayerM_Sorcery_Spellcast_BankPortal"
local FIRE_FX = "/Game/Art/VFX/Library/Combat/Magic/Fire/Attack_01/NS_Attack_Fire_Magic_01_Impact"

local base_building_class = nil
local remote_job = nil
local remote_job_status = nil
local remote_job_token = 0

local CATEGORY_NAMES = {
    ["ItemFilter.Material.BasicMaterial"] = "Basic",
    ["ItemFilter.Material.Bone"] = "Bone",
    ["ItemFilter.Material.Cloth"] = "Cloth",
    ["ItemFilter.Material.Component"] = "Component",
    ["ItemFilter.Material.Essence"] = "Essence",
    ["ItemFilter.Material.Gem"] = "Gem",
    ["ItemFilter.Material.Herb"] = "Herb",
    ["ItemFilter.Material.Hide"] = "Hide",
    ["ItemFilter.Material.Leather"] = "Leather",
    ["ItemFilter.Material.Metal"] = "Metal",
    ["ItemFilter.Material.Mineral"] = "Mineral",
    ["ItemFilter.Material.Ore"] = "Ore",
    ["ItemFilter.Material.PristineFish"] = "Prime Fish",
    ["ItemFilter.Material.ProcessedMaterial"] = "Processed",
    ["ItemFilter.Material.RawFish"] = "Raw Fish",
    ["ItemFilter.Material.RawIngredient"] = "Ingredient",
    ["ItemFilter.Material.Rune"] = "Rune",
    ["ItemFilter.Material.Seed"] = "Seed",
    ["ItemFilter.Material.SpecialMaterial"] = "Special",
    ["ItemFilter.Material.Thread"] = "Thread",
    ["ItemFilter.Material.Wood"] = "Wood",
    ["ItemFilter.Type.Consumable.Drink"] = "Drink",
    ["ItemFilter.Type.Consumable.Food"] = "Food",
    ["ItemFilter.Type.Consumable.Potion"] = "Potion",
    ["ItemFilter.Type.Consumable.Tome"] = "Tome",
    ["ItemFilter.Type.Consumable.Plan"] = "Plan",
    ["ItemFilter.Type.Consumable.Pattern"] = "Pattern",
    ["ItemFilter.Type.Consumable.Vestige"] = "Vestige",
    ["ItemFilter.Type.Consumable.Whetstone"] = "Whetstone",
    ["ItemFilter.Type.Consumable"] = "Consumable",
    ["ItemFilter.Type.Equipment.Accessory"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Ammo"] = "Ammo",
    ["ItemFilter.Type.Equipment.Amulet"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Armour"] = "Armour",
    ["ItemFilter.Type.Equipment.Armor"] = "Armour",
    ["ItemFilter.Type.Equipment.Cape"] = "Cape",
    ["ItemFilter.Type.Equipment.Jewellery"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Jewelry"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Ring"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Shield"] = "Shield",
    ["ItemFilter.Type.Equipment.Tool"] = "Tool",
    ["ItemFilter.Type.Equipment.Trinket"] = "Jewellery",
    ["ItemFilter.Type.Equipment.Weapon"] = "Weapon",
    ["ItemFilter.Type.Resource"] = "Resource",
    ["ItemFilter.Type.QuestItem"] = "Quest",
}

local TAG_PREFIX_NAMES = {
    { "ItemFilter.Type.Equipment.Weapon", "Weapon" },
    { "ItemFilter.Type.Equipment.Tool", "Tool" },
    { "ItemFilter.Type.Equipment.Armour", "Armour" },
    { "ItemFilter.Type.Equipment.Armor", "Armour" },
    { "ItemFilter.Type.Equipment.Shield", "Shield" },
    { "ItemFilter.Type.Equipment.Cape", "Cape" },
    { "ItemFilter.Type.Equipment.Ammo", "Ammo" },
    { "ItemFilter.Type.Equipment.Trinket", "Jewellery" },
    { "ItemFilter.Type.Equipment.Jewel", "Jewellery" },
    { "ItemFilter.Type.Equipment.Ring", "Jewellery" },
    { "ItemFilter.Type.Equipment.Amulet", "Jewellery" },
    { "ItemFilter.Type.Equipment.Accessory", "Jewellery" },
    { "ItemFilter.Type.Consumable.Food", "Food" },
    { "ItemFilter.Type.Consumable.Drink", "Drink" },
    { "ItemFilter.Type.Consumable.Potion", "Potion" },
}

local DEFAULT_SETTINGS = {
    rangeMeters = 40,
    autoOpenOnStorage = true,
    autoDepositOnOpen = false,
    costEnabled = false,
    costAmount = 5,
    costRune = "Air",
    enableTrash = false,
    trashFire = true,
    trashCostEnabled = false,
    trashCostAmount = 5,
    trashCostRune = "Fire",
    castAnimation = true,
    includeRunes = false,
    includeAmmo = false,
    anyStorage = true,
}

-- Document access -------------------------------------------------------------

local NON_STORAGE_PATTERNS = {
    "bp_station", "rack", "caperack", "weaponrack", "armourrack",
    "armorstand", "armourstand", "pedestal", "trophy", "display",
    "mannequin", "smelter", "furnace", "anvil", "forge", "kiln",
    "sawmill", "cooking", "grill", "cauldron", "altar", "tanner",
    "loom", "spinning", "workbench", "craftingstation", "grindstone",
    "fermentation", "planter", "trough", "compost", "gravestone",
    "campfire", "bed", "throne", "chair", "sign", "lantern",
    "torch", "brazier", "portal", "lodestone", "totem", "obelisk",
}

local function matches_non_storage_name(name)
    local lower = tostring(name or ""):lower()
    if lower == "" then return false end
    for _, pat in ipairs(NON_STORAGE_PATTERNS) do
        if lower:find(pat, 1, true) then
            return true
        end
    end
    return false
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function organiser_document()
    local org = store.get("organiser")
    if type(org) ~= "table" then return nil end
    if type(org.settings) ~= "table" then
        org.settings = {}
        for k, v in pairs(DEFAULT_SETTINGS) do org.settings[k] = v end
    else
        for k, v in pairs(DEFAULT_SETTINGS) do
            if org.settings[k] == nil then org.settings[k] = v end
        end
    end
    if type(org.labels) ~= "table" then
        org.labels = {}
    else
        for idx = #org.labels, 1, -1 do
            local entry = org.labels[idx]
            if type(entry) ~= "table" or matches_non_storage_name(entry.name) then
                table.remove(org.labels, idx)
            end
        end
    end
    if type(org.locks) ~= "table" then org.locks = {} end
    return org
end

function M.settings()
    local org = organiser_document()
    return org and org.settings or DEFAULT_SETTINGS
end

function M.setting(key)
    local s = M.settings()
    return s[key]
end

function M.set_setting(key, value)
    local org = organiser_document()
    if not org then return false, "settings storage is unavailable" end
    org.settings[key] = value
    return store.save("organiser")
end

function M.locks()
    local org = organiser_document()
    return org and org.locks or {}
end

function M.lock(item_name)
    local locks = M.locks()
    return locks[trim(item_name)]
end

function M.set_lock(item_name, count)
    local org = organiser_document()
    if not org then return false, "settings storage is unavailable" end
    local name = trim(item_name)
    if not name or name == "" then return false, "item name is required" end
    if count == nil or count == 0 or count == "0" then
        org.locks[name] = nil
    elseif count == "all" or count == math.huge then
        org.locks[name] = "all"
    else
        local n = tonumber(count)
        if not n or n < 0 then return false, "count must be a positive number or 'all'" end
        org.locks[name] = math.floor(n)
    end
    return store.save("organiser")
end

function M.clear_all_locks()
    local org = organiser_document()
    if not org then return false, "settings storage is unavailable" end
    org.locks = {}
    return store.save("organiser")
end

local BANK_THEMES = {
    {
        id = "ore",
        label = "All: Ore",
        name = "Ore & Smithing",
        categories = { "Ore", "Metal", "Mineral" },
        patterns = { "smelter", "furnace", "anvil", "forge", "kiln" },
        station_name = "Smelter / Furnace",
        chest_type = "Iron Chest",
    },
    {
        id = "wood",
        label = "All: Wood",
        name = "Wood & Forestry",
        categories = { "Wood" },
        patterns = { "sawmill", "stonecutter", "carpentry", "wood" },
        station_name = "Sawmill / Carpentry Bench",
        chest_type = "Chest",
    },
    {
        id = "equipment",
        label = "All: Equipment",
        name = "Equipment & Combat",
        categories = { "Weapon", "Armour", "Shield", "Jewellery", "Cape", "Tool", "Ammo" },
        patterns = { "armour", "armor", "fletching", "masterwork", "weapon", "tool" },
        station_name = "Armour & Weapons Bench",
        chest_type = "Iron Chest",
    },
    {
        id = "food",
        label = "All: Food",
        name = "Food & Cooking",
        categories = { "Food", "Drink", "Ingredient", "Raw Fish", "Prime Fish" },
        patterns = { "grill", "cooking", "fermentation", "food" },
        station_name = "Cooking Station / Grill",
        chest_type = "Chest",
    },
    {
        id = "magic",
        label = "All: Potion",
        name = "Alchemy & Magic",
        categories = { "Potion", "Consumable", "Herb", "Essence", "Rune", "Tome", "Vestige", "Whetstone" },
        patterns = { "cauldron", "grindstone", "altar", "alchemy", "magic", "sorcery" },
        station_name = "Cauldron & Alchemy Table",
        chest_type = "Chest",
    },
    {
        id = "crafting",
        label = "All: Component",
        name = "Crafting & Leather",
        categories = { "Bone", "Hide", "Leather", "Thread", "Cloth", "Gem", "Currency", "Component", "Processed", "Seed", "Special", "Basic", "Resource" },
        patterns = { "tanner", "loom", "spinning", "craftingstation", "workbench" },
        station_name = "Tanner & Loom",
        chest_type = "Chest",
    },
}

local BROAD_PARENT_CATEGORIES = {
    resource = true,
    consumable = true,
}

local THEME_FALLBACK_CATEGORIES = {}
for _, theme in ipairs(BANK_THEMES) do
    local key = theme.label:match("^[Aa][Ll][Ll]:%s*(.+)$")
    if key then
        local map = {}
        for _, cat in ipairs(theme.categories or {}) do
            local clow = cat:lower()
            if not BROAD_PARENT_CATEGORIES[clow] then
                map[clow] = true
            end
        end
        THEME_FALLBACK_CATEGORIES[key:lower()] = map
    end
end

-- Label Parsing & Rules -------------------------------------------------------

function M.parse_label(label)
    if not label or label == "" then return nil end
    local text = trim(label)
    if text == "" then return nil end
    if text:lower() == "misc" then return { kind = "misc" } end
    if text:lower() == "trash" then return { kind = "trash" } end
    local cat = text:match("^[Aa][Ll][Ll]:%s*(.+)$")
    if cat then return { kind = "cat", value = trim(cat) } end
    return { kind = "item", value = text }
end

local BROAD_CATCHALL_CATEGORIES = {
    resource = true,
    consumable = true,
    basic = true,
    processed = true,
    special = true,
    component = true,
}

local CATEGORY_THEME_ID = {}
for _, theme in ipairs(BANK_THEMES) do
    for _, cat in ipairs(theme.categories or {}) do
        local clow = cat:lower()
        if not BROAD_PARENT_CATEGORIES[clow] and not BROAD_CATCHALL_CATEGORIES[clow] and not CATEGORY_THEME_ID[clow] then
            CATEGORY_THEME_ID[clow] = theme.id
        end
    end
end

function M.rule_score(rule, item_info, target_items)
    if not rule or not item_info then return nil end
    if rule.kind == "item" then
        if rule.value:lower() == tostring(item_info.name or ""):lower() then
            return 3
        end
        return nil
    end
    if rule.kind == "cat" then
        local wanted = rule.value:lower()
        local has_specific = false
        for _, category_name in ipairs(item_info.categories or {}) do
            if not BROAD_CATCHALL_CATEGORIES[category_name:lower()] then
                has_specific = true
                break
            end
        end
        for _, category_name in ipairs(item_info.categories or {}) do
            if category_name:lower() == wanted then
                if BROAD_CATCHALL_CATEGORIES[wanted] and has_specific then
                    return 1.5
                end
                return 2
            end
        end
        local theme_cats = THEME_FALLBACK_CATEGORIES[wanted]
        if theme_cats then
            for _, category_name in ipairs(item_info.categories or {}) do
                if theme_cats[category_name:lower()] then
                    return 1.5
                end
            end
        end
        return nil
    end
    if rule.kind == "misc" then
        for _, other in ipairs(target_items or {}) do
            if other.id == item_info.id or (other.name and item_info.name and other.name:lower() == item_info.name:lower()) then
                return 1
            end
        end
        return nil
    end
    return nil
end

local function item_similarity_sets(info)
    local specific, broad, themes = {}, {}, {}
    for _, cat in ipairs(info and info.categories or {}) do
        local cl = cat:lower()
        if BROAD_CATCHALL_CATEGORIES[cl] or BROAD_PARENT_CATEGORIES[cl] then
            broad[cl] = true
        else
            specific[cl] = true
            local tid = CATEGORY_THEME_ID[cl]
            if tid then themes[tid] = true end
        end
    end
    return specific, broad, themes
end

function M.similarity_score(item_info, container_items, exclude_slot)
    if not item_info or not container_items then return 0 end
    local id_l = tostring(item_info.id or ""):lower()
    local name_l = tostring(item_info.name or ""):lower()
    local spec, broad, themes = item_similarity_sets(item_info)
    local score = 0

    for _, other in ipairs(container_items) do
        if exclude_slot == nil or other.slot ~= exclude_slot then
            local o_id_l = tostring(other.id or ""):lower()
            local o_name_l = tostring(other.name or ""):lower()
            if (id_l ~= "" and o_id_l == id_l) or (name_l ~= "" and name_l ~= "?" and o_name_l == name_l) then
                score = score + 100
            else
                local matched_tier = 0
                for _, oc in ipairs(other.categories or {}) do
                    local ocl = oc:lower()
                    if spec[ocl] then
                        matched_tier = 10
                        break
                    end
                    if broad[ocl] and matched_tier < 0.5 then
                        matched_tier = 0.5
                    end
                    local tid = CATEGORY_THEME_ID[ocl]
                    if tid and themes[tid] and matched_tier < 3 then
                        matched_tier = 3
                    end
                end
                score = score + matched_tier
            end
        end
    end
    return score
end

local function filter_peer_items(items, exclude_slot)
    if exclude_slot == nil or not items then return items end
    local peers = {}
    for _, other in ipairs(items) do
        if other.slot ~= exclude_slot then
            peers[#peers + 1] = other
        end
    end
    return peers
end

local function placement_score(rule, item_info, container_items, exclude_slot)
    if not rule or not item_info or rule.kind == "trash" then return 0 end
    local base_items = (rule.kind == "misc" and exclude_slot ~= nil)
        and filter_peer_items(container_items, exclude_slot)
        or container_items
    local base = M.rule_score(rule, item_info, base_items)
    local sim = M.similarity_score(item_info, container_items, exclude_slot)
    if base and base >= 1 then
        return base + math.min(0.45, sim * 0.001)
    end
    if rule.kind == "misc" then
        return 0.20 + math.min(0.60, sim * 0.005)
    end
    if sim > 0 then
        return math.min(0.19, sim * 0.001)
    end
    return 0
end

-- UObject Inspection Helpers --------------------------------------------------

local function safe_call(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value end
    return fallback
end

local function to_string_value(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local result = safe_call(function() return value:ToString() end)
    if type(result) == "string" then return result end
    return nil
end

local function f_name(object)
    return to_string_value(safe_call(function() return object:GetFName() end))
end

local function is_default_object(object)
    local full = safe_call(function() return object:GetFullName() end, "")
    return full:find("Default__", 1, true) ~= nil
end

local function actor_position(actor)
    return safe_call(function() return actor:K2_GetActorLocation() end)
end

local function distance_squared(a, b)
    if not a or not b then return math.huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function append_unique_cat(list, cat)
    if not cat or cat == "" then return end
    for _, existing in ipairs(list) do
        if existing == cat then return end
    end
    list[#list + 1] = cat
end

local function category_from_tag(tag_name)
    if not tag_name or tag_name == "" then return nil end
    if CATEGORY_NAMES[tag_name] then return CATEGORY_NAMES[tag_name] end
    for _, entry in ipairs(TAG_PREFIX_NAMES) do
        if tag_name:sub(1, #entry[1]) == entry[1] then
            return entry[2]
        end
    end
    return nil
end

local function has_word_token(text, kw)
    return text:find("%f[%a]" .. kw .. "s?%f[%A]") ~= nil
        or text:find("%f[%a]" .. kw .. "es%f[%A]") ~= nil
end

local SKIP_CRAFT_INFERENCE = {
    weapon = true, shield = true, armour = true, jewellery = true,
    cape = true, tool = true, ammo = true, potion = true,
    food = true, drink = true, tome = true, plan = true,
    pattern = true, vestige = true, whetstone = true, quest = true,
    ["raw fish"] = true, ["prime fish"] = true,
}

local CRAFT_INFERENCE_RULES = {
    { "Ore", { "ore" } },
    { "Metal", { "metal", "bar", "ingot", "spike", "rivet", "salvage", "shrapnel" } },
    { "Mineral", { "stone", "gypsum", "sandstone", "clay", "limestone", "granite", "obsidian", "coal", "charcoal", "flint", "salt", "sulphur", "sulfur", "lime", "pellet" } },
    { "Wood", { "wood", "blightwood", "log", "plank", "timber", "bark", "twig" } },
    { "Leather", { "leather" } },
    { "Hide", { "pelt", "hide", "dragonhide", "fur", "fleece", "skin" } },
    { "Thread", { "thread", "yarn", "twine", "wool", "string", "cord", "fibre", "fibres", "fiber", "fibers", "fibrous", "cactus" } },
    { "Cloth", { "cloth", "linen", "silk", "fabric" } },
    { "Bone", { "bone", "bonemeal", "skull", "spine", "horn", "antler", "fang", "claw", "tusk", "talon", "feather", "chitin", "carapace", "scale", "shell", "wing", "tooth" } },
    { "Herb", { "herb", "flower", "leaf", "leaves", "moss", "root", "spore", "flax", "marigold", "harralander", "bitterweed", "vervain", "avantoe", "weed", "weeds" } },
    { "Seed", { "seed" } },
    { "Gem", { "gem", "crystal", "amber", "quartz", "sapphire", "emerald", "ruby", "diamond", "jade", "opal", "topaz", "onyx", "dragonstone" } },
    { "Essence", { "essence", "anima", "ember", "ether", "core", "dust", "ash", "ashes", "ectoplasm", "powder" } },
    { "Processed", { "oil", "sap", "resin", "wax", "slime", "tallow", "paste", "glue", "tar", "dye", "adhesive", "naphtha", "glass", "ichor", "blood", "monoxide" } },
    { "Special", { "visage", "artifact", "curiosities", "head", "heart" } },
    { "Component", { "limbs", "limb", "handle", "mould", "mold" } },
    { "Currency", { "chit", "coin", "token", "currency", "doubloon" } },
    { "Ingredient", { "flour", "sugar", "egg", "butter", "milk", "cream", "honey", "spice", "meat", "steak", "cabbage", "mushroom", "onion", "potato", "pumpkin", "tomato", "watermelon", "wheat" } },
}

local ID_PREFIX_CATEGORIES = {
    { "^item_quest_", "Quest" },
    { "^item_activity_postbox_", "Quest" },
    { "^item_journal_", "Quest" },
    { "^da_consumable_plan_", "Plan" },
    { "^da_consumable_pattern_", "Pattern" },
    { "^da_consumable_vestige_", "Vestige" },
    { "^item_consumable_planpack_", "Plan" },
    { "^item_consumable_tome_", "Tome" },
    { "^item_consumable_potion_", "Potion" },
    { "^item_farming_.*potion", "Potion" },
    { "^item_consumable_tea_", "Drink" },
    { "^item_consumable_water_", "Drink" },
    { "^item_consumable_whetstone", "Whetstone" },
    { "^item_consumable_weaponbarbs", "Whetstone" },
    { "^item_consumable_weaponpoison", "Whetstone" },
    { "^item_consumable_wardstone", "Essence" },
    { "^item_consumable_magicfocus", "Essence" },
    { "^item_logging_axe_", "Tool" },
    { "^item_pickaxe_", "Tool" },
    { "^item_spade_", "Tool" },
    { "^item_wateringcan_", "Tool" },
    { "^item_fishingrod_", "Tool" },
    { "^item_fishingnet_", "Tool" },
    { "^item_secateurs_", "Tool" },
    { "^item_torch", "Tool" },
    { "^item_bucket_", "Tool" },
    { "^item_armour_", "Armour" },
    { "^item_armor_", "Armour" },
    { "^item_shield_", "Shield" },
    { "^item_masterworks_shield_", "Shield" },
    { "^item_cape_", "Cape" },
    { "^item_ammo_", "Ammo" },
    { "^item_sword_", "Weapon" },
    { "^item_scimitar_", "Weapon" },
    { "^item_club_", "Weapon" },
    { "^item_longbow_", "Weapon" },
    { "^item_shortbow_", "Weapon" },
    { "^item_crossbow_", "Weapon" },
    { "^item_staff_", "Weapon" },
    { "^item_masterwork_staff_", "Weapon" },
    { "^item_dagger_", "Weapon" },
    { "^item_greataxe_", "Weapon" },
    { "^item_greatsword_", "Weapon" },
    { "^item_hammer_", "Weapon" },
    { "^item_mace_", "Weapon" },
    { "^item_masterworks_greatsword_", "Weapon" },
    { "^item_dr_main_reforged_greatsword", "Weapon" },
    { "^item_throwable_", "Weapon" },
    { "^item_scarabstaff", "Weapon" },
    { "^item_resources_fish_raw_pristine_", "Prime Fish" },
    { "^item_resources_fish_raw_", "Raw Fish" },
    { "^item_fishbait_", "Basic" },
    { "^item_fishingbait_", "Basic" },
}

local function infer_categories_from_identity(id, name, cats)
    local id_l = tostring(id or ""):lower()
    local n_l = tostring(name or ""):lower()
    local id_words = id_l:gsub("_", " ")

    local matched_prefix = false
    for _, entry in ipairs(ID_PREFIX_CATEGORIES) do
        if id_l:find(entry[1]) then
            append_unique_cat(cats, entry[2])
            matched_prefix = true
            break
        end
    end

    if not matched_prefix then
        if (id_l:find("^item_trinket_") or id_l:find("^item_jewellery_") or id_l:find("_ring_") or id_l:find("_amulet_"))
            and not id_l:find("quest", 1, true) then
            append_unique_cat(cats, "Jewellery")
        elseif id_l:find("_key_", 1, true) or id_l:find("quest", 1, true)
            or id_l:find("_puzzle", 1, true) or id_l:find("sealbreakkey", 1, true) then
            append_unique_cat(cats, "Quest")
        elseif id_l:find("^item_consumable_") then
            if #cats == 0 then
                append_unique_cat(cats, id_l:find("pack", 1, true) and "Special" or "Food")
            end
        elseif #cats == 0 then
            if n_l:find("ring", 1, true) or n_l:find("amulet", 1, true) or n_l:find("necklace", 1, true) then
                append_unique_cat(cats, "Jewellery")
            elseif n_l:find("hatchet", 1, true) or n_l:find("pickaxe", 1, true) then
                append_unique_cat(cats, "Tool")
            end
        end
    end

    for _, existing in ipairs(cats) do
        if SKIP_CRAFT_INFERENCE[existing:lower()] then
            return
        end
    end

    if id_l:find("^item_rune_") or (has_word_token(n_l, "rune") and not has_word_token(n_l, "stone")) then
        append_unique_cat(cats, "Rune")
        return
    end
    if (has_word_token(n_l, "shard") and (has_word_token(n_l, "vault") or has_word_token(n_l, "ascension") or has_word_token(n_l, "upgrade")))
        or id_l:find("upgrade_shard", 1, true) then
        append_unique_cat(cats, "Essence")
        return
    end

    if id_l:find("_currency_", 1, true) then
        append_unique_cat(cats, "Currency")
        return
    end
    for _, rule in ipairs(CRAFT_INFERENCE_RULES) do
        local cat_name, kws = rule[1], rule[2]
        for _, kw in ipairs(kws) do
            if has_word_token(n_l, kw) or has_word_token(id_words, kw) then
                append_unique_cat(cats, cat_name)
                return
            end
        end
    end
    if #cats == 0 and id_l:find("^item_resources_") then
        append_unique_cat(cats, "Resource")
    end
end

local function item_info(item)
    if not engine.is_valid(item) then return nil end
    local data = safe_call(function() return item.ItemData end)
    if not engine.is_valid(data) then
        data = engine.object_call(item, "BP_GetItemData")
    end
    if not engine.is_valid(data) then return nil end

    local name = trim(to_string_value(safe_call(function() return data.Name end))
        or f_name(data) or "?")
    local info = {
        item = item,
        data = data,
        id = f_name(data) or "?",
        name = name,
        count = tonumber(safe_call(function() return item.Count end, 0)) or 0,
        maxStack = tonumber(safe_call(function() return data.MaxStackSize end, 1)) or 1,
        categories = {},
    }
    pcall(function()
        local tags = data.ItemFilterTags.GameplayTags
        if tags and tags.ForEach then
            tags:ForEach(function(_, tag_entry)
                local tag_obj = tag_entry:get()
                local tag_name = to_string_value(safe_call(function() return tag_obj.TagName end))
                local mapped = category_from_tag(tag_name)
                if mapped then
                    append_unique_cat(info.categories, mapped)
                end
            end)
        end
    end)
    infer_categories_from_identity(info.id, info.name, info.categories)
    return info
end

local function read_inventory_slots(inv, first_slot, last_slot)
    local out = {}
    local slots = safe_call(function() return inv.ItemSlots end)
    if slots and slots.ForEach then
        slots:ForEach(function(index, element)
            local slot_index = index - 1
            if (not first_slot or slot_index >= first_slot) and (not last_slot or slot_index <= last_slot) then
                local item = element:get()
                local info = item_info(item)
                if info then
                    info.slot = slot_index
                    out[#out + 1] = info
                end
            end
        end)
    end
    return out
end

M.read_slots = read_inventory_slots

local function backpack_slot_ranges(inv, settings)
    local want_runes = settings and settings.includeRunes == true
    local want_ammo = settings and settings.includeAmmo == true
    local want = { [PAGE_ITEMS] = true, [PAGE_RUNES] = want_runes, [PAGE_AMMO] = want_ammo }

    local ranges = {}
    local start_slot = tonumber(safe_call(function() return inv.NumberOfQuickActionSlots end, 0)) or 0
    local pages = safe_call(function() return inv.InventoryPages end)
    if pages and pages.ForEach then
        pages:ForEach(function(_, page_entry)
            local page = page_entry:get()
            local slot_type = tonumber(safe_call(function() return page.SlotType end, -1))
            local num_slots = tonumber(safe_call(function() return page.NumSlots end, 0)) or 0
            if want[slot_type] and num_slots > 0 then
                ranges[#ranges + 1] = { start_slot, start_slot + num_slots - 1 }
            end
            start_slot = start_slot + num_slots
        end)
    end
    if #ranges == 0 then
        local max_slots = tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or 0
        if max_slots > 10 then ranges[#ranges + 1] = { 10, max_slots - 1 } end
    end
    return ranges
end

-- Storage Identification & Labelling ------------------------------------------

local function is_remote_client()
    if type(engine.local_generation_allowed) == "function" then
        local allowed, mode = engine.local_generation_allowed()
        if allowed == true and (mode == "Standalone" or mode == "ListenServer" or mode == "AuthorityHost") then
            return false
        end
        return true
    end
    return false
end

local function has_world_linked_storage()
    if type(FindFirstOf) ~= "function" then return false end
    local c = safe_call(function() return FindFirstOf("LinkedInventoryComponent") end)
    return engine.is_valid(c) and not is_default_object(c)
end

local function guid_fields_equal(a, b)
    if not a or not b then return false end
    local aa, ab, ac, ad = safe_call(function() return a.A end), safe_call(function() return a.B end),
        safe_call(function() return a.C end), safe_call(function() return a.D end)
    local ba, bb, bc, bd = safe_call(function() return b.A end), safe_call(function() return b.B end),
        safe_call(function() return b.C end), safe_call(function() return b.D end)
    if aa ~= nil and ba ~= nil then
        return aa == ba and ab == bb and ac == bc and ad == bd
    end
    return tostring(a) == tostring(b)
end

local function is_private_locked_from_local(ownership)
    if not engine.is_valid(ownership) then return false end
    if safe_call(function() return ownership.bIsPrivatelyOwned end, false) ~= true then
        return false
    end

    local controller = engine.local_controller()
    if not engine.is_valid(controller) then return true end

    local my_guid = safe_call(function() return controller:GetCharacterGuid() end)
    if my_guid then
        local locked_from_me = safe_call(function() return ownership:IsPrivatelyLockedFromPlayer(my_guid) end)
        if type(locked_from_me) == "boolean" then
            return locked_from_me
        end
        local owned_by_me = safe_call(function() return ownership:IsOwnedBy(my_guid) end)
        if type(owned_by_me) == "boolean" then
            return not owned_by_me
        end
        local owner_guid = safe_call(function() return ownership:GetOwningCharacterGuid() end)
        if owner_guid then
            local eq = safe_call(function() return controller:IsCharacterGuidEqual(owner_guid) end)
            if type(eq) == "boolean" then
                return not eq
            end
            if guid_fields_equal(my_guid, owner_guid) then
                return false
            end
        end
    end

    local my_pid = to_string_value(safe_call(function() return controller:GetPlayerId() end))
    local own_pid = to_string_value(safe_call(function() return ownership.OwningPlayerId end))
    if my_pid and my_pid ~= "" and own_pid and own_pid ~= "" then
        return my_pid ~= own_pid
    end

    return true
end

local function is_built_storage(actor, settings, opts)
    if not engine.is_valid(actor) or is_default_object(actor) then return false end
    if not engine.is_valid(base_building_class) then
        base_building_class = safe_call(function() return StaticFindObject("/Script/Dominion.BaseBuildingActor") end)
    end
    if not engine.is_valid(base_building_class)
        or safe_call(function() return actor:IsA(base_building_class) end) ~= true then
        return false
    end

    local full_lower = safe_call(function() return actor:GetFullName() end, ""):lower()
    if matches_non_storage_name(full_lower) then
        return false
    end

    local linked = safe_call(function() return actor.LinkedInventoryComponent end)
    if engine.is_valid(linked) then
        if safe_call(function() return linked.bIsLocked end, false) == true then
            return false
        end
    elseif is_remote_client() and has_world_linked_storage() then
        -- On a joined server, require LinkedInventoryComponent or renameable CustomName so
        -- non-storage props with an InventoryComponent are never mutated over the network.
        if safe_call(function() return actor:GetCustomName() end) == nil then
            return false
        end
    end

    local allow_private = type(opts) == "table" and opts.allow_private == true
    if is_remote_client() and not allow_private then
        local ownership = safe_call(function() return actor.OwnershipComponent end)
        if is_private_locked_from_local(ownership) then
            return false
        end
    end

    if settings and settings.anyStorage == false then
        return safe_call(function() return actor:GetCustomName() end) ~= nil
    end
    return true
end

local function game_custom_name(actor)
    return to_string_value(safe_call(function() return actor:GetCustomName() end))
end

local function find_stored_label(actor)
    local org = organiser_document()
    if not org or not org.labels then return nil, nil end
    local name = safe_call(function() return actor:GetFullName() end, "")
    local pos = actor_position(actor)
    for index, entry in ipairs(org.labels) do
        if entry.name == name then return entry, index end
        if pos and entry.x and entry.y and entry.z then
            if distance_squared(pos, { X = entry.x, Y = entry.y, Z = entry.z }) < 100 * 100 then
                return entry, index
            end
        end
    end
    return nil, nil
end

function M.label_of(actor)
    if not engine.is_valid(actor) then return nil end
    local custom = game_custom_name(actor)
    local stored = find_stored_label(actor)
    if custom and custom ~= "" then
        local clean_custom = trim(custom)
        if stored and stored.label and stored.native_at_set ~= nil
            and clean_custom == trim(stored.native_at_set) then
            return stored.label
        end
        return clean_custom
    end
    return stored and stored.label or nil
end

local function ufunction_param_count(path)
    local finder = _G and _G.StaticFindObject
    if type(finder) ~= "function" then return nil end
    local ok, fn = pcall(finder, path)
    if not ok or not engine.is_valid(fn) or type(fn.ForEachProperty) ~= "function" then
        return nil
    end
    local count = 0
    local iter_ok = pcall(function()
        fn:ForEachProperty(function()
            count = count + 1
        end)
    end)
    return iter_ok and count or nil
end

local function sender_unique_id(controller)
    local ps = controller and safe_call(function() return controller.PlayerState end)
    if not ps then return {} end
    local uid = safe_call(function() return ps.UniqueID end)
    if uid ~= nil then return uid end
    uid = safe_call(function() return ps.UniqueId end)
    return uid ~= nil and uid or {}
end

local function invoke_native_rename(controller, actor, label_text)
    local ftext = FText(label_text or "")
    local server_params = ufunction_param_count("/Script/Dominion.DominionPlayerController:Server_SetObjectCustomName")
    local setter = sender_unique_id(controller)
    local ok_rename, rename_err
    if server_params == 2 then
        ok_rename, rename_err = pcall(function()
            controller:Server_SetObjectCustomName(actor, ftext)
        end)
    else
        ok_rename, rename_err = pcall(function()
            controller:Server_SetObjectCustomName(actor, ftext, setter)
        end)
        if not ok_rename and server_params == nil then
            ok_rename, rename_err = pcall(function()
                controller:Server_SetObjectCustomName(actor, ftext)
            end)
        end
    end
    if not ok_rename then
        log.warn("Organiser: chest rename RPC failed: " .. tostring(rename_err))
        if not is_remote_client() then
            local iface_params = ufunction_param_count("/Script/Dominion.Renameable:SetCustomName")
            if iface_params == 1 then
                pcall(function() actor:SetCustomName(ftext) end)
            else
                local ok_set = pcall(function() actor:SetCustomName(ftext, setter) end)
                if not ok_set and iface_params == nil then
                    pcall(function() actor:SetCustomName(ftext) end)
                end
            end
        end
    end
end

function M.set_label(controller, actor, label, opts)
    if not engine.is_valid(actor) then return false, "invalid storage actor" end
    local org = organiser_document()
    if not org then return false, "settings storage is unavailable" end

    local text = label and trim(label):sub(1, NAME_LIMIT) or nil
    if text == "" then text = nil end

    local native_before = game_custom_name(actor)
    local custom_name_supported = native_before ~= nil
    if custom_name_supported and engine.is_valid(controller) then
        invoke_native_rename(controller, actor, text)
    end

    local existing, index = find_stored_label(actor)
    if text == nil then
        if index then table.remove(org.labels, index) end
    else
        local pos = actor_position(actor) or { X = 0, Y = 0, Z = 0 }
        if not existing then
            existing = {}
            org.labels[#org.labels + 1] = existing
        end
        existing.name = safe_call(function() return actor:GetFullName() end, "?")
        existing.x = math.floor(pos.X or 0)
        existing.y = math.floor(pos.Y or 0)
        existing.z = math.floor(pos.Z or 0)
        existing.label = text
        existing.native_at_set = native_before and trim(native_before) or ""
    end
    if not (opts and opts.skip_save) then
        store.save("organiser")
    end
    return true
end

-- Open Storage & Nearby Containers Discovery ----------------------------------

local function storage_from_api(api)
    if not engine.is_valid(api) then return nil end
    local inv = safe_call(function() return api:GetInventoryComponent() end)
    if not engine.is_valid(inv) then
        inv = safe_call(function() return api.InventoryComponent end)
    end
    if not engine.is_valid(inv) then return nil end
    local controller = engine.local_controller()
    local player_inv = engine.is_valid(controller) and safe_call(function() return controller.InventoryComponent end) or nil
    if player_inv and inv == player_inv then return nil end
    local actor = safe_call(function() return inv:GetOwner() end)
    if not engine.is_valid(actor) or is_default_object(actor) then return nil end
    if not engine.is_valid(base_building_class) then
        base_building_class = safe_call(function() return StaticFindObject("/Script/Dominion.BaseBuildingActor") end)
    end
    if engine.is_valid(base_building_class)
        and safe_call(function() return actor:IsA(base_building_class) end) ~= true then
        return nil
    end
    if matches_non_storage_name(safe_call(function() return actor:GetFullName() end, "")) then
        return nil
    end
    return inv, actor
end

function M.open_storage()
    if type(FindAllOf) ~= "function" then return nil end

    -- Prefer live activated WorldActorInventoryMainPanel when available so pooled/closed UIAPIs do not trigger false positives
    local live_panel_count = 0
    local fallback_hit = nil
    local panels = safe_call(function() return FindAllOf("WorldActorInventoryMainPanel") end, {})
    for _, panel in pairs(panels) do
        if engine.is_valid(panel) and not is_default_object(panel) then
            live_panel_count = live_panel_count + 1
            local active = safe_call(function() return panel:IsActivated() end)
            if active == nil then
                active = safe_call(function() return panel.bIsActive end)
            end
            local visible = safe_call(function() return panel:IsVisible() end)
            if active == true then
                local api = safe_call(function() return panel.WorldInventoryManagerAPI end)
                local inv, actor = storage_from_api(api)
                if inv then return inv, actor, api, panel end
            elseif visible == true and not fallback_hit then
                local api = safe_call(function() return panel.WorldInventoryManagerAPI end)
                local inv, actor = storage_from_api(api)
                if inv then fallback_hit = { inv, actor, api, panel } end
            end
        end
    end

    if fallback_hit then
        return fallback_hit[1], fallback_hit[2], fallback_hit[3], fallback_hit[4]
    end

    if live_panel_count > 0 then
        return nil
    end

    local apis = safe_call(function() return FindAllOf("WorldActorInventoryUIAPI") end, {})
    for _, api in ipairs(apis) do
        if engine.is_valid(api) and not is_default_object(api) then
            local initialized = safe_call(function() return api:IsInitialized() end)
            if initialized ~= false then
                local inv, actor = storage_from_api(api)
                if inv then return inv, actor, api, nil end
            end
        end
    end
    return nil
end

-- Bank Themes & Workstation Mapping -------------------------------------------

function M.bank_themes()
    return BANK_THEMES
end

function M.all_storage_in_reach(origin, settings)
    if not origin or type(FindAllOf) ~= "function" then return {} end
    local max_range = (settings and settings.rangeMeters or 40) * 100
    local reach_squared = max_range * max_range

    local results = {}
    local invs = safe_call(function() return FindAllOf("InventoryComponent") end, {})
    for _, inv in ipairs(invs) do
        if engine.is_valid(inv) and not is_default_object(inv) then
            local actor = safe_call(function() return inv:GetOwner() end)
            if is_built_storage(actor, settings) then
                local pos = actor_position(actor)
                local d2 = distance_squared(origin, pos)
                if d2 <= reach_squared then
                    local native_name = game_custom_name(actor)
                    local label = M.label_of(actor)
                    local rule = M.parse_label(label)
                    local slots = read_inventory_slots(inv)
                    local max_slots = tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or #slots
                    results[#results + 1] = {
                        actor = actor,
                        inv = inv,
                        native_name = native_name,
                        label = label,
                        rule = rule,
                        distance = math.sqrt(d2) / 100,
                        d2 = d2,
                        pos = pos,
                        slots = slots,
                        maxSlots = max_slots,
                    }
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.d2 < b.d2 end)
    return results
end

function M.labelled_storage_in_reach(origin, settings)
    local all = M.all_storage_in_reach(origin, settings)
    local labelled = {}
    for _, st in ipairs(all) do
        if st.rule then
            labelled[#labelled + 1] = st
        end
    end
    return labelled
end

function M.detect_workstations(origin, reach_meters)
    if not origin or type(FindAllOf) ~= "function" then return {} end
    local max_range = (reach_meters or 40) * 100
    local reach_sq = max_range * max_range

    local stations = {}
    local seen_actors = {}

    local function check_actor(actor)
        if not engine.is_valid(actor) or is_default_object(actor) then return end
        local addr = safe_call(function() return actor:GetAddress() end) or actor
        if seen_actors[addr] then return end

        local pos = actor_position(actor)
        if not pos then return end
        local d2 = distance_squared(origin, pos)
        if d2 > reach_sq then return end

        local full_name = safe_call(function() return actor:GetFullName() end, "")
        local name_lower = full_name:lower()

        if name_lower:find("chest", 1, true) or name_lower:find("barrel", 1, true) or name_lower:find("rack", 1, true) then
            return
        end

        for _, theme in ipairs(BANK_THEMES) do
            for _, pat in ipairs(theme.patterns) do
                if name_lower:find(pat, 1, true) then
                    seen_actors[addr] = true
                    stations[#stations + 1] = {
                        actor = actor,
                        name = theme.station_name,
                        theme = theme,
                        pos = pos,
                        distance = math.sqrt(d2) / 100,
                        d2 = d2,
                    }
                    return
                end
            end
        end
    end

    local buildings = safe_call(function() return FindAllOf("BaseBuildingActor") end, {})
    for _, b in ipairs(buildings) do check_actor(b) end

    local procs = safe_call(function() return FindAllOf("ProcessingStationComponent") end, {})
    for _, ps in ipairs(procs) do
        if engine.is_valid(ps) and not is_default_object(ps) then
            local owner = safe_call(function() return ps:GetOwner() end)
            check_actor(owner)
        end
    end

    table.sort(stations, function(a, b) return a.d2 < b.d2 end)
    return stations
end

-- Label Suggestions for Open Storage ------------------------------------------

local function score_themes_for_slots(slots)
    local counts = {}
    for _, info in ipairs(slots or {}) do
        local matched = {}
        for _, theme in ipairs(BANK_THEMES) do
            local fb = THEME_FALLBACK_CATEGORIES[theme.label:match("^[Aa][Ll][Ll]:%s*(.+)$"):lower()]
            for _, cat in ipairs(info.categories or {}) do
                local cl = cat:lower()
                if fb and fb[cl] and not matched[theme.id] then
                    matched[theme.id] = true
                    counts[theme.id] = (counts[theme.id] or 0) + 1
                end
            end
        end
    end
    return counts
end

function M.recommend_chest_label(inv, actor)
    if not engine.is_valid(inv) then return "Misc", "Default catch-all" end
    local slots = read_inventory_slots(inv)
    local actor_pos = actor_position(actor)
    if actor_pos then
        local stations = M.detect_workstations(actor_pos, 10)
        if stations[1] and stations[1].theme then
            return stations[1].theme.label, "Near " .. tostring(stations[1].name)
        end
    end

    local theme_counts = score_themes_for_slots(slots)
    local best_theme, best_count = nil, 0
    for _, theme in ipairs(BANK_THEMES) do
        local c = theme_counts[theme.id] or 0
        if c > best_count then
            best_count = c
            best_theme = theme
        end
    end
    if best_theme then
        return best_theme.label, string.format("%d matching stack(s)", best_count)
    end
    return "Misc", "General / mixed storage"
end

function M.label_suggestions(inv, actor)
    if not engine.is_valid(inv) then return {} end
    local slots = read_inventory_slots(inv)
    local seen_names, cat_counts = {}, {}
    local item_list = {}
    local distinct_count = 0

    for _, info in ipairs(slots) do
        if not seen_names[info.name] then
            seen_names[info.name] = true
            distinct_count = distinct_count + 1
            item_list[#item_list + 1] = info.name
        end
        for _, cat in ipairs(info.categories or {}) do
            if not BROAD_PARENT_CATEGORIES[cat:lower()] then
                cat_counts[cat] = (cat_counts[cat] or 0) + 1
            end
        end
    end

    local suggestions, added = {}, {}
    local function push(lbl)
        if lbl and lbl ~= "" and not added[lbl] then
            added[lbl] = true
            suggestions[#suggestions + 1] = lbl
        end
    end

    -- 1. Recommended bank role (workstation proximity or dominant contents)
    local rec_label = M.recommend_chest_label(inv, actor)
    push(rec_label)

    -- 2. Specific categories sorted by stack frequency
    local cat_entries = {}
    for cat, count in pairs(cat_counts) do
        cat_entries[#cat_entries + 1] = { label = "All: " .. cat, count = count }
    end
    table.sort(cat_entries, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.label < b.label
    end)
    for _, entry in ipairs(cat_entries) do
        push(entry.label)
    end

    -- 3. Remaining standard Bank Sorter roles so every role is always available
    for _, theme in ipairs(BANK_THEMES) do
        push(theme.label)
    end
    push("Misc")

    -- 4. Single-item names last (never crowding out category & bank roles)
    table.sort(item_list)
    for _, item in ipairs(item_list) do
        push(item)
    end
    push("Trash")
    return suggestions
end

-- Rune Costs & Visual Feedback ------------------------------------------------

local function rune_stacks(inv, rune_name)
    local target_id = "ITEM_Rune_" .. tostring(rune_name or "Air")
    local stacks, total = {}, 0
    for _, info in ipairs(read_inventory_slots(inv)) do
        if info.id == target_id then
            stacks[#stacks + 1] = info
            total = total + info.count
        end
    end
    return stacks, total
end

local function charge_runes(inv, controller, rune_name, amount)
    local needed = math.floor(tonumber(amount) or 0)
    if needed <= 0 then return true end
    local stacks = rune_stacks(inv, rune_name)
    for _, stack in ipairs(stacks) do
        if needed <= 0 then break end
        local to_take = math.min(needed, stack.count)
        local ok = pcall(function()
            controller:RemoveItemsStartingFromSlotIndex(inv, stack.slot, to_take)
        end)
        if ok then needed = needed - to_take end
    end
    return needed <= 0
end

local function play_deposit_animation(pawn, settings)
    if not (settings and settings.castAnimation) or not engine.is_valid(pawn) then return end
    pcall(function() LoadAsset(CAST_MONTAGE) end)
    local montage = safe_call(function() return StaticFindObject(CAST_MONTAGE .. ".AM_PlayerM_Sorcery_Spellcast_BankPortal") end)
    if engine.is_valid(montage) then
        pcall(function() pawn:PlayAnimMontage(montage, 1.0, FName("None")) end)
    end
end

local function spawn_burn_vfx(actor, settings)
    if not (settings and settings.trashFire) or not engine.is_valid(actor) then return end
    pcall(function() LoadAsset(FIRE_FX) end)
    local fx = safe_call(function() return StaticFindObject(FIRE_FX .. ".NS_Attack_Fire_Magic_01_Impact") end)
    local lib = safe_call(function() return StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary") end)
    local pos = actor_position(actor)
    if engine.is_valid(fx) and engine.is_valid(lib) and pos then
        pcall(function()
            lib:SpawnSystemAtLocation(actor, fx, { X = pos.X, Y = pos.Y, Z = pos.Z + 40 },
                { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, true, true, 0, true)
        end)
    end
end

-- Remote-Safe Paced Execution Helpers -----------------------------------------

local function async_mod()
    local mod = package.loaded.rlm_async
    if type(mod) == "table" and type(mod.after) == "function" then return mod end
    if type(require) == "function" then
        local ok, loaded = pcall(require, "rlm_async")
        if ok and type(loaded) == "table" and type(loaded.after) == "function" then
            return loaded
        end
    end
    return nil
end

local function report_remote_progress(message)
    remote_job_status = message
    local ui = package.loaded.rlm_ui
    if ui and type(ui.report_status) == "function" then
        pcall(ui.report_status, "info", message)
    end
    log.info("Organiser: " .. tostring(message))
end

function M.is_busy()
    return remote_job ~= nil
end

function M.job_status()
    return remote_job_status
end

function M.cancel_job()
    remote_job_token = remote_job_token + 1
    remote_job = nil
    remote_job_status = nil
end

local function slot_snapshot_at(inv, slot_idx)
    if not engine.is_valid(inv) then return nil, 0 end
    local item = safe_call(function() return inv:GetItemFromSlot(slot_idx) end)
    if engine.is_valid(item) then
        local data = safe_call(function() return item.ItemData end)
        local id = engine.is_valid(data) and f_name(data) or nil
        local count = tonumber(safe_call(function() return item.Count end))
        if id and count then return id, count end
    end
    local n = safe_call(function() return inv:GetNumItemsInSlot(slot_idx) end)
    if n == 0 then return nil, 0 end
    for _, info in ipairs(read_inventory_slots(inv, slot_idx, slot_idx)) do
        if info.slot == slot_idx then return info.id, info.count or 0 end
    end
    if type(n) == "number" and n > 0 then return "?", n end
    return nil, 0
end

local function execute_remote_transfer(token, ctrl, src_inv, src_slot, dst_inv, dst_slot, amount, is_split, on_done)
    local async = async_mod()
    if not async or token ~= remote_job_token then
        on_done(false, "cancelled")
        return
    end
    if not engine.is_valid(ctrl) or not engine.is_valid(src_inv) or not engine.is_valid(dst_inv) then
        on_done(false, "invalid inventory or controller")
        return
    end

    local src_id_before, before = slot_snapshot_at(src_inv, src_slot)
    if before <= 0 or not src_id_before or src_id_before == "?" then
        on_done(false, "source slot unavailable")
        return
    end
    local dst_id_before, dst_count_before = slot_snapshot_at(dst_inv, dst_slot)

    if dst_count_before > 0 and (dst_id_before == "?" or not dst_id_before
        or (src_inv ~= dst_inv and dst_id_before ~= src_id_before)) then
        on_done(false, "target slot mismatch")
        return
    end

    local split = is_split and amount and amount > 0 and amount < before
    local moved_count = split and amount or before
    local ok, rpc_ret = pcall(function()
        if split then
            return ctrl:SplitAndPutStack(src_inv, src_slot, moved_count, dst_inv, dst_slot)
        else
            return ctrl:MoveItemBetweenInventories(src_inv, src_slot, dst_inv, dst_slot)
        end
    end)
    if not ok or rpc_ret == false then
        on_done(false, "RPC rejected")
        return
    end

    local same_id_non_split = (not split) and dst_count_before > 0 and dst_id_before == src_id_before
    local swaps_slots = dst_count_before > 0 and dst_id_before ~= src_id_before
    local expected_src_count = swaps_slots and dst_count_before or before - moved_count
    local expected_src_id = swaps_slots and dst_id_before
        or (expected_src_count > 0 and src_id_before or nil)
    local expected_dst_count = moved_count + (swaps_slots and 0 or dst_count_before)
    local started = engine.real_time_seconds()
    local deadline = started + 2.0
    local delay = 0.18
    local checks = 0

    local function poll_remote_transfer()
        if token ~= remote_job_token or not remote_job then return end
        local now = engine.real_time_seconds()
        if now < started or not engine.is_valid(ctrl)
            or not engine.is_valid(src_inv) or not engine.is_valid(dst_inv) then
            on_done(false, "cancelled")
            return
        end
        checks = checks + 1
        local src_id_after, after = slot_snapshot_at(src_inv, src_slot)
        local dst_id_after, dst_count_after = slot_snapshot_at(dst_inv, dst_slot)
        local confirmed = false
        if same_id_non_split then
            local changed = (after ~= before or dst_count_after ~= dst_count_before)
            local conserved = (after + dst_count_after) == (before + dst_count_before)
            confirmed = changed and conserved
                and (after == 0 or src_id_after == src_id_before)
                and dst_id_after == src_id_before
        elseif after == expected_src_count and (after == 0 or src_id_after == expected_src_id) then
            confirmed = (dst_id_after == src_id_before and dst_count_after == expected_dst_count)
        end
        if confirmed then
            -- Plan the next move on a fresh scheduler pass.
            local queued, queue_error = async.after(0, function()
                if token == remote_job_token and remote_job then on_done(true) end
            end)
            if not queued then on_done(false, tostring(queue_error)) end
            return
        end
        if now >= deadline or checks >= 4 then
            log.warn(("Organiser transfer unconfirmed after %.0f ms (%d checks)")
                :format((now - started) * 1000, checks))
            on_done(false, "transfer could not be verified")
            return
        end
        delay = math.min(delay * 1.5, deadline - now)
        local scheduled, sched_err = async.after(delay, poll_remote_transfer)
        if not scheduled then
            on_done(false, tostring(sched_err))
        end
    end

    local scheduled, sched_err = async.after(delay, poll_remote_transfer)
    if not scheduled then
        on_done(false, tostring(sched_err))
    end
end

local function find_next_sort_step(inv)
    local slots = read_inventory_slots(inv)
    if #slots <= 1 then return nil end

    local by_id = {}
    for _, info in ipairs(slots) do
        if info.id and info.id ~= "?" then
            local list = by_id[info.id]
            if not list then list = {}; by_id[info.id] = list end
            list[#list + 1] = info
        end
    end

    for _, list in pairs(by_id) do
        if #list > 1 then
            table.sort(list, function(a, b) return a.slot < b.slot end)
            for i = 1, #list do
                local dest = list[i]
                local max_stack = dest.maxStack or 1
                if dest.count > 0 and dest.count < max_stack then
                    for j = #list, i + 1, -1 do
                        local src = list[j]
                        if src.count > 0 then
                            local to_move = math.min(max_stack - dest.count, src.count)
                            if to_move > 0 then
                                return {
                                    phase = "merge",
                                    src_slot = src.slot,
                                    dst_slot = dest.slot,
                                    amount = to_move,
                                    is_split = to_move < src.count,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local target_list = {}
    for _, info in ipairs(slots) do target_list[#target_list + 1] = info end
    table.sort(target_list, M.compare_items)
    for i = 1, #target_list do
        local desired_slot = i - 1
        local wanted = target_list[i]
        if wanted.slot ~= desired_slot then
            return {
                phase = "swap",
                src_slot = wanted.slot,
                dst_slot = desired_slot,
                amount = wanted.count,
                is_split = false,
            }
        end
    end
    return nil
end

local function run_remote_sort(token, inv, ctrl, label, on_done)
    local steps_done, merges_done = 0, 0
    local max_steps = 60

    local function next_step()
        if token ~= remote_job_token or not remote_job or not engine.is_valid(inv) then
            on_done(steps_done, merges_done)
            return
        end
        if steps_done >= max_steps then
            on_done(steps_done, merges_done)
            return
        end
        local step = find_next_sort_step(inv)
        if not step then
            on_done(steps_done, merges_done)
            return
        end
        execute_remote_transfer(token, ctrl, inv, step.src_slot, inv, step.dst_slot, step.amount, step.is_split,
            function(ok)
                if not ok then
                    on_done(steps_done, merges_done)
                    return
                end
                steps_done = steps_done + 1
                if step.phase == "merge" then merges_done = merges_done + 1 end
                report_remote_progress(string.format("Sorting %s... (%d move(s))", label or "chest", steps_done))
                next_step()
            end)
    end
    next_step()
end

local function inventory_snapshot(snapshots, inv)
    local slots = snapshots[inv]
    if not slots then
        slots = read_inventory_slots(inv)
        snapshots[inv] = slots
    end
    return slots
end

local function find_dest_slot_in_inv(inv, item, slots)
    local max_slot_count = tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or 0
    local occupied_by_slot = {}
    for _, occ in ipairs(slots) do
        occupied_by_slot[occ.slot] = occ
    end
    for slot_idx = 0, max_slot_count - 1 do
        local occ = occupied_by_slot[slot_idx]
        if occ and occ.id == item.id and ((occ.maxStack or 1) - occ.count) >= item.count then
            return slot_idx
        end
    end
    for slot_idx = 0, max_slot_count - 1 do
        if not occupied_by_slot[slot_idx] then
            return slot_idx
        end
    end
    return nil
end

local function find_next_resort_step(storage_list, destinations)
    -- Discard these reads after each move so the next pass sees replication.
    local snapshots = {}
    for _, src_st in ipairs(storage_list) do
        if engine.is_valid(src_st.inv) and src_st.rule and src_st.rule.kind ~= "trash" then
            local src_items = inventory_snapshot(snapshots, src_st.inv)
            table.sort(src_items, function(a, b) return a.slot > b.slot end)

            for _, item in ipairs(src_items) do
                local score_here = placement_score(src_st.rule, item, src_items, item.slot)
                local best_dest, best_slot = nil, nil
                local best_score = score_here

                for _, dest_st in ipairs(destinations) do
                    if dest_st.inv ~= src_st.inv and engine.is_valid(dest_st.inv) then
                        local dest_items = inventory_snapshot(snapshots, dest_st.inv)
                        local score_there = placement_score(dest_st.rule, item, dest_items, nil)
                        if score_there > best_score or (score_there == best_score and best_dest and dest_st.d2 < best_dest.d2 and score_there > score_here) then
                            local candidate_slot = find_dest_slot_in_inv(dest_st.inv, item, dest_items)
                            if candidate_slot ~= nil then
                                best_score = score_there
                                best_dest = dest_st
                                best_slot = candidate_slot
                            end
                        end
                    end
                end

                if best_dest and best_slot ~= nil and best_score > score_here then
                    return {
                        src_st = src_st,
                        dst_st = best_dest,
                        src_slot = item.slot,
                        dst_slot = best_slot,
                        amount = item.count,
                    }
                end
            end
        end
    end
    return nil
end

local function run_remote_resort(token, storage_list, destinations, ctrl, on_done)
    local relocated = 0
    local modified = {}
    local max_relocations = 100

    local function next_step()
        if token ~= remote_job_token or not remote_job then
            on_done(relocated, modified)
            return
        end
        if relocated >= max_relocations then
            on_done(relocated, modified)
            return
        end
        local step = find_next_resort_step(storage_list, destinations)
        if not step then
            on_done(relocated, modified)
            return
        end
        execute_remote_transfer(token, ctrl, step.src_st.inv, step.src_slot, step.dst_st.inv, step.dst_slot, step.amount, false,
            function(ok)
                if not ok then
                    on_done(relocated, modified)
                    return
                end
                relocated = relocated + 1
                modified[step.src_st] = true
                modified[step.dst_st] = true
                report_remote_progress(string.format("Relocating across chests... (%d moved)", relocated))
                next_step()
            end)
    end
    next_step()
end

-- Deposit Operation -----------------------------------------------------------

local function find_next_deposit_step(inv, storage_list, locks_table, s, cost_active, cost_amount, rune_name)
    local ranges = backpack_slot_ranges(inv, s)
    local carried_items = {}
    for _, r in ipairs(ranges) do
        for _, info in ipairs(read_inventory_slots(inv, r[1], r[2])) do
            carried_items[#carried_items + 1] = info
        end
    end
    if #carried_items == 0 then return nil end

    local carried_totals = {}
    for _, info in ipairs(carried_items) do
        carried_totals[info.name] = (carried_totals[info.name] or 0) + info.count
    end

    local to_send = {}
    local rune_item_name = "ITEM_Rune_" .. tostring(rune_name)
    for name, total in pairs(carried_totals) do
        local lock_rule = locks_table[name]
        local keep_count = 0
        if lock_rule == "all" or lock_rule == math.huge then
            keep_count = total
        elseif type(lock_rule) == "number" then
            keep_count = lock_rule
        end
        if cost_active and (name == rune_name or name == rune_item_name) then
            keep_count = keep_count + cost_amount
        end
        to_send[name] = math.max(0, total - keep_count)
    end

    table.sort(carried_items, function(a, b) return a.slot > b.slot end)

    local snapshots = {}
    for _, info in ipairs(carried_items) do
        local want = math.min(info.count, to_send[info.name] or 0)
        if want > 0 then
            local candidates = {}
            for i, st in ipairs(storage_list) do
                if engine.is_valid(st.inv) then
                    local slots = inventory_snapshot(snapshots, st.inv)
                    local score = placement_score(st.rule, info, slots, nil)
                    if score > 0 then
                        candidates[#candidates + 1] = { storage = st, index = i, score = score }
                    end
                end
            end
            table.sort(candidates, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a.storage.d2 < b.storage.d2
            end)

            local max_stack = info.maxStack or 1
            for _, cand in ipairs(candidates) do
                local max_slot_count = tonumber(safe_call(function() return cand.storage.inv.MaxSlotCount end, 0)) or 0
                local occupied_by_slot = {}
                for _, occ in ipairs(inventory_snapshot(snapshots, cand.storage.inv)) do
                    occupied_by_slot[occ.slot] = occ
                end
                local target_slot, room = nil, 0
                for slot_idx = 0, max_slot_count - 1 do
                    local occ = occupied_by_slot[slot_idx]
                    if occ and occ.id == info.id and ((occ.maxStack or max_stack) - occ.count) > 0 then
                        target_slot = slot_idx
                        room = (occ.maxStack or max_stack) - occ.count
                        break
                    end
                end
                if target_slot == nil then
                    for slot_idx = 0, max_slot_count - 1 do
                        if not occupied_by_slot[slot_idx] then
                            target_slot = slot_idx
                            room = max_stack
                            break
                        end
                    end
                end
                if target_slot ~= nil and room > 0 then
                    local n = math.min(want, room)
                    return {
                        src_slot = info.slot,
                        dst_inv = cand.storage.inv,
                        dst_slot = target_slot,
                        amount = n,
                        is_split = n < info.count,
                        container_key = cand.index,
                    }
                end
            end
        end
    end
    return nil
end

function M.deposit_backpack()
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then return false, "local player controller is unavailable" end
    local inv = safe_call(function() return controller.InventoryComponent end)
    local ctrl = safe_call(function() return controller.InventoryController end)
    local pawn = safe_call(function() return controller.Pawn end)
    if not engine.is_valid(inv) or not engine.is_valid(ctrl) then
        return false, "inventory controller is unavailable"
    end

    local s = M.settings()
    local pawn_pos = actor_position(pawn)
    local storage_list = M.labelled_storage_in_reach(pawn_pos, s)
    if #storage_list == 0 then
        return false, "No labelled storage within reach (" .. tostring(s.rangeMeters) .. " m)."
    end

    local cost_amount = math.floor(tonumber(s.costAmount) or 0)
    local cost_active = s.costEnabled and cost_amount > 0
    local rune_name = s.costRune or "Air"
    if cost_active then
        local _, have_runes = rune_stacks(inv, rune_name)
        if have_runes < cost_amount then
            return false, string.format("Organiser requires %d %s runes (carried: %d).",
                cost_amount, rune_name, have_runes)
        end
    end

    local locks_table = M.locks()
    local ranges = backpack_slot_ranges(inv, s)
    local carried_items = {}
    for _, r in ipairs(ranges) do
        for _, info in ipairs(read_inventory_slots(inv, r[1], r[2])) do
            carried_items[#carried_items + 1] = info
        end
    end
    if #carried_items == 0 then
        return true, "Backpack is already empty."
    end

    if is_remote_client() then
        if remote_job ~= nil then
            return false, "An Organiser job is already running on the server."
        end
        local async = async_mod()
        if not async then
            return false, "Async network scheduler is unavailable on remote server."
        end
        remote_job_token = remote_job_token + 1
        local token = remote_job_token
        remote_job = "deposit"
        local moved, containers, max_steps, steps_done = 0, {}, 80, 0
        report_remote_progress("Depositing items safely over network...")

        local function finish()
            local ccount = 0
            for _ in pairs(containers) do ccount = ccount + 1 end
            local paid_text = ""
            if moved > 0 and cost_active and charge_runes(inv, ctrl, rune_name, cost_amount) then
                paid_text = string.format(" (-%d %s runes)", cost_amount, rune_name)
            end
            if token == remote_job_token then remote_job = nil end
            report_remote_progress(string.format("Deposited %d item(s) into %d container(s)%s.", moved, ccount, paid_text))
        end

        local function next_step()
            if token ~= remote_job_token or not remote_job or steps_done >= max_steps then
                finish()
                return
            end
            local step = find_next_deposit_step(inv, storage_list, locks_table, s, cost_active, cost_amount, rune_name)
            if not step then
                finish()
                return
            end
            execute_remote_transfer(token, ctrl, inv, step.src_slot, step.dst_inv, step.dst_slot, step.amount, step.is_split,
                function(ok)
                    if not ok then finish(); return end
                    steps_done = steps_done + 1
                    moved = moved + step.amount
                    containers[step.container_key] = true
                    report_remote_progress(string.format("Depositing safely... (%d item(s) moved)", moved))
                    next_step()
                end)
        end

        local ok_sched, sched_err = async.after(0.05, next_step)
        if not ok_sched then
            remote_job = nil
            return false, "Failed to schedule deposit: " .. tostring(sched_err)
        end
        return true, "Depositing carried items safely over network..."
    end

    local carried_totals = {}
    for _, info in ipairs(carried_items) do
        carried_totals[info.name] = (carried_totals[info.name] or 0) + info.count
    end

    local to_send = {}
    local rune_item_name = "ITEM_Rune_" .. tostring(rune_name)
    for name, total in pairs(carried_totals) do
        local lock_rule = locks_table[name]
        local keep_count = 0
        if lock_rule == "all" or lock_rule == math.huge then
            keep_count = total
        elseif type(lock_rule) == "number" then
            keep_count = lock_rule
        end
        if cost_active and (name == rune_name or name == rune_item_name) then
            keep_count = keep_count + cost_amount
        end
        to_send[name] = math.max(0, total - keep_count)
    end

    table.sort(carried_items, function(a, b) return a.slot > b.slot end)

    local storage_space = {}
    local inv_snapshots = {}
    local function snapshot_for_index(idx, target_inv)
        local list = inv_snapshots[idx]
        if not list then
            list = read_inventory_slots(target_inv)
            inv_snapshots[idx] = list
        end
        return list
    end
    local total_moved, total_kept = 0, 0
    local containers_used = {}

    for _, info in ipairs(carried_items) do
        local want = math.min(info.count, to_send[info.name] or 0)
        if want > 0 then
            local candidates = {}
            for i, st in ipairs(storage_list) do
                local score = placement_score(st.rule, info, snapshot_for_index(i, st.inv), nil)
                if score > 0 then
                    candidates[#candidates + 1] = { storage = st, index = i, score = score }
                end
            end
            table.sort(candidates, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a.storage.d2 < b.storage.d2
            end)

            local left = want
            local max_stack = info.maxStack or 1

            for _, cand in ipairs(candidates) do
                if left <= 0 then break end
                local slots = storage_space[cand.index]
                if not slots then
                    slots = {}
                    local max_slot_count = tonumber(safe_call(function() return cand.storage.inv.MaxSlotCount end, 0)) or 0
                    for slot_idx = 0, max_slot_count - 1 do
                        slots[slot_idx] = { empty = true }
                    end
                    for _, occupied in ipairs(read_inventory_slots(cand.storage.inv)) do
                        slots[occupied.slot] = {
                            id = occupied.id,
                            name = occupied.name,
                            free = math.max(0, (occupied.maxStack or 1) - occupied.count),
                        }
                    end
                    storage_space[cand.index] = slots
                end

                local target_order = {}
                for slot_idx, st_data in pairs(slots) do
                    if st_data.id == info.id and st_data.free > 0 then
                        target_order[#target_order + 1] = { slot = slot_idx, rank = 0 }
                    end
                end
                for slot_idx, st_data in pairs(slots) do
                    if st_data.empty then
                        target_order[#target_order + 1] = { slot = slot_idx, rank = 1 }
                    end
                end
                table.sort(target_order, function(a, b)
                    if a.rank ~= b.rank then return a.rank < b.rank end
                    return a.slot < b.slot
                end)

                for _, target in ipairs(target_order) do
                    if left <= 0 then break end
                    local st_data = slots[target.slot]
                    local room = st_data.empty and max_stack or st_data.free
                    local n = math.min(left, room)
                    local ok
                    if n == info.count then
                        ok = pcall(function()
                            ctrl:MoveItemBetweenInventories(inv, info.slot, cand.storage.inv, target.slot)
                        end)
                    else
                        ok = pcall(function()
                            ctrl:SplitAndPutStack(inv, info.slot, n, cand.storage.inv, target.slot)
                        end)
                    end
                    if ok then
                        slots[target.slot] = { id = info.id, name = info.name, free = room - n }
                        local snap = snapshot_for_index(cand.index, cand.storage.inv)
                        snap[#snap + 1] = {
                            slot = target.slot,
                            id = info.id,
                            name = info.name,
                            count = n,
                            maxStack = max_stack,
                            categories = info.categories,
                        }
                        left = left - n
                        total_moved = total_moved + n
                        info.count = info.count - n
                        containers_used[cand.index] = true
                    end
                end
            end
            to_send[info.name] = (to_send[info.name] or 0) - (want - left)
            total_kept = total_kept + info.count
        else
            total_kept = total_kept + info.count
        end
    end

    local container_count = 0
    for _ in pairs(containers_used) do container_count = container_count + 1 end

    local paid_text = ""
    if total_moved > 0 and cost_active then
        if charge_runes(inv, ctrl, rune_name, cost_amount) then
            paid_text = string.format(" (-%d %s runes)", cost_amount, rune_name)
        end
    end

    if total_moved > 0 then
        play_deposit_animation(pawn, s)
    end

    local message = string.format("Deposited %d items into %d container(s), kept %d%s.",
        total_moved, container_count, total_kept, paid_text)
    log.info("Organiser: " .. message)
    return true, message, { moved = total_moved, kept = total_kept, containers = container_count }
end

-- Container Sorting & Re-sorting ----------------------------------------------

local CATEGORY_ORDER = {
    -- Equipment
    ["Weapon"] = 10,
    ["Shield"] = 11,
    ["Armour"] = 12,
    ["Jewellery"] = 13,
    ["Cape"] = 14,
    ["Tool"] = 15,
    ["Ammo"] = 16,
    -- Consumables
    ["Potion"] = 20,
    ["Food"] = 21,
    ["Drink"] = 22,
    ["Tome"] = 24,
    ["Plan"] = 25,
    ["Pattern"] = 26,
    ["Vestige"] = 27,
    ["Whetstone"] = 28,
    ["Consumable"] = 29,
    -- Raw & Extraction Materials
    ["Ore"] = 30,
    ["Metal"] = 31,
    ["Mineral"] = 32,
    ["Wood"] = 33,
    ["Ingredient"] = 34,
    ["Raw Fish"] = 35,
    ["Prime Fish"] = 36,
    ["Seed"] = 37,
    -- Crafting & Magic Materials (ordered by sub-family below)
    ["Bone"] = 38,
    ["Hide"] = 38.4,
    ["Leather"] = 38.6,
    ["Thread"] = 39.1,
    ["Cloth"] = 39.2,
    ["Currency"] = 39.8,
    ["Gem"] = 40.2,
    ["Essence"] = 40.3,
    ["Rune"] = 40.5,
    ["Herb"] = 37.5,
    ["Component"] = 41,
    ["Processed"] = 41.2,
    ["Special"] = 41.4,
    ["Basic"] = 41.6,
    ["Resource"] = 41.8,
    -- Quest
    ["Quest"] = 50,
}

local MATERIAL_FAMILY_PATTERNS = {
    -- Animal parts & leathercraft
    { 38.05, { "bone", "bonemeal", "skull", "spine", "tooth" } },
    { 38.15, { "horn", "antler", "fang", "claw", "tusk", "talon", "wing" } },
    { 38.25, { "feather", "scale", "shell", "chitin", "carapace" } },
    { 38.40, { "pelt", "hide", "dragonhide", "fur", "fleece", "skin" } },
    { 38.60, { "leather" } },
    -- Textiles
    { 39.10, { "thread", "yarn", "twine", "string", "cord", "wool", "fibre", "fibres", "fibrous", "cactus" } },
    { 39.20, { "cloth", "linen", "silk", "fabric", "weave" } },
    { 39.80, { "chit", "coin", "token", "currency", "doubloon" } },
    -- Botanical
    { 37.50, { "herb", "flower", "leaf", "leaves", "moss", "root", "spore", "flax", "marigold", "harralander", "bitterweed", "vervain" } },
    -- Minerals, gems, alchemy & arcana
    { 31.50, { "bar", "ingot", "spike", "rivet", "nail" } },
    { 32.50, { "upgrade core", "upgrade_core", "core", "mould", "mold" } },
    { 40.10, { "oil", "sap", "resin", "wax", "slime", "tallow", "paste", "adhesive", "naphtha", "glass", "ichor", "blood", "glue", "tar", "dye", "monoxide" } },
    { 40.20, { "gem", "crystal", "quartz", "amber", "pearl", "ruby", "emerald", "diamond", "sapphire", "jade", "opal", "topaz", "onyx", "dragonstone" } },
    { 40.30, { "essence", "anima", "ember", "ether" } },
    { 40.35, { "shard", "dust", "ash", "ashes", "powder", "coal", "charcoal" } },
    { 40.50, { "rune" } },
}

local function item_sort_rank(info)
    local min_rank = 99
    if info and info.categories then
        for _, cat in ipairs(info.categories) do
            local r = CATEGORY_ORDER[cat]
            if r and r < min_rank then min_rank = r end
        end
    end

    -- For mixed crafting/resource/unclassified stacks, group visually by material family
    -- (leather together, threads/cloth together, bones/horns together, herbs together, cores/shards together).
    if min_rank >= 38 then
        local n_l = tostring(info and info.name or ""):lower()
        local id_l = tostring(info and info.id or ""):lower():gsub("_", " ")
        for _, entry in ipairs(MATERIAL_FAMILY_PATTERNS) do
            local rank, kws = entry[1], entry[2]
            for _, kw in ipairs(kws) do
                if has_word_token(n_l, kw) or has_word_token(id_l, kw) then
                    return rank
                end
            end
        end
    end
    return min_rank
end

function M.compare_items(a, b)
    if not a and not b then return false end
    if not a then return false end
    if not b then return true end
    local rank_a = item_sort_rank(a)
    local rank_b = item_sort_rank(b)
    if rank_a ~= rank_b then return rank_a < rank_b end
    local name_a = tostring(a.name or ""):lower()
    local name_b = tostring(b.name or ""):lower()
    if name_a ~= name_b then return name_a < name_b end
    local count_a = tonumber(a.count) or 0
    local count_b = tonumber(b.count) or 0
    if count_a ~= count_b then return count_a > count_b end
    local id_a = tostring(a.id or "")
    local id_b = tostring(b.id or "")
    if id_a ~= id_b then return id_a < id_b end
    return (tonumber(a.slot) or math.huge) < (tonumber(b.slot) or math.huge)
end

function M.sort_storage(inv, ctrl)
    if not engine.is_valid(inv) then return false, "invalid inventory" end
    if not ctrl then
        local controller = engine.local_controller()
        ctrl = controller and safe_call(function() return controller.InventoryController end)
    end
    if not engine.is_valid(ctrl) then return false, "inventory controller unavailable" end

    local slots = read_inventory_slots(inv)
    if #slots == 0 then return true, "Storage is empty.", 0 end

    if is_remote_client() then
        if remote_job ~= nil then
            return false, "An Organiser job is already running on the server."
        end
        local async = async_mod()
        if not async then
            return false, "Async network scheduler is unavailable on remote server."
        end
        remote_job_token = remote_job_token + 1
        local token = remote_job_token
        remote_job = "sort"
        report_remote_progress("Sorting container safely over network...")
        local ok_sched, sched_err = async.after(0.05, function()
            run_remote_sort(token, inv, ctrl, "open chest", function(steps_done, merges_done)
                if token == remote_job_token then remote_job = nil end
                report_remote_progress(string.format("Sorted chest cleanly (%d move(s), %d merge(s)).", steps_done, merges_done))
            end)
        end)
        if not ok_sched then
            remote_job = nil
            return false, "Failed to schedule chest sort: " .. tostring(sched_err)
        end
        return true, "Sorting chest safely over network..."
    end

    -- Phase 1: Consolidate partial stacks of the same item
    local by_id = {}
    for _, info in ipairs(slots) do
        if info.id and info.id ~= "?" then
            local list = by_id[info.id]
            if not list then
                list = {}
                by_id[info.id] = list
            end
            list[#list + 1] = info
        end
    end

    local merged_count = 0
    for _, list in pairs(by_id) do
        if #list > 1 then
            table.sort(list, function(a, b) return a.slot < b.slot end)
            for i = 1, #list do
                local dest = list[i]
                local max_stack = dest.maxStack or 1
                if dest.count > 0 and dest.count < max_stack then
                    for j = #list, i + 1, -1 do
                        local src = list[j]
                        if src.count > 0 then
                            local room = max_stack - dest.count
                            local to_move = math.min(room, src.count)
                            if to_move > 0 then
                                local ok
                                if to_move == src.count then
                                    ok = pcall(function()
                                        ctrl:MoveItemBetweenInventories(inv, src.slot, inv, dest.slot)
                                    end)
                                else
                                    ok = pcall(function()
                                        ctrl:SplitAndPutStack(inv, src.slot, to_move, inv, dest.slot)
                                    end)
                                end
                                if ok then
                                    dest.count = dest.count + to_move
                                    src.count = src.count - to_move
                                    merged_count = merged_count + 1
                                    if dest.count >= max_stack then break end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Re-read slots after consolidation
    slots = read_inventory_slots(inv)
    if #slots <= 1 then
        return true, "Storage is organized.", merged_count
    end

    -- Phase 2: In-place deterministic slot sort
    local target_list = {}
    for _, s in ipairs(slots) do target_list[#target_list + 1] = s end
    table.sort(target_list, M.compare_items)

    local slot_occupant = {}
    for _, item in ipairs(slots) do
        slot_occupant[item.slot] = item
    end

    local moved_count = 0
    for i = 1, #target_list do
        local desired_slot = i - 1
        local wanted = target_list[i]
        local curr_slot = wanted.slot
        if curr_slot ~= desired_slot then
            local occupant = slot_occupant[desired_slot]
            local ok = pcall(function()
                ctrl:MoveItemBetweenInventories(inv, curr_slot, inv, desired_slot)
            end)
            if ok then
                moved_count = moved_count + 1
                wanted.slot = desired_slot
                slot_occupant[desired_slot] = wanted
                if occupant then
                    occupant.slot = curr_slot
                    slot_occupant[curr_slot] = occupant
                else
                    slot_occupant[curr_slot] = nil
                end
            end
        end
    end

    local message = string.format("Sorted %d item stack(s) (merged %d partial stack(s)).",
        #target_list, merged_count)
    log.info("Organiser: " .. message)
    return true, message, moved_count
end

function M.sort_open_storage()
    local inv, actor = M.open_storage()
    if not engine.is_valid(inv) or not engine.is_valid(actor) then
        return false, "No storage container is currently open."
    end
    local controller = engine.local_controller()
    local ctrl = controller and safe_call(function() return controller.InventoryController end)
    if not engine.is_valid(ctrl) then
        return false, "Inventory controller is unavailable."
    end
    return M.sort_storage(inv, ctrl)
end

function M.resort_nearby_storage()
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then
        return false, "Local player controller is unavailable."
    end
    local ctrl = safe_call(function() return controller.InventoryController end)
    local pawn = safe_call(function() return controller.Pawn end)
    local player_inv = safe_call(function() return controller.InventoryComponent end)
    if not engine.is_valid(ctrl) or not engine.is_valid(player_inv) then
        return false, "Inventory controller is unavailable."
    end

    local s = M.settings()
    local pawn_pos = actor_position(pawn)
    local storage_list = M.labelled_storage_in_reach(pawn_pos, s)
    if #storage_list < 2 then
        return false, "Need at least 2 labelled containers within reach (" .. tostring(s.rangeMeters) .. " m) to re-sort."
    end

    local cost_amount = math.floor(tonumber(s.costAmount) or 0)
    local cost_active = s.costEnabled and cost_amount > 0
    local rune_name = s.costRune or "Air"
    if cost_active then
        local _, have_runes = rune_stacks(player_inv, rune_name)
        if have_runes < cost_amount then
            return false, string.format("Organiser requires %d %s runes (carried: %d).",
                cost_amount, rune_name, have_runes)
        end
    end

    local destinations = {}
    for _, st in ipairs(storage_list) do
        if st.rule and st.rule.kind ~= "trash" then
            destinations[#destinations + 1] = st
        end
    end
    if #destinations == 0 then
        return false, "No valid non-trash destination containers available."
    end

    if is_remote_client() then
        if remote_job ~= nil then
            return false, "An Organiser job is already running on the server."
        end
        local async = async_mod()
        if not async then
            return false, "Async network scheduler is unavailable on remote server."
        end
        remote_job_token = remote_job_token + 1
        local token = remote_job_token
        remote_job = "resort"
        report_remote_progress("Re-sorting nearby chests safely over network...")

        local ok_sched, sched_err = async.after(0.05, function()
            run_remote_resort(token, storage_list, destinations, ctrl, function(relocated, modified)
                local mod_list = {}
                for st in pairs(modified) do mod_list[#mod_list + 1] = st end
                local idx = 0
                local function sort_next_modified()
                    if token ~= remote_job_token or not remote_job then
                        if token == remote_job_token then remote_job = nil end
                        return
                    end
                    idx = idx + 1
                    local st = mod_list[idx]
                    if not st then
                        if cost_active and relocated > 0 then
                            charge_runes(player_inv, ctrl, rune_name, cost_amount)
                        end
                        if token == remote_job_token then remote_job = nil end
                        report_remote_progress(string.format("Re-sorted %d stack(s) across %d container(s).", relocated, #mod_list))
                        return
                    end
                    local function schedule_next_mod()
                        local ok_n = async.after(0.02, sort_next_modified)
                        if not ok_n and token == remote_job_token then remote_job = nil end
                    end
                    run_remote_sort(token, st.inv, ctrl, st.label or "chest", schedule_next_mod)
                end
                sort_next_modified()
            end)
        end)
        if not ok_sched then
            remote_job = nil
            return false, "Failed to schedule nearby re-sort: " .. tostring(sched_err)
        end
        return true, "Re-sorting nearby chests safely over network..."
    end

    local function find_free_backpack_slot()
        local ranges = backpack_slot_ranges(player_inv, s)
        local occupied_slots = {}
        for _, r in ipairs(ranges) do
            for _, info in ipairs(read_inventory_slots(player_inv, r[1], r[2])) do
                occupied_slots[info.slot] = true
            end
        end
        for _, r in ipairs(ranges) do
            for slot_idx = r[1], r[2] do
                if not occupied_slots[slot_idx] then
                    return slot_idx
                end
            end
        end
        return nil
    end

    local dest_spaces = {}
    local function get_dest_space(st)
        local key = tostring(safe_call(function() return st.actor:GetFullName() end, st.inv))
        if not dest_spaces[key] then
            local slots = {}
            local max_slot_count = tonumber(safe_call(function() return st.inv.MaxSlotCount end, 0)) or 0
            for slot_idx = 0, max_slot_count - 1 do
                slots[slot_idx] = { empty = true }
            end
            for _, occ in ipairs(read_inventory_slots(st.inv)) do
                slots[occ.slot] = {
                    id = occ.id,
                    name = occ.name,
                    free = math.max(0, (occ.maxStack or 1) - occ.count),
                }
            end
            dest_spaces[key] = { slots = slots, max = max_slot_count }
        end
        return dest_spaces[key]
    end

    local resort_snapshots = {}
    local function resort_snapshot_for(inv_obj)
        local list = resort_snapshots[inv_obj]
        if not list then
            list = read_inventory_slots(inv_obj)
            resort_snapshots[inv_obj] = list
        end
        return list
    end

    local total_relocated = 0
    local modified_containers = {}

    for _, src_st in ipairs(storage_list) do
        if src_st.rule and src_st.rule.kind ~= "trash" then
            local src_snap = resort_snapshot_for(src_st.inv)
            local src_items = {}
            for _, entry in ipairs(src_snap) do src_items[#src_items + 1] = entry end
            table.sort(src_items, function(a, b) return a.slot > b.slot end)

            for _, item in ipairs(src_items) do
                local current_src_snap = resort_snapshot_for(src_st.inv)
                local score_here = placement_score(src_st.rule, item, current_src_snap, item.slot)
                local best_dest, best_space, best_slot = nil, nil, nil
                local best_score = score_here

                for _, dest_st in ipairs(destinations) do
                    if dest_st.inv ~= src_st.inv then
                        local dest_snap = resort_snapshot_for(dest_st.inv)
                        local score_there = placement_score(dest_st.rule, item, dest_snap, nil)
                        if score_there > best_score or (score_there == best_score and best_dest and dest_st.d2 < best_dest.d2 and score_there > score_here) then
                            local space = get_dest_space(dest_st)
                            local candidate_slot = nil
                            for slot_idx = 0, space.max - 1 do
                                local st_data = space.slots[slot_idx]
                                if st_data and st_data.id == item.id and st_data.free and st_data.free >= item.count then
                                    candidate_slot = slot_idx
                                    break
                                end
                            end
                            if candidate_slot == nil then
                                for slot_idx = 0, space.max - 1 do
                                    local st_data = space.slots[slot_idx]
                                    if st_data and st_data.empty then
                                        candidate_slot = slot_idx
                                        break
                                    end
                                end
                            end
                            if candidate_slot ~= nil then
                                best_score = score_there
                                best_dest = dest_st
                                best_space = space
                                best_slot = candidate_slot
                            end
                        end
                    end
                end

                if best_dest and best_slot ~= nil and best_score > score_here then
                    local space = best_space
                    local target_slot = best_slot
                        local ok = pcall(function()
                            ctrl:MoveItemBetweenInventories(src_st.inv, item.slot, best_dest.inv, target_slot)
                        end)
                        if not ok then
                            local buffer_slot = find_free_backpack_slot()
                            if buffer_slot ~= nil then
                                local step1 = pcall(function()
                                    ctrl:MoveItemBetweenInventories(src_st.inv, item.slot, player_inv, buffer_slot)
                                end)
                                if step1 then
                                    local step2 = pcall(function()
                                        ctrl:MoveItemBetweenInventories(player_inv, buffer_slot, best_dest.inv, target_slot)
                                    end)
                                    ok = step2
                                end
                            end
                        end

                        if ok then
                            total_relocated = total_relocated + 1
                            local prev_data = space.slots[target_slot]
                            local free_left = prev_data.empty and ((item.maxStack or 1) - item.count) or (prev_data.free - item.count)
                            space.slots[target_slot] = { id = item.id, name = item.name, free = math.max(0, free_left) }

                            for idx, entry in ipairs(current_src_snap) do
                                if entry.slot == item.slot then
                                    table.remove(current_src_snap, idx)
                                    break
                                end
                            end
                            local dest_snap = resort_snapshot_for(best_dest.inv)
                            dest_snap[#dest_snap + 1] = {
                                slot = target_slot,
                                id = item.id,
                                name = item.name,
                                count = item.count,
                                maxStack = item.maxStack,
                                categories = item.categories,
                            }

                            modified_containers[src_st] = true
                            modified_containers[best_dest] = true
                        end
                end
            end
        end
    end

    if total_relocated == 0 then
        return true, "All items in nearby containers are already organized."
    end

    local mod_count = 0
    for st in pairs(modified_containers) do
        mod_count = mod_count + 1
        pcall(function() M.sort_storage(st.inv, ctrl) end)
    end

    local paid_text = ""
    if cost_active and total_relocated > 0 then
        if charge_runes(player_inv, ctrl, rune_name, cost_amount) then
            paid_text = string.format(" (-%d %s runes)", cost_amount, rune_name)
        end
    end

    if total_relocated > 0 then
        play_deposit_animation(pawn, s)
    end

    local message = string.format("Re-sorted %d misplaced item stack(s) across %d container(s)%s.",
        total_relocated, mod_count, paid_text)
    log.info("Organiser: " .. message)
    return true, message, { relocated = total_relocated, containers = mod_count }
end

-- Base Storage Advisor & Adaptive Bank Sorter -------------------------------

local SUB_CATEGORY_ROLES = {
    { id = "sub_metal",     label = "All: Metal",     category = "Metal",     station_theme = "ores",      min_stacks = 2 },
    { id = "sub_mineral",   label = "All: Mineral",   category = "Mineral",   station_theme = "ores",      min_stacks = 2 },
    { id = "sub_leather",   label = "All: Leather",   category = "Leather",   station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_hide",      label = "All: Hide",      category = "Hide",      station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_thread",    label = "All: Thread",    category = "Thread",    station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_cloth",     label = "All: Cloth",     category = "Cloth",     station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_bone",      label = "All: Bone",      category = "Bone",      station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_herb",      label = "All: Herb",      category = "Herb",      station_theme = "magic",     min_stacks = 2 },
    { id = "sub_seed",      label = "All: Seed",      category = "Seed",      station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_essence",   label = "All: Essence",   category = "Essence",   station_theme = "magic",     min_stacks = 2 },
    { id = "sub_rune",      label = "All: Rune",      category = "Rune",      station_theme = "magic",     min_stacks = 2 },
    { id = "sub_gem",       label = "All: Gem",       category = "Gem",       station_theme = "ores",      min_stacks = 2 },
    { id = "sub_weapon",     label = "All: Weapon",     category = "Weapon",     station_theme = "equipment", min_stacks = 2 },
    { id = "sub_armour",     label = "All: Armour",     category = "Armour",     station_theme = "equipment", min_stacks = 2 },
    { id = "sub_shield",     label = "All: Shield",     category = "Shield",     station_theme = "equipment", min_stacks = 2 },
    { id = "sub_cape",       label = "All: Cape",       category = "Cape",       station_theme = "equipment", min_stacks = 2 },
    { id = "sub_jewellery",  label = "All: Jewellery",  category = "Jewellery",  station_theme = "equipment", min_stacks = 2 },
    { id = "sub_tool",       label = "All: Tool",       category = "Tool",       station_theme = "equipment", min_stacks = 2 },
    { id = "sub_ammo",       label = "All: Ammo",       category = "Ammo",       station_theme = "equipment", min_stacks = 2 },
    { id = "sub_tome",       label = "All: Tome",       category = "Tome",       station_theme = "magic",     min_stacks = 2 },
    { id = "sub_ingredient", label = "All: Ingredient", category = "Ingredient", station_theme = "food",      min_stacks = 2 },
    { id = "sub_currency",   label = "All: Currency",   category = "Currency",   station_theme = "crafting",  min_stacks = 2 },
    { id = "sub_raw_fish",   label = "All: Raw Fish",   category = "Raw Fish",   station_theme = "food",      min_stacks = 2 },
    { id = "sub_prime_fish", label = "All: Prime Fish", category = "Prime Fish", station_theme = "food",      min_stacks = 2 },
    { id = "sub_drink",      label = "All: Drink",      category = "Drink",      station_theme = "food",      min_stacks = 2 },
}

function M.plan_base_roles(all_chests, workstations, opts)
    all_chests = all_chests or {}
    workstations = workstations or {}
    local force_replan = type(opts) == "table" and opts.force_replan == true

    local eligible_count = 0
    local free_chests = {}
    local misc_chests = {}
    local role_counts = {}
    local role_capacity = {}
    local cat_demand = {}
    local item_demand = {}
    local item_list = {}

    for _, chest in ipairs(all_chests) do
        local is_trash = chest.rule and chest.rule.kind == "trash"
        if not is_trash then
            eligible_count = eligible_count + 1
            local lbl = chest.label and trim(chest.label) or ""
            local low = lbl:lower()
            if force_replan or lbl == "" then
                free_chests[#free_chests + 1] = chest
            elseif low == "misc" then
                misc_chests[#misc_chests + 1] = chest
            else
                role_counts[low] = (role_counts[low] or 0) + 1
                role_capacity[low] = (role_capacity[low] or 0) + (tonumber(chest.maxSlots) or 20)
            end

            for _, item in ipairs(chest.slots or {}) do
                local seen_cats = {}
                for _, cat in ipairs(item.categories or {}) do
                    local cl = cat:lower()
                    if not seen_cats[cl] then
                        seen_cats[cl] = true
                        cat_demand[cl] = (cat_demand[cl] or 0) + 1
                    end
                end
                local nm = item.name and trim(item.name) or ""
                if nm ~= "" and nm ~= "?" then
                    local key = nm:lower()
                    local rec = item_demand[key]
                    if not rec then
                        rec = { name = nm, stacks = 0, categories = item.categories or {} }
                        item_demand[key] = rec
                        item_list[#item_list + 1] = rec
                    end
                    rec.stacks = rec.stacks + 1
                end
            end
        end
    end

    local tier = "starter"
    if eligible_count >= 20 then
        tier = "granular"
    elseif eligible_count >= 8 then
        tier = "standard"
    end

    -- Preserve at most 1 catch-all "Misc" chest once spare chests exist; allow excess "Misc"
    -- chests (or the single "Misc" chest in compact starter bases) to take needed bank roles.
    local reserve_misc = (tier == "starter") and (#free_chests >= 6 and 1 or 0) or (#free_chests >= 1 and 1 or 0)
    for i = reserve_misc + 1, #misc_chests do
        free_chests[#free_chests + 1] = misc_chests[i]
    end
    if reserve_misc >= 1 and misc_chests[1] then
        role_counts["misc"] = 1
        role_capacity["misc"] = tonumber(misc_chests[1].maxSlots) or 20
    end

    local available = {}
    for _, c in ipairs(free_chests) do available[#available + 1] = c end

    local station_range_sq = (10 * 100) * (10 * 100)
    local function pick_best_chest(match_cats, station_theme_id, exact_item_name, expected_demand)
        if #available == 0 then return nil end
        local best_idx = 1
        local best_score = -math.huge
        local best_d2 = math.huge
        local demand = tonumber(expected_demand) or 0

        for idx, chest in ipairs(available) do
            local score = 0
            local cap = tonumber(chest.maxSlots) or 20
            -- Fit large/busy categories onto 48/64-slot chests and keep light roles on smaller chests.
            if demand >= 10 then
                if cap >= demand then
                    score = score + 20
                else
                    score = score - 25
                end
                score = score + math.min(cap, 64) * 0.4
            else
                if demand > 0 and cap >= demand then score = score + 4 end
                score = score + (64 - math.min(cap, 64)) * 0.15
            end
            if station_theme_id and chest.pos then
                for _, ws in ipairs(workstations) do
                    if ws.theme and ws.theme.id == station_theme_id then
                        local d = distance_squared(chest.pos, ws.pos)
                        if d < station_range_sq then
                            score = score + 100 + math.max(0, 10 - math.sqrt(d) / 100)
                            break
                        end
                    end
                end
            end
            local item_bonus = 0
            for _, item in ipairs(chest.slots or {}) do
                if exact_item_name and tostring(item.name or ""):lower() == exact_item_name:lower() then
                    item_bonus = item_bonus + 12
                elseif match_cats then
                    for _, cat in ipairs(item.categories or {}) do
                        if match_cats[cat:lower()] then
                            item_bonus = item_bonus + 5
                            break
                        end
                    end
                end
            end
            score = score + math.min(item_bonus, 25)
            local d2 = chest.d2 or math.huge
            if score > best_score or (score == best_score and d2 < best_d2) then
                best_score = score
                best_d2 = d2
                best_idx = idx
            end
        end

        return table.remove(available, best_idx)
    end

    local assignments = {}
    local function assign_chest(chest, label, reason_tier, reason)
        if not chest or not label then return end
        local low = label:lower()
        role_counts[low] = (role_counts[low] or 0) + 1
        role_capacity[low] = (role_capacity[low] or 0) + (tonumber(chest.maxSlots) or 20)
        assignments[#assignments + 1] = {
            chest = chest,
            label = label,
            tier = reason_tier,
            reason = reason,
        }
    end

    -- Pass 1: Active core coarse bank themes (demand > 0 or matching nearby workstation)
    local active_station_themes = {}
    for _, ws in ipairs(workstations) do
        if ws.theme and ws.theme.id then
            active_station_themes[ws.theme.id] = true
        end
    end

    local theme_requests = {}
    for _, theme in ipairs(BANK_THEMES) do
        local demand = 0
        local cat_set = {}
        for _, tc in ipairs(theme.categories or {}) do
            local tcl = tc:lower()
            cat_set[tcl] = true
            demand = demand + (cat_demand[tcl] or 0)
        end
        theme_requests[#theme_requests + 1] = {
            theme = theme,
            demand = demand,
            cat_set = cat_set,
            has_station = active_station_themes[theme.id] == true,
        }
    end
    table.sort(theme_requests, function(a, b)
        if a.demand ~= b.demand then return a.demand > b.demand end
        if a.has_station ~= b.has_station then return a.has_station end
        return a.theme.id < b.theme.id
    end)

    for _, req in ipairs(theme_requests) do
        if #available == 0 then break end
        local low = req.theme.label:lower()
        if (role_counts[low] or 0) == 0 and (req.demand > 0 or req.has_station) then
            local chest = pick_best_chest(req.cat_set, req.theme.id, nil, req.demand)
            if chest then
                assign_chest(chest, req.theme.label, 1, "Core bank role")
            end
        end
    end

    -- Pass 2 (Standard & Granular): Split busy sub-categories into dedicated chests
    if tier ~= "starter" and #available > 0 then
        local sub_candidates = {}
        for idx, sub in ipairs(SUB_CATEGORY_ROLES) do
            local cl = sub.category:lower()
            local demand = cat_demand[cl] or 0
            local low = sub.label:lower()
            if (role_counts[low] or 0) == 0 and demand >= (sub.min_stacks or 2) then
                sub_candidates[#sub_candidates + 1] = { sub = sub, demand = demand, order = idx }
            end
        end
        table.sort(sub_candidates, function(a, b)
            if a.demand ~= b.demand then return a.demand > b.demand end
            return a.order < b.order
        end)
        for _, cand in ipairs(sub_candidates) do
            if #available == 0 then break end
            local cat_set = { [cand.sub.category:lower()] = true }
            local chest = pick_best_chest(cat_set, cand.sub.station_theme, nil, cand.demand)
            if chest then
                assign_chest(chest, cand.sub.label, 2,
                    string.format("%d %s stack(s) in base", cand.demand, cand.sub.category))
            end
        end
    end

    -- Pass 3 (Proportional Bulk & Overflow): Once base has 8+ chests and spare capacity,
    -- promote heavy bulk items (>= 3 stacks at 14+, >= 4 at 8..13) and add overflow chests above 75% load.
    if tier ~= "starter" and #available > 0 then
        local bulk_threshold = (eligible_count >= 14) and 3 or 4
        table.sort(item_list, function(a, b)
            if a.stacks ~= b.stacks then return a.stacks > b.stacks end
            return a.name:lower() < b.name:lower()
        end)
        for _, rec in ipairs(item_list) do
            if #available == 0 then break end
            if rec.stacks >= bulk_threshold and #rec.name <= NAME_LIMIT then
                local low = rec.name:lower()
                if (role_counts[low] or 0) == 0 and not low:find("^all:") and low ~= "misc" and low ~= "trash" then
                    local chest = pick_best_chest(nil, nil, rec.name, rec.stacks)
                    if chest then
                        assign_chest(chest, rec.name, 3, string.format("%d stacks need dedicated storage", rec.stacks))
                    end
                end
            end
        end

        for _, sub in ipairs(SUB_CATEGORY_ROLES) do
            if #available == 0 then break end
            local low = sub.label:lower()
            local demand = cat_demand[sub.category:lower()] or 0
            local cap = role_capacity[low] or 0
            if cap > 0 and demand > math.floor(cap * 0.75) and (role_counts[low] or 0) < 4 then
                local chest = pick_best_chest({ [sub.category:lower()] = true }, sub.station_theme, nil, math.max(1, demand - cap))
                if chest then
                    assign_chest(chest, sub.label, 3,
                        string.format("Overflow capacity (%d/%d slots demanded)", demand, cap))
                end
            end
        end

        for _, req in ipairs(theme_requests) do
            if #available == 0 then break end
            local low = req.theme.label:lower()
            local cap = role_capacity[low] or 0
            if cap > 0 and req.demand > math.floor(cap * 0.75) and (role_counts[low] or 0) < 4 then
                local chest = pick_best_chest(req.cat_set, req.theme.id, nil, math.max(1, req.demand - cap))
                if chest then
                    assign_chest(chest, req.theme.label, 3,
                        string.format("Overflow capacity (%d/%d slots demanded)", req.demand, cap))
                end
            end
        end
    end

    -- Pass 4: Fill any remaining 0-demand core themes if chests remain, plus at most one catch-all Misc chest
    for _, req in ipairs(theme_requests) do
        if #available == 0 then break end
        local low = req.theme.label:lower()
        if (role_counts[low] or 0) == 0 then
            local chest = pick_best_chest(req.cat_set, req.theme.id, nil)
            if chest then
                assign_chest(chest, req.theme.label, 1, "Core bank role")
            end
        end
    end

    if #available > 0 and (role_counts["misc"] or 0) == 0 then
        local chest = pick_best_chest(nil, nil, nil)
        if chest then
            assign_chest(chest, "Misc", 1, "Base catch-all storage")
        end
    end

    return {
        tier = tier,
        total_chests = eligible_count,
        free_before = #free_chests,
        free_after = #available,
        assignments = assignments,
        role_counts = role_counts,
        cat_demand = cat_demand,
        sub_candidates = SUB_CATEGORY_ROLES,
    }
end

function M.base_advisor_report()
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then
        return nil, "Local player controller is unavailable."
    end
    local pawn = safe_call(function() return controller.Pawn end)
    local pawn_pos = actor_position(pawn)
    if not pawn_pos then
        return nil, "Player position is unavailable."
    end

    local s = M.settings()
    local all_chests = M.all_storage_in_reach(pawn_pos, s)
    local workstations = M.detect_workstations(pawn_pos, s.rangeMeters or 40)
    local plan = M.plan_base_roles(all_chests, workstations)

    local theme_stats = {}
    for _, theme in ipairs(BANK_THEMES) do
        theme_stats[theme.id] = {
            theme = theme,
            chest_count = 0,
            total_capacity = 0,
            stored_stacks = 0,
            stored_items = 0,
            chests = {},
        }
    end

    local unassigned_chests = {}
    for _, chest in ipairs(all_chests) do
        local matched_theme = nil
        if chest.label then
            for _, theme in ipairs(BANK_THEMES) do
                if chest.label:lower() == theme.label:lower() then
                    matched_theme = theme
                    break
                end
            end
        end
        if matched_theme then
            local stat = theme_stats[matched_theme.id]
            stat.chest_count = stat.chest_count + 1
            stat.total_capacity = stat.total_capacity + (chest.maxSlots or 20)
            stat.chests[#stat.chests + 1] = chest
        else
            unassigned_chests[#unassigned_chests + 1] = chest
        end

        for _, item in ipairs(chest.slots or {}) do
            for _, theme in ipairs(BANK_THEMES) do
                local is_match = false
                for _, cat in ipairs(item.categories or {}) do
                    for _, t_cat in ipairs(theme.categories) do
                        if cat:lower() == t_cat:lower() then
                            is_match = true
                            break
                        end
                    end
                    if is_match then break end
                end
                if is_match then
                    local stat = theme_stats[theme.id]
                    stat.stored_stacks = stat.stored_stacks + 1
                    stat.stored_items = stat.stored_items + (item.count or 1)
                    break
                end
            end
        end
    end

    local recommendations = {}
    local station_reports = {}

    for _, ws in ipairs(workstations) do
        local nearest_chest = nil
        local min_dist = math.huge
        for _, chest in ipairs(all_chests) do
            local d = distance_squared(ws.pos, chest.pos)
            if d < min_dist then
                min_dist = d
                nearest_chest = chest
            end
        end
        local dist_m = math.sqrt(min_dist) / 100
        local report = {
            station = ws.name,
            theme = ws.theme,
            distance = math.floor(ws.distance or 0),
            nearest_chest = nearest_chest,
            chest_dist = math.floor(dist_m),
            has_nearby_chest = dist_m <= 10,
        }
        station_reports[#station_reports + 1] = report

        if not nearest_chest or dist_m > 10 then
            recommendations[#recommendations + 1] = {
                kind = "missing_station_chest",
                station = ws.name,
                theme = ws.theme,
                dist = math.floor(dist_m),
                priority = 1,
                title = string.format("Build %s near %s", ws.theme.chest_type, ws.name),
                detail = string.format("Nearest chest is %d m away. Place an %s within 8 m and label it [%s] for linked crafting.",
                    math.floor(dist_m), ws.theme.chest_type, ws.theme.label),
            }
        elseif nearest_chest.label ~= ws.theme.label then
            recommendations[#recommendations + 1] = {
                kind = "station_mismatch",
                station = ws.name,
                theme = ws.theme,
                priority = 3,
                title = string.format("Re-label chest near %s to [%s]", ws.name, ws.theme.label),
                detail = string.format("Nearest chest is %d m away and labelled [%s]. Re-labelling to [%s] allows materials to flow automatically.",
                    math.floor(dist_m), nearest_chest.label or "Unlabelled", ws.theme.label),
            }
        end
    end

    for _, theme in ipairs(BANK_THEMES) do
        local stat = theme_stats[theme.id]
        if stat.stored_stacks > 0 and stat.chest_count == 0 then
            recommendations[#recommendations + 1] = {
                kind = "unassigned_theme",
                theme = theme,
                priority = 2,
                title = string.format("Build dedicated %s for %s", theme.chest_type, theme.name),
                detail = string.format("You have %d %s stacks scattered across mixed storage with no dedicated chest. Build a %s labelled [%s].",
                    stat.stored_stacks, theme.name, theme.chest_type, theme.label),
            }
        elseif stat.total_capacity > 0 then
            local util_pct = math.floor((stat.stored_stacks / stat.total_capacity) * 100)
            stat.util_pct = util_pct
            if util_pct >= 85 then
                recommendations[#recommendations + 1] = {
                    kind = "near_capacity",
                    theme = theme,
                    priority = 2,
                    title = string.format("Expand %s storage (%d%% full)", theme.name, util_pct),
                    detail = string.format("%s storage holds %d/%d slots (%d%%). Add another %s near %s to prevent overflow.",
                        theme.name, stat.stored_stacks, stat.total_capacity, util_pct, theme.chest_type, theme.station_name),
                }
            end
        end
    end

    if #plan.assignments > 0 then
        local preview_names = {}
        for i = 1, math.min(4, #plan.assignments) do
            preview_names[#preview_names + 1] = "[" .. plan.assignments[i].label .. "]"
        end
        recommendations[#recommendations + 1] = {
            kind = "adaptive_plan",
            priority = 2,
            title = string.format("Auto-assign %d %s role(s) via Organise Base",
                #plan.assignments, tostring(plan.tier)),
            detail = string.format("Base tier '%s' (%d chest(s)) can assign %s to free chests without overwriting existing labels.",
                tostring(plan.tier), plan.total_chests, table.concat(preview_names, ", ")),
        }
    end

    table.sort(recommendations, function(a, b) return a.priority < b.priority end)

    return {
        total_chests = #all_chests,
        unassigned_chests = #unassigned_chests,
        granularity_tier = plan.tier,
        pending_assignments = #plan.assignments,
        workstations = station_reports,
        themes = theme_stats,
        recommendations = recommendations,
    }
end

function M.auto_organise_base(opts)
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then
        return false, "Local player controller is unavailable."
    end
    local ctrl = safe_call(function() return controller.InventoryController end)
    local pawn = safe_call(function() return controller.Pawn end)
    local pawn_pos = actor_position(pawn)
    if not engine.is_valid(ctrl) or not pawn_pos then
        return false, "Inventory controller or player position is unavailable."
    end

    local s = M.settings()
    local all_chests = M.all_storage_in_reach(pawn_pos, s)
    if #all_chests == 0 then
        return false, "No storage containers found within reach (" .. tostring(s.rangeMeters) .. " m)."
    end

    local force_replan = not (type(opts) == "table" and opts.force_replan == false)
    local plan_opts = { force_replan = force_replan }
    local workstations = M.detect_workstations(pawn_pos, s.rangeMeters or 40)
    local plan = M.plan_base_roles(all_chests, workstations, plan_opts)

    local pending_labels = {}
    local queued_chests = {}
    local newly_labelled = 0
    for _, step in ipairs(plan.assignments) do
        local prev_low = tostring(step.chest.label or ""):lower()
        local next_low = tostring(step.label or ""):lower()
        local native_low = step.chest.native_name ~= nil and trim(step.chest.native_name):lower() or nil
        if prev_low ~= next_low then
            pending_labels[#pending_labels + 1] = { chest = step.chest, label = step.label }
            queued_chests[step.chest] = true
            newly_labelled = newly_labelled + 1
        elseif native_low ~= nil and (native_low == "" or (force_replan and native_low ~= next_low)) then
            pending_labels[#pending_labels + 1] = { chest = step.chest, label = step.label }
            queued_chests[step.chest] = true
        end
        step.chest.label = step.label
        step.chest.rule = M.parse_label(step.label)
    end
    for _, chest in ipairs(all_chests) do
        local is_trash = chest.rule and chest.rule.kind == "trash"
        if not queued_chests[chest] and not is_trash
            and chest.label and chest.label ~= ""
            and chest.native_name ~= nil and trim(chest.native_name) == "" then
            pending_labels[#pending_labels + 1] = { chest = chest, label = chest.label }
            queued_chests[chest] = true
        end
    end

    if is_remote_client() then
        if remote_job ~= nil then
            return false, "An Organiser job is already running on the server."
        end
        local async = async_mod()
        if not async then
            return false, "Async network scheduler is unavailable on remote server (refusing unpaced RPC burst)."
        end

        remote_job_token = remote_job_token + 1
        local token = remote_job_token
        remote_job = "auto_organise"
        report_remote_progress(string.format("Bank Sorter started (%d chest(s))...", #all_chests))

        local label_idx = 0
        local function run_sort_phase(relocated)
            local sort_chests = {}
            for _, chest in ipairs(all_chests) do
                if not (chest.rule and chest.rule.kind == "trash") then
                    sort_chests[#sort_chests + 1] = chest
                end
            end
            local sort_idx = 0
            local function next_sort_chest()
                if token ~= remote_job_token or not remote_job then
                    if token == remote_job_token then remote_job = nil end
                    return
                end
                sort_idx = sort_idx + 1
                local chest = sort_chests[sort_idx]
                if not chest then
                    if token == remote_job_token then remote_job = nil end
                    report_remote_progress(string.format(
                        "Bank Sorter: Organised %d chest(s) (%d new role(s), %d stack(s) relocated).",
                        #all_chests, newly_labelled, relocated))
                    return
                end
                local function schedule_next()
                    local ok_n = async.after(0.02, next_sort_chest)
                    if not ok_n and token == remote_job_token then remote_job = nil end
                end
                run_remote_sort(token, chest.inv, ctrl, chest.label or "chest", schedule_next)
            end
            next_sort_chest()
        end

        local function run_resort_phase()
            if token ~= remote_job_token or not remote_job then
                if token == remote_job_token then remote_job = nil end
                return
            end
            local labelled, dests = {}, {}
            for _, st in ipairs(all_chests) do
                if st.rule then
                    labelled[#labelled + 1] = st
                    if st.rule.kind ~= "trash" then dests[#dests + 1] = st end
                end
            end
            if #labelled < 2 or #dests == 0 then
                run_sort_phase(0)
                return
            end
            run_remote_resort(token, labelled, dests, ctrl, function(relocated)
                run_sort_phase(relocated)
            end)
        end

        local function next_label_step()
            if token ~= remote_job_token or not remote_job then
                if token == remote_job_token then remote_job = nil end
                return
            end
            label_idx = label_idx + 1
            local entry = pending_labels[label_idx]
            if not entry then
                if label_idx > 1 then store.save("organiser") end
                run_resort_phase()
                return
            end
            M.set_label(controller, entry.chest.actor, entry.label, { skip_save = true })
            report_remote_progress(string.format("Assigning role [%s] (%d/%d)...",
                entry.label, label_idx, #pending_labels))
            local ok_n = async.after(0.18, next_label_step)
            if not ok_n and token == remote_job_token then remote_job = nil end
        end

        local ok_sched, sched_err = async.after(0.05, next_label_step)
        if not ok_sched then
            remote_job = nil
            return false, "Failed to schedule base organise: " .. tostring(sched_err)
        end
        return true, string.format("Bank Sorter running safely (%d chest(s), %d new role(s))...",
            #all_chests, newly_labelled), {
            chests = #all_chests,
            new_labels = newly_labelled,
            moved = 0,
            async = true,
        }
    end

    for _, entry in ipairs(pending_labels) do
        M.set_label(controller, entry.chest.actor, entry.label)
    end

    local resort_ok, resort_msg, resort_data = M.resort_nearby_storage()

    local sorted_chests = 0
    for _, chest in ipairs(all_chests) do
        local ok = pcall(function() M.sort_storage(chest.inv, ctrl) end)
        if ok then sorted_chests = sorted_chests + 1 end
    end

    local moved_items = resort_data and resort_data.relocated or 0
    local message = string.format("Bank Sorter: Organised %d chest(s) (%d assigned new roles, %d item stack(s) re-sorted into bank tabs).",
        #all_chests, newly_labelled, moved_items)
    log.info("Organiser: " .. message)
    return true, message, {
        chests = #all_chests,
        new_labels = newly_labelled,
        moved = moved_items,
    }
end

function M.replan_organise_base()
    return M.auto_organise_base({ force_replan = true })
end

-- Trash Incineration ----------------------------------------------------------

function M.incinerate_storage(storage_inv, storage_actor)
    local s = M.settings()
    if not (s and s.enableTrash) then return false, "trash container deletion is disabled" end
    if not engine.is_valid(storage_inv) or not engine.is_valid(storage_actor) then
        return false, "invalid storage actor or inventory"
    end
    if M.label_of(storage_actor) ~= "Trash" then
        return false, "storage is not labelled Trash"
    end

    local controller = engine.local_controller()
    local ctrl = safe_call(function() return controller.InventoryController end)
    local pawn = safe_call(function() return controller.Pawn end)
    local pinv = safe_call(function() return controller.InventoryComponent end)
    if not engine.is_valid(ctrl) then return false, "inventory controller unavailable" end

    local contents = read_inventory_slots(storage_inv)
    if #contents == 0 then return true, "Trash container is empty." end

    local cost_amount = math.floor(tonumber(s.trashCostAmount) or 0)
    local charging = s.trashCostEnabled and cost_amount > 0
    local rune_name = s.trashCostRune or "Fire"
    if charging then
        local _, have_runes = rune_stacks(pinv, rune_name)
        if have_runes < cost_amount then
            return false, string.format("Trash requires %d %s runes to incinerate (carried: %d).",
                cost_amount, rune_name, have_runes)
        end
    end

    local destroyed_count = 0
    for _, info in ipairs(contents) do
        local ok = pcall(function()
            ctrl:DestroyItemFromInventory(storage_inv, info.slot, pawn)
        end)
        if ok then destroyed_count = destroyed_count + info.count end
    end

    if destroyed_count > 0 then
        if charging then
            charge_runes(pinv, ctrl, rune_name, cost_amount)
        end
        spawn_burn_vfx(storage_actor, s)
        local message = string.format("Trash: incinerated %d item(s).", destroyed_count)
        log.info("Organiser: " .. message)
        return true, message
    end
    return true, "No items destroyed."
end

-- The manager loads a new module before stopping the previous one. Claim the
-- registered callbacks from start, after the previous module has stopped.
local HOOK_DISPATCH = "__RSDW_PUBLIC_ORGANISER_HOOKS"
local hud
local auto_deposit_container

function M.on_storage_opened(api)
    local inv, actor = storage_from_api(api)
    if not inv then return false end
    local settings = M.settings()
    if settings.autoOpenOnStorage ~= false and hud and hud.on_storage_opened() then
        return true
    end
    if settings.autoDepositOnOpen == true then
        local name = engine.full_name(actor)
        if name and name ~= "" and auto_deposit_container ~= name then
            auto_deposit_container = name
            return M.deposit_backpack()
        end
    end
    return false
end

function M.on_storage_closed(api)
    auto_deposit_container = nil
    if hud then hud.on_storage_closed() end
    if not M.setting("enableTrash") then return end
    local inv, actor = storage_from_api(api)
    if inv and M.label_of(actor) == "Trash" then
        M.incinerate_storage(inv, actor)
    end
end

function M.arm_hooks(chest_hud)
    hud = chest_hud
    if type(RegisterHook) ~= "function" or type(ExecuteInGameThread) ~= "function" then return end

    local registry = rawget(_G, HOOK_DISPATCH)
    if not registry then
        registry = { hooks = {} }
        rawset(_G, HOOK_DISPATCH, registry)
    end
    registry.owner = M
    if registry.register ~= RegisterHook then
        registry.register = RegisterHook
        registry.hooks = {}
    end

    local methods = {
        SetInventory = "on_storage_opened",
        ToggleInventory = "on_storage_opened",
        CloseCurrentInventory = "on_storage_closed",
    }
    for name, handler in pairs(methods) do
        if not registry.hooks[name] then
            local ok = pcall(RegisterHook, "/Script/Dominion.WorldActorInventoryUIAPI:" .. name, function(ctx)
                local owner = registry.owner
                if not owner then return end
                local api = safe_call(function() return ctx:get() end)
                if not api then return end
                ExecuteInGameThread(function()
                    if registry.owner == owner then pcall(owner[handler], api) end
                end)
            end)
            if ok then registry.hooks[name] = true end
        end
    end
end

function M.stop()
    local registry = rawget(_G, HOOK_DISPATCH)
    if registry and registry.owner == M then registry.owner = nil end
    M.cancel_job()
    auto_deposit_container = nil
    hud = nil
end

return M
