local _, ns = ...

-- Leave room for a chat command or a short personal note.
local CHAT_BYTES = 240
local MAX_QUANTITY = 99
local ROW_HEIGHT, CONTACT_HEIGHT = 23, 46
local CONTACT_WIDTH, CONTACT_GAP = 320, 18

local function validQuantity(quantity)
  return type(quantity) == "number" and quantity >= 1 and quantity <= MAX_QUANTITY
    and quantity == math.floor(quantity)
end

local CHAT_ABBREVIATIONS = {
  Agility = "Agi", Intellect = "Int", Stamina = "Stam", Strength = "Str",
  Spirit = "Spi", Resistance = "Resist", Resistances = "Resists",
}

local function shortChatName(name)
  local title, qualifier = name:match("^(.-)( %b())$")
  title = (title or name):gsub("^(Weapon %- .-) Weapon$", "%1"):gsub("^2H Weapon %- ", "2H - ")
  return title:gsub("%a+", CHAT_ABBREVIATIONS) .. (qualifier or "")
end

local function prepareMessages(enchants)
  local prefix, suffix = "LF ench: ", ". Got mats"
  local limit = CHAT_BYTES - #suffix
  local parts, current = {}, prefix
  for _, entry in ipairs(enchants) do
    local name = (entry.quantity > 1 and entry.quantity .. "x " or "") .. shortChatName(entry.name)
    local separator = current == prefix and "" or "; "
    if #current + #separator + #name > limit and current ~= prefix then
      parts[#parts + 1] = current .. suffix
      current, separator = prefix, ""
    end
    while #name > limit - #prefix do
      local stop = limit - #prefix
      -- Don't cut a UTF-8 character between its leading and continuation bytes.
      while stop > 1 do
        local following = name:byte(stop + 1)
        if following < 128 or following >= 192 then break end
        stop = stop - 1
      end
      local whitespace = name:sub(1, stop):match("^.*()%s")
      if whitespace and whitespace > stop / 2 then stop = whitespace - 1 end
      parts[#parts + 1] = prefix .. name:sub(1, stop) .. suffix
      name = name:sub(stop + 1):gsub("^%s+", "")
    end
    current = current .. separator .. name
  end
  if current ~= prefix then parts[#parts + 1] = current .. suffix end
  return parts
end

function ns.CreateShoppingPane(parent, control, tooltip, scrollFrame, services)
  local pane = CreateFrame("Frame", nil, parent)
  pane.enchantRows, pane.materialRows, pane.contactRows = {}, {}, {}
  pane.part = 1
  pane.materials, pane.pendingEnchants, pane.tradeMessages = {}, {}, {}
  pane:Hide()
  local list = CreateFrame("Frame", nil, pane)
  list:SetPoint("TOPLEFT", pane, "TOPLEFT")
  list:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT")
  local contacts = CreateFrame("Frame", nil, pane)
  contacts:SetPoint("TOPLEFT", list, "TOPRIGHT", CONTACT_GAP, 0)
  contacts:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", CONTACT_GAP, 0)
  contacts:SetWidth(CONTACT_WIDTH)
  contacts:Hide()
  local divider = contacts:CreateTexture(nil, "ARTWORK")
  divider:SetPoint("TOPLEFT", -10, 2)
  divider:SetPoint("BOTTOMLEFT", -10, -1)
  divider:SetWidth(1)
  divider:SetColorTexture(0.62, 0.48, 0.32, 0.42)

  local function text(owner, font, value)
    local label = owner:CreateFontString(nil, "OVERLAY", font)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(value or "")
    return label
  end

  local function scroller(view)
    local scroll = scrollFrame(view)
    local area = CreateFrame("Frame", nil, scroll)
    area:SetHeight(1)
    scroll:SetScrollChild(area)
    local bar = scroll.ScrollBar
    local function syncScroll()
      local limit = area:GetHeight() - scroll:GetHeight()
      -- An exact row fit can round to a fractional overflow at some UI scales.
      if limit <= 1 then limit = 0 end
      if scroll:GetVerticalScroll() > limit then scroll:SetVerticalScroll(limit) end
      if bar then bar:SetShown(limit > 0) end
    end
    scroll:HookScript("OnSizeChanged", syncScroll)
    scroll:HookScript("OnScrollRangeChanged", syncScroll)
    if bar then bar:HookScript("OnShow", syncScroll) end
    function scroll:SetContentHeight(height)
      area:SetHeight(height)
      syncScroll()
    end
    local fill = scroll:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(0.087, 0.077, 0.068, 1)
    return scroll, area
  end

  -- Gold marks the next contact action. Blue marks an available lookup.
  local function accent(button, tone)
    if not button.accentFill then
      local fill = button:CreateTexture(nil, "BACKGROUND", nil, 1)
      fill:SetAllPoints()
      local edge = button:CreateTexture(nil, "ARTWORK")
      edge:SetPoint("TOPLEFT")
      edge:SetPoint("BOTTOMLEFT")
      edge:SetWidth(2)
      button.accentFill, button.accentEdge = fill, edge
    elseif button.accentTone == tone then
      return
    end
    button.accentTone = tone
    if tone == "gold" then
      button.accentFill:SetColorTexture(0.31, 0.22, 0.10, 1)
      button.accentEdge:SetColorTexture(0.97, 0.73, 0.32, 1)
      button.text:SetTextColor(1, 0.89, 0.63)
    elseif tone == "lookup" then
      button.accentFill:SetColorTexture(0.13, 0.19, 0.21, 1)
      button.accentEdge:SetColorTexture(0.45, 0.67, 0.74, 1)
      button.text:SetTextColor(0.79, 0.89, 0.92)
    else
      button.text:SetTextColor(0.77, 0.73, 0.66)
    end
    button.accentFill:SetShown(tone ~= nil)
    button.accentEdge:SetShown(tone ~= nil)
  end

  function pane:Quantity(id)
    local entry = EnchantBookShopping[id]
    local quantity = type(entry) == "table" and entry.quantity or entry
    return validQuantity(quantity) and quantity or 0
  end

  function pane:IsDone(id)
    local entry = EnchantBookShopping[id]
    return type(entry) == "table" and entry.done == true
  end

  function pane:CanAdd(id)
    return services.recipe(id) ~= nil and (self:IsDone(id) or self:Quantity(id) < MAX_QUANTITY)
  end

  function pane:Count()
    local count = 0
    for id in pairs(EnchantBookShopping) do
      if services.recipe(id) and not self:IsDone(id) then count = count + self:Quantity(id) end
    end
    return count
  end

  local function listChanged(keepUndo, id)
    if not keepUndo then pane.clearedList = nil end
    pane.part = 1
    if pane.OnListChanged then pane:OnListChanged(id) end
    if pane:IsShown() then pane:Refresh() end
  end

  function pane:ChangeQuantity(id, delta)
    if not services.recipe(id) or (self:IsDone(id) and delta < 0) then return end
    local current = self:IsDone(id) and 0 or self:Quantity(id)
    local quantity = math.max(0, math.min(MAX_QUANTITY, current + delta))
    if quantity == current then return end
    EnchantBookShopping[id] = quantity > 0 and {quantity = quantity} or nil
    listChanged(nil, id)
  end

  function pane:MarkDone(id, done)
    local quantity = self:Quantity(id)
    if quantity == 0 or not services.recipe(id) then return end
    EnchantBookShopping[id] = {quantity = quantity, done = done or nil}
    listChanged(nil, id)
  end

  local enchantHeading = text(list, "GameFontNormal", "Enchants")
  enchantHeading:SetPoint("TOPLEFT", 0, -4)
  local find = control("Find enchanter", list)
  find:SetSize(125, 23)
  find:SetPoint("BOTTOMLEFT", 0, 1)
  find.text:SetPoint("RIGHT", -20, 0)
  tooltip(find, "Show or hide enchanters who know the recipes on your list.")
  local arrow = {}
  for i = 1, 7 do
    local dot = find:CreateTexture(nil, "ARTWORK")
    dot:SetSize(1.5, 1.5)
    dot:SetColorTexture(0.88, 0.76, 0.57, 1)
    arrow[i] = dot
  end
  local function paintToggle(expanded)
    find:SetText(expanded and "Hide enchanters" or "Find enchanter")
    local direction = expanded and -1 or 1
    for i, dot in ipairs(arrow) do
      dot:SetPoint("CENTER", find, "RIGHT", -12 + direction * (2 - math.abs(i - 4)), i - 4)
    end
    accent(find, not expanded and not pane.selectedCrafter and "gold" or nil)
  end
  paintToggle(false)
  local clearDone = control("Clear done", list, true)
  clearDone:SetSize(77, 23)
  clearDone:SetScript("OnClick", function()
    for id in pairs(EnchantBookShopping) do
      if pane:IsDone(id) then EnchantBookShopping[id] = nil end
    end
    listChanged()
  end)
  local clearList = control("Clear list", list, true)
  clearList:SetSize(82, 23)
  clearList:SetPoint("TOPRIGHT", 0, 2)
  clearDone:SetPoint("RIGHT", clearList, "LEFT", -3, 0)
  clearList:SetScript("OnClick", function()
    if pane.clearedList then
      EnchantBookShopping, pane.clearedList = pane.clearedList, nil
    else
      pane.clearedList, EnchantBookShopping = EnchantBookShopping, {}
    end
    listChanged(true)
  end)
  pane.find, pane.clearDone, pane.clearList = find, clearDone, clearList
  local enchantsScroll, enchantsArea = scroller(list)
  enchantsScroll:SetPoint("TOPLEFT", 0, -25)
  enchantsScroll:SetPoint("TOPRIGHT", -24, -25)
  enchantsScroll:SetHeight(ROW_HEIGHT * 3)
  local browse = control("Open recipe book", enchantsArea)
  browse:SetSize(121, ROW_HEIGHT)
  browse:SetPoint("TOPLEFT")
  browse:SetScript("OnClick", function() parent:SelectTab(false) end)
  tooltip(browse, "Open the recipe book and use + to add an enchant.")
  pane.browse = browse

  local materialSection = CreateFrame("Frame", nil, list)
  materialSection:SetAllPoints(list)
  local materialsHeading = text(materialSection, "GameFontNormal", "Materials")
  materialsHeading:SetPoint("TOPLEFT", enchantsScroll, "BOTTOMLEFT", 0, -13)
  local search = control("Search Auctionator", materialSection)
  search:SetSize(142, 24)
  search:SetPoint("TOPRIGHT", enchantsScroll, "BOTTOMRIGHT", 24, -7)
  tooltip(search, "Open the Auction House first. With the built-in search, click once per material.")
  pane.search = search

  local materialsScroll, materialsArea = scroller(materialSection)
  materialsScroll:SetPoint("TOPLEFT", enchantsScroll, "BOTTOMLEFT", 0, -47)
  materialsScroll:SetPoint("BOTTOMRIGHT", -24, 111)
  local emptyMaterials = text(materialsArea, "GameFontDisableSmall", "Your materials will appear here.")
  emptyMaterials:SetPoint("TOPLEFT", 8, -7)

  local columns = {
    { key = "needed", label = "Need", width = 41 },
    { key = "have", label = "In bags", width = 45 },
    { key = "buy", label = "To buy", width = 46 },
    { key = "cost", label = "Est. cost", width = 82 },
  }
  local function materialColumns(owner, reference, heading)
    local values, offset = {}, -5
    for i = #columns, 1, -1 do
      local col = columns[i]
      local label = text(owner, heading and "GameFontDisableSmall" or "GameFontHighlightSmall", heading and col.label)
      label:SetWidth(col.width)
      label:SetJustifyH("RIGHT")
      label:SetPoint(heading and "BOTTOMRIGHT" or "RIGHT", reference, heading and "TOPRIGHT" or "RIGHT", offset, heading and 4 or 0)
      values[col.key] = label
      offset = offset - col.width
    end
    return values, offset
  end
  materialColumns(materialSection, materialsScroll, true)
  local materialLabel = text(materialSection, "GameFontDisableSmall", "Material")
  materialLabel:SetPoint("BOTTOMLEFT", materialsScroll, "TOPLEFT", 6, 4)

  local total = text(list, "GameFontNormal")
  local source = text(list, "GameFontDisableSmall")
  pane.total, pane.priceSource = total, source

  local preview = CreateFrame("Frame", nil, list)
  preview:SetPoint("BOTTOMLEFT", 0, 28)
  preview:SetPoint("BOTTOMRIGHT", 0, 28)
  local paper = preview:CreateTexture(nil, "BACKGROUND")
  paper:SetAllPoints()
  paper:SetColorTexture(0.085, 0.075, 0.066, 1)
  local messageLabel = text(list, "GameFontNormal")
  messageLabel:SetPoint("BOTTOMLEFT", preview, "TOPLEFT", 0, 4)
  local prev = control("Back", list, true)
  prev:SetSize(46, 23)
  local nextPart = control("Next", list, true)
  nextPart:SetSize(46, 23)
  nextPart:SetPoint("BOTTOMRIGHT", preview, "TOPRIGHT", 0, 0)
  prev:SetPoint("RIGHT", nextPart, "LEFT", -3, 0)
  local recipient = CreateFrame("Frame", nil, list)
  recipient:SetPoint("BOTTOMLEFT", preview, "TOPLEFT", 0, 22)
  recipient:SetPoint("BOTTOMRIGHT", preview, "TOPRIGHT", 0, 22)
  recipient:SetHeight(21)
  recipient:Hide()
  local clearRecipient = control("×", recipient, true)
  clearRecipient:SetSize(25, 23)
  clearRecipient:SetPoint("RIGHT", 0, 0)
  tooltip(clearRecipient, "Clear the selected enchanter.")
  local who = control("Who", recipient, true)
  who:SetSize(48, 23)
  who:SetPoint("RIGHT", clearRecipient, "LEFT", -3, 0)
  tooltip(who, "Check the selected enchanter's online status and zone with /who.")
  local recipientName = text(recipient, "GameFontHighlightSmall")
  recipientName:SetPoint("LEFT", 0, 0)
  recipientName:SetPoint("RIGHT", who, "LEFT", -5, 0)
  local whisper = control("Whisper", list)
  accent(whisper, "gold")
  whisper:SetSize(73, 24)
  whisper:SetPoint("BOTTOMRIGHT", 0, 1)
  whisper:Hide()
  tooltip(whisper, "Open a whisper with this message part ready to review and send.")
  local copy = control("Select to copy", list, true)
  copy:SetSize(94, 24)
  copy:SetPoint("BOTTOMRIGHT", 0, 1)
  tooltip(copy, "Select this message part. Press Ctrl+C to copy it.")
  local message = CreateFrame("EditBox", nil, preview)
  message:SetAutoFocus(false)
  message:SetMultiLine(true)
  message:SetFontObject("GameFontHighlight")
  message:SetJustifyH("LEFT")
  message:SetJustifyV("TOP")
  message:SetPoint("TOPLEFT", 7, -4)
  message:SetPoint("TOPRIGHT", -7, -4)
  local measure = text(preview, "GameFontHighlight")
  measure:SetWordWrap(true)
  measure:SetNonSpaceWrap(true)
  measure:Hide()
  local measuredWidth, measuredText, previewHeight
  local function layoutDraft(width)
    local draft = message:GetText() or ""
    if width ~= measuredWidth or draft ~= measuredText then
      measuredWidth, measuredText = width, draft
      measure:SetWidth(math.max(1, width - 14))
      measure:SetText(draft)
      previewHeight = math.ceil(measure:GetStringHeight()) + 10
      preview:SetHeight(previewHeight)
      message:SetHeight(previewHeight - 8)
    end
    local sourceY = 28 + previewHeight + 23 + (pane.selectedCrafter and 22 or 0)
    source:SetPoint("BOTTOMLEFT", 0, sourceY)
    source:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, sourceY)
    total:SetPoint("BOTTOMLEFT", 0, sourceY + 14)
    total:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, sourceY + 14)
    local footer = sourceY + 32
    materialsScroll:SetPoint("BOTTOMRIGHT", -24, footer)
    local height = 110 + enchantsScroll:GetHeight()
    if #pane.pendingEnchants > 0 then
      local materialHeight = ROW_HEIGHT * math.max(1, math.min(6, #pane.materials))
      height = 69 + 25 + enchantsScroll:GetHeight() + 47 + materialHeight + footer + 1
    end
    local changed = pane.contentHeight ~= height
    pane.contentHeight = height
    return changed
  end
  message:SetScript("OnTextChanged", function(box, edited)
    if edited then box:SetText(pane.messages[pane.part] or "") end
  end)
  message:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
  message:SetScript("OnMouseUp", function(box) box:HighlightText() end)
  message:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
  pane:SetScript("OnHide", function() message:ClearFocus() end)
  pane.message, pane.messageLabel, pane.copy, pane.nextPart = message, messageLabel, copy, nextPart
  pane.recipientName, pane.who, pane.whisper, pane.clearRecipient = recipientName, who, whisper, clearRecipient

  local function contactName(crafter)
    return crafter.area and (crafter.name .. "  ·  " .. crafter.area) or crafter.name
  end

  local showPart
  local function renderRecipient(crafter)
    if (pane.selectedCrafter and pane.selectedCrafter.key) ~= (crafter and crafter.key) then pane.part = 1 end
    pane.selectedCrafter = crafter
    pane.messages = crafter and prepareMessages(crafter.matches) or pane.tradeMessages
    showPart()
    local selected = crafter ~= nil
    recipient:SetShown(selected)
    whisper:SetShown(selected)
    accent(find, not contacts:IsShown() and not selected and "gold" or nil)
    copy:SetPoint("BOTTOMRIGHT", selected and -79 or 0, 1)
    if selected then
      recipientName:SetText(contactName(crafter))
      who:SetShown(services.canWho())
      who:SetEnabled(services.whoReady())
    end
  end
  who:SetScript("OnClick", function()
    if pane.selectedCrafter then services.who(pane.selectedCrafter) end
  end)
  clearRecipient:SetScript("OnClick", function()
    pane.selectedKey = nil
    pane:RefreshContacts()
  end)
  whisper:SetScript("OnClick", function()
    local crafter = pane.selectedCrafter
    if not crafter then return end
    message:ClearFocus()
    services.whisper(crafter.name, pane.messages[pane.part])
  end)

  showPart = function()
    local parts = pane.messages
    pane.part = math.max(1, math.min(pane.part, #parts))
    local nextText = parts[pane.part] or ""
    if message:GetText() ~= nextText then
      message:SetText(nextText)
      message:SetCursorPosition(0)
    end
    preview:SetShown(#parts > 0)
    message:SetShown(#parts > 0)
    copy:SetShown(#parts > 0)
    prev:SetShown(#parts > 1)
    nextPart:SetShown(#parts > 1)
    local title = pane.selectedCrafter and "Whisper draft" or "Trade message"
    if #parts > 1 then title = title .. "  " .. pane.part .. "/" .. #parts end
    messageLabel:SetText(#parts > 0 and title or "")
    prev:SetEnabled(pane.part > 1)
    nextPart:SetEnabled(pane.part < #parts)
    if layoutDraft(list:GetWidth()) then parent:FitToScreen() end
  end
  prev:SetScript("OnClick", function() pane.part = pane.part - 1; showPart() end)
  nextPart:SetScript("OnClick", function() pane.part = pane.part + 1; showPart() end)
  copy:SetScript("OnClick", function()
    message:SetFocus()
    message:HighlightText()
  end)

  local function rowFrame(area, i)
    local row = CreateFrame("Frame", nil, area)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", area, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", 5, 0)
    icon:SetSize(16, 16)
    local line = row:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT", 5, 0)
    line:SetPoint("BOTTOMRIGHT", -5, 0)
    line:SetHeight(1)
    line:SetColorTexture(0.62, 0.48, 0.32, 0.17)
    row.icon = icon
    return row
  end

  local function enchantRow(i)
    if pane.enchantRows[i] then return pane.enchantRows[i] end
    local row = rowFrame(enchantsArea, i)
    local add = control("+", row)
    add:SetSize(23, 21)
    add:SetPoint("RIGHT", -5, 0)
    add:SetScript("OnClick", function() pane:ChangeQuantity(row.id, 1) end)
    local count = text(row, "GameFontHighlightSmall")
    count:SetWidth(30)
    count:SetJustifyH("CENTER")
    count:SetPoint("RIGHT", add, "LEFT", -3, 0)
    local remove = control("−", row)
    remove:SetSize(23, 21)
    remove:SetPoint("RIGHT", count, "LEFT", -3, 0)
    remove:SetScript("OnClick", function() pane:ChangeQuantity(row.id, -1) end)
    local name = text(row, "GameFontHighlightSmall")
    name:SetPoint("LEFT", 49, 0)
    local done = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    done:SetSize(24, 24)
    done:SetPoint("LEFT", 0, 0)
    row.icon:SetPoint("LEFT", 27, 0)
    done:SetScript("OnClick", function(button) pane:MarkDone(row.id, button:GetChecked()) end)
    tooltip(done, "Mark all copies of this enchant complete. Uncheck to add them back.")
    name:SetPoint("RIGHT", remove, "LEFT", -4, 0)
    row.count, row.name, row.add, row.remove, row.done = count, name, add, remove, done
    pane.enchantRows[i] = row
    return row
  end

  local function materialRow(i)
    if pane.materialRows[i] then return pane.materialRows[i] end
    local row = rowFrame(materialsArea, i)
    local values, offset = materialColumns(row, row)
    local button = control("", row, true)
    button:SetHeight(ROW_HEIGHT)
    button:SetPoint("LEFT", 21, 0)
    button:SetPoint("RIGHT", row, "RIGHT", offset - 3, 0)
    button.text:SetJustifyH("LEFT")
    button:SetScript("OnClick", function() pane:SearchOne(row.material) end)
    button:SetScript("OnEnter", function(buttonFrame)
      GameTooltip:SetOwner(buttonFrame, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(row.material.id)
      if row.material.buy > 0 then GameTooltip:AddLine("Click to search this material", 0.75, 0.75, 0.85) end
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    row.values, row.name = values, button
    pane.materialRows[i] = row
    return row
  end

  local matchesHeading = text(contacts, "GameFontNormal", "Enchanters")
  matchesHeading:SetPoint("TOPLEFT", 0, -4)
  local closeContacts = control("×", contacts, true)
  closeContacts:SetSize(24, 23)
  closeContacts:SetPoint("TOPRIGHT", 0, 2)
  tooltip(closeContacts, "Collapse enchanters.")
  local checkNext = control("Check next", contacts)
  checkNext:SetSize(110, 23)
  checkNext:SetPoint("RIGHT", closeContacts, "LEFT", -5, 0)
  tooltip(checkNext, "Run one /who lookup. Unchecked contacts with unknown status come first.")
  local finder = {checked = {}}
  local checkTarget

  local function showCheckState(button)
    local waiting = services.whoWait()
    local label
    if type(waiting) == "number" then label = "Check in " .. waiting .. "s"
    elseif waiting then label = waiting
    elseif checkTarget then label = next(finder.checked) and "Check next" or "Check online"
    else label = "Check again" end
    if button.lastLabel ~= label then
      button.lastLabel = label
      button:SetText(label)
    end
    if type(waiting) ~= "number" then button:SetScript("OnUpdate", nil) end
  end

  local function nextCandidate()
    local candidate
    for _, crafter in ipairs(pane.orderedContacts) do
      if not finder.checked[crafter.key] then
        if crafter.status == 2 then return crafter end
        candidate = candidate or crafter
      end
    end
    return candidate
  end

  checkNext:SetScript("OnClick", function()
    if not services.whoReady() then return end
    if not checkTarget then
      wipe(finder.checked)
      checkTarget = nextCandidate()
    end
    if checkTarget then services.who(checkTarget, finder) end
  end)
  pane.checkNext = checkNext
  local contactsScroll, contactsArea = scroller(contacts)
  contactsScroll:SetPoint("TOPLEFT", 0, -32)
  contactsScroll:SetPoint("BOTTOMRIGHT", -24, 0)
  local noMatches = text(contactsArea, "GameFontDisableSmall")
  noMatches:SetPoint("TOPLEFT", 8, -7)

  function pane:FindingEnchanters()
    return contacts:IsShown()
  end

  function pane:ExtraWidth()
    return self:FindingEnchanters() and (CONTACT_WIDTH + CONTACT_GAP) or 0
  end

  local function showContacts(show)
    contacts:SetShown(show)
    paintToggle(show)
    find:SetEnabled(show or #pane.pendingEnchants > 0)
    parent:FitToScreen()
    if show then
      contactsScroll:SetVerticalScroll(0)
      parent:RefreshPresence()
    end
  end
  find:SetScript("OnClick", function() showContacts(not pane:FindingEnchanters()) end)
  closeContacts:SetScript("OnClick", function() showContacts(false) end)
  pane.closeContacts = closeContacts

  local function contactRow(i)
    if pane.contactRows[i] then return pane.contactRows[i] end
    local row = CreateFrame("Button", nil, contactsArea)
    row:SetHeight(CONTACT_HEIGHT)
    row:SetPoint("TOPLEFT", contactsArea, "TOPLEFT", 0, -(i - 1) * CONTACT_HEIGHT)
    row:SetPoint("TOPRIGHT", contactsArea, "TOPRIGHT", 0, -(i - 1) * CONTACT_HEIGHT)
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local selectedBar = row:CreateTexture(nil, "ARTWORK")
    selectedBar:SetPoint("TOPLEFT", 0, -2)
    selectedBar:SetPoint("BOTTOMLEFT", 0, 2)
    selectedBar:SetWidth(2)
    selectedBar:SetColorTexture(0.9, 0.69, 0.32, 1)
    row.selectedBar = selectedBar
    local selectContact = control("Select", row)
    selectContact:SetSize(63, 20)
    selectContact:SetPoint("BOTTOMRIGHT", -6, 4)
    local whoContact = control("Who", row, true)
    whoContact:SetSize(39, 20)
    whoContact:SetPoint("RIGHT", selectContact, "LEFT", -4, 0)
    whoContact:SetScript("OnClick", function() services.who(row.crafter, finder) end)
    tooltip(whoContact, "Check this enchanter's online status and zone.")
    local function choose()
      pane.selectedKey = row.crafter.key
      if GameTooltip then GameTooltip:Hide() end
      pane:RefreshContacts()
    end
    row:SetScript("OnClick", choose)
    selectContact:SetScript("OnClick", choose)
    local name = text(row, "GameFontHighlight")
    local coverage = text(row, "GameFontNormalSmall")
    coverage:SetPoint("TOPRIGHT", -7, -5)
    row.coverage = coverage
    name:SetPoint("TOPLEFT", 8, -4)
    name:SetPoint("TOPRIGHT", coverage, "TOPLEFT", -8, 1)
    local status = text(row, "GameFontDisableSmall")
    status:SetPoint("LEFT", 8, -9)
    status:SetPoint("RIGHT", whoContact, "LEFT", -4, 0)
    row:SetScript("OnEnter", function(button)
      GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
      GameTooltip:SetText(row.crafter.name)
      if not row.crafter.area then GameTooltip:AddLine("Use Who to check their zone.", 0.75, 0.75, 0.75) end
      for _, enchant in ipairs(row.crafter.matches) do GameTooltip:AddLine(enchant.name, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row.name, row.status, row.selectContact, row.whoContact = name, status, selectContact, whoContact
    pane.contactRows[i] = row
    return row
  end

  function pane:RefreshContacts()
    local picking = self:FindingEnchanters()
    if not picking and not self.selectedKey then
      renderRecipient(nil)
      return
    end
    local byName, matches = {}, {}
    local zones = services.zones()
    for _, enchant in ipairs(self.pendingEnchants) do
      local only = not picking and self.selectedKey or nil
      for _, known in ipairs(services.knownBy(enchant.recipe.id, parent.presence, only, true)) do
        if known.key ~= parent.ownName then
          local crafter = byName[known.key]
          if not crafter then
            crafter = known
            crafter.matches = {}
            crafter.area = parent.contactAreas and parent.contactAreas[crafter.key]
            local areaKey = services.zoneKey(crafter.area)
            crafter.sameZone = areaKey ~= nil and zones[areaKey] == true
            byName[crafter.key] = crafter
            matches[#matches + 1] = crafter
          end
          crafter.matches[#crafter.matches + 1] = enchant
        end
      end
    end
    local selected = byName[self.selectedKey]
    if not selected then self.selectedKey = nil end
    renderRecipient(selected)
    if not picking then return end
    table.sort(matches, function(a, b)
      if a.status ~= b.status then return a.status < b.status end
      if #a.matches ~= #b.matches then return #a.matches > #b.matches end
      if a.sameZone ~= b.sameZone then return a.sameZone end
      if a.lastSeenAt ~= b.lastSeenAt then return a.lastSeenAt > b.lastSeenAt end
      return a.key < b.key
    end)
    self.orderedContacts = matches
    checkTarget = nextCandidate()
    checkNext:SetShown(#matches > 0 and services.canWho())
    local whoReady = services.whoReady()
    checkNext:SetEnabled(whoReady)
    accent(checkNext, whoReady and "lookup" or nil)
    showCheckState(checkNext)
    local waiting = services.whoWait()
    if type(waiting) == "number" then checkNext:SetScript("OnUpdate", showCheckState) end
    for i, crafter in ipairs(matches) do
      local row = contactRow(i)
      row.crafter = crafter
      row.name:SetText(contactName(crafter))
      row.coverage:SetText(("%d/%d %s"):format(#crafter.matches, #self.pendingEnchants, #self.pendingEnchants == 1 and "enchant" or "enchants"))
      row.status:SetText(services.status(crafter) .. (crafter.sameZone and "  ·  Same zone" or ""))
      row.selectedBar:SetShown(crafter.key == self.selectedKey)
      row.selectContact:SetText(crafter.key == self.selectedKey and "Selected" or "Select")
      row.whoContact:SetShown(services.canWho())
      row.whoContact:SetEnabled(services.whoReady())
      row:Show()
    end
    for i = #matches + 1, #self.contactRows do self.contactRows[i]:Hide() end
    noMatches:SetShown(#matches == 0)
    noMatches:SetText(#self.pendingEnchants > 0 and "No matches yet. Use the trade message." or "No pending enchants.")
    contactsScroll:SetContentHeight(math.max(1, #matches) * CONTACT_HEIGHT)
  end

  function pane:Fit(width)
    list:SetWidth(width)
    layoutDraft(width)
    enchantsArea:SetWidth(width - 24)
    materialsArea:SetWidth(width - 24)
    contactsArea:SetWidth(CONTACT_WIDTH - 24)
  end

  function pane:SearchOne(material)
    if not material or material.buy == 0 then return end
    if not services.auctionOpen() then
      services.say("Open the Auction House first.")
      return
    end
    if material.name == "item:" .. material.id then
      services.say("Still loading this material's name. Try again shortly.")
    elseif services.searchNative(material.name) then
      self.lastSearched = material.id
    else
      services.say("The built-in Auction House search is unavailable.")
    end
  end

  function pane:UseBatch()
    return not self.nativeOnly and services.canBatch()
  end

  function pane:Search()
    if not services.auctionOpen() then
      services.say("Open the Auction House first.")
      return
    end
    if self:UseBatch() then
      local names, advanced = {}, {}
      for _, material in ipairs(self.materials) do
        if material.buy > 0 and material.name ~= "item:" .. material.id then
          names[#names + 1] = material.name
          advanced[#advanced + 1] = {searchString = material.name, isExact = true, quantity = material.buy}
        end
      end
      if #names == 0 then
        services.say("Still loading material names. Try again shortly.")
        return
      end
      if services.searchBatch(names, advanced) then return end
      self.nativeOnly = true
      search:SetText("Search next item")
    end

    local count, lastIndex = #self.materials, 0
    for i, material in ipairs(self.materials) do
      if material.id == self.lastSearched then lastIndex = i; break end
    end
    for i = 1, count do
      local material = self.materials[(lastIndex + i - 1) % count + 1]
      if material.buy > 0 and material.name ~= "item:" .. material.id then
        self:SearchOne(material)
        return
      end
    end
    services.say("Still loading material names. Try again shortly.")
  end
  search:SetScript("OnClick", function() pane:Search() end)

  function pane:Refresh()
    local enchants, pending, materials, needed = {}, {}, {}, {}
    local unknown, doneCount = 0, 0
    for id in pairs(EnchantBookShopping) do
      local recipe, quantity = services.recipe(id), self:Quantity(id)
      if recipe and quantity > 0 then
        local done = self:IsDone(id)
        local entry = {recipe = recipe, quantity = quantity, name = services.enchantName(recipe), done = done}
        enchants[#enchants + 1] = entry
        if done then
          doneCount = doneCount + 1
        else
          if #recipe.r == 0 then unknown = unknown + 1 end
          for _, reagent in ipairs(recipe.r) do
            needed[reagent[1]] = (needed[reagent[1]] or 0) + reagent[2] * quantity
          end
        end
      end
    end
    table.sort(enchants, function(a, b)
      if a.done ~= b.done then return not a.done end
      if a.name ~= b.name then return a.name < b.name end
      return a.recipe.id < b.recipe.id
    end)
    for id, amount in pairs(needed) do
      local have = services.bagCount(id)
      materials[#materials + 1] = {
        id = id, name = services.itemName(id), needed = amount, have = have,
        buy = math.max(0, amount - (have or 0)),
      }
    end
    table.sort(materials, function(a, b)
      if (a.buy > 0) ~= (b.buy > 0) then return a.buy > 0 end
      if a.name ~= b.name then return a.name < b.name end
      return a.id < b.id
    end)
    self.materials = materials

    for i, entry in ipairs(enchants) do
      local row = enchantRow(i)
      row.id = entry.recipe.id
      row.icon:SetTexture(services.spellIcon(entry.recipe))
      row.name:SetText(entry.name)
      row.count:SetText(entry.quantity)
      row.done:SetChecked(entry.done)
      row.add:SetEnabled(not entry.done and entry.quantity < MAX_QUANTITY)
      row.remove:SetEnabled(not entry.done)
      if entry.done then
        row.name:SetTextColor(0.57, 0.55, 0.51)
      else
        row.name:SetTextColor(1, 0.95, 0.86)
        pending[#pending + 1] = entry
      end
      row:Show()
    end
    for i = #enchants + 1, #self.enchantRows do self.enchantRows[i]:Hide() end
    self.pendingEnchants = pending
    find:SetEnabled(#pending > 0 or self:FindingEnchanters())
    clearDone:SetShown(doneCount > 0)
    clearList:SetShown(#enchants > 0 or self.clearedList ~= nil)
    clearList:SetText(self.clearedList and "Undo clear" or "Clear list")
    browse:SetShown(#enchants == 0)
    enchantHeading:SetText(#enchants == 0 and "Your list is empty" or (#pending == 0 and "All enchants complete" or "Enchants"))
    local enchantHeight = ROW_HEIGHT * math.max(1, math.min(4, #enchants))
    enchantsScroll:SetHeight(enchantHeight)
    materialSection:SetShown(#pending > 0)
    if #pending == 0 and self:FindingEnchanters() then showContacts(false) end
    find:SetShown(#pending > 0)
    enchantsScroll:SetContentHeight(ROW_HEIGHT * math.max(1, #enchants))

    local prices, buyReagents = {}, {}
    local subtotal, unpriced = 0, 0
    for i, material in ipairs(materials) do
      local row = materialRow(i)
      row.material = material
      row.icon:SetTexture(services.itemIcon(material.id))
      row.name:SetText(services.coloredItem(material.id))
      row.values.needed:SetText(material.needed)
      row.values.have:SetText(material.have or "—")
      row.values.buy:SetText(material.buy)
      if material.buy > 0 then row.values.buy:SetTextColor(1, 0.82, 0.49)
      else row.values.buy:SetTextColor(0.55, 0.78, 0.53) end
      local price
      if material.buy > 0 then
        price = services.unitPrice(material.id, prices)
        subtotal = subtotal + (price or 0) * material.buy
        unpriced = unpriced + (price and 0 or 1)
        buyReagents[#buyReagents + 1] = {material.id, material.buy}
      end
      row.values.cost:SetText(price and services.money(price * material.buy) or (material.buy > 0 and "Unpriced" or "—"))
      row:Show()
    end
    for i = #materials + 1, #self.materialRows do self.materialRows[i]:Hide() end
    emptyMaterials:SetShown(#materials == 0)
    materialsScroll:SetContentHeight(ROW_HEIGHT * math.max(1, #materials))

    local estimate = services.costLabel(subtotal, unpriced)
    if unknown > 0 and unpriced == 0 then
      estimate = subtotal > 0 and ("≥" .. estimate) or "Unavailable"
    end
    local totalText = "Estimated to buy  ·  " .. estimate
    if unknown == 0 and #buyReagents == 0 then totalText = "All mats in bags" end
    total:SetText(#pending == 0 and "" or totalText)
    emptyMaterials:SetText(unknown > 0 and "Reagents unknown for this list." or "No materials required.")
    local sources = services.priceSources({r = buyReagents}, prices)
    if unknown > 0 then
      sources = sources .. (sources ~= "" and "  ·  " or "") .. "Reagents unknown for " .. unknown
    end
    source:SetText(sources)
    local auctionOpen = services.auctionOpen()
    search:SetText(auctionOpen and (self:UseBatch() and "Search Auctionator" or "Search next item") or "Open AH to search")
    search:SetEnabled(auctionOpen == true)
    accent(search, auctionOpen and "lookup" or nil)
    search:SetShown(#buyReagents > 0)
    self.tradeMessages = prepareMessages(pending)
    self:RefreshContacts()
  end

  if ns.performance then
    pane.Refresh = ns.performance.Wrap("Refresh shopping list", pane.Refresh)
    pane.RefreshContacts = ns.performance.Wrap("Rank enchanters", pane.RefreshContacts)
  end
  return pane
end
