local ADDON_NAME = ...

local defaults = {
  point = "CENTER",
  relativePoint = "CENTER",
  x = 0,
  y = 160,
  size = 96,
  shown = true,
  debug = false,
  lastSlot = nil,
}

local db
local hookedButtons = {}
local mouseBoundSlots = {}
local mouseBoundDirections = {}
local lastHookScan = 0
local updatePowerBar

local frame = CreateFrame("Button", "DKGunShuBiaoFrame", UIParent, "BackdropTemplate")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:SetFrameStrata("HIGH")
frame:SetSize(defaults.size, defaults.size)
frame:SetBackdrop({
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
})
frame:SetBackdropColor(0, 0, 0, 0.25)
frame:SetBackdropBorderColor(0, 0, 0, 0.85)

local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints(frame)
icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
cooldown:SetAllPoints(frame)

local countText = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 3)
countText:SetText("")

local slotText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
slotText:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -3)
slotText:SetTextColor(1, 0.9, 0.3)
slotText:SetText("")

local upMarker = frame:CreateTexture(nil, "OVERLAY")
upMarker:SetTexture("Interface\\AddOns\\DKGunShuBiao\\media\\wheel-up.tga")
upMarker:SetPoint("BOTTOM", frame, "TOP", 0, 3)
upMarker:Hide()

local downMarker = frame:CreateTexture(nil, "OVERLAY")
downMarker:SetTexture("Interface\\AddOns\\DKGunShuBiao\\media\\wheel-down.tga")
downMarker:SetPoint("TOP", frame, "BOTTOM", 0, -3)
downMarker:Hide()

local powerBar = CreateFrame("StatusBar", nil, frame, "BackdropTemplate")
powerBar:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, 0)
powerBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 6, 0)
powerBar:SetWidth(24)
powerBar:SetMinMaxValues(0, 100)
powerBar:SetValue(0)
powerBar:SetOrientation("VERTICAL")
powerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
powerBar:SetStatusBarColor(0, 0.82, 1, 0.95)
powerBar:SetBackdrop({
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
})
powerBar:SetBackdropColor(0, 0, 0, 0.55)
powerBar:SetBackdropBorderColor(0, 0, 0, 0.9)

local powerText = powerBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
powerText:SetPoint("CENTER", powerBar, "CENTER", 0, 0)
powerText:SetTextColor(1, 1, 1)
powerText:SetText("")

local function copyDefaults()
  DKGunShuBiaoDB = DKGunShuBiaoDB or {}
  db = DKGunShuBiaoDB
  for key, value in pairs(defaults) do
    if db[key] == nil then
      db[key] = value
    end
  end
end

local function debugPrint(...)
  if db and db.debug then
    print("|cff66ccffDK滚鼠标:|r", ...)
  end
end

local function getButtonSlot(button)
  if not button then
    return nil
  end

  local slot = button.action or button._state_action
  if not slot and button.GetAttribute then
    slot = button:GetAttribute("action")
      or button:GetAttribute("action1")
      or button:GetAttribute("labaction-0")
      or button:GetAttribute("labaction-1")
  end

  slot = tonumber(slot)
  if slot and slot > 0 then
    return slot
  end
end

local function isMouseKey(key)
  if type(key) ~= "string" then
    return false
  end
  return key:match("MOUSEWHEELUP$") ~= nil
    or key:match("MOUSEWHEELDOWN$") ~= nil
    or key:match("BUTTON%d+$") ~= nil
end

local function getDirectionFromKey(key)
  if type(key) ~= "string" then
    return nil
  end
  if key:match("MOUSEWHEELUP$") then
    return "UP"
  elseif key:match("MOUSEWHEELDOWN$") then
    return "DN"
  end
end

local function addBindingTarget(targets, target)
  if type(target) == "string" and target ~= "" then
    targets[target] = true
  end
end

local function getButtonBindingTargets(button)
  local targets = {}
  if not button then
    return targets
  end

  addBindingTarget(targets, button.keyBoundTarget)
  addBindingTarget(targets, button.bindName)

  if button.config then
    addBindingTarget(targets, button.config.keyBoundTarget)
  end

  local name = button.GetName and button:GetName()
  if name then
    addBindingTarget(targets, name)
    addBindingTarget(targets, "CLICK " .. name .. ":Keybind")
    addBindingTarget(targets, "CLICK " .. name .. ":LeftButton")
  end

  return targets
end

local function buttonHasMouseBinding(button)
  local slot = getButtonSlot(button)
  local targets = getButtonBindingTargets(button)

  for target in pairs(targets) do
    for i = 1, select("#", GetBindingKey(target)) do
      local key = select(i, GetBindingKey(target))
      if isMouseKey(key) then
        if slot then
          mouseBoundSlots[slot] = true
          mouseBoundDirections[slot] = getDirectionFromKey(key) or mouseBoundDirections[slot]
        end
        return true, key, target
      end
    end
  end

  return false
