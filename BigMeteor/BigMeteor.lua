local ADDON_NAME = ...

local addon = CreateFrame("Frame")

local defaults = {
  position = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -80,
  },
  scale = 1,
  alpha = 1,
  locked = false,
  auraIDs = {
    fireMark = 1295144,
    shadowMark = 1295140,
  },
  auraNames = {
    fireMark = "余烬印记",
    shadowMark = "暗影印记",
  },
  spellIDs = {
    immolate = 47811,
    conflagrate = 17962,
    shadowburn = 47827,
    shadowflame = 61290,
    meteor = 1295386,
    chaosBolt = 59172,
    incinerate = 47838,
  },
  dotAuraIDs = {
    immolate = 47811,
    shadowflame = 61291,
  },
  dotAuraNames = {
    immolate = "献祭",
    shadowflame = "暗影烈焰",
  },
}

local function applyFixedAuraConfig(db)
  db.auraIDs = db.auraIDs or {}
  db.auraNames = db.auraNames or {}
  db.spellIDs = db.spellIDs or {}
  db.dotAuraIDs = db.dotAuraIDs or {}
  db.dotAuraNames = db.dotAuraNames or {}
  db.auraIDs.fireMark = defaults.auraIDs.fireMark
  db.auraIDs.shadowMark = defaults.auraIDs.shadowMark
  db.auraNames.fireMark = defaults.auraNames.fireMark
  db.auraNames.shadowMark = defaults.auraNames.shadowMark

  for key, value in pairs(defaults.spellIDs) do
    db.spellIDs[key] = value
  end

  for key, value in pairs(defaults.dotAuraIDs) do
    db.dotAuraIDs[key] = value
  end

  for key, value in pairs(defaults.dotAuraNames) do
    db.dotAuraNames[key] = value
  end
end

local state = {
  targetExists = false,
  targetDead = false,
  fireStacks = 0,
  shadowStacks = 0,
  fireDuration = 0,
  shadowDuration = 0,
  fireExpires = 0,
  shadowExpires = 0,
  immolateExpires = 0,
  shadowflameExpires = 0,
  recommendations = {},
  debugLines = {},
}

local ui = {}
local stackMax = 6
local burstWindowSeconds = 2.6
local shadowburnStacks = 2
local shadowflameFireStacks = 2
local shadowflameShadowStacks = 2
local shadowflameTickShadowStacks = 1

local function copyDefaults(source, target)
  if type(source) ~= "table" then
    return target
  end

  if type(target) ~= "table" then
    target = {}
  end

  for key, value in pairs(source) do
    if type(value) == "table" then
      target[key] = copyDefaults(value, target[key])
    elseif target[key] == nil then
      target[key] = value
    end
  end

  return target
end

local function matchAura(auraSpellID, auraName, expectedSpellID, expectedName)
  if expectedSpellID and expectedSpellID ~= 0 and auraSpellID == expectedSpellID then
    return true
  end

  if expectedName and expectedName ~= "" and auraName and tostring(auraName) == tostring(expectedName) then
    return true
  end

  return false
end

local function normalizeCount(count)
  if count and count > 0 then
    return count
  end

  return 1
end

local function addAuraInfo(result, auraSpellID, auraName, count, duration, expires)
  result.stacks = math.max(result.stacks, normalizeCount(count))

  if duration and duration > 0 and expires and expires > 0 then
    local remaining = expires - GetTime()
    if remaining > result.remaining then
      result.remaining = remaining
      result.duration = duration
      result.expires = expires
    end
  end
end

local function getTargetDebuffInfo(unit, spellID, auraName)
  if (not spellID or spellID == 0) and (not auraName or auraName == "") then
    return 0, 0, 0
  end

  local result = {
    stacks = 0,
    duration = 0,
    expires = 0,
    remaining = 0,
  }

  for index = 1, 40 do
    local name, _, count, _, duration, expires, _, _, _, auraSpellID = UnitAura(unit, index, "HARMFUL")
    if not name then
      break
    end

    if matchAura(auraSpellID, name, spellID, auraName) then
      addAuraInfo(result, auraSpellID, name, count, duration, expires)
    end
  end

  if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
    for index = 1, 40 do
      local aura = C_UnitAuras.GetDebuffDataByIndex(unit, index)
      if not aura then
        break
      end

      if matchAura(aura.spellId, aura.name, spellID, auraName) then
        addAuraInfo(result, aura.spellId, aura.name, aura.applications or aura.charges, aura.duration, aura.expirationTime)
      end
    end
  end

  return result.stacks, result.duration, result.expires
