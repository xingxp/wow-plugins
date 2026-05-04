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
    shadowBolt = 47809,
    lifeTap = 57946,
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
  lastShadowburnCast = 0,
  pendingShadowburnCast = 0,
  lastConflagrateCast = 0,
  shadowStacksAfterShadowburn = 0,
  activeCastSpell = nil,
  activeCastName = nil,
  activeCastRecommended = nil,
  lockedNextRecommendation = nil,
  activeCastMatched = false,
  recommendations = {},
  debugLines = {},
}

local ui = {}
local stackMax = 6
local meteorChainPadding = 0.5
local conflagrateBuffSeconds = 6
local immolateRefreshPadding = 0.6
local windowSafetyPadding = 0.15
local shadowburnStacks = 2
local shadowflameFireStacks = 2
local shadowflameShadowStacks = 2
local shadowflameTickShadowStacks = 1
local layout = {
  gap = 7,
  stackWidth = 34,
  cooldownWidth = 34,
  recommendationWidth = 102,
  panelPadding = 10,
  barHeight = 134,
  recommendationHeight = 40,
  recommendationGap = 7,
  verticalBorders = 8,
}
layout.frameWidth = layout.panelPadding * 2
  + layout.stackWidth * 2
  + layout.cooldownWidth
  + layout.recommendationWidth
  + layout.gap * 3
  + layout.verticalBorders

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

local function isPlayerAuraCaster(caster)
  return caster == "player"
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
    local name, _, count, _, duration, expires, caster, _, _, auraSpellID = UnitAura(unit, index, "HARMFUL")
    if not name then
      break
    end

    if isPlayerAuraCaster(caster) and matchAura(auraSpellID, name, spellID, auraName) then
      addAuraInfo(result, auraSpellID, name, count, duration, expires)
    end
  end

  if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
    for index = 1, 40 do
      local aura = C_UnitAuras.GetDebuffDataByIndex(unit, index)
      if not aura then
        break
      end

      if isPlayerAuraCaster(aura.sourceUnit) and matchAura(aura.spellId, aura.name, spellID, auraName) then
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

local function getSpellCooldownRemaining(spellID)
  if not spellID or spellID == 0 then
    return 0
  end

  local start, duration, enabled = GetSpellCooldown(spellID)
  if enabled == 0 or not start or not duration or duration <= 1.5 then
    return 0
  end

  return math.max(0, start + duration - GetTime())
end

local function getSpellCastSeconds(spellID, fallback)
  local castMS = select(4, GetSpellInfo(spellID))
  if castMS and castMS > 0 then
    return castMS / 1000
  end

  return fallback or 1.5
end

local function getGCDSeconds()
  local haste = UnitSpellHaste("player") or 0
  return math.max(0.75, 1.5 / (1 + haste / 100))
end

local function isSpellInRange(spellID, unit)
  local inRange = IsSpellInRange(GetSpellInfo(spellID), unit)
  return inRange == nil or inRange == 1
end

local function isRecommendationSame(left, right)
  return left == right
end

local function addRecommendation(list, spellID)
  if not spellID or spellID == 0 or #list >= 2 then
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