end

local function applyPosition()
  frame:ClearAllPoints()
  frame:SetSize(db.size, db.size)
  upMarker:SetSize(db.size, math.max(12, math.floor(db.size * 0.25)))
  downMarker:SetSize(db.size, math.max(12, math.floor(db.size * 0.25)))
  powerBar:SetWidth(math.max(22, math.floor(db.size * 0.26)))
  frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
  if db.shown then
    frame:Show()
  else
    frame:Hide()
  end
  updatePowerBar()
end

updatePowerBar = function()
  local maxPower = UnitPowerMax("player", Enum and Enum.PowerType and Enum.PowerType.RunicPower or 6) or 0
  local power = UnitPower("player", Enum and Enum.PowerType and Enum.PowerType.RunicPower or 6) or 0

  powerBar:SetMinMaxValues(0, maxPower > 0 and maxPower or 100)
  powerBar:SetValue(power)
  powerText:SetText(tostring(power) .. "/" .. tostring(maxPower))

  if select(2, UnitClass("player")) == "DEATHKNIGHT" then
    powerBar:Show()
  else
    powerBar:Hide()
  end
end

local function updateCooldown(slot)
  local start, duration, enable, modRate = GetActionCooldown(slot)
  start = start or 0
  duration = duration or 0
  modRate = modRate or 1

  if duration > 0 and start > 0 and enable ~= 0 then
    if cooldown.SetCooldown then
      cooldown:SetCooldown(start, duration, modRate)
    end
    cooldown:Show()
  else
    if cooldown.Clear then
      cooldown:Clear()
    elseif cooldown.SetCooldown then
      cooldown:SetCooldown(0, 0)
    end
    cooldown:Hide()
  end
end

local function setDirection(direction)
  if direction == "UP" then
    upMarker:Show()
    downMarker:Hide()
  elseif direction == "DN" then
    upMarker:Hide()
    downMarker:Show()
  else
    upMarker:Hide()
    downMarker:Hide()
  end
end

local function showSlot(slot, source, direction)
  slot = tonumber(slot)
  if not slot or slot <= 0 or not HasAction(slot) then
    return
  end

  db.lastSlot = slot
  db.lastDirection = direction or db.lastDirection
  local texture = GetActionTexture(slot) or "Interface\\Icons\\INV_Misc_QuestionMark"
  local count = GetActionCount(slot)

  icon:SetTexture(texture)
  countText:SetText(count and count > 0 and count or "")
  slotText:SetText(tostring(slot))
  setDirection(db.lastDirection)
  updateCooldown(slot)
  updatePowerBar()

  if not db.shown then
    db.shown = true
    frame:Show()
  end

  debugPrint("slot", slot, source or "", db.lastDirection or "")
end

local function refreshLast()
  if db and db.lastSlot then
    showSlot(db.lastSlot, "refresh")
  end
end

local function shouldHookFrame(obj)
  if type(obj) ~= "table" or hookedButtons[obj] then
    return false
  end
  if not obj.GetObjectType or not obj.HookScript then
    return false
  end

  if getButtonSlot(obj) then
    return true
  end

  local name = obj.GetName and obj:GetName()
  if type(name) ~= "string" then
    return false
  end

  return name:find("ActionButton", 1, true)
    or name:find("MultiBar", 1, true)
    or name:find("NDui_ActionBar", 1, true)
end

local function hookButton(button, source)
  if not shouldHookFrame(button) then
    return
  end

  hookedButtons[button] = true

  button:HookScript("PreClick", function(self)
    local slot = getButtonSlot(self)
    local hasMouseBinding, key = buttonHasMouseBinding(self)
    if slot and hasMouseBinding then
      showSlot(slot, source .. ":PreClick:" .. tostring(key), getDirectionFromKey(key))
    end
  end)

  button:HookScript("PostClick", function(self)
    local slot = getButtonSlot(self)
    local hasMouseBinding, key = buttonHasMouseBinding(self)
    if slot and hasMouseBinding then
      showSlot(slot, source .. ":PostClick:" .. tostring(key), getDirectionFromKey(key))
    end
  end)
end

