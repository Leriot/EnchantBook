-- EnchantBook: browse every enchanting recipe in WoW Forever without being an enchanter.
-- Reagent prices from Auctionator or saved AH searches, and every time you open
-- someone's enchanting window the recipes they know are recorded (new ones are added).
local ADDON, ns = ...
local CALLER = "EnchantBook"
local BOOK_ICON = "Interface\\AddOns\\EnchantBook\\EnchantBookIcon"

local DB                       -- EnchantBookDB (saved)
local market = {}              -- active scope and Auction House
local linkedUntil = {}         -- recent linked profession windows (session only)
local recipes, byId, watchedItems = {}, {}, {}   -- merged list (static data + recipes learned from scans)
local frame                    -- main window

local function say(msg) print("|cff9d7cffEnchantBook|r: " .. msg) end
local function unpackResult(ok, ...) if ok then return ... end end
local function try(f, ...) if type(f) ~= "function" then return end return unpackResult(pcall(f, ...)) end
local function plain(value, kind)
  return type(value) == kind and not (issecretvalue and issecretvalue(value))
end

-- Forever character names can contain surnames and are addressed without a realm suffix.
local function characterName(name)
  if plain(name, "string") then return name:match("^([^%-]+)") end
end

local function characterKey(name)
  local character = characterName(name)
  return character and character:lower()
end

local function normalizedScopePart(value)
  if plain(value, "string") and value ~= "" then return value:lower():gsub("%s+", "") end
end

local regionIDs = { us = 1, na = 1, kr = 2, eu = 3, tw = 4, cn = 5 }
local ruleNames = { pve = "pve", pvp = "pvp", rp = "rp", rppvp = "rppvp", hc = "hc", hardcore = "hc" }

local function foreverRealmScope(realm)
  if not realm then return end
  local region, ruleset = realm:match("^camwow([a-z]+)%d*realm%d+([a-z]+)$")
  return regionIDs[region], ruleNames[ruleset]
end

function market.ReadScope()
  local project = WOW_PROJECT_ID
  local forever = WOW_PROJECT_CAMELOT ~= nil and project == WOW_PROJECT_CAMELOT
  local realm = normalizedScopePart(try(GetNormalizedRealmName)) or normalizedScopePart(try(GetRealmName))
  local region = try(GetCurrentRegion)
  if not plain(region, "number") or region < 1 then
    region = regionIDs[normalizedScopePart(try(GetCurrentRegionName))]
  end
  local realmRegion, realmRule = foreverRealmScope(realm)
  local faction = normalizedScopePart(try(UnitFactionGroup, "player"))
  local ruleset
  if forever then
    local rules = Enum and Enum.GameRule
    local active = C_GameRules and C_GameRules.IsGameRuleActive
    if rules and active then
      local pvp, rp = try(active, rules.PvPRuleset), try(active, rules.RPRuleset)
      if rules.HardcoreRuleset and try(active, rules.HardcoreRuleset) == true then
        ruleset = "hc"
      elseif plain(pvp, "boolean") and plain(rp, "boolean") then
        ruleset = rp and (pvp and "rppvp" or "rp") or (pvp and "pvp" or "pve")
      end
    end
    ruleset = ruleset or realmRule
    region = region or realmRegion
  end
  local community = forever and ruleset or (not forever and realm)
  if not project or not region or not community or (faction ~= "alliance" and faction ~= "horde") then return end
  local key = table.concat({ project, region, community }, ":")
  return { key = key, contactKey = key .. ":" .. faction, region = region, realm = realm,
    ruleset = ruleset, faction = faction }
end

function market.ContactName(name, realm)
  local character = characterName(name)
  local scope = market.scope
  if not character or not scope then return end
  local suffix = normalizedScopePart(realm) or normalizedScopePart(name:match("^[^%-]+%-(.+)$"))
  if not suffix or suffix == scope.realm then return character end
  if scope.ruleset then
    local region, ruleset = foreverRealmScope(suffix)
    if region == scope.region and ruleset == scope.ruleset then return character end
  end
end

local function rememberLastSeen(key, seenAt)
  if not key then return end
  if seenAt > (market.contacts.lastSeenByName[key] or 0) then market.contacts.lastSeenByName[key] = seenAt end
  local offlineSince = market.contacts.offlineSinceByName[key]
  if offlineSince and seenAt >= offlineSince then market.contacts.offlineSinceByName[key] = nil end
end

local function unitCharacterName(unit)
  local name, surname = try(UnitNameUnmodified or UnitName, unit)
  name = characterName(name)
  if not name then return end
  if plain(surname, "string") and surname ~= "" and not name:find(" ", 1, true) then
    return name .. " " .. surname
  end
  return name
end