local function addForcedRecommendation(list, spellID)
  if not spellID or spellID == 0 or #list >= 2 then
    return
  end

  if not GetSpellTexture(spellID) then
    return
  end

  for _, existing in ipairs(list) do
    if isRecommendationSame(existing, spellID) then
      return
    end
  end

  list[#list + 1] = spellID
end

local function getKnownSpellIDByName(spellName)
  if not spellName or not BigMeteorDB or not BigMeteorDB.spellIDs then
    return nil
  end

  for _, spellID in pairs(BigMeteorDB.spellIDs) do
    if GetSpellInfo(spellID) == spellName then
      return spellID
    end
  end

  return nil
end

local function findKnownSpellIDInArgs(...)
  if not BigMeteorDB or not BigMeteorDB.spellIDs then
    return nil
  end

  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "number" then
      for _, spellID in pairs(BigMeteorDB.spellIDs) do
        if value == spellID then
          return spellID
        end
      end
    elseif type(value) == "string" then
      local spellID = getKnownSpellIDByName(value)
      if spellID then
        return spellID
      end
    end
  end

  return nil
end

local function getPlayerCastInfo()
  local name, _, texture, startMS, endMS, _, _, _, spellID = UnitCastingInfo("player")
  if name then
    return spellID or getKnownSpellIDByName(name), texture, startMS / 1000, endMS / 1000, name
  end

  name, _, texture, startMS, endMS, _, _, spellID = UnitChannelInfo("player")
  if name then
    return spellID or getKnownSpellIDByName(name), texture, startMS / 1000, endMS / 1000, name
  end

  return nil, nil, 0, 0, nil
end

local function isSpellSameAsCast(spellID, castSpellID, castName)
  if spellID and castSpellID and spellID == castSpellID then
    return true
  end

  if spellID and castName and GetSpellInfo(spellID) == castName then
    return true
  end

  return false
end

local function getSpellActionSeconds(spellID, ctx, fallback)
  local castMS = select(4, GetSpellInfo(spellID))
  if castMS and castMS > 0 then
    return castMS / 1000
  end

  return (ctx and ctx.gcdSeconds) or fallback or 1.5
end

local function getHastedCastSeconds(baseSeconds)
  local haste = UnitSpellHaste("player") or 0
  return baseSeconds / (1 + haste / 100)
end

local function buildCombatContext()
  local spellIDs = BigMeteorDB.spellIDs
  local ctx = {
    spellIDs = spellIDs,
    gcdSeconds = getGCDSeconds(),
    fireRemaining = getRemaining(state.fireExpires),
    shadowRemaining = getRemaining(state.shadowExpires),
    shadowflameRemaining = getRemaining(state.shadowflameExpires),
    immolateRemaining = getRemaining(state.immolateExpires),
    shadowburnReady = isSpellReady(spellIDs.shadowburn),
    shadowburnRemaining = getSpellCooldownRemaining(spellIDs.shadowburn),
    conflagrateReady = isSpellReady(spellIDs.conflagrate),
    conflagrateRemaining = getSpellCooldownRemaining(spellIDs.conflagrate),
    shadowflameInRange = isSpellInRange(spellIDs.shadowflame, "target"),
    shadowflameReady = isSpellReady(spellIDs.shadowflame) and isSpellInRange(spellIDs.shadowflame, "target"),
    meteorReady = isSpellReady(spellIDs.meteor),
    chaosBoltReady = isSpellReady(spellIDs.chaosBolt),
  }

  ctx.hasImmolate = ctx.immolateRemaining > 0
  ctx.immolateCastSeconds = getHastedCastSeconds(1.5)
  ctx.immolateRefreshThreshold = ctx.immolateCastSeconds + immolateRefreshPadding
  ctx.immolateRefreshNeeded = ctx.immolateRemaining <= ctx.immolateRefreshThreshold
  ctx.meteorCastSeconds = getSpellActionSeconds(spellIDs.meteor, ctx, 1.5)
  ctx.chaosBoltSeconds = getSpellActionSeconds(spellIDs.chaosBolt, ctx, 1.5)
  ctx.incinerateSeconds = getSpellActionSeconds(spellIDs.incinerate, ctx, 1.5)
  ctx.shadowBoltSeconds = getSpellActionSeconds(spellIDs.shadowBolt, ctx, 1.5)
  ctx.recentlyCastShadowburn = GetTime() - (state.lastShadowburnCast or 0) <= (ctx.meteorCastSeconds + ctx.gcdSeconds + meteorChainPadding)
    or isPendingShadowburnCast()
  ctx.conflagrateBuffRemaining = math.max(0, conflagrateBuffSeconds - (GetTime() - (state.lastConflagrateCast or 0)))

  return ctx
end

local function fireHoldsUntil(ctx, delay)
  return state.fireStacks >= stackMax and ctx.fireRemaining >= delay
end

local function shadowHoldsForMeteor(ctx, shadowStacks, delay)
  local predictedStacks = shadowStacks
  if ctx.shadowflameRemaining >= delay then
    predictedStacks = predictedStacks + shadowflameTickShadowStacks
  end

  return predictedStacks >= stackMax
end

local function canMeteorLandAfterShadowburn(ctx, extraDelay)
  local impactDelay = (extraDelay or 0) + ctx.meteorCastSeconds
  local shadowStacks = state.shadowStacks
  if ctx.recentlyCastShadowburn then
    shadowStacks = math.max(shadowStacks, state.shadowStacksAfterShadowburn or 0)
  end

  return ctx.meteorReady
    and fireHoldsUntil(ctx, impactDelay)
    and shadowHoldsForMeteor(ctx, shadowStacks, impactDelay)
end

local function meteorLandsInConflagrateWindow(ctx, extraDelay)
  local impactDelay = (extraDelay or 0) + ctx.meteorCastSeconds
  return ctx.conflagrateBuffRemaining >= impactDelay
end

local function canCastConflagrateBeforeMeteor(ctx)
  return ctx.conflagrateReady
    and ctx.hasImmolate
    and canMeteorLandAfterShadowburn(ctx, ctx.gcdSeconds)
end

local function chainMeteorAfterShadowburn(list, ctx)
  local spellIDs = ctx.spellIDs

  if canCastConflagrateBeforeMeteor(ctx) then
    addRecommendation(list, spellIDs.conflagrate)
    addRecommendation(list, spellIDs.meteor)
    return true
  end

  if ctx.conflagrateRemaining > 0
    and ctx.conflagrateRemaining <= ctx.gcdSeconds
    and canMeteorLandAfterShadowburn(ctx, ctx.conflagrateRemaining + ctx.gcdSeconds)
  then
    addRecommendation(list, spellIDs.lifeTap)
    addRecommendation(list, spellIDs.meteor)
    return true
  end

  addForcedRecommendation(list, spellIDs.meteor)
  return true
end

local function markShadowburnCast()
  state.lastShadowburnCast = GetTime()
  state.pendingShadowburnCast = 0
  state.shadowStacksAfterShadowburn = math.min(stackMax, state.shadowStacks + shadowburnStacks)
end

local function markPendingShadowburnCast()
  state.pendingShadowburnCast = GetTime()
end

local function isPendingShadowburnCast()
  return state.pendingShadowburnCast and state.pendingShadowburnCast > 0 and GetTime() - state.pendingShadowburnCast <= 3
end

local function findNextRecommendationAfter(spellID, spellName)
  for _, recommendation in ipairs(state.recommendations or {}) do
    if not isSpellSameAsCast(recommendation, spellID, spellName) then
      return recommendation
    end
  end

  return nil
end

local function shouldReplaceLockedNext(lockedSpellID, newSpellID)
  if not lockedSpellID or not newSpellID or lockedSpellID == newSpellID then
    return false
  end

  local spellIDs = BigMeteorDB and BigMeteorDB.spellIDs
  if not spellIDs then
    return false
  end

  return newSpellID == spellIDs.meteor
    or newSpellID == spellIDs.shadowburn
    or newSpellID == spellIDs.conflagrate and lockedSpellID ~= spellIDs.meteor
    or newSpellID == spellIDs.immolate and lockedSpellID ~= spellIDs.meteor and lockedSpellID ~= spellIDs.shadowburn
end

local canStartShadowburnMeteorWindow

local function predictNextAfterCast(spellID, spellName)
  local spellIDs = BigMeteorDB and BigMeteorDB.spellIDs
  if not spellIDs then
    return nil
  end

  if isSpellSameAsCast(spellIDs.shadowburn, spellID, spellName) then
    local ctx = buildCombatContext()
    if canCastConflagrateBeforeMeteor(ctx) then
      return spellIDs.conflagrate
    end
    return spellIDs.meteor
  end

  if isSpellSameAsCast(spellIDs.conflagrate, spellID, spellName) then
    if state.activeCastRecommended == spellIDs.conflagrate and state.recommendations and state.recommendations[2] then
      return state.recommendations[2]
    end
    if canStartShadowburnMeteorWindow(buildCombatContext()) then
      return spellIDs.shadowburn
    end
    return spellIDs.chaosBolt
  end

  if isSpellSameAsCast(spellIDs.meteor, spellID, spellName) then
    return spellIDs.chaosBolt
  end

  if isSpellSameAsCast(spellIDs.immolate, spellID, spellName) then
    return spellIDs.conflagrate
  end

  if isSpellSameAsCast(spellIDs.shadowflame, spellID, spellName) then
    if canStartShadowburnMeteorWindow(buildCombatContext()) then
      return spellIDs.shadowburn
    end
  end

  return findNextRecommendationAfter(spellID, spellName)
end

canStartShadowburnMeteorWindow = function(ctx)
  local impactDelay = ctx.gcdSeconds + ctx.meteorCastSeconds

  return ctx.shadowburnReady
    and ctx.meteorReady
    and fireHoldsUntil(ctx, impactDelay)
    and shadowHoldsForMeteor(ctx, state.shadowStacks + shadowburnStacks, impactDelay)
end

local function shadowflameCanPrepareMeteorWindow(ctx)
  if not ctx.shadowflameReady then
    return false
  end

  local fireStacksAfter = math.min(stackMax, state.fireStacks + shadowflameFireStacks)
  local shadowStacksAfter = math.min(stackMax, state.shadowStacks + shadowflameShadowStacks)
  return fireStacksAfter >= stackMax
    and shadowStacksAfter >= stackMax
    and ctx.shadowburnReady
    and ctx.meteorReady
end

local function nextShadowburnWindowSoon(ctx)
  if ctx.shadowburnReady or ctx.shadowburnRemaining <= 0 then
    return false
  end

  return ctx.meteorReady
    and state.fireStacks >= stackMax
    and (
      state.shadowStacks + shadowburnStacks >= stackMax
      or shadowHoldsForMeteor(ctx, state.shadowStacks + shadowburnStacks, ctx.shadowburnRemaining + ctx.gcdSeconds + ctx.meteorCastSeconds)
    )
end

local function castFitsBeforeShadowburn(ctx, actionSeconds)
  if ctx.shadowburnReady or ctx.shadowburnRemaining <= 0 then
    return true
  end

  return actionSeconds + windowSafetyPadding < ctx.shadowburnRemaining
end

local function recommendLayerBuilder(list, ctx)
  local spellIDs = ctx.spellIDs

  if state.shadowStacks < stackMax - 1 then
    if ctx.shadowflameInRange then
      addRecommendation(list, spellIDs.shadowflame)
    else
      addRecommendation(list, spellIDs.shadowBolt)
    end
    return
  end

  if state.fireStacks < stackMax then
    addRecommendation(list, spellIDs.incinerate)
    return
  end

  if state.shadowStacks < stackMax then
    if ctx.shadowflameInRange then
      addRecommendation(list, spellIDs.shadowflame)
    else
      addRecommendation(list, spellIDs.shadowBolt)
    end
  end
end

local function buildRecommendations()
  local ctx = buildCombatContext()
  local spellIDs = ctx.spellIDs
  local list = {}

  if not state.targetExists or state.targetDead then
    return list
  end

  if ctx.recentlyCastShadowburn then
    chainMeteorAfterShadowburn(list, ctx)
    return list
  end

  if canStartShadowburnMeteorWindow(ctx) then
    if ctx.hasImmolate
      and ctx.conflagrateReady
      and fireHoldsUntil(ctx, ctx.gcdSeconds + ctx.gcdSeconds + ctx.meteorCastSeconds)
    then
      addRecommendation(list, spellIDs.conflagrate)
      addRecommendation(list, spellIDs.shadowburn)
      return list
    end

    if ctx.hasImmolate
      and not meteorLandsInConflagrateWindow(ctx, ctx.gcdSeconds)
      and ctx.conflagrateRemaining > 0
      and ctx.conflagrateRemaining <= ctx.gcdSeconds
      and fireHoldsUntil(ctx, ctx.conflagrateRemaining + ctx.gcdSeconds + ctx.gcdSeconds + ctx.meteorCastSeconds)
    then
      addRecommendation(list, spellIDs.lifeTap)
      addRecommendation(list, spellIDs.conflagrate)
      return list
    end

    addRecommendation(list, spellIDs.shadowburn)
    addRecommendation(list, spellIDs.meteor)
    return list
  end

  if nextShadowburnWindowSoon(ctx) and not castFitsBeforeShadowburn(ctx, math.min(ctx.chaosBoltSeconds, ctx.incinerateSeconds, ctx.shadowBoltSeconds)) then
    addRecommendation(list, spellIDs.lifeTap)
    return list
  end

  if ctx.immolateRefreshNeeded
    and (
      not canStartShadowburnMeteorWindow(ctx)
      or ctx.immolateRemaining <= ctx.immolateCastSeconds
    )
  then
    addRecommendation(list, spellIDs.immolate)
    if ctx.hasImmolate and ctx.conflagrateReady then
      addRecommendation(list, spellIDs.conflagrate)
    end
    return list
  end

  if ctx.immolateRefreshNeeded and castFitsBeforeShadowburn(ctx, ctx.immolateCastSeconds) then
    addRecommendation(list, spellIDs.immolate)
    if ctx.hasImmolate then
      addRecommendation(list, spellIDs.conflagrate)
    end
    return list
  end

  if ctx.hasImmolate and ctx.conflagrateReady and castFitsBeforeShadowburn(ctx, ctx.gcdSeconds) then
    addRecommendation(list, spellIDs.conflagrate)
    addRecommendation(list, spellIDs.chaosBolt)
    return list
  end

  if ctx.chaosBoltReady and castFitsBeforeShadowburn(ctx, ctx.chaosBoltSeconds) then
    addRecommendation(list, spellIDs.chaosBolt)
    recommendLayerBuilder(list, ctx)
    return list
  end

  if shadowflameCanPrepareMeteorWindow(ctx) and castFitsBeforeShadowburn(ctx, ctx.gcdSeconds) then
    addRecommendation(list, spellIDs.shadowflame)
    addRecommendation(list, spellIDs.shadowburn)
    return list
  end

  recommendLayerBuilder(list, ctx)
  if #list > 0 then
    return list
  end

  if ctx.immolateRefreshNeeded then
    addRecommendation(list, spellIDs.immolate)
    return list
  end

  if castFitsBeforeShadowburn(ctx, ctx.shadowBoltSeconds) then
    addRecommendation(list, spellIDs.shadowBolt)
  end

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
      lines[#lines + 1] = ("%d:%s x%d %s"):format(auraSpellID, name, count, aura.sourceUnit or "?")
    end
  else
    for index = 1, 12 do
      local name, _, _, count, _, _, caster, _, _, debuffSpellID = UnitDebuff(unit, index)
      if not name then
        break
      end
      lines[#lines + 1] = ("%d:%s x%d %s"):format(debuffSpellID or 0, name, count or 0, caster or "?")
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

  local start, duration, enabled = GetSpellCooldown(BigMeteorDB.spellIDs.shadowburn)
  if enabled ~= 0 and start and duration and duration > 1.5 then
    local remaining = math.max(0, start + duration - GetTime())
    ui.shadowburnCooldownFill:SetHeight((remaining / duration) * layout.barHeight)
    ui.shadowburnCooldownText:SetText(formatRemaining(start + duration))
  else
    ui.shadowburnCooldownFill:SetHeight(0)
    ui.shadowburnCooldownText:SetText("")
  end

  local activeSpellID, activeTexture, castStart, castEnd, activeSpellName = getPlayerCastInfo()
  local activeCastProgress = 0
  if activeSpellID and castEnd > castStart then
    activeCastProgress = math.min(1, math.max(0, (GetTime() - castStart) / (castEnd - castStart)))
  end

  local display = {}
  if activeSpellID then
    display[1] = {
      spellID = activeSpellID,
      spellName = activeSpellName,
      texture = activeTexture,
      active = true,
      matched = state.activeCastMatched,
      progress = activeCastProgress,
    }

    local nextRecommendation = findNextRecommendationAfter(activeSpellID, activeSpellName)
    if state.lockedNextRecommendation and not shouldReplaceLockedNext(state.lockedNextRecommendation, nextRecommendation) then
      nextRecommendation = state.lockedNextRecommendation
    elseif nextRecommendation then
      state.lockedNextRecommendation = nextRecommendation
    end

    if nextRecommendation then
      display[2] = {
        spellID = nextRecommendation,
        active = false,
      }
    end
  else
    for index = 1, 2 do
      if state.recommendations[index] then
        display[index] = {
          spellID = state.recommendations[index],
          active = false,
        }
      end
    end
  end

  for index = 1, 2 do
    local row = display[index]
    local button = ui.recommendations[index]

    if row and row.spellID then
      button.icon:SetTexture(row.texture or GetSpellTexture(row.spellID))
      button.icon:Show()
      button.text:SetText(row.spellName or GetSpellInfo(row.spellID) or "")
      button.text:Show()
      if row.active then
        local r, g, b = 0.16, 0.78, 0.42
        if not row.matched then
          r, g, b = 0.90, 0.22, 0.18
        end
        button.progress:SetColorTexture(r, g, b, 0.58)
        button.progress:SetWidth(math.max(1, layout.recommendationWidth * (row.progress or 0)))
        button.progress:Show()
      else
        button.progress:Hide()
      end
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
  if BigMeteorDB and state.targetExists and not state.targetDead then
    state.recommendations = buildRecommendations()
  end
  updateBars()
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

local function clearActiveCast()
  state.activeCastSpell = nil
  state.activeCastName = nil
  state.activeCastRecommended = nil
  state.lockedNextRecommendation = nil
  state.activeCastMatched = false
end

local function captureActiveCast(...)
  local spellID = findKnownSpellIDInArgs(...)
  local spellName
  if not spellID then
    spellID, _, _, _, spellName = getPlayerCastInfo()
  end

  state.activeCastSpell = spellID
  state.activeCastName = spellName
  state.activeCastRecommended = state.recommendations and state.recommendations[1] or nil
  state.lockedNextRecommendation = predictNextAfterCast(spellID, spellName)
  state.activeCastMatched = isSpellSameAsCast(state.activeCastRecommended, spellID, spellName)

  if isSpellSameAsCast(BigMeteorDB.spellIDs.shadowburn, spellID, spellName) then
    markPendingShadowburnCast()
  end
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
  frame:SetSize(layout.stackWidth, layout.barHeight)
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
    bar:SetSize(layout.stackWidth - 8, 16)
    bar:SetPoint("BOTTOM", 0, 6 + (index - 1) * 21)
    stacks[index] = bar
  end

  return frame, stacks
end

local function createUI()
  local frame = CreateFrame("Button", "BigMeteorFrame", UIParent, "BackdropTemplate")
  frame:SetSize(layout.frameWidth, 154)
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

  local leftColumn, leftStacks = createStackColumn(frame, "LEFT", frame, "LEFT", layout.panelPadding, 0)
  local rightColumn, rightStacks = createStackColumn(frame, "LEFT", leftColumn, "RIGHT", layout.gap, 0)

  local leftTime = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  leftTime:SetPoint("CENTER", leftColumn, "CENTER", 0, 0)
  leftTime:SetWidth(layout.stackWidth + 18)
  leftTime:SetJustifyH("CENTER")
  leftTime:SetText("")
  leftTime:SetTextColor(1.0, 0.95, 0.95)

  local rightTime = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  rightTime:SetPoint("CENTER", rightColumn, "CENTER", 0, 0)
  rightTime:SetWidth(layout.stackWidth + 18)
  rightTime:SetJustifyH("CENTER")
  rightTime:SetText("")
  rightTime:SetTextColor(0.95, 0.9, 1.0)

  local debugText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  debugText:SetPoint("TOP", frame, "BOTTOM", 0, -8)
  debugText:SetWidth(360)
  debugText:SetJustifyH("CENTER")
  debugText:SetText("")
  debugText:SetTextColor(0.9, 0.9, 0.9)

  local shadowburnCooldown = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  shadowburnCooldown:SetSize(layout.cooldownWidth, layout.barHeight)
  shadowburnCooldown:SetPoint("LEFT", rightColumn, "RIGHT", layout.gap, 0)
  shadowburnCooldown:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  shadowburnCooldown:SetBackdropColor(0.03, 0.03, 0.04, 0.68)
  addFlatBorder(shadowburnCooldown, 0.42, 0.44, 0.48, 0.75)

  local shadowburnCooldownFill = shadowburnCooldown:CreateTexture(nil, "ARTWORK")
  shadowburnCooldownFill:SetPoint("BOTTOMLEFT", 4, 4)
  shadowburnCooldownFill:SetPoint("BOTTOMRIGHT", -4, 4)
  shadowburnCooldownFill:SetColorTexture(0.84, 0.36, 1.0, 0.85)
  shadowburnCooldownFill:SetHeight(0)

  local shadowburnCooldownText = shadowburnCooldown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  shadowburnCooldownText:SetPoint("CENTER", shadowburnCooldown, "CENTER", 0, 0)
  shadowburnCooldownText:SetWidth(layout.cooldownWidth + 20)
  shadowburnCooldownText:SetJustifyH("CENTER")
  shadowburnCooldownText:SetText("")

  local recommendations = {}
  for index = 1, 2 do
    local button = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    button:SetSize(layout.recommendationWidth, layout.recommendationHeight)
    button:SetPoint("TOPLEFT", shadowburnCooldown, "TOPRIGHT", layout.gap, -(index - 1) * (layout.recommendationHeight + layout.recommendationGap))
    button:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    button:SetBackdropColor(0.02, 0.02, 0.03, 0.68)
    addFlatBorder(button, 0.42, 0.44, 0.48, 0.75)

    local progress = button:CreateTexture(nil, "BACKGROUND")
    progress:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    progress:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    progress:SetWidth(1)
    progress:Hide()
    button.progress = progress

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
  ui.shadowburnCooldown = shadowburnCooldown
  ui.shadowburnCooldownFill = shadowburnCooldownFill
  ui.shadowburnCooldownText = shadowburnCooldownText
  ui.leftStacks = leftStacks
  ui.rightStacks = rightStacks
  ui.leftTime = leftTime
  ui.rightTime = rightTime
  ui.debugText = debugText
  ui.recommendations = recommendations

  applyFrameSettings()
  updateBars()
end

addon:SetScript("OnEvent", function(_, event, arg1, ...)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    BigMeteorDB = copyDefaults(defaults, BigMeteorDB or {})
    applyFixedAuraConfig(BigMeteorDB)
    createUI()
    refreshState()
    return
  end

  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit = arg1
    if unit == "player" then
      local spellID = findKnownSpellIDInArgs(...)
      if isSpellSameAsCast(BigMeteorDB.spellIDs.shadowburn, spellID, state.activeCastName) or isPendingShadowburnCast() then
        markShadowburnCast()
      elseif spellID == BigMeteorDB.spellIDs.conflagrate then
        state.lastConflagrateCast = GetTime()
      end
    end
    refreshState()
    return
  end

  if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
    if arg1 == "player" then
      captureActiveCast(...)
      updateBars()
    end
    return
  end

  if event == "UNIT_SPELLCAST_STOP"
    or event == "UNIT_SPELLCAST_CHANNEL_STOP"
    or event == "UNIT_SPELLCAST_FAILED"
    or event == "UNIT_SPELLCAST_INTERRUPTED"
  then
    if arg1 == "player" then
      if event == "UNIT_SPELLCAST_STOP" and isSpellSameAsCast(BigMeteorDB.spellIDs.shadowburn, state.activeCastSpell, state.activeCastName) then
        markShadowburnCast()
      end
      clearActiveCast()
      refreshState()
    end
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
addon:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
addon:RegisterEvent("UNIT_SPELLCAST_START")
addon:RegisterEvent("UNIT_SPELLCAST_STOP")
addon:RegisterEvent("UNIT_SPELLCAST_FAILED")
addon:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
addon:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
addon:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