end

local function formatRemaining(expires)
  if not expires or expires <= 0 then
    return ""
  end

  local remaining = expires - GetTime()
  if remaining <= 0 then
    return ""
  end

  if remaining >= 10 then
    return ("%d"):format(remaining + 0.5)
  end

  return ("%.1f"):format(remaining)
end

local function getRemaining(expires)
  if not expires or expires <= 0 then
    return 0
  end

  return math.max(0, expires - GetTime())
end

local function isSpellReady(spellID)
  if not spellID or spellID == 0 then
    return false
  end

  local start, duration, enabled = GetSpellCooldown(spellID)
  if enabled == 0 then
    return false
  end

  return not start or start == 0 or not duration or duration <= 1.5
end

local function getSpellCastSeconds(spellID, fallback)
  local castMS = select(4, GetSpellInfo(spellID))
  if castMS and castMS > 0 then
    return castMS / 1000
  end

  return fallback or 1.5
end

local function isRecommendationSame(left, right)
  return left == right
end

local function addRecommendation(list, spellID)
  if not spellID or spellID == 0 or #list >= 3 then
    return
  end

  if not GetSpellTexture(spellID) or not isSpellReady(spellID) then
    return
  end

  for _, existing in ipairs(list) do
    if isRecommendationSame(existing, spellID) then
      return
    end
  end

  list[#list + 1] = spellID
end

local function buildRecommendations()
  local spellIDs = BigMeteorDB.spellIDs
  local list = {}

  if not state.targetExists or state.targetDead then
    return list
  end

  local shadowburnReady = isSpellReady(spellIDs.shadowburn)
  local shadowflameReady = isSpellReady(spellIDs.shadowflame)
  local meteorReady = isSpellReady(spellIDs.meteor)
  local hasImmolate = getRemaining(state.immolateExpires) > 0
  local fireRemaining = getRemaining(state.fireExpires)
  local shadowflameRemaining = getRemaining(state.shadowflameExpires)
  local immolateRefreshSeconds = getSpellCastSeconds(spellIDs.immolate, 1.5)
  local immolateRefreshNeeded = getRemaining(state.immolateExpires) <= immolateRefreshSeconds
  local meteorCastSeconds = getSpellCastSeconds(spellIDs.meteor, 1.5)
  local fireReady = state.fireStacks >= stackMax
  local shadowReady = state.shadowStacks >= stackMax
  local shadowReadyByMeteorImpact = state.shadowStacks + shadowflameTickShadowStacks >= stackMax
    and shadowflameRemaining >= meteorCastSeconds
  local shadowburnCanFinish = fireReady and state.shadowStacks + shadowburnStacks >= stackMax
  local shadowflameFireStacksAfter = math.min(stackMax, state.fireStacks + shadowflameFireStacks)
  local shadowflameShadowStacksAfter = math.min(stackMax, state.shadowStacks + shadowflameShadowStacks)
  local shadowflameCanSetUpMeteor = shadowflameReady
    and meteorReady
    and shadowflameFireStacksAfter >= stackMax
    and shadowflameShadowStacksAfter >= stackMax
  local meteorNowReady = fireReady and (shadowReady or shadowReadyByMeteorImpact) and meteorReady
  local shadowburnSetupReady = shadowburnReady and meteorReady and shadowburnCanFinish

  if immolateRefreshNeeded and (not (meteorNowReady or shadowburnSetupReady or shadowflameCanSetUpMeteor) or fireRemaining <= burstWindowSeconds) then
    addRecommendation(list, spellIDs.immolate)
  end

  if meteorNowReady then
    addRecommendation(list, spellIDs.meteor)
    return list
  end

  if shadowburnSetupReady then
    addRecommendation(list, spellIDs.shadowburn)
    addRecommendation(list, spellIDs.meteor)
    return list
  end

  if shadowflameCanSetUpMeteor then
    addRecommendation(list, spellIDs.shadowflame)
    addRecommendation(list, spellIDs.meteor)
    return list
  end

  if state.shadowStacks < stackMax - 1 then
    addRecommendation(list, spellIDs.shadowflame)
  end

  if state.fireStacks < stackMax then
    if hasImmolate then
      addRecommendation(list, spellIDs.conflagrate)
    end
    addRecommendation(list, spellIDs.chaosBolt)
    addRecommendation(list, spellIDs.incinerate)
  end

  if state.shadowStacks < stackMax then
    addRecommendation(list, spellIDs.shadowflame)
  end

  addRecommendation(list, spellIDs.chaosBolt)
  addRecommendation(list, spellIDs.incinerate)

  return list
end

local function collectDebuffDebug(unit)
  local lines = {}

  if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
    for index = 1, 12 do
      local aura = C_UnitAuras.GetDebuffDataByIndex(unit, index)
      if not aura then
        break
      end

      local name = aura.name or "?"
      local auraSpellID = aura.spellId or 0
      local count = aura.applications or aura.charges or 0
      lines[#lines + 1] = ("%d:%s x%d"):format(auraSpellID, name, count)
    end
  else
    for index = 1, 12 do
      local name, _, _, count, _, _, _, _, _, debuffSpellID = UnitDebuff(unit, index)
      if not name then
        break
      end
      lines[#lines + 1] = ("%d:%s x%d"):format(debuffSpellID or 0, name, count or 0)
    end
  end

  return lines
end

local function updateBars()
  if not ui.frame then
    return
  end

  for index = 1, stackMax do
    if state.targetExists and not state.targetDead and index <= state.fireStacks then
      ui.leftStacks[index]:SetColorTexture(1.0, 0.12, 0.08, 1.0)
    else
      ui.leftStacks[index]:SetColorTexture(0.12, 0.03, 0.03, 0.18)
    end

    if state.targetExists and not state.targetDead and index <= state.shadowStacks then
      ui.rightStacks[index]:SetColorTexture(0.84, 0.36, 1.0, 1.0)
    else
      ui.rightStacks[index]:SetColorTexture(0.08, 0.04, 0.12, 0.18)
    end
  end

  ui.leftTime:SetText(formatRemaining(state.fireExpires))
  ui.rightTime:SetText(formatRemaining(state.shadowExpires))
  for index = 1, 3 do
    local recommendation = state.recommendations[index]
    local button = ui.recommendations[index]

    if recommendation then
      button.icon:SetTexture(GetSpellTexture(recommendation))
      button.icon:Show()
      button.text:SetText(GetSpellInfo(recommendation) or "")
      button.text:Show()
      button:Show()
    else
      button:Hide()
    end
  end
  ui.debugText:SetText(table.concat(state.debugLines, "\n"))
end

local function updateTimers()
  if not ui.frame then
    return
  end

  ui.leftTime:SetText(formatRemaining(state.fireExpires))
  ui.rightTime:SetText(formatRemaining(state.shadowExpires))
end

local function refreshState()
  state.targetExists = UnitExists("target") and true or false
  state.targetDead = UnitIsDead("target") and true or false

  if state.targetExists and not state.targetDead then
    state.fireStacks, state.fireDuration, state.fireExpires = getTargetDebuffInfo("target", BigMeteorDB.auraIDs.fireMark, BigMeteorDB.auraNames.fireMark)
    state.shadowStacks, state.shadowDuration, state.shadowExpires = getTargetDebuffInfo("target", BigMeteorDB.auraIDs.shadowMark, BigMeteorDB.auraNames.shadowMark)
    _, _, state.immolateExpires = getTargetDebuffInfo("target", BigMeteorDB.dotAuraIDs.immolate, BigMeteorDB.dotAuraNames.immolate)
    _, _, state.shadowflameExpires = getTargetDebuffInfo("target", BigMeteorDB.dotAuraIDs.shadowflame, BigMeteorDB.dotAuraNames.shadowflame)
    state.recommendations = buildRecommendations()
    state.debugLines = collectDebuffDebug("target")
  else
    state.fireStacks = 0
    state.shadowStacks = 0
    state.fireDuration = 0
    state.shadowDuration = 0
    state.fireExpires = 0
    state.shadowExpires = 0
    state.immolateExpires = 0
    state.shadowflameExpires = 0
    state.recommendations = {}
    state.debugLines = {}
  end

  updateBars()
end

local function savePosition()
  local point, _, relativePoint, x, y = ui.frame:GetPoint(1)
  BigMeteorDB.position.point = point
  BigMeteorDB.position.relativePoint = relativePoint
  BigMeteorDB.position.x = x
  BigMeteorDB.position.y = y
end

local function applyFrameSettings()
  local pos = BigMeteorDB.position
  ui.frame:ClearAllPoints()
  ui.frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
  ui.frame:SetScale(BigMeteorDB.scale or 1)
  ui.frame:SetAlpha(BigMeteorDB.alpha or 1)
end

local function addFlatBorder(frame, r, g, b, a)
  local top = frame:CreateTexture(nil, "BORDER")
  top:SetColorTexture(r, g, b, a)
  top:SetPoint("TOPLEFT")
  top:SetPoint("TOPRIGHT")
  top:SetHeight(1)

  local bottom = frame:CreateTexture(nil, "BORDER")
  bottom:SetColorTexture(r, g, b, a)
  bottom:SetPoint("BOTTOMLEFT")
  bottom:SetPoint("BOTTOMRIGHT")
  bottom:SetHeight(1)

  local left = frame:CreateTexture(nil, "BORDER")
  left:SetColorTexture(r, g, b, a)
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(1)

  local right = frame:CreateTexture(nil, "BORDER")
  right:SetColorTexture(r, g, b, a)
  right:SetPoint("TOPRIGHT")
  right:SetPoint("BOTTOMRIGHT")
  right:SetWidth(1)
end

local function createStackColumn(parent, anchorPoint, relativeTo, relativePoint, xOffset, yOffset)
  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetSize(60, 156)
  frame:SetPoint(anchorPoint, relativeTo, relativePoint, xOffset, yOffset)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  frame:SetBackdropColor(0.02, 0.02, 0.03, 0.72)
  addFlatBorder(frame, 0.75, 0.78, 0.82, 0.85)

  local stacks = {}
  for index = 1, stackMax do
    local bar = frame:CreateTexture(nil, "ARTWORK")
    bar:SetSize(42, 20)
    bar:SetPoint("BOTTOM", 0, 8 + (index - 1) * 24)
    stacks[index] = bar
  end

  return frame, stacks
end

local function createUI()
  local frame = CreateFrame("Button", "BigMeteorFrame", UIParent, "BackdropTemplate")
  frame:SetSize(278, 174)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetClampedToScreen(true)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  frame:SetBackdropColor(0.03, 0.03, 0.05, 0.55)
  addFlatBorder(frame, 0.65, 0.68, 0.72, 0.55)
  frame:SetScript("OnDragStart", function(self)
    if BigMeteorDB.locked then
      return
    end
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)
  frame:SetScript("OnUpdate", function(self, elapsed)
    self.timerElapsed = (self.timerElapsed or 0) + elapsed
    if self.timerElapsed < 0.1 then
      return
    end
    self.timerElapsed = 0
    updateTimers()
  end)

  local leftColumn, leftStacks = createStackColumn(frame, "LEFT", frame, "LEFT", 12, 0)
  local rightColumn, rightStacks = createStackColumn(frame, "LEFT", leftColumn, "RIGHT", 6, 0)

  local leftTime = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  leftTime:SetPoint("CENTER", leftColumn, "CENTER", 0, 0)
  leftTime:SetWidth(52)
  leftTime:SetJustifyH("CENTER")
  leftTime:SetText("")
  leftTime:SetTextColor(1.0, 0.95, 0.95)

  local rightTime = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  rightTime:SetPoint("CENTER", rightColumn, "CENTER", 0, 0)
  rightTime:SetWidth(52)
  rightTime:SetJustifyH("CENTER")
  rightTime:SetText("")
  rightTime:SetTextColor(0.95, 0.9, 1.0)

  local debugText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  debugText:SetPoint("TOP", frame, "BOTTOM", 0, -8)
  debugText:SetWidth(360)
  debugText:SetJustifyH("CENTER")
  debugText:SetText("")
  debugText:SetTextColor(0.9, 0.9, 0.9)

  local recommendations = {}
  for index = 1, 3 do
    local button = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    button:SetSize(104, 40)
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -19 - (index - 1) * 47)
    button:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    button:SetBackdropColor(0.02, 0.02, 0.03, 0.68)
    addFlatBorder(button, 0.42, 0.44, 0.48, 0.75)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 4, -4)
    icon:SetSize(32, 32)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    text:SetText("")
    text:Hide()
    button.text = text
    button:Hide()
    recommendations[index] = button
  end

  ui.frame = frame
  ui.leftColumn = leftColumn
  ui.rightColumn = rightColumn
  ui.leftStacks = leftStacks
  ui.rightStacks = rightStacks
  ui.leftTime = leftTime
  ui.rightTime = rightTime
  ui.debugText = debugText
  ui.recommendations = recommendations

  applyFrameSettings()
  updateBars()
end

addon:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    BigMeteorDB = copyDefaults(defaults, BigMeteorDB or {})
    applyFixedAuraConfig(BigMeteorDB)
    createUI()
    refreshState()
    return
  end

  if event == "UNIT_AURA" and arg1 ~= "target" then
    return
  end

  refreshState()
end)

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_TARGET_CHANGED")
addon:RegisterEvent("UNIT_AURA")