local function chatAvailable()
  if try(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then
    say("Chat actions are currently restricted.")
    return false
  end
  return true
end

local function pasteInChat(text)
  if not chatAvailable() then return end
  local active = try(ChatFrameUtil and ChatFrameUtil.GetActiveWindow or ChatEdit_GetActiveWindow)
  if active and type(active.Insert) == "function" and pcall(active.Insert, active, text) then
    try(active.SetFocus, active)
    return
  end
  try(ChatFrameUtil and ChatFrameUtil.OpenChat or ChatFrame_OpenChat, text, DEFAULT_CHAT_FRAME)
end

local function whisper(name)
  if not chatAvailable() then return end
  if ChatFrameUtil and ChatFrameUtil.OpenChat then
    -- Set the recipient directly so slash-command autocomplete cannot split a surname.
    local box = try(ChatFrameUtil.OpenChat, "", DEFAULT_CHAT_FRAME)
    if box and try(function()
      box:SetTellTarget(name)
      box:SetChatType("WHISPER")
      box:UpdateHeader()
      return true
    end) then return end
  elseif not name:find(" ", 1, true) and ChatFrame_SendTell then
    try(ChatFrame_SendTell, name, DEFAULT_CHAT_FRAME)
    return
  end
  say("Could not open a whisper to " .. name .. ".")
end

-----------------------------------------------------------------------
-- data helpers
-----------------------------------------------------------------------
local QUALITY_HEX = { [0]="9d9d9d", [1]="ffffff", [2]="1eff00", [3]="0070dd", [4]="a335ee", [5]="ff8000" }

local function itemName(id, noRequest)
  local name, _, q = try(C_Item and C_Item.GetItemInfo or GetItemInfo, id)
  local d = EnchantBook_Data.items[id] or (DB and DB.extraItems[id])
  if not name and not d and not noRequest and C_Item and C_Item.RequestLoadItemDataByID then try(C_Item.RequestLoadItemDataByID, id) end
  return name or (d and d[1]) or ("item:" .. id), q or (d and d[2]) or 1
end
local function coloredItem(id)
  local n, q = itemName(id)
  return "|cff" .. (QUALITY_HEX[q] or "ffffff") .. n .. "|r"
end
local function itemIcon(id)
  return try(C_Item and C_Item.GetItemIconByID or GetItemIcon, id) or 134400
end
local function spellIcon(r)
  if r.p then return itemIcon(r.p) end
  return try(C_Spell and C_Spell.GetSpellTexture or GetSpellTexture, r.id) or 136244
end

local function pasteRecipe(r)
  if not r then return end
  local link
  if r.p then link = select(2, try(C_Item and C_Item.GetItemInfo or GetItemInfo, r.p)) end
  link = link or try(C_TradeSkillUI and C_TradeSkillUI.GetRecipeLink, r.id)
    or try(C_Spell and C_Spell.GetSpellLink or GetSpellLink, r.id)
  pasteInChat(plain(link, "string") and link ~= "" and link or r.n)
end

-- full effect text: crafted items -> their tooltip lines; enchants -> the spell's description
local function effectText(r)
  if r.p and C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local data = try(C_TooltipInfo.GetItemByID, r.p)
    if data and data.lines and #data.lines > 1 then
      local out = {}
      for i = 2, #data.lines do
        local l = data.lines[i]
        local t = l.leftText
        if t and t ~= "" and not t:find("^Sell Price") then
          if l.rightText and l.rightText ~= "" then t = t .. "   " .. l.rightText end
          local c = l.leftColor
          if c and c.GenerateHexColorMarkup then t = c:GenerateHexColorMarkup() .. t .. "|r" end
          out[#out + 1] = t
          if #out >= 10 then break end
        end
      end
      if #out > 0 then return table.concat(out, "\n") end
    end
    return nil
  end
  local desc = try(C_Spell and C_Spell.GetSpellDescription or GetSpellDescription, r.id)
  if not desc or desc == "" then
    if C_Spell and C_Spell.RequestLoadSpellData then try(C_Spell.RequestLoadSpellData, r.id) end
    return nil
  end
  return "|cffffd100" .. desc .. "|r"
end

local function hasAuctionator() return Auctionator and Auctionator.API and Auctionator.API.v1 end
local function scopedAuctionator()
  local api = hasAuctionator()
  local scope = market.scope
  if not api or not scope then return end
  if not scope.ruleset then return api end
  -- Auctionator's Forever database currently keys by ruleset alone. Use it only if
  -- its selected database identifies the same ruleset and house.
  local house = market.openHouse or scope.faction
  if house == "unknown" then return end
  local providerKey = Auctionator.State and normalizedScopePart(Auctionator.State.CurrentRealm)
  if providerKey == scope.ruleset .. house then return api end
end

local function batchSearchAPI()
  local api = hasAuctionator()
  if api and (type(api.MultiSearchExact) == "function" or type(api.MultiSearch) == "function") then return api end
end

local function auctionHouseIsOpen()
  return AuctionFrame and try(AuctionFrame.IsShown, AuctionFrame)
    or AuctionHouseFrame and try(AuctionHouseFrame.IsShown, AuctionHouseFrame)
end

local function searchNativeAH(name)
  if AuctionFrame and AuctionFrame:IsShown() and BrowseName and AuctionFrameTab1 and AuctionFrameBrowse_Search then
    AuctionFrameTab1:Click()
    if BrowseResetButton then BrowseResetButton:Click() end
    BrowseName:SetText(name)
    AuctionFrameBrowse_Search()
    return true
  end
  local house = AuctionHouseFrame
  if house and house:IsShown() and house.SendBrowseQuery and house.SearchBar then
    house:GetCategoriesList():SetSelectedCategory(nil)
    house:SendBrowseQuery(name, nil, nil, {})
    house.SearchBar:SetSearchText(name)
    return true
  end
end
local AH_PRICE_LIFETIME = 7 * 24 * 60 * 60

local function positiveNumber(value)
  return plain(value, "number") and value > 0
end

function market.Prices(create)
  local scope = market.scope
  if not scope then return end
  local house = market.openHouse or scope.faction
  if house == "unknown" then return end
  local key = scope.key .. ":" .. house
  local byMarket = EnchantBookAHPrices.byMarket
  if create and not byMarket[key] then byMarket[key] = {} end
  return byMarket[key]
end

function market.UpdateHouse(open)
  market.openHouse = nil
  if not open then return end
  local rawFaction = try(UnitFactionGroup, "npc")
  local faction = normalizedScopePart(rawFaction)
  local npcExists = try(UnitExists, "npc")
  if faction == "alliance" or faction == "horde" or faction == "neutral" then
    market.openHouse = faction
  elseif not (issecretvalue and issecretvalue(rawFaction)) and plain(npcExists, "boolean") and npcExists then
    market.openHouse = "neutral"
  else
    market.openHouse = "unknown"
  end
end

local function savedAHPrice(id, ahPrices)
  local entry = ahPrices and ahPrices[id]
  if not entry then return end
  if type(entry) ~= "table" or not positiveNumber(entry.price) or not positiveNumber(entry.seenAt)
    or time() - entry.seenAt >= AH_PRICE_LIFETIME then
    ahPrices[id] = nil
    return
  end
  return entry.price, entry.seenAt
end

function market.HasPriceData()
  local api = hasAuctionator()
  if api and (type(api.GetVendorPriceByItemID) == "function" or (scopedAuctionator() and type(api.GetAuctionPriceByItemID) == "function")) then return true end
  local ahPrices = market.Prices()
  if ahPrices then
    for id in pairs(ahPrices) do
      if savedAHPrice(id, ahPrices) then return true end
    end
  end
  return false
end

local ahPriceEvents = {
  AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = true, AUCTION_HOUSE_BROWSE_RESULTS_ADDED = true,
  ITEM_KEY_ITEM_INFO_RECEIVED = true,
  COMMODITY_SEARCH_RESULTS_UPDATED = true, COMMODITY_SEARCH_RESULTS_ADDED = true,
  ITEM_SEARCH_RESULTS_UPDATED = true, ITEM_SEARCH_RESULTS_ADDED = true,
  AUCTION_ITEM_LIST_UPDATE = true,
}

local function recordAHPrices(event, key)
  if not auctionHouseIsOpen() then return end
  if not market.openHouse or market.openHouse == "unknown" then market.UpdateHouse(true) end
  local ahPrices = market.Prices(true)
  if not ahPrices then return end
  local best = {}
  local function record(id, price)
    if positiveNumber(id) and watchedItems[id] and positiveNumber(price) and (not best[id] or price < best[id]) then
      best[id] = price
    end
  end
  local house = C_AuctionHouse
  if event == "AUCTION_ITEM_LIST_UPDATE" then
    local count = try(GetNumAuctionItems, "list")
    if not positiveNumber(count) then return end
    for i = 1, count do
      local _, _, quantity, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = try(GetAuctionItemInfo, "list", i)
      if positiveNumber(buyout) and positiveNumber(quantity) then
        if not positiveNumber(id) then
          local link = try(GetAuctionItemLink, "list", i)
          id = plain(link, "string") and tonumber(link:match("item:(%d+)")) or nil
        end
        record(id, buyout / quantity)
      end
    end
  elseif not house then
    return
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
      or event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    local onlyID
    if event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
      if not positiveNumber(key) or not watchedItems[key] then return end
      onlyID = key
    end
    local results = try(house.GetBrowseResults)
    if not plain(results, "table") then return end
    for _, result in ipairs(results) do
      if plain(result, "table") and plain(result.itemKey, "table") then
        local id = result.itemKey.itemID
        if positiveNumber(id) and (not onlyID or id == onlyID) and watchedItems[id]
          and positiveNumber(result.minPrice) and positiveNumber(result.totalQuantity) then
          -- Browse gives unit prices for commodities. Item buyouts come from the listing view.
          local info = try(house.GetItemKeyInfo, result.itemKey)
          if plain(info, "table") and plain(info.isCommodity, "boolean") and info.isCommodity then
            record(id, result.minPrice)
          end
        end
      end
    end
  else
    local commodity = event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED"
    local id, getCount, getResult
    if commodity then
      id, getCount, getResult = key, house.GetNumCommoditySearchResults, house.GetCommoditySearchResultInfo
    else
      id = plain(key, "table") and key.itemID
      getCount, getResult = house.GetNumItemSearchResults, house.GetItemSearchResultInfo
    end
    if not positiveNumber(id) or not watchedItems[id] then return end
    local count = try(getCount, key)
    if not positiveNumber(count) then return end
    for i = 1, count do
      local result = try(getResult, key, i)
      if plain(result, "table") and positiveNumber(result.quantity) then
        if commodity then record(id, result.unitPrice)
        elseif positiveNumber(result.buyoutAmount) then record(id, result.buyoutAmount / result.quantity) end
      end
    end
  end
  local now = time()
  local changed = false
  for id, price in pairs(best) do
    local previous = ahPrices[id]
    if type(previous) ~= "table" or previous.price ~= price or previous.seenAt ~= now then
      ahPrices[id] = { price = price, seenAt = now }
      changed = true
    end
  end
  return changed
end

local function unitPrice(id, prices)
  local row = prices[id]
  if not row then
    local api = hasAuctionator()
    local priceAPI = scopedAuctionator()
    local auction = priceAPI and try(priceAPI.GetAuctionPriceByItemID, CALLER, id)
    local vendor = api and try(api.GetVendorPriceByItemID, CALLER, id)
    if not positiveNumber(auction) then auction = nil end
    if not positiveNumber(vendor) then vendor = nil end
    local savedAt
    if not auction then auction, savedAt = savedAHPrice(id, market.Prices()) end
    row = { auction or vendor, not auction and vendor ~= nil, vendor, savedAt }
    prices[id] = row
  end
  return row[1], row[2], row[3], row[4]
end
local function recipeCost(r, prices)
  local total, missing, includesSaved = 0, 0, false
  for _, rg in ipairs(r.r) do
    local p, _, _, savedAt = unitPrice(rg[1], prices)
    includesSaved = includesSaved or savedAt ~= nil
    if p then total = total + p * rg[2] else missing = missing + 1 end
  end
  return total, missing, includesSaved
end
local function money(total)
  local copper = math.floor(total + 0.5)
  local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
  copper = copper % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 then parts[#parts + 1] = silver .. "s" end
  if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. "c" end
  return table.concat(parts, " ")
end

local function costLabel(total, missing, compact)
  if missing > 0 and total == 0 then return "Unpriced" end
  local amount = money(total)
  if missing == 0 then return amount end
  return "≥" .. amount .. (compact and "" or (" (" .. missing .. " unpriced)"))
end

local function priceSources(recipe, prices)
  local api = hasAuctionator()
  local auctionator, vendor, saved, maxAge, unknownAge
  for _, reagent in ipairs(recipe.r) do
    local price, vendorOnly, _, savedAt = unitPrice(reagent[1], prices)
    if savedAt then
      saved = math.min(saved or savedAt, savedAt)
    elseif vendorOnly then
      vendor = true
    elseif price then
      auctionator = true
      local age = try(api and api.GetAuctionAgeByItemID, CALLER, reagent[1])
      if plain(age, "number") and age >= 0 then maxAge = math.max(maxAge or age, age)
      else unknownAge = true end
    end
  end
  local sources = {}
  if auctionator then
    local age = unknownAge and "age unavailable" or (maxAge == 0 and "today" or (maxAge .. "d old"))
    sources[#sources + 1] = "Auctionator: " .. age
  end
  if saved then sources[#sources + 1] = "Saved AH: " .. date("%d %b %H:%M", saved) end
  if vendor then sources[#sources + 1] = "Vendor" end
  return table.concat(sources, "  ·  ")
end

local function rebuild()
  wipe(recipes); wipe(byId); wipe(watchedItems)
  for _, r in ipairs(EnchantBook_Data.recipes) do recipes[#recipes + 1] = r; byId[r.id] = r end
  for id, r in pairs(DB.extra) do
    if not byId[id] then r.id = id; r.new = true; recipes[#recipes + 1] = r; byId[id] = r end
  end
  for _, r in ipairs(recipes) do
    if r.f then watchedItems[r.f] = true end
    if r.p then watchedItems[r.p] = true end
    for _, rg in ipairs(r.r) do watchedItems[rg[1]] = true end
  end
end

-- roles: m=melee/rogue, c=caster dps, h=healer, t=tank, u=utility (professions, resistances, speed, tools)
local ROLES = {
  { key = "m", label = "Melee",   tip = "Rogue / warrior / hunter / feral:\nagility, strength, attack power, weapon procs" },
  { key = "c", label = "Caster",  tip = "Spell damage, intellect, spell crit" },
  { key = "h", label = "Healer",  tip = "Healing, spirit, mana regen, intellect" },
  { key = "t", label = "Tank",    tip = "Stamina, defense, armor, dodge, block, threat" },
  { key = "u", label = "Utility", tip = "Gathering, resistances, mount & run speed" },
}
local ROLE_NAME = {} for _, r in ipairs(ROLES) do ROLE_NAME[r.key] = r.label end
local FALLBACK_KEYS = {
  m = { "agility", "strength", "striking", "impact", "crusader", "slayer", "haste", "stealth", "attack power" },
  c = { "intellect", "spell power", "spellpower", "fire power", "frost power", "shadow power", "arcane power", "wizard oil" },
  h = { "healing", "spirit", "mana regen", "mana oil" },
  t = { "stamina", "defense", "deflect", "block", "dodge", "threat", "absorption", "protection" },
}
local function roles(r) -- bundled data carries r.ro; recipes found in-game get guessed from their name
  if r.p then return "" end
  if r.ro then return r.ro end
  local s, out = (r.n .. " " .. (r.e or "")):lower(), ""
  for _, k in ipairs({ "m", "c", "h", "t" }) do
    for _, w in ipairs(FALLBACK_KEYS[k]) do if s:find(w, 1, true) then out = out .. k break end end
  end
  r.ro = out ~= "" and out or "u"
  return r.ro
end
local SKILL_BRACKETS = {
  { label = "All skills", low = 0, high = math.huge },
  { label = "1-149 skill", low = 1, high = 149 },
  { label = "150-249 skill", low = 150, high = 249 },
  { label = "250+ skill", low = 250, high = math.huge },
}
local ENCHANT, CRAFTED_ITEM, TEMPORARY_BUFF = "Enchant", "Crafted item", "Temporary buff"
local RECIPE_TYPES = { ENCHANT, CRAFTED_ITEM, TEMPORARY_BUFF }
-- Crafted products with a temporary effect verified in Forever spell or item data.
local BUFF_PRODUCTS = {
  [217308] = true, -- Enchanted Sigil: Innovation
  [221028] = true, -- Enchanted Sigil: Living Dreams
  [228978] = true, -- Enchanted Sigil: Flowing Waters
  [228980] = true, -- Conductive Shield Coating
  [232611] = true, -- Magnificent Trollshine
  [279976] = true, -- Enchanted Lute
  [279985] = true, -- Arcane Salvager
  [279987] = true, -- Arcane Forge
}

local function recipeType(r)
  if not r.p then return ENCHANT end
  if r.c == "Oil" or BUFF_PRODUCTS[r.p] then return TEMPORARY_BUFF end
  return CRAFTED_ITEM
end

local STATS = {
  { "agi", "Agility" }, { "str", "Strength" }, { "sta", "Stamina" },
  { "int", "Intellect" }, { "spi", "Spirit" }, { "ap", "Attack power" },
  { "sp", "Spell power / dmg" }, { "heal", "Healing" }, { "mana", "Mana" },
  { "crit", "Critical strike" }, { "hit", "Hit" }, { "haste", "Haste" },
  { "dmg", "Weapon / other dmg" }, { "defense", "Defense / armor" },
  { "res", "Resistance" }, { "move", "Movement" }, { "threat", "Threat" },
  { "proc", "Triggered effects" }, { "utility", "Utility" }, { "unverified", "Unverified" },
}
local EFFECT_STATS = {
  ["Agility"] = { "Agi", "agi" }, ["Strength"] = { "Str", "str" },
  ["Stamina"] = { "Sta", "sta" }, ["Intellect"] = { "Int", "int" }, ["Spirit"] = { "Spi", "spi" },
  ["All Stats"] = { "stats", "agi str sta int spi" },
  ["Spell Power"] = { "SP", "sp" }, ["Healing Spells"] = { "heal", "heal" },
  ["Weapon Damage"] = { "Wep", "dmg" }, ["All Resistances"] = { "all res", "res" },
  ["Fire Resistance"] = { "Fire res", "res" }, ["Frost Resistance"] = { "Frost res", "res" },
  ["Nature Resistance"] = { "Nature res", "res" }, ["Shadow Resistance"] = { "Shadow res", "res" },
  ["Arcane Damage"] = { "Arcane", "sp" }, ["Fire Damage"] = { "Fire", "sp" },
  ["Frost Damage"] = { "Frost", "sp" }, ["Frost Spell Damage"] = { "Frost", "sp" },
  ["Holy Damage"] = { "Holy", "sp" }, ["Nature Damage"] = { "Nature", "sp" },
  ["Shadow Damage"] = { "Shadow", "sp" }, ["Armor"] = { "Armor", "defense" },
  ["Blocking"] = { "block", "defense" }, ["Defense"] = { "def", "defense" },
  ["Dodge"] = { "dodge", "defense" }, ["Haste"] = { "haste", "haste" }, ["Threat"] = { "threat", "threat" },
  ["Beastslaying"] = { "vs beasts", "dmg" }, ["Elemental Slayer"] = { "vs elementals", "dmg" },
  ["Fishing"] = { "Fishing", "utility" }, ["Herbalism"] = { "Herbalism", "utility" },
  ["Mining"] = { "Mining", "utility" }, ["Skinning"] = { "Skinning", "utility" },
}

local function recipeEffect(r)
  local curated = EnchantBook_Effects and EnchantBook_Effects[r.id]
  if curated then return curated[1], curated[2] end
  if not r.p and r.e then
    local stat, amount = r.e:match("^([%a ]+) (%+%d+%%?)$")
    if not amount then amount, stat = r.e:match("^(%+%d+%%?) ([%a ]+)$") end
    local info = stat and EFFECT_STATS[stat]
    if info then return amount .. " " .. info[1], info[2] end
  end
  return "Unverified", "unverified"
end

local function skillColor(skill)
  if skill < 150 then return "a6a6a6" end
  if skill < 200 then return "67da7b" end
  if skill <= 250 then return "ffe170" end
  return "ffa655"
end

-----------------------------------------------------------------------
-- scanning someone's (or your own) enchanting window
-----------------------------------------------------------------------
local function looksLikeEnchanting(ids)
  local T = C_TradeSkillUI
  local info = T and try(T.GetBaseProfessionInfo)
  if info and (info.professionID == 333 or info.parentProfessionID == 333 or info.professionID == 2940 or info.parentProfessionID == 2940) then return true end
  local hits = 0
  for _, id in ipairs(ids) do if EnchantBook_Data and byId[id] then hits = hits + 1 if hits >= 3 then return true end end end
  return false
end

local function recordRecipe(id, crafter, learned)
  local now = time()
  if learned and crafter then
    market.contacts.seen[id] = market.contacts.seen[id] or {}
    market.contacts.seen[id][crafter] = now
    rememberLastSeen(characterKey(crafter), now)
  end
  DB.exists[id] = true
  if not learned and not byId[id] then return false end
  local old = DB.extra[id]
  if byId[id] and (byId[id] ~= old or (old.n ~= "Recipe " .. id and #old.r > 0)) then return false end
  -- not in the bundled data: build an entry from the schematic
  local T = C_TradeSkillUI
  local info = try(T.GetRecipeInfo, id) or {}
  local sch = try(T.GetRecipeSchematic, id, false)
  local rg = {}
  if sch and sch.reagentSlotSchematics then
    for _, slot in ipairs(sch.reagentSlotSchematics) do
      local first = slot.reagents and slot.reagents[1]
      if first and first.itemID then
        rg[#rg + 1] = { first.itemID, slot.quantityRequired or 1 }
        local n, _, q = try(C_Item and C_Item.GetItemInfo or GetItemInfo, first.itemID)
        if n then DB.extraItems[first.itemID] = { n, q or 1 } end
      end
    end
  end
  local name = info.name or (sch and sch.name)
  if not name or not sch or not sch.reagentSlotSchematics then return false end
  local entry = old or { g = 0, y = 0, e = "", t = "", foundBy = crafter, foundAt = now }
  entry.n = name
  entry.c = name:match("^Enchant (.-) %- ") or "Other"
  entry.p = sch.outputItemID ~= 0 and sch.outputItemID or nil
  entry.r, entry.ro = rg, nil
  DB.extra[id] = entry
  if old then return false end
  return true
end

local lastScan = 0
local LINKED_ONLINE_FOR = 5 * 60
local function scan()
  local T = C_TradeSkillUI
  local crafter, linked
  local ids = {}
  if T and T.GetAllRecipeIDs then
    ids = try(T.GetAllRecipeIDs) or {}
    local isLinked, who = try(T.IsTradeSkillLinked)
    linked = isLinked
    if isLinked then
      crafter = market.ContactName(who)
      if crafter then
        for _, unit in ipairs({ "target", "mouseover" }) do
          if characterKey(unitCharacterName(unit)) == characterKey(crafter) then
            local _, realm = try(UnitFullName, unit)
            local faction = normalizedScopePart(try(UnitFactionGroup, unit))
            if not market.ContactName(who, realm) or (faction and faction ~= market.scope.faction) then
              crafter = nil
              break
            end
          end
        end
      end
    elseif market.scope and not try(T.IsTradeSkillGuild) and not try(T.IsTradeSkillGuildMember) and not try(T.IsNPCCrafting) then
      crafter = unitCharacterName("player")
    end
  end
  if #ids == 0 or not looksLikeEnchanting(ids) then return end
  if not linked and try(T.IsNPCCrafting) then crafter = nil end
  local new, learnedCount = 0, 0
  for _, id in ipairs(ids) do
    local info = try(T.GetRecipeInfo, id)
    local learned = info and info.learned
    if learned then learnedCount = learnedCount + 1 end
    if recordRecipe(id, crafter, learned) then new = new + 1 end
  end
  if new > 0 then rebuild() end
  if linked and crafter and learnedCount > 0 then
    local key = characterKey(crafter)
    local untilTime = GetTime() + LINKED_ONLINE_FOR
    linkedUntil[key] = untilTime
    C_Timer.After(LINKED_ONLINE_FOR, function()
      if linkedUntil[key] ~= untilTime then return end
      linkedUntil[key] = nil
      if frame and frame:IsShown() then frame:RefreshPresence() end
    end)
  end
  if crafter and GetTime() - lastScan > 5 then
    say(string.format("recorded %s's enchanting (%d known%s).", crafter, learnedCount,
      new > 0 and (", |cff00ff00" .. new .. " new recipe" .. (new > 1 and "s" or "") .. " added|r") or ""))
  end
  lastScan = GetTime()
  if frame and frame:IsShown() then frame:RefreshPresence(true) end
end

-----------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------
local ROW_H, MARGIN, PANE_GAP, SCROLL_GUTTER = 24, 18, 30, 24
local FILTER_GAP = 5
local EFFECT_MAX_WIDTH, COST_WIDTH, COLUMN_GAP = 104, 96, 8
local CATS = { "All" }
local sorts = { "Skill", "Name", "Cost", "Slot" }
local COLUMNS = { presenceX = 52, presenceWidth = 19, slotX = 77 }
local equipment = {
  missingColor = { 1, 0.43, 0.43 },
  slots = {
    { "Head", "HeadSlot" }, { "Necklace", "NeckSlot" }, { "Shoulders", "ShoulderSlot" },
    { "Cloak", "BackSlot" }, { "Chest", "ChestSlot" }, { "Bracer", "WristSlot" },
    { "Gloves", "HandsSlot" }, { "Legs", "LegsSlot" }, { "Boots", "FeetSlot" },
    { "Main hand", "MainHandSlot" }, { "Off hand", "SecondaryHandSlot" }, { "Ranged", "RangedSlot" },
  },
}
equipment.status = {
  missing = { label = "Missing", color = equipment.missingColor },
  enchanted = { label = "Enchanted", color = { 0.50, 0.82, 0.53 } },
  empty = { label = "Empty", color = { 0.60, 0.56, 0.51 } },
  pending = { label = "Unavailable", color = { 0.60, 0.56, 0.51 } },
  ineligible = { label = "Ineligible", color = { 0.60, 0.56, 0.51 } },
}

local function equippedEnhancement(slotID)
  if not slotID then return "pending" end
  local ok, link = pcall(GetInventoryItemLink, "player", slotID)
  if not ok or (issecretvalue and issecretvalue(link)) then return "pending" end
  if link == nil then
    local hasItemID, itemID = pcall(GetInventoryItemID, "player", slotID)
    if hasItemID and not (issecretvalue and issecretvalue(itemID)) and itemID == nil then return "empty" end
  elseif type(link) == "string" then
    -- The permanent enchant field also holds armor kits, scopes and other applied enhancements.
    local enchant = link:match("item:%d+:(%d*):") or link:match("^item:%d+:(%d*)$")
    if (tonumber(enchant) or 0) > 0 then return "enchanted", link end
    local lineTypes = Enum and Enum.TooltipDataLineType
    local permanent = lineTypes and (lineTypes.ItemEnchantmentPermanent or lineTypes.ItemEnchant)
    if permanent then
      local data = try(C_TooltipInfo and C_TooltipInfo.GetInventoryItem, "player", slotID)
      if plain(data, "table") and plain(data.lines, "table") then
        for _, line in ipairs(data.lines) do
          if plain(line, "table") and plain(line.type, "number") and line.type == permanent then
            return "enchanted", link
          end
        end
      end
    end
    if enchant then return "missing", link end
  end
  return "pending"
end

function equipment.Read()
  local gear, missing, pending = {}, {}, false
  local itemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
  for i, slot in ipairs(equipment.slots) do
    local label, token = slot[1], slot[2]
    local status, link = equippedEnhancement(try(GetInventorySlotInfo, token))
    gear[i] = status
    if status == "pending" then pending = true end
    if status == "missing" then
      if token == "RangedSlot" then
        local _, _, _, equipLocation, _, class, subclass = try(itemInfoInstant, link)
        if not plain(equipLocation, "string") or not plain(class, "number") or not plain(subclass, "number") then
          gear[i], pending = "pending", true
        elseif class == 2 and (subclass == 2 or subclass == 3 or subclass == 18) then -- bows, guns, crossbows
          missing[label] = true
        else
          gear[i] = "ineligible"
        end
      elseif token == "MainHandSlot" or token == "SecondaryHandSlot" then
        local _, _, _, equipLocation = try(itemInfoInstant, link)
        if not plain(equipLocation, "string") then
          pending = true
        else
          if equipLocation == "INVTYPE_SHIELD" then
            missing.Shield = true
          elseif equipLocation == "INVTYPE_HOLDABLE" then
            missing["Off-Hand"] = true
          elseif equipLocation == "INVTYPE_2HWEAPON" then
            missing.Weapon, missing["2H Weapon"] = true, true
          elseif equipLocation == "INVTYPE_WEAPON" or equipLocation == "INVTYPE_WEAPONMAINHAND"
            or equipLocation == "INVTYPE_WEAPONOFFHAND" then
            missing.Weapon = true
          end
        end
      else
        missing[label] = true
      end
    end
  end
  return gear, missing, pending
end

local function recipeDisplayName(r)
  if r.p then return r.n end
  local name = r.n:gsub("^Enchant ", "")
  local prefix = r.c .. " - "
  return name:sub(1, #prefix) == prefix and name:sub(#prefix + 1) or name
end

local function buildCats()
  local seen = {}
  for _, r in ipairs(recipes) do
    if not r.p then seen[r.c] = true end
  end
  wipe(CATS); CATS[1] = "All"
  local t = {}
  for c in pairs(seen) do t[#t + 1] = c end
  table.sort(t)
  for _, c in ipairs(t) do CATS[#CATS + 1] = c end
end

local function matches(r, text, names, effect)
  if text == "" then return true end
  if r.n:lower():find(text, 1, true) or (r.e or ""):lower():find(text, 1, true)
    or effect:lower():find(text, 1, true) then return true end
  for _, rg in ipairs(r.r) do
    local id = rg[1]
    if not names[id] then names[id] = itemName(id, true):lower() end
    if names[id]:find(text, 1, true) then return true end
  end
  return false
end

local ONLINE, UNKNOWN, OFFLINE = 1, 2, 3
local STATUS_LABELS = { [ONLINE] = "|cff60df79Online|r", [OFFLINE] = "|cffff7474Offline|r" }
local WHO_COOLDOWN, WHO_TIMEOUT, WHO_VALID_FOR = 5, 15, 120
local whoStatus = {}
local pendingWho, whoCooldownUntil
local OFFLINE_RETENTION = 14 * 24 * 60 * 60
local readPresence

local function updateContactRetention(states)
  local now = time()
  local expired = {}
  for key, status in pairs(states) do
    if market.contacts.lastSeenByName[key] then
      if status == ONLINE then
        rememberLastSeen(key, now)
      elseif status == OFFLINE then
        local since = market.contacts.offlineSinceByName[key]
        if not since or since < market.contacts.lastSeenByName[key] or since > now then
          market.contacts.offlineSinceByName[key] = now
        elseif now - since > OFFLINE_RETENTION then
          expired[key] = true
        end
      end
    end
  end
  if not next(expired) then return false end
  for id, enchanters in pairs(market.contacts.seen) do
    for name in pairs(enchanters) do
      if expired[characterKey(name)] then enchanters[name] = nil end
    end
    if not next(enchanters) then market.contacts.seen[id] = nil end
  end
  for key in pairs(expired) do
    market.contacts.offlineSinceByName[key], market.contacts.lastSeenByName[key], whoStatus[key], linkedUntil[key] = nil, nil, nil, nil
  end
  return true
end

local function whoAPI()
  local api = C_FriendList
  if api and type(api.GetNumWhoResults) == "function" and type(api.GetWhoInfo) == "function" then return api end
end

local function refreshPresence()
  if frame and frame:IsShown() then
    frame:RefreshPresence()
  else
    readPresence()
  end
end

local function finishWho(status)
  local request = pendingWho
  if not request then return end
  pendingWho = nil
  if request.finder then request.finder.checked[request.key] = true end
  if status then
    whoStatus[request.key] = { status = status, expiresAt = GetTime() + WHO_VALID_FOR }
    if status == ONLINE then rememberLastSeen(request.key, time())
    else linkedUntil[request.key] = nil end
    C_Timer.After(WHO_VALID_FOR, refreshPresence)
  end
  refreshPresence()
end

local function checkWho(crafter, finder)
  local api = whoAPI()
  if not api or not chatAvailable() then return end
  if pendingWho or whoCooldownUntil then
    say("Wait a moment before another /who lookup.")
    return
  end

  local query = 'n-"' .. crafter.name .. '"'
  local request = { key = crafter.key, name = crafter.name, finder = finder }
  pendingWho, whoCooldownUntil = request, GetTime() + WHO_COOLDOWN
  C_Timer.After(WHO_COOLDOWN, function()
    whoCooldownUntil = nil
    refreshPresence()
  end)
  local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social
  local ok, result = pcall(api.SendWho, query, origin)
  if ok and result == false then
    pendingWho = nil
    say("WoW declined the /who lookup. Try again in a moment.")
    refreshPresence()
    return
  end
  if not ok then
    local openChat = ChatFrameUtil and ChatFrameUtil.OpenChat or ChatFrame_OpenChat
    if type(openChat) ~= "function" or not pcall(openChat, (SLASH_WHO1 or "/who") .. " " .. query, DEFAULT_CHAT_FRAME) then
      pendingWho = nil
      say("/who is unavailable right now.")
      refreshPresence()
      return
    end
    say("Press Enter to run the /who lookup.")
  end

  refreshPresence()
  C_Timer.After(WHO_TIMEOUT, function()
    if pendingWho ~= request then return end
    say("No exact /who match for " .. request.name .. " was returned.")
    finishWho()
  end)
end

local function receiveWho()
  local request, api = pendingWho, whoAPI()
  if not request or not api then return end
  local count, total = try(api.GetNumWhoResults)
  if not plain(count, "number") then return end
  if count == 0 and plain(total, "number") and total == 0 then
    finishWho(OFFLINE)
    return
  end
  -- Nonempty results can belong to another search. Require the exact name.
  for i = 1, count do
    local info = try(api.GetWhoInfo, i)
    local name = plain(info, "table") and market.ContactName(info.fullName)
    if name and name:lower() == request.key then
      finishWho(ONLINE)
      return
    end
  end
end

local function matchesWhoLine(message, template)
  if not plain(template, "string") then return false end
  local pattern = template:gsub("%%[%d]+%$([sd])", "%%%1")
    :gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    :gsub("%%s", ".-"):gsub("%%d", "%%d+")
  return message:match("^" .. pattern .. "$") ~= nil
end

local function receiveWhoChat(message)
  if not pendingWho or not plain(message, "string") then return end
  local zero = try(string.format, WHO_NUM_RESULTS, 0)
  if zero then zero = zero:gsub("|4[^:;]+:([^;]+);", "%1") end
  message = message:gsub("|4[^:;]+:([^;]+);", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  if message == zero or message:lower():match("^%s*0 players total%.?%s*$") then
    finishWho(OFFLINE)
    return
  end
  local name = message:match("|Hplayer:([^|:]+)[^|]*|h")
  if characterKey(market.ContactName(name)) == pendingWho.key and
    (matchesWhoLine(message, WHO_LIST_FORMAT) or matchesWhoLine(message, WHO_LIST_GUILD_FORMAT)) then
    finishWho(ONLINE)
  end
end

readPresence = function()
  local states = {}
  local function add(name, connected)
    name = market.ContactName(name)
    if not name or not plain(connected, "boolean") then return end
    local key = name:lower()
    if connected or not states[key] then states[key] = connected and ONLINE or OFFLINE end
  end
  local function addUnit(unit)
    local faction = normalizedScopePart(try(UnitFactionGroup, unit))
    if not market.scope or (faction and faction ~= market.scope.faction) then return end
    local _, realm = try(UnitFullName, unit)
    local name = market.ContactName(unitCharacterName(unit), realm)
    if name then add(name, try(UnitIsConnected, unit)) end
  end
  local friends = C_FriendList
  for i = 1, try(friends and friends.GetNumFriends) or 0 do
    local info = try(friends.GetFriendInfoByIndex, i)
    if plain(info, "table") then add(info.name, info.connected) end
  end
  if try(IsInGuild) then
    for i = 1, try(GetNumGuildMembers) or 0 do
      local name, _, _, _, _, _, _, _, connected = try(GetGuildRosterInfo, i)
      add(name, connected)
    end
  end
  if try(IsInRaid) then
    for i = 1, try(GetNumGroupMembers) or 0 do addUnit("raid" .. i) end
  else
    for i = 1, try(GetNumSubgroupMembers) or 0 do addUnit("party" .. i) end
  end
  local targetIsPlayer = try(UnitIsPlayer, "target")
  if plain(targetIsPlayer, "boolean") and targetIsPlayer then addUnit("target") end
  local ownName = unitCharacterName("player")
  add(ownName, true)
  local now = GetTime()
  for key, result in pairs(whoStatus) do
    if result.expiresAt <= now then whoStatus[key] = nil
    elseif not states[key] then states[key] = result.status end
  end
  local recentLinked = {}
  for key, expiresAt in pairs(linkedUntil) do
    if expiresAt <= now then linkedUntil[key] = nil
    elseif not states[key] then states[key], recentLinked[key] = ONLINE, true end
  end
  local contactsRemoved = updateContactRetention(states)
  return states, ownName and ownName:lower(), recentLinked, contactsRemoved
end

local function knownBy(id, presence)
  local list = {}
  local byName = {}
  for who, seenAt in pairs(market.contacts.seen[id] or {}) do
    local name = characterName(who)
    if name then
      local key = name:lower()
      local previous = byName[key]
      if not previous or seenAt > previous.seenAt or (seenAt == previous.seenAt and name < previous.name) then
        byName[key] = { key = key, name = name, seenAt = seenAt,
          lastSeenAt = math.max(seenAt, market.contacts.lastSeenByName[key] or 0), status = presence[key] or UNKNOWN }
      end
    end
  end
  for _, crafter in pairs(byName) do list[#list + 1] = crafter end
  table.sort(list, function(a, b)
    if a.status ~= b.status then return a.status < b.status end
    if a.lastSeenAt ~= b.lastSeenAt then return a.lastSeenAt > b.lastSeenAt end
    if a.seenAt ~= b.seenAt then return a.seenAt > b.seenAt end
    return a.key < b.key
  end)
  return list
end

function market.LastSeenLabel(seenAt)
  local age = math.max(0, time() - seenAt)
  if age < 60 then return "Last seen just now" end
  if age < 86400 then
    local hours = math.floor(age / 3600)
    local count, unit = hours > 0 and hours or math.floor(age / 60), hours > 0 and "hour" or "minute"
    return ("Last seen %d %s%s ago"):format(count, unit, count == 1 and "" or "s")
  end
  return "Last seen " .. date("%d %b %Y", seenAt)
end

local function recipeAvailability(id, presence)
  local seen = market.contacts.seen[id]
  if not seen or not next(seen) then return end
  for who in pairs(seen) do
    if presence[characterKey(who)] == ONLINE then return true end
  end
  return false
end

local function makeFrame()
  local f = CreateFrame("Frame", "EnchantBookFrame", UIParent)
  f.presence = {}
  f:SetPoint(DB.pos and DB.pos[1] or "CENTER", UIParent, DB.pos and DB.pos[3] or "CENTER", DB.pos and DB.pos[4] or 0, DB.pos and DB.pos[5] or 0)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing(); local a, _, b, x, y = s:GetPoint(); DB.pos = { a, nil, b, x, y } end)
  f:SetFrameStrata("HIGH")
  tinsert(UISpecialFrames, "EnchantBookFrame")
  local border = f:CreateTexture(nil, "BACKGROUND", nil, -2)
  border:SetAllPoints()
  border:SetColorTexture(0.31, 0.25, 0.19, 1)
  local surface = f:CreateTexture(nil, "BACKGROUND", nil, -1)
  surface:SetPoint("TOPLEFT", 1, -1)
  surface:SetPoint("BOTTOMRIGHT", -1, 1)
  surface:SetColorTexture(0.115, 0.102, 0.090, 1)
  local titleBar = f:CreateTexture(nil, "BORDER")
  titleBar:SetPoint("TOPLEFT", 1, -1)
  titleBar:SetPoint("TOPRIGHT", -1, -1)
  titleBar:SetHeight(26)
  titleBar:SetColorTexture(0.075, 0.067, 0.060, 1)
  local titleRule = f:CreateTexture(nil, "BORDER")
  titleRule:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT")
  titleRule:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT")
  titleRule:SetHeight(1)
  titleRule:SetColorTexture(0.42, 0.33, 0.24, 0.70)
  f.TitleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.TitleText:SetPoint("CENTER", titleBar)
  f.TitleText:SetTextColor(0.98, 0.87, 0.67)
  local version = try(C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata, ADDON, "Version")
  local title = version and ("EnchantBook " .. version) or "EnchantBook"
  f.TitleText:SetText(("|T%s:17:17:0:0|t  %s"):format(BOOK_ICON, title))

  -- search
  local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  search:SetHeight(24); search:SetPoint("TOPLEFT", MARGIN + 3, -34); search:SetAutoFocus(false)
  local searchPending
  search:HookScript("OnTextChanged", function()
    if searchPending then return end
    searchPending = true
    C_Timer.After(0.12, function()
      searchPending = false
      if f:IsShown() then f:Refresh(true) end
    end)
  end)
  f.search = search

  local function control(text, parent, quiet)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(24)
    if not quiet then
      local bg = b:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(0.15, 0.13, 0.11, 0.92)
      local trim = b:CreateTexture(nil, "BORDER")
      trim:SetPoint("BOTTOMLEFT", 0, 0)
      trim:SetPoint("BOTTOMRIGHT", 0, 0)
      trim:SetHeight(1)
      trim:SetColorTexture(0.63, 0.46, 0.28, 0.70)
    end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.text:SetWordWrap(false)
    b.text:SetTextColor(0.87, 0.80, 0.69)
    b.text:SetText(text)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    function b:SetText(value) self.text:SetText(value) end
    return b
  end

  local function tooltip(button, text)
    button:SetScript("OnEnter", function(s)
      GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
      GameTooltip:SetText(text)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
  end

  local close = control("×", f, true)
  close:SetSize(24, 22)
  close:SetPoint("TOPRIGHT", -5, -3)
  close:SetScript("OnClick", function() f:Hide() end)
  tooltip(close, "Close EnchantBook")
  f.CloseButton = close

  -- Draw the caret independently of the active UI font.
  local function caret(parent)
    local icon = CreateFrame("Frame", nil, parent)
    icon:SetSize(7, 4)
    local strokes = {}
    for i = 1, 4 do
      local stroke = icon:CreateTexture(nil, "ARTWORK")
      stroke:SetSize(9 - 2 * i, 1)
      stroke:SetColorTexture(0.86, 0.70, 0.49, 1)
      strokes[i] = stroke
    end
    function icon:SetAscending(up)
      if self.ascending == up then return end
      self.ascending = up
      for i, stroke in ipairs(strokes) do
        stroke:SetPoint("TOP", self, "TOP", 0, up and i - 4 or 1 - i)
      end
    end
    icon:SetAscending(false)
    return icon
  end

  local function markDropdown(button)
    local icon = caret(button)
    icon:SetPoint("RIGHT", -7, 0)
    button.text:SetPoint("RIGHT", -18, 0)
  end

  f.catIdx, f.sortIdx, f.recipeType = 1, 1, ENCHANT
  local reset = control("×", f, true)
  reset:SetWidth(27)
  tooltip(reset, "Clear the search and filters")
  local stats = control("Stats", f, true)
  stats:SetWidth(76)
  reset:SetPoint("RIGHT", stats, "LEFT", -FILTER_GAP, 0)
  tooltip(stats, "Show recipes that match any checked stat")
  local gearButton = control("Gear", f, true)
  gearButton:SetWidth(69)
  stats:SetPoint("RIGHT", gearButton, "LEFT", -FILTER_GAP, 0)
  tooltip(gearButton, "Check permanent enhancements on your equipped gear")

  local cat = control("All slots", f)
  cat:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -3, -8)
  cat.text:SetJustifyH("LEFT")
  local skill = control("All skills", f)
  skill:SetWidth(91)
  skill.text:SetJustifyH("LEFT")
  tooltip(skill, "Show only recipes that turn yellow within this skill bracket")
  local kind = control("Enchants", f, true)
  kind:SetWidth(110)
  tooltip(kind, "Browse enchants, crafted items or temporary buffs")
  local filters = control("Filters", f, true)
  filters:SetWidth(68)
  kind:SetPoint("RIGHT", filters, "LEFT", -FILTER_GAP, 0)
  tooltip(filters, "Filter by role or show seen recipes only")
  for _, button in ipairs({ cat, skill, kind, filters, stats, gearButton }) do markDropdown(button) end

  local menu = CreateFrame("Frame", nil, f)
  menu:SetFrameStrata("DIALOG")
  menu:EnableMouse(true)
  menu:Hide()
  local menuEdge = menu:CreateTexture(nil, "BACKGROUND")
  menuEdge:SetAllPoints()
  menuEdge:SetColorTexture(0.47, 0.36, 0.25, 1)
  local menuBg = menu:CreateTexture(nil, "BORDER")
  menuBg:SetPoint("TOPLEFT", 1, -1)
  menuBg:SetPoint("BOTTOMRIGHT", -1, 1)
  menuBg:SetColorTexture(0.09, 0.08, 0.07, 0.99)
  menu.items = {}

  local function showOption(b)
    local option = b.option
    local disabled = option.heading or (option.checkbox and option.count == 0 and not option.selected)
    b:SetEnabled(not disabled)
    b:SetText(option.label)
    b.check:SetShown(option.checkbox == true)
    if option.checkbox then
      b.check.mark:SetShown(option.selected == true)
      if option.selected then
        b.check.edge:SetColorTexture(0.77, 0.60, 0.38, 1)
        b.check.fill:SetColorTexture(0.31, 0.23, 0.15, 1)
      elseif disabled then
        b.check.edge:SetColorTexture(0.28, 0.25, 0.22, 1)
        b.check.fill:SetColorTexture(0.13, 0.12, 0.11, 1)
      else
        b.check.edge:SetColorTexture(0.49, 0.41, 0.32, 1)
        b.check.fill:SetColorTexture(0.14, 0.12, 0.10, 1)
      end
    end
    b.text:SetPoint("LEFT", option.checkbox and 28 or 6, 0)
    if option.missing then b.text:SetTextColor(unpack(equipment.missingColor))
    elseif disabled and not option.status then b.text:SetTextColor(0.64, 0.58, 0.48)
    elseif option.selected then b.text:SetTextColor(1, 0.82, 0.49)
    else b.text:SetTextColor(0.90, 0.87, 0.82) end
    if option.status then
      b.num:SetWidth(77)
      b.num:SetTextColor(unpack(option.status.color))
      b.num:SetText(option.status.label)
    else
      b.num:SetWidth(25)
      b.num:SetTextColor(0.65, 0.62, 0.58)
      b.num:SetText(option.count or (option.selected and not option.checkbox and "•" or ""))
    end
  end

  local function openMenu(anchor, options, choose, columns, alignRight)
    if menu:IsShown() and menu.anchor == anchor then menu:Hide(); return end
    menu.anchor, menu.choose = anchor, choose
    menu:ClearAllPoints()
    local corner = alignRight and "RIGHT" or "LEFT"
    menu:SetPoint("TOP" .. corner, anchor, "BOTTOM" .. corner, 0, -3)
    local perColumn = math.ceil(#options / columns)
    local itemWidth = (anchor == stats or anchor == gearButton) and 176 or 151
    local itemHeight = 23
    for i, option in ipairs(options) do
      local b = menu.items[i]
      if not b then
        b = control("", menu, true)
        b.text:SetJustifyH("LEFT")
        local check = CreateFrame("Frame", nil, b)
        check:SetSize(14, 14)
        check:SetPoint("LEFT", 6, 0)
        check.edge = check:CreateTexture(nil, "BACKGROUND")
        check.edge:SetAllPoints()
        check.fill = check:CreateTexture(nil, "ARTWORK")
        check.fill:SetPoint("TOPLEFT", 1, -1)
        check.fill:SetPoint("BOTTOMRIGHT", -1, 1)
        check.mark = check:CreateTexture(nil, "OVERLAY")
        check.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check.mark:SetSize(17, 17)
        check.mark:SetPoint("CENTER", 1, 1)
        b.check = check
        b.num = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.num:SetPoint("RIGHT", -6, 0)
        b.num:SetJustifyH("RIGHT")
        b.text:SetPoint("RIGHT", b.num, "LEFT", -5, 0)
        b:SetScript("OnClick", function(s)
          if not s.option.checkbox then menu:Hide() end
          menu.choose(s.option.value)
          f:Refresh(true)
        end)
        b:SetScript("OnEnter", function(s)
          if not s.option.tip then return end
          GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
          GameTooltip:SetText(s.option.tip, 1, 1, 1, 1, true)
          GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        menu.items[i] = b
      end
      local col, row = math.floor((i - 1) / perColumn), (i - 1) % perColumn
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 5 + col * itemWidth, -5 - row * itemHeight)
      b:SetSize(itemWidth, itemHeight)
      b.option = option
      showOption(b)
      b:Show()
    end
    for i = #options + 1, #menu.items do menu.items[i]:Hide() end
    menu:SetSize(columns * itemWidth + 10, perColumn * itemHeight + 10)
    menu:Show()
  end

  menu:SetScript("OnUpdate", function(s)
    if IsMouseButtonDown("LeftButton") and not s:IsMouseOver() and not s.anchor:IsMouseOver() then s:Hide() end
  end)
  f:HookScript("OnHide", function() menu:Hide() end)
  reset:SetScript("OnClick", function()
    menu:Hide()
    f.catIdx, f.recipeType, DB.role, DB.skillBracket, DB.onlySeen = 1, ENCHANT, nil, nil, false
    DB.highlightMissing, DB.onlyMissing = nil, nil
    wipe(DB.stats)
    search:SetText("")
    f:Refresh(true)
  end)
  cat:SetScript("OnClick", function(s)
    buildCats()
    local options = {}
    for i, name in ipairs(CATS) do
      options[i] = { label = i == 1 and "All slots" or name, value = i, count = 0, selected = i == f.catIdx }
    end
    local slotCounts = {}
    for _, r in ipairs(recipes) do
      if not r.p and (not DB.onlySeen or market.contacts.seen[r.id]) then
        options[1].count = options[1].count + 1
        slotCounts[r.c] = (slotCounts[r.c] or 0) + 1
      end
    end
    for i = 2, #CATS do
      options[i].count = slotCounts[CATS[i]] or 0
      options[i].missing = (DB.highlightMissing or DB.onlyMissing) and f.missingSlots[CATS[i]]
    end
    openMenu(s, options, function(value) f.catIdx = value end, 2)
  end)
  skill:SetScript("OnClick", function(s)
    local options = {}
    for i, bracket in ipairs(SKILL_BRACKETS) do
      options[i] = { label = bracket.label, value = i, selected = i == (DB.skillBracket or 1) }
    end
    openMenu(s, options, function(value) DB.skillBracket = value end, 1)
  end)
  kind:SetScript("OnClick", function(s)
    local options = {}
    for i, recipeKind in ipairs(RECIPE_TYPES) do
      options[i] = { label = recipeKind .. "s", value = recipeKind, selected = recipeKind == f.recipeType }
    end
    openMenu(s, options, function(value) f.recipeType = value end, 1, true)
  end)
  filters:SetScript("OnClick", function(s)
    local options = {{ label = "Seen only", value = "seen", selected = DB.onlySeen,
      tip = "Show recipes recorded in an enchanter's window" }}
    if f.recipeType == ENCHANT then
      options[#options + 1] = { label = "Role", heading = true }
      options[#options + 1] = { label = "Any role", value = false, selected = DB.role == nil }
      for _, role in ipairs(ROLES) do
        options[#options + 1] = { label = role.label, value = role.key, selected = role.key == DB.role, tip = role.tip }
      end
    end
    openMenu(s, options, function(value)
      if value == "seen" then DB.onlySeen = not DB.onlySeen
      else DB.role = value or nil end
    end, 1, true)
  end)
  stats:SetScript("OnClick", function(s)
    local options = {}
    for i, definition in ipairs(STATS) do
      local key, label = definition[1], definition[2]
      options[i] = { label = label, value = key, checkbox = true,
        selected = DB.stats[key] == true, count = f.statCounts[key] or 0 }
    end
    openMenu(s, options, function(key) DB.stats[key] = not DB.stats[key] or nil end, 2, true)
  end)
  local function gearOptions()
    local options = {
      { label = "Highlight missing", value = "highlightMissing", checkbox = true, selected = DB.highlightMissing,
        tip = "Color eligible slots red when your equipped item has no permanent enhancement" },
      { label = "Unenchanted only", value = "onlyMissing", checkbox = true, selected = DB.onlyMissing,
        tip = "Show only enchants for equipped items that are missing a permanent enhancement" },
      { label = "Equipped gear", heading = true },
    }
    for i, slot in ipairs(equipment.slots) do
      options[#options + 1] = { label = slot[1], heading = true, status = equipment.status[f.gear[i]],
        missing = (DB.highlightMissing or DB.onlyMissing) and f.gear[i] == "missing" }
    end
    return options
  end
  gearButton:SetScript("OnClick", function(s)
    openMenu(s, gearOptions(), function(key) DB[key] = not DB[key] or nil end, 1, true)
  end)
  local separator = f:CreateTexture(nil, "ARTWORK")
  separator:SetColorTexture(0.58, 0.46, 0.31, 0.32)
  separator:SetWidth(1)

  local function modernScroll(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    local bar = scroll.ScrollBar
    try(bar and bar.SetHideIfUnscrollable, bar, true)
    return scroll
  end

  local sf = modernScroll(f)
  sf:SetPoint("TOPLEFT", cat, "BOTTOMLEFT", 0, -31)
  sf:SetPoint("BOTTOMLEFT", MARGIN, 30)
  local listSurface = sf:CreateTexture(nil, "BACKGROUND")
  listSurface:SetAllPoints()
  listSurface:SetColorTexture(0.087, 0.077, 0.068, 1)
  local content = CreateFrame("Frame", nil, sf); content:SetHeight(1); sf:SetScrollChild(content)
  f.rows, f.content, f.scroll = {}, content, sf

  local head = CreateFrame("Frame", nil, f)
  head:SetPoint("BOTTOMLEFT", sf, "TOPLEFT", 0, 3)
  head:SetPoint("BOTTOMRIGHT", sf, "TOPRIGHT", 0, 3)
  head:SetHeight(18)
  local rule = head:CreateTexture(nil, "ARTWORK")
  rule:SetPoint("BOTTOMLEFT")
  rule:SetPoint("BOTTOMRIGHT")
  rule:SetHeight(1)
  rule:SetColorTexture(0.62, 0.48, 0.32, 0.55)
  local headingNames = { "Skill", "Name", "Mat cost", "Slot" }
  local sortHeaders = {}
  for index, title in ipairs(headingNames) do
    local button = control(title, head, true)
    button:SetHeight(18)
    button.sortIndex = index
    button.indicator = caret(button)
    button:SetScript("OnClick", function(s)
      menu:Hide()
      DB.sortDesc = f.sortIdx == s.sortIndex and not DB.sortDesc
      f.sortIdx = s.sortIndex
      f:Refresh(true)
    end)
    tooltip(button, "Sort by " .. title:lower())
    sortHeaders[index] = button
  end
  sortHeaders[1]:SetWidth(COLUMNS.presenceX); sortHeaders[1]:SetPoint("LEFT", 0, 1)
  sortHeaders[1].text:SetJustifyH("LEFT")
  sortHeaders[2].text:SetJustifyH("LEFT")
  sortHeaders[4]:SetPoint("LEFT", COLUMNS.slotX - 6, 1)
  sortHeaders[4].text:SetJustifyH("LEFT")
  local availability = control("•", head, true)
  availability:SetSize(COLUMNS.presenceWidth, 18)
  availability:SetPoint("LEFT", COLUMNS.presenceX, 1)
  availability.text:SetTextColor(0.76, 0.72, 0.65)
  tooltip(availability, "Enchanter availability\nGreen: a recorded enchanter is online\nRed: nobody recorded is confirmed online\nBlank: no enchanter recorded")
  sortHeaders[3]:SetWidth(COST_WIDTH); sortHeaders[3]:SetPoint("RIGHT", -2, 1)
  sortHeaders[3].text:SetJustifyH("RIGHT")
  local effectHeading = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  effectHeading:SetText("Effect")
  effectHeading:SetTextColor(0.76, 0.72, 0.65)
  effectHeading:SetJustifyH("LEFT")
  local empty = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  empty:SetPoint("TOP", sf, "TOP", 0, -40)
  empty:SetText("No recipes match these filters.")
  empty:Hide()
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.count:SetPoint("BOTTOMLEFT", MARGIN, 10)
  f.count:SetJustifyH("LEFT")
  f.count:SetWordWrap(false)

  -- Keep the cost and auction actions visible while long descriptions scroll.
  local d = CreateFrame("Frame", nil, f)
  f.detail = d
  d:SetPoint("BOTTOMRIGHT", -MARGIN, 12)
  local detailSurface = d:CreateTexture(nil, "BACKGROUND")
  detailSurface:SetPoint("TOPLEFT", -8, 8)
  detailSurface:SetPoint("BOTTOMRIGHT", 4, -4)
  detailSurface:SetColorTexture(0.135, 0.118, 0.102, 1)
  local detailScroll = modernScroll(d)
  detailScroll:SetPoint("TOPLEFT")
  detailScroll:SetPoint("BOTTOMRIGHT", -SCROLL_GUTTER, 66)
  d.scroll = detailScroll
  local body = CreateFrame("Frame", nil, detailScroll); body:SetHeight(1); detailScroll:SetScrollChild(body)
  d.body = body

  d.icon = CreateFrame("Button", nil, body); d.icon:SetSize(40, 40); d.icon:SetPoint("TOPLEFT", 0, -1)
  d.icon.tex = d.icon:CreateTexture(nil, "ARTWORK"); d.icon.tex:SetAllPoints()
  d.icon:SetScript("OnEnter", function(s)
    if not f.sel then return end
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    if f.sel.p then GameTooltip:SetItemByID(f.sel.p) else GameTooltip:SetSpellByID(f.sel.id) end
    GameTooltip:AddLine("Click to link in chat", 0.75, 0.75, 0.85)
    GameTooltip:Show()
  end)
  d.icon:SetScript("OnLeave", GameTooltip_Hide)
  d.icon:SetScript("OnClick", function() pasteRecipe(f.sel) end)
  local function bodyText(font)
    local text = body:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    text:SetSpacing(3)
    return text
  end
  d.name = bodyText("GameFontHighlightLarge")
  d.name:SetTextColor(1, 0.91, 0.76)
  local nameLink = CreateFrame("Button", nil, body)
  nameLink:SetAllPoints(d.name)
  nameLink:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  nameLink:SetScript("OnClick", function() pasteRecipe(f.sel) end)
  nameLink:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    GameTooltip:SetText("Link in chat")
    GameTooltip:Show()
  end)
  nameLink:SetScript("OnLeave", GameTooltip_Hide)
  d.sub = bodyText("GameFontHighlightSmall")
  d.desc = bodyText("GameFontHighlight")
  d.info = bodyText("GameFontHighlightSmall")
  d.rhead = bodyText("GameFontNormal")
  d.rhead:SetText("Reagents")
  d.seen = bodyText("GameFontNormal")
  local find = control("Find enchanter", body)
  find:SetSize(128, 24)
  d.find = find
  find:SetScript("OnClick", function(s)
    if not f.sel or not s:IsShown() then return end
    if f.finder and s.online then
      whisper(s.online.name)
      return
    end
    if not f.finder or not s.candidate then f.finder = { checked = {} } end
    if s.online then f:ShowRecipe(f.sel); return end
    local candidate = s.candidate or s.retry
    if candidate then checkWho(candidate, f.finder) end
  end)
  find:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    local text = s.online and (f.finder and "Whisper " or "Online: ") .. s.online.name
      or "Check recorded enchanters one at a time"
    GameTooltip:SetText(text)
    GameTooltip:Show()
  end)
  find:SetScript("OnLeave", GameTooltip_Hide)
  local function showCooldown(button)
    local seconds = math.max(1, math.ceil(whoCooldownUntil - GetTime()))
    local label = "Who cooldown " .. seconds .. "s"
    if button.text:GetText() ~= label then button:SetText(label) end
  end
  find:SetScript("OnUpdate", function(s)
    if s.showCooldown and whoCooldownUntil then showCooldown(s) end
  end)
  d.reag, d.enchanters = {}, {}
  local function enchanterRow(i)
    if d.enchanters[i] then return d.enchanters[i] end
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(33)
    row.remove = control("×", row, true)
    row.remove:SetSize(28, 22)
    row.remove:SetPoint("RIGHT")
    row.remove:SetScript("OnClick", function()
      local id = row.recipeId
      local seen = id and market.contacts.seen[id]
      if not seen or not row.crafter then return end
      for who in pairs(seen) do
        if characterKey(who) == row.crafter.key then seen[who] = nil end
      end
      if not next(seen) then market.contacts.seen[id] = nil end
      f:Refresh()
    end)
    tooltip(row.remove, "Remove this enchanter from the selected recipe")
    row.whisper = control("Whisper", row)
    row.whisper:SetSize(74, 22)
    row.whisper:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
    row.whisper:SetScript("OnClick", function()
      if row.crafter then whisper(row.crafter.name) end
    end)
    row.who = control("Who", row, true)
    row.who:SetSize(48, 22)
    row.who:SetPoint("RIGHT", row.whisper, "LEFT", -6, 0)
    row.who:SetScript("OnClick", function()
      if row.crafter then checkWho(row.crafter) end
    end)
    row.who:SetScript("OnEnter", function(s)
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:SetText("Check /who for " .. row.crafter.name)
      GameTooltip:AddLine("Lookup status lasts two minutes.", 0.8, 0.8, 0.8)
      GameTooltip:Show()
    end)
    row.who:SetScript("OnLeave", GameTooltip_Hide)
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.status:SetPoint("BOTTOMLEFT", 0, 3)
    row.status:SetJustifyH("LEFT")
    row.status:SetWordWrap(false)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 0, -3)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    d.enchanters[i] = row
    return row
  end
  local function reagentRow(i)
    if d.reag[i] then return d.reag[i] end
    local b = CreateFrame("Button", nil, body)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.55, 0.43, 0.28, i % 2 == 1 and 0.13 or 0.05)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetSize(24, 24); b.icon:SetPoint("LEFT", 6, 0)
    b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.price:SetPoint("RIGHT", -8, 0); b.price:SetJustifyH("RIGHT"); b.price:SetSpacing(2); b.price:SetWordWrap(true)
    b.qty = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.qty:SetWidth(32); b.qty:SetPoint("RIGHT", b.price, "LEFT", -8, 0); b.qty:SetJustifyH("RIGHT")
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
    b.name:SetJustifyH("LEFT"); b.name:SetWordWrap(true)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnEnter", function(s)
      if not s.item then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(s.item)
      GameTooltip:AddLine("Click to search the Auction House", 0.75, 0.75, 0.85)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:SetScript("OnClick", function(s)
      if not s.item then return end
      if IsModifiedClick("CHATLINK") then
        local link = select(2, try(C_Item and C_Item.GetItemInfo or GetItemInfo, s.item))
        pasteInChat(link or (itemName(s.item)))
      else f:SearchAH({ (itemName(s.item)) }) end
    end)
    d.reag[i] = b
    return b
  end

  local footerRule = d:CreateTexture(nil, "ARTWORK")
  footerRule:SetPoint("BOTTOMLEFT", 0, 62); footerRule:SetPoint("BOTTOMRIGHT", 0, 62)
  footerRule:SetHeight(1); footerRule:SetColorTexture(0.62, 0.48, 0.32, 0.42)
  d.total = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  d.total:SetPoint("BOTTOMLEFT", 0, 46)
  d.total:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -4, 46)
  d.total:SetJustifyH("LEFT")
  d.priceSource = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.priceSource:SetPoint("BOTTOMLEFT", 0, 29)
  d.priceSource:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -4, 29)
  d.priceSource:SetJustifyH("LEFT")
  d.priceSource:SetWordWrap(false)

  local ah = control("Search mats on AH", d); ah:SetSize(154, 24)
  ah:SetPoint("BOTTOMLEFT", 0, 0)
  ah:SetScript("OnClick", function()
    if not f.sel then return end
    local terms = {}
    for _, rg in ipairs(f.sel.r) do terms[#terms + 1] = (itemName(rg[1])) end
    f:SearchAH(terms)
  end)
  local fs = control("Search formula on AH", d, true); fs:SetSize(150, 24)
  fs:SetPoint("LEFT", ah, "RIGHT", 8, 0)
  fs:SetScript("OnClick", function() if f.sel and f.sel.f then f:SearchAH({ (itemName(f.sel.f)) }) end end)
  d.ahBtn, d.fBtn = ah, fs

  function f:SearchAH(terms)
    if not auctionHouseIsOpen() then
      say("open the auction house first, then click again."); return
    end
    local api = batchSearchAPI()
    if api then
      if pcall(api.MultiSearchExact, CALLER, terms) or pcall(api.MultiSearch, CALLER, terms) then return end
    end
    if #terms == 1 and try(searchNativeAH, terms[1]) then return end
    say(#terms > 1 and "Bulk search is unavailable. Click a reagent to search for it." or "Auction House search is unavailable.")
  end

  function f:ShowRecipe(r, prices)
    prices = prices or {}
    local previous = self.sel
    local canPrice = market.HasPriceData()
    self.sel = r
    if previous ~= r then self.finder = nil end
    if not r then d:Hide(); detailScroll:SetVerticalScroll(0); return end
    d:Show()
    d.icon.tex:SetTexture(spellIcon(r))
    d.name:SetText(r.n .. (r.new and "  |cffc1a5ff(new)|r" or ""))
    local sub = r.p and recipeType(r) or r.c
    if r.e and r.e ~= "" and r.e ~= r.n:gsub("^Enchant .- %- ", "") then sub = sub .. "  -  |cffffffff" .. r.e .. "|r" end
    local rl = {}
    for k in roles(r):gmatch(".") do rl[#rl + 1] = ROLE_NAME[k] end
    if #rl >= 4 then rl = { "Everyone" } end
    if #rl > 0 then sub = sub .. "\n|cff9d7cffFor: " .. table.concat(rl, ", ") .. "|r" end
    d.sub:SetText(sub)
    local lines = {}
    if r.g and r.g > 0 then lines[#lines + 1] = string.format("Skill: |cffffff00yellow at %d|r, |cff40c040green at %d|r, |cff808080grey at %d|r", r.g, math.floor((r.g + r.y) / 2), r.y) end
    if r.t and r.t ~= "" then lines[#lines + 1] = "Requires: " .. r.t end
    if r.f then
      local p, _, _, savedAt = unitPrice(r.f, prices)
      lines[#lines + 1] = "Taught by: " .. coloredItem(r.f) .. (p and ((savedAt and "  Saved AH ~" or "  ") .. money(p)) or "")
    elseif r.a == 1 then lines[#lines + 1] = "Taught by: |cffffffffstarting recipe|r"
    else lines[#lines + 1] = "Teaching source: unverified" end
    if r.p then
      local price, vendorOnly, _, savedAt = unitPrice(r.p, prices)
      lines[#lines + 1] = "Creates: " .. coloredItem(r.p) .. (price and not vendorOnly and ((savedAt and "  Saved AH ~" or "  AH ~") .. money(price)) or "")
    end
    local summary = recipeEffect(r)
    d.desc:SetText(effectText(r) or (summary ~= "Unverified" and summary) or "|cff808080Effect unverified|r")
    d.info:SetText(table.concat(lines, "\n"))
    local function height(text) return math.ceil(text:GetStringHeight() or 0) end
    local y = 2
    local function place(text, inset, gap)
      text:ClearAllPoints()
      text:SetWidth(self.detailWidth - inset)
      text:SetPoint("TOPLEFT", body, "TOPLEFT", inset, -y)
      y = y + height(text) + gap
    end
    place(d.name, 52, 5)
    place(d.sub, 52, 12)
    y = math.max(55, y)
    place(d.desc, 0, 13)
    place(d.info, 0, 16)
    place(d.rhead, 0, 7)
    for i, rg in ipairs(r.r) do
      local b = reagentRow(i)
      b.item = rg[1]
      b.icon:SetTexture(itemIcon(rg[1]))
      b.name:SetText(coloredItem(rg[1]))
      b.qty:SetText("×" .. rg[2])
      local p, onlyVendor, v, savedAt = unitPrice(rg[1], prices)
      local txt = p and money(p * rg[2]) or "|cff888895Unpriced|r"
      if savedAt then txt = txt .. "\n|cffaaaabeSaved AH " .. date("%d.%m.", savedAt) .. "|r" end
      if onlyVendor then txt = txt .. "\n|cffaaaabeVendor only|r"
      elseif v then txt = txt .. "\n|cffaaaabeVendor " .. money(v * rg[2]) .. "|r" end
      local priceW = canPrice and self.reagentPriceWidth or 1
      b.price:SetWidth(priceW)
      b.name:SetWidth(self.detailWidth - priceW - 94)
      b.price:SetText(canPrice and txt or "")
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
      b:SetWidth(self.detailWidth)
      local rowH = math.max(34, height(b.name) + 12, height(b.price) + 12)
      b:SetHeight(rowH)
      b:Show()
      y = y + rowH + 4
    end
    for i = #r.r + 1, #d.reag do d.reag[i].item = nil; d.reag[i]:Hide() end
    local total, missing, includesSaved = recipeCost(r, prices)
    local label = includesSaved and "Est. mats: " or "Total mats: "
    d.total:SetText(canPrice and (label .. costLabel(total, missing)) or "Search the Auction House to save prices.")
    local sources = priceSources(r, prices)
    d.priceSource:SetText(sources)
    d.priceSource:SetShown(sources ~= "")
    local enchanters = knownBy(r.id, self.presence)
    local lookup = whoAPI() ~= nil
    local finder = self.finder
    local online, candidate, retry, hasContact
    for _, crafter in ipairs(enchanters) do
      if crafter.key ~= self.ownName then
        hasContact = true
        if crafter.status == ONLINE then
          online = crafter
          break
        elseif crafter.status == UNKNOWN then
          retry = retry or crafter
          if not finder or not finder.checked[crafter.key] then candidate = candidate or crafter end
        end
      end
    end
    find.online, find.candidate, find.retry = online, candidate, retry
    local canFind = online ~= nil or (lookup and hasContact == true)
    find:SetShown(canFind)
    find.showCooldown = false
    if canFind then
      local hasNext = candidate ~= nil or retry ~= nil
      local enabled = online ~= nil or (hasNext and not pendingWho and not whoCooldownUntil)
      local text = "Find enchanter"
      if finder and online then text = "Whisper online"
      elseif finder and pendingWho and pendingWho.finder == finder then text = "Checking..."
      elseif not online and hasNext and pendingWho then text = "Waiting for Who"
      elseif not online and hasNext and whoCooldownUntil then find.showCooldown = true
      elseif finder and candidate then text = "Check next"
      elseif finder and retry then text = "Check again"
      elseif not candidate and not online then text = "None online" end
      if find.showCooldown then showCooldown(find) else find:SetText(text) end
      find:SetEnabled(enabled)
      if enabled then find.text:SetTextColor(0.87, 0.80, 0.69)
      else find.text:SetTextColor(0.58, 0.53, 0.46) end
    end
    d.seen:SetText(#enchanters > 0 and "Known by" or "|cff808080No enchanters recorded yet.|r")
    y = y + 8
    find:ClearAllPoints()
    find:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    local headingStart = y
    place(d.seen, 0, 6)
    if canFind then y = math.max(y, headingStart + 27) end
    for i, crafter in ipairs(enchanters) do
      local row = enchanterRow(i)
      row.recipeId, row.crafter = r.id, crafter
      row.name:SetText(crafter.name)
      local status = STATUS_LABELS[crafter.status] or market.LastSeenLabel(crafter.lastSeenAt)
      if self.recentLinked[crafter.key] then status = status .. " · linked book" end
      row.status:SetText(status)
      local other = crafter.key ~= self.ownName
      local showWho = other and lookup
      row.whisper:SetShown(other)
      row.who:SetShown(showWho)
      row.who:SetText(pendingWho and pendingWho.key == crafter.key and "Who..." or "Who")
      local textWidth = self.detailWidth - 36 - (other and 78 or 0) - (showWho and 54 or 0)
      row.name:SetWidth(textWidth)
      row.status:SetWidth(textWidth)
      row:SetWidth(self.detailWidth)
      row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
      row:Show()
      y = y + row:GetHeight() + 2
    end
    for i = #enchanters + 1, #d.enchanters do
      d.enchanters[i].recipeId, d.enchanters[i].crafter = nil, nil
      d.enchanters[i]:Hide()
    end
    body:SetHeight(math.max(1, y))
    local scroll = previous == r and detailScroll:GetVerticalScroll() or 0
    detailScroll:SetVerticalScroll(math.max(0, math.min(scroll, y - detailScroll:GetHeight())))
    local showBatch = #r.r > 0 and batchSearchAPI() ~= nil
    d.ahBtn:SetShown(showBatch)
    d.fBtn:ClearAllPoints()
    if showBatch then d.fBtn:SetPoint("LEFT", ah, "RIGHT", 8, 0)
    else d.fBtn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, 0) end
    d.fBtn:SetShown(r.f ~= nil)
  end

  local function updateMarker(b, presence)
    local available = recipeAvailability(b.r.id, presence)
    b.marker:SetText(available == nil and "" or (available and "|cff5be876•|r" or "|cffff6666•|r"))
    b.available = available
  end

  local function row(i)
    local b = f.rows[i]
    if b then return b end
    b = CreateFrame("Button", nil, content); b:SetHeight(ROW_H - 1)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.sel = b:CreateTexture(nil, "BACKGROUND"); b.sel:SetAllPoints(); b.sel:SetColorTexture(0.60, 0.44, 0.24, 0.28)
    local line = b:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT", 5, 0); line:SetPoint("BOTTOMRIGHT", -5, 0)
    line:SetHeight(1); line:SetColorTexture(0.62, 0.48, 0.32, 0.13)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetSize(17, 17); b.icon:SetPoint("LEFT", 5, 0)
    b.skill = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); b.skill:SetPoint("LEFT", b.icon, "RIGHT", 4, 0); b.skill:SetWidth(24); b.skill:SetJustifyH("RIGHT")
    b.marker = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.marker:SetPoint("LEFT", COLUMNS.presenceX, 0)
    b.marker:SetWidth(COLUMNS.presenceWidth)
    b.marker:SetJustifyH("CENTER")
    b.slot = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.slot:SetPoint("LEFT", COLUMNS.slotX, 0)
    b.slot:SetJustifyH("LEFT")
    b.slot:SetWordWrap(false)
    b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.right:SetPoint("RIGHT", -8, 0); b.right:SetJustifyH("RIGHT"); b.right:SetWordWrap(false)
    b.effect = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.effect:SetJustifyH("LEFT")
    b.effect:SetWordWrap(false)
    b.effect:SetTextColor(0.78, 0.76, 0.85)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("RIGHT", b.effect, "LEFT", -COLUMN_GAP, 0)
    b.text:SetJustifyH("LEFT"); b.text:SetWordWrap(false)
    if b.text.SetMaxLines then b.text:SetMaxLines(1) end
    b:SetScript("OnEnter", function(s)
      if not s.r then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:AddLine(s.r.n, 1, 0.9, 0.65, true)
      local summary = s.effect:GetText()
      if summary and summary ~= "" then GameTooltip:AddLine(summary, 0.85, 0.85, 0.9, true) end
      if s.r.e and s.r.e ~= "" then GameTooltip:AddLine(s.r.e, 1, 1, 1, true) end
      if s.cost ~= nil then GameTooltip:AddLine("Mat cost: " .. costLabel(s.cost, s.missing), 1, 1, 1, true) end
      if s.includesSaved then GameTooltip:AddLine("Includes saved AH prices", 0.75, 0.75, 0.85) end
      if s.missingEnchant then GameTooltip:AddLine("Equipped gear is missing a permanent enhancement", unpack(equipment.missingColor)) end
      if s.available == true then GameTooltip:AddLine("A recorded enchanter is online", 0.36, 0.91, 0.46)
      elseif s.available == false then GameTooltip:AddLine("No recorded enchanter is confirmed online", 1, 0.48, 0.48) end
      GameTooltip:AddLine("Shift-click to link in chat", 0.75, 0.75, 0.85)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:SetScript("OnClick", function(s)
      if try(IsModifiedClick, "CHATLINK") then pasteRecipe(s.r); return end
      f:ShowRecipe(s.r)
      for _, button in ipairs(f.rows) do button.sel:SetShown(button.r == f.sel) end
    end)
    f.rows[i] = b
    return b
  end

  function f:FitToScreen()
    local screenW = try(UIParent.GetWidth, UIParent) or 960
    local screenH = try(UIParent.GetHeight, UIParent) or 680
    if screenW <= 24 or screenH <= 24 then screenW, screenH = 960, 680 end
    local width = math.max(900, math.min(1040, screenW - 42))
    local height = math.max(500, math.min(635, screenH - 42))
    self:SetScale(math.min(1, (screenW - 8) / width, (screenH - 8) / height))
    self:SetSize(width, height)

    local space = width - 2 * MARGIN - PANE_GAP
    local left = math.min(math.floor(space * 0.59), space - SCROLL_GUTTER - 330)
    local listW = left - SCROLL_GUTTER
    local detailX = MARGIN + left + PANE_GAP
    self.detailWidth = space - left - SCROLL_GUTTER
    self.reagentPriceWidth = math.max(106, math.floor(self.detailWidth * 0.34))
    self.effectWidth = math.min(EFFECT_MAX_WIDTH, math.floor(listW * 0.205))
    self.slotWidth = math.min(73, math.max(64, math.floor(listW * 0.135)))
    self.listWidth = listW

    search:SetWidth(listW - 6)
    gearButton:SetPoint("RIGHT", search, "LEFT", listW - 3, 0)
    cat:SetWidth(listW - skill:GetWidth() - kind:GetWidth() - filters:GetWidth() - 3 * FILTER_GAP)
    filters:SetPoint("RIGHT", cat, "LEFT", listW, 0)
    separator:ClearAllPoints()
    separator:SetPoint("TOPLEFT", MARGIN + left + PANE_GAP / 2, -33)
    separator:SetPoint("BOTTOMLEFT", MARGIN + left + PANE_GAP / 2, 12)
    sf:SetWidth(listW)
    content:SetWidth(listW)
    self.count:SetWidth(left)
    d:SetPoint("TOPLEFT", detailX, -34)
    body:SetWidth(self.detailWidth)
  end

  function f:Refresh(resetScroll)
    buildCats()
    if self.catIdx > #CATS then self.catIdx = 1 end
    local slot = CATS[self.catIdx]
    local canPrice = market.HasPriceData()
    if not canPrice and sorts[self.sortIdx] == "Cost" then self.sortIdx = 2 end
    local isEnchantTab = self.recipeType == ENCHANT
    if not isEnchantTab and sorts[self.sortIdx] == "Slot" then self.sortIdx = 2 end
    self.gear, self.missingSlots, self.gearPending = equipment.Read()
    local highlight = isEnchantTab and (DB.highlightMissing or DB.onlyMissing)
    local onlyMissing = isEnchantTab and DB.onlyMissing
    cat:SetShown(isEnchantTab)
    cat:SetText(slot == "All" and "All slots" or slot)
    if highlight and self.missingSlots[slot] then cat.text:SetTextColor(unpack(equipment.missingColor))
    else cat.text:SetTextColor(0.87, 0.80, 0.69) end
    skill:ClearAllPoints()
    if isEnchantTab then skill:SetPoint("LEFT", cat, "RIGHT", FILTER_GAP, 0)
    else skill:SetPoint("TOPLEFT", cat, "TOPLEFT") end
    local bracket = SKILL_BRACKETS[DB.skillBracket] or SKILL_BRACKETS[1]
    skill:SetText(bracket.label)
    kind:SetText(self.recipeType .. "s")
    local activeFilters = (DB.onlySeen and 1 or 0) + (isEnchantTab and DB.role and 1 or 0)
    filters:SetText(activeFilters > 0 and ("Filters · " .. activeFilters) or "Filters")
    local priceColumn = canPrice and COST_WIDTH + COLUMN_GAP or 0
    local nameX = COLUMNS.slotX + (isEnchantTab and self.slotWidth + COLUMN_GAP or 0)
    sortHeaders[4]:SetWidth(self.slotWidth)
    sortHeaders[4]:SetShown(isEnchantTab)
    sortHeaders[2]:SetWidth(self.listWidth - priceColumn - self.effectWidth - 2 * COLUMN_GAP - nameX + 6)
    sortHeaders[2]:SetPoint("LEFT", nameX - 6, 1)
    for index, header in ipairs(sortHeaders) do
      local active = index == self.sortIdx
      header.indicator:SetShown(active)
      header.text:SetPoint("RIGHT", index == 3 and active and -18 or -6, 0)
      if active then
        header.text:SetTextColor(1, 0.82, 0.49)
        header.indicator:SetAscending(not DB.sortDesc)
        header.indicator:ClearAllPoints()
        if index == 3 then
          header.indicator:SetPoint("RIGHT", -6, 0)
        else
          local titleWidth = try(header.text.GetStringWidth, header.text) or #headingNames[index] * 6
          header.indicator:SetPoint("LEFT", header.text, "LEFT", math.min(titleWidth + 4, header:GetWidth() - 16), 0)
        end
      else
        header.text:SetTextColor(0.76, 0.72, 0.65)
      end
    end
    sortHeaders[3]:SetShown(canPrice)
    effectHeading:ClearAllPoints()
    effectHeading:SetWidth(self.effectWidth)
    effectHeading:SetPoint("RIGHT", head, "RIGHT", -COLUMN_GAP - priceColumn, 1)
    local text = (self.search:GetText() or ""):lower()
    local selectedStats = 0
    for _, definition in ipairs(STATS) do
      if DB.stats[definition[1]] then selectedStats = selectedStats + 1 end
    end
    stats:SetText(selectedStats > 0 and ("Stats · " .. selectedStats) or "Stats")
    local gearActive = (DB.highlightMissing and 1 or 0) + (DB.onlyMissing and 1 or 0)
    gearButton:SetText(gearActive > 0 and ("Gear · " .. gearActive) or "Gear")
    local canReset = not isEnchantTab or text ~= "" or self.catIdx ~= 1 or activeFilters > 0
      or bracket.low > 0 or selectedStats > 0 or gearActive > 0
    reset:SetShown(canReset)
    search:SetWidth(self.listWidth - 6 - gearButton:GetWidth() - stats:GetWidth() - 2 * FILTER_GAP
      - (canReset and reset:GetWidth() + FILTER_GAP or 0))
    local list, names, effects, statCounts, shortNames = {}, {}, {}, {}, {}
    local typeCount, seenCount = 0, 0
    for _, r in ipairs(recipes) do
      if recipeType(r) == self.recipeType then
        local seen = market.contacts.seen[r.id] ~= nil
        local skillLevel = r.g or 0
        typeCount = typeCount + 1
        if seen then seenCount = seenCount + 1 end
        if (not isEnchantTab or slot == "All" or r.c == slot) and (not DB.onlySeen or seen)
          and (not isEnchantTab or not DB.role or roles(r):find(DB.role, 1, true))
          and (not onlyMissing or self.missingSlots[r.c])
          and skillLevel >= bracket.low and skillLevel <= bracket.high then
          local label, tags = recipeEffect(r)
          if matches(r, text, names, label) then
            local include = selectedStats == 0
            for tag in tags:gmatch("%S+") do
              statCounts[tag] = (statCounts[tag] or 0) + 1
              include = include or DB.stats[tag]
            end
            if include then
              list[#list + 1] = r
              effects[r] = label
              shortNames[r] = recipeDisplayName(r)
            end
          end
        end
      end
    end
    self.statCounts = statCounts
    if menu:IsShown() and menu.anchor == stats then
      for _, item in ipairs(menu.items) do
        if item:IsShown() then
          item.option.selected = DB.stats[item.option.value] == true
          item.option.count = statCounts[item.option.value] or 0
          showOption(item)
        end
      end
    end
    if menu:IsShown() and menu.anchor == gearButton then
      for i, option in ipairs(gearOptions()) do
        menu.items[i].option = option
        showOption(menu.items[i])
      end
    end
    local s = sorts[self.sortIdx]
    local cost, missing, saved, prices = {}, {}, {}, {}
    if canPrice then
      for _, r in ipairs(list) do cost[r], missing[r], saved[r] = recipeCost(r, prices) end
    end
    local function priceGroup(r)
      if missing[r] == 0 then return 1 end
      return cost[r] > 0 and 2 or 3
    end
    local desc = DB.sortDesc
    local function key(r)
      if s == "Cost" then return cost[r] end
      if s == "Skill" then return r.g or 0 end
      if s == "Slot" then return r.c end
      return shortNames[r]:lower()
    end
    table.sort(list, function(a, b)
      if s == "Cost" and missing[a] and missing[b] then
        local ga, gb = priceGroup(a), priceGroup(b)
        if ga ~= gb then return ga < gb end
      end
      local ka, kb = key(a), key(b)
      if ka ~= kb then
        if desc then return ka > kb end
        return ka < kb
      end
      if s == "Slot" then
        local nameA, nameB = shortNames[a]:lower(), shortNames[b]:lower()
        if nameA ~= nameB then return nameA < nameB end
      end
      if a.n ~= b.n then return a.n < b.n end
      return a.id < b.id
    end)
    local selected = list[1]
    if not resetScroll then
      for _, r in ipairs(list) do if r == self.sel then selected = r; break end end
    end
    self:ShowRecipe(selected, prices)
    for i, r in ipairs(list) do
      local b = row(i)
      b.r, b.cost, b.missing, b.includesSaved = r, cost[r], missing[r], saved[r]
      b:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
      b:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i - 1) * ROW_H)
      b.right:SetWidth(canPrice and COST_WIDTH or 1)
      b.effect:ClearAllPoints()
      b.effect:SetWidth(self.effectWidth)
      b.effect:SetPoint("RIGHT", b, "RIGHT", -COLUMN_GAP - priceColumn, 0)
      b.effect:SetText(effects[r])
      b.icon:SetTexture(spellIcon(r))
      b.skill:SetText((r.g or 0) > 0 and ("|cff" .. skillColor(r.g) .. r.g .. "|r") or (r.new and "|cffc1a5ffnew|r" or "—"))
      b.missingEnchant = highlight and self.missingSlots[r.c]
      b.slot:SetShown(isEnchantTab)
      b.slot:SetWidth(self.slotWidth)
      b.slot:SetText(r.c)
      if b.missingEnchant then b.slot:SetTextColor(unpack(equipment.missingColor))
      else b.slot:SetTextColor(0.79, 0.74, 0.67) end
      b.text:SetPoint("LEFT", b, "LEFT", nameX, 0)
      b.text:SetText(shortNames[r])
      updateMarker(b, self.presence)
      b.right:SetText(cost[r] and costLabel(cost[r], missing[r], true) or "")
      b.sel:SetShown(self.sel == r)
      b:Show()
    end
    for i = #list + 1, #self.rows do self.rows[i]:Hide() end
    empty:SetShown(#list == 0)
    local listHeight = math.max(1, #list * ROW_H)
    self.content:SetHeight(listHeight)
    sf:SetVerticalScroll(resetScroll and 0 or math.max(0, math.min(sf:GetVerticalScroll(), listHeight - sf:GetHeight())))
    self.count:SetText(string.format("%d shown  ·  %d %ss  ·  %d seen", #list, typeCount, self.recipeType:lower(), seenCount))

  end

  function f:RefreshPresence(updateList)
    local contactsRemoved
    self.presence, self.ownName, self.recentLinked, contactsRemoved = readPresence()
    if updateList or contactsRemoved then self:Refresh(); return end
    for _, b in ipairs(self.rows) do
      if b:IsShown() then updateMarker(b, self.presence) end
    end
    if self.sel then self:ShowRecipe(self.sel) end
  end

  local function requestGuildRoster()
    if not try(IsInGuild) then return end
    local now = GetTime()
    if f.lastGuildRequest and now - f.lastGuildRequest < 15 then return end
    f.lastGuildRequest = now
    try(C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster)
  end
  f.RequestGuildRoster = requestGuildRoster
  f:FitToScreen()
  f:SetScript("OnShow", function(s)
    s:FitToScreen()
    s:RefreshPresence(true)
    requestGuildRoster()
  end)
  f:Hide()
  return f
end

local function toggle()
  frame = frame or makeFrame()
  frame:SetShown(not frame:IsShown())
end
ns.Toggle = toggle

-----------------------------------------------------------------------
-- minimap button (LibDataBroker + LibDBIcon, so EllesmereUI's minimap collects it)
-----------------------------------------------------------------------
local function setupMinimap()
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
  if not (LDB and Icon) then return end
  local obj = LDB:NewDataObject("EnchantBook", {
    type = "launcher", text = "EnchantBook", icon = BOOK_ICON,
    OnClick = function(_, btn)
      if btn == "RightButton" then DB.onlySeen = not DB.onlySeen; say("showing " .. (DB.onlySeen and "only recipes seen in windows" or "all recipes") .. ".")
        if frame and frame:IsShown() then frame:Refresh() end
      else toggle() end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine("EnchantBook")
      tt:AddLine("|cffffffffLeft-click|r open recipe browser", 0.8, 0.8, 0.8)
      tt:AddLine("|cffffffffRight-click|r toggle 'seen only'", 0.8, 0.8, 0.8)
    end,
  })
  Icon:Register("EnchantBook", obj, DB.minimap)
end

-----------------------------------------------------------------------
-- events / slash
-----------------------------------------------------------------------
local ev = CreateFrame("Frame")
local pending = false
local presenceEvents = {
  FRIENDLIST_UPDATE = true, GUILD_ROSTER_UPDATE = true, PLAYER_GUILD_UPDATE = true,
  GROUP_ROSTER_UPDATE = true, UNIT_CONNECTION = true, PLAYER_TARGET_CHANGED = true,
  PLAYER_ENTERING_WORLD = true,
}
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "GET_ITEM_INFO_RECEIVED", "SPELL_DATA_LOAD_RESULT", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
for e in pairs(presenceEvents) do pcall(ev.RegisterEvent, ev, e) end
for e in pairs(ahPriceEvents) do pcall(ev.RegisterEvent, ev, e) end
pcall(ev.RegisterEvent, ev, "WHO_LIST_UPDATE")
pcall(ev.RegisterEvent, ev, "CHAT_MSG_SYSTEM")
pcall(ev.RegisterEvent, ev, "PLAYER_EQUIPMENT_CHANGED")
pcall(ev.RegisterEvent, ev, "UNIT_INVENTORY_CHANGED")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_SHOW")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_CLOSED")
local dataRefreshPending = false
local function refreshAfterData()
  if dataRefreshPending or not (frame and frame:IsShown()) then return end
  dataRefreshPending = true
  C_Timer.After(0.3, function()
    dataRefreshPending = false
    if frame:IsShown() then frame:Refresh() end
  end)
end
function market.Initialize(loggedIn)
  local scope = loggedIn and market.ReadScope()
  local oldKey = market.scope and market.scope.contactKey
  if oldKey ~= (scope and scope.contactKey or nil) then
    wipe(whoStatus)
    wipe(linkedUntil)
    pendingWho = nil
  end
  market.scope = scope or nil
  if scope then
    DB.contactScopes[scope.contactKey] = DB.contactScopes[scope.contactKey] or {}
    market.contacts = DB.contactScopes[scope.contactKey]
  else
    market.contacts = {}
  end
  market.contacts.seen = market.contacts.seen or {}
  market.contacts.lastSeenByName = market.contacts.lastSeenByName or {}
  market.contacts.offlineSinceByName = market.contacts.offlineSinceByName or {}
end

ev:SetScript("OnEvent", function(_, event, arg1, success)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    EnchantBookDB = EnchantBookDB or {}
    DB = EnchantBookDB
    EnchantBookAHPrices = type(EnchantBookAHPrices) == "table" and EnchantBookAHPrices or {}
    EnchantBookAHPrices.byMarket = EnchantBookAHPrices.byMarket or {}
    DB.contactScopes = DB.contactScopes or {}
    DB.extra = DB.extra or {}; DB.extraItems = DB.extraItems or {}; DB.exists = DB.exists or {}
    market.Initialize(try(IsLoggedIn) == true)
    if not SKILL_BRACKETS[DB.skillBracket] then
      local oldMinimum = tonumber(DB.minSkill) or 0
      DB.skillBracket = oldMinimum >= 250 and 4 or (oldMinimum >= 150 and 3 or 1)
    end
    DB.minSkill = nil
    DB.stats = DB.stats or {}
    DB.minimap = DB.minimap or {}
    rebuild()
  elseif event == "PLAYER_LOGIN" then
    market.Initialize(true)
    setupMinimap()
    local _, build = try(GetBuildInfo)
    local dataBuild = tonumber((EnchantBook_Data.build or ""):match("(%d+)$"))
    if tonumber(build) and dataBuild and tonumber(build) > dataBuild then
      say("recipe data is from build " .. dataBuild .. ". Install a newer EnchantBook release when available.")
    end
  elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
    if frame and frame:IsShown() then frame:FitToScreen(); frame:Refresh() end
  elseif presenceEvents[event] then
    local scopeWasUnavailable = not market.scope
    if event == "PLAYER_ENTERING_WORLD" and scopeWasUnavailable then market.Initialize(true) end
    if frame and frame:IsShown() then
      frame:RefreshPresence(scopeWasUnavailable and market.scope ~= nil)
      if event == "PLAYER_GUILD_UPDATE" then frame:RequestGuildRoster() end
    elseif event == "FRIENDLIST_UPDATE" or event == "GUILD_ROSTER_UPDATE" or next(market.contacts.offlineSinceByName) then
      readPresence()
    end
  elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_INVENTORY_CHANGED" then
    if event == "PLAYER_EQUIPMENT_CHANGED" or arg1 == "player" then refreshAfterData() end
  elseif event == "WHO_LIST_UPDATE" then
    receiveWho()
  elseif event == "CHAT_MSG_SYSTEM" then
    receiveWhoChat(arg1)
  elseif event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
    market.UpdateHouse(event == "AUCTION_HOUSE_SHOW")
    refreshAfterData()
  elseif ahPriceEvents[event] then
    if recordAHPrices(event, arg1) then refreshAfterData() end
  elseif event == "GET_ITEM_INFO_RECEIVED" or event == "SPELL_DATA_LOAD_RESULT" then
    local relevant = event == "GET_ITEM_INFO_RECEIVED" and (watchedItems[arg1] or (frame and frame.gearPending))
      or event == "SPELL_DATA_LOAD_RESULT" and byId[arg1]
    if success ~= false and relevant then refreshAfterData() end
  elseif event ~= "ADDON_LOADED" and DB and not pending then
    pending = true
    C_Timer.After(0.7, function() pending = false; pcall(scan) end)
  end
end)

SLASH_ENCHANTBOOK1 = "/eb"
SLASH_ENCHANTBOOK2 = "/enchantbook"
SlashCmdList.ENCHANTBOOK = function(msg)
  msg = (msg or ""):lower()
  if msg == "minimap" then
    DB.minimap.hide = not DB.minimap.hide
    local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if Icon then if DB.minimap.hide then Icon:Hide("EnchantBook") else Icon:Show("EnchantBook") end end
  elseif msg == "scan" then pcall(scan)
  else toggle() end
end