local function hookKnownButtons()
  local prefixes = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "BonusActionButton",
  }

  for _, prefix in ipairs(prefixes) do
    for i = 1, 12 do
      hookButton(_G[prefix .. i], prefix)
    end
  end

  for bar = 1, 8 do
    local header = _G["NDui_ActionBar" .. bar]
    if header and header.buttons then
      for _, button in pairs(header.buttons) do
        hookButton(button, "NDui_ActionBar" .. bar)
      end
    end
    for i = 1, 12 do
      hookButton(_G["NDui_ActionBar" .. bar .. "Button" .. i], "NDui_ActionBar" .. bar)
    end
  end

  local lib = LibStub and LibStub("LibActionButton-1.0-NDui", true)
  if lib then
    if not frame._dkmLabCallbacks then
      frame._dkmLabCallbacks = true
      if lib.RegisterCallback then
        lib.RegisterCallback(frame, "OnButtonCreated", function(_, button)
          hookButton(button, "LAB:created")
        end)
        lib.RegisterCallback(frame, "OnButtonUpdate", function(_, button)
          hookButton(button, "LAB:update")
        end)
      end
    end
    if lib.GetAllButtons then
      for button in pairs(lib:GetAllButtons()) do
        hookButton(button, "LAB:scan")
      end
    elseif lib.buttonRegistry then
      for button in pairs(lib.buttonRegistry) do
        hookButton(button, "LAB:registry")
      end
    end
  end
end

local function hookUseAction()
  if frame._dkmUseActionHooked or not hooksecurefunc then
    return
  end
  frame._dkmUseActionHooked = true

  hooksecurefunc("UseAction", function(slot)
    slot = tonumber(slot)
    if slot and mouseBoundSlots[slot] then
      showSlot(slot, "UseAction:mouse-bound", mouseBoundDirections[slot])
    end
  end)

  if ActionButtonDown then
    hooksecurefunc("ActionButtonDown", function(id)
      local slot = tonumber(id)
      if slot and mouseBoundSlots[slot] then
        showSlot(slot, "ActionButtonDown:mouse-bound", mouseBoundDirections[slot])
      end
    end)
  end

  if ActionButtonUp then
    hooksecurefunc("ActionButtonUp", function(id)
      local slot = tonumber(id)
      if slot and mouseBoundSlots[slot] then
        showSlot(slot, "ActionButtonUp:mouse-bound", mouseBoundDirections[slot])
      end
    end)
  end
end

frame:SetScript("OnDragStart", function(self)
  if IsShiftKeyDown() then
    self:StartMoving()
  end
end)

frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relativePoint, x, y = self:GetPoint(1)
  db.point = point or "CENTER"
  db.relativePoint = relativePoint or "CENTER"
  db.x = x or 0
  db.y = y or 0
end)

frame:SetScript("OnUpdate", function(_, elapsed)
  frame.elapsed = (frame.elapsed or 0) + elapsed
  if frame.elapsed >= 0.15 then
    frame.elapsed = 0
    refreshLast()
  end

  lastHookScan = lastHookScan + elapsed
  if lastHookScan >= 2 then
    lastHookScan = 0
    hookKnownButtons()
  end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterEvent("UNIT_POWER_UPDATE")
frame:RegisterEvent("UNIT_POWER_FREQUENT")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    copyDefaults()
    applyPosition()
  elseif event == "PLAYER_LOGIN" then
    copyDefaults()
    applyPosition()
    hookUseAction()
    hookKnownButtons()
    C_Timer.After(1, hookKnownButtons)
    C_Timer.After(3, hookKnownButtons)
    C_Timer.After(8, hookKnownButtons)
    refreshLast()
    print("|cff66ccffDK滚鼠标|r loaded. /dkm, /dkm debug, Shift-drag to move.")
  elseif event == "ACTIONBAR_SLOT_CHANGED" then
    if arg1 == 0 or arg1 == db.lastSlot then
      refreshLast()
    end
  elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
    if arg1 == "player" then
      updatePowerBar()
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    updatePowerBar()
    refreshLast()
  else
    refreshLast()
  end
end)

SLASH_DKGUNSHUBIAO1 = "/dkm"
SlashCmdList.DKGUNSHUBIAO = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "debug" then
    db.debug = not db.debug
    print("|cff66ccffDK滚鼠标 debug:|r", db.debug and "on" or "off")
  elseif msg == "hide" then
    db.shown = false
    frame:Hide()
  elseif msg == "show" then
    db.shown = true
    frame:Show()
  elseif msg == "reset" then
    db.point = defaults.point
    db.relativePoint = defaults.relativePoint
    db.x = defaults.x
    db.y = defaults.y
    db.size = defaults.size
    db.shown = true
    applyPosition()
  elseif msg:match("^size%s+%d+$") then
    local size = tonumber(msg:match("%d+"))
    db.size = math.max(32, math.min(160, size))
    applyPosition()
  else
    db.shown = not db.shown
    if db.shown then
      frame:Show()
    else
      frame:Hide()
    end
    print("|cff66ccffDK滚鼠标:|r /dkm show, /dkm hide, /dkm reset, /dkm size 96, /dkm debug")
  end
end
