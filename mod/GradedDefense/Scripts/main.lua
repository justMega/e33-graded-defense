-- GradedDefense - UE4SS Lua mod for Clair Obscur: Expedition 33 (UE 5.4)
--
-- 1. Graded defense. Vanilla is binary: a hit is cancelled only if it lands
--    while the hero's dodge / parry / jump immunity is running, i.e. if you
--    pressed inside [hit - immuneDuration, hit]. This mod adds an outer window
--    on both sides of that:
--      early side - you pressed, immunity ran out, the hit landed up to
--                   OuterEarly seconds later: the damage is scaled down before
--                   the game applies it;
--      late side  - the hit landed and you pressed up to OuterLate seconds
--                   later: the reduced share of that hit is handed back as HP.
--    The reduction is MaxReduction at the edge of the vanilla window and falls
--    linearly to MinReduction at the far edge of the outer window.
--
-- 2. Timing circle. Every enemy attack declares its hit moments up front in a
--    BP_BattleSequenceTimeline (ActionEffect keyframes). For each upcoming hit
--    a ring shrinks onto a centre dot; it reaches the dot exactly when the hit
--    lands. The filled discs behind it are the windows drawn at the same
--    scale, so "press while the ring is inside the green disc" is the rule.
--
-- Game-side facts this relies on (decompiled from the Blueprint bytecode):
--   * BP_jRPG_Character_Battle_Base_C:TryStartDodge/Parry/Jump/GradientParry
--     (out Success) call StartDefensiveMove, which sets
--     DefensiveMoveImmunityStartTime / EndTime on the game-time clock.
--   * AC_jRPG_CharacterBattleStats_C:ReceiveDamageFromObject cancels the hit if
--     the matching move is still active; otherwise it runs the BP_BattleDamages
--     pipeline, whose last steps are ApplyDebugOverrides ->
--     ApplyTargetClampAndRounding -> Finish -> ReduceHP(GetFinalDamages).
--     The value is BP_BattleDamages.CurrentInputDamages_Base.
--   * Attack flags live on the ATTACKER's stats component:
--     IsCurrentAttackJumpable / Gradient / Unblockable / Undodgeable.
--   * UE4SS Lua hooks on Blueprint functions run after the function body.
--   * Every attack is a BP_EpicBattleSequenceActor; when it starts it calls
--     OnBattleSequenceStarts(self) on the attacker. Only sequences that carry a
--     "BattleKeyframes" track declare their hit times up front (the timeline
--     above). The others fire their hits from inside the sequence, so for those
--     the mod records when hits really arrive (ReceiveDamageFromObject on the
--     defender, called whether or not the hit was dodged) and replays those
--     times the next time the same sequence plays. Stored in gd_learned.txt.
--     Learned times are used for declared attacks too once they exist: the
--     declared keyframe of a ranged attack is the launch, ~0.45 s before impact.

local UEHelpers = require("UEHelpers")
local cfg = require("gd_config")

local TAG = "[GradedDefense] "
local function log(msg) print(TAG .. msg .. "\n") end
local function dbg(msg) if cfg.Debug then log(msg) end end

local CHAR = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_Battle_Base.BP_jRPG_Character_Battle_Base_C:"
local DAMAGES = "/Game/Gameplay/Battle/BP_BattleDamages.BP_BattleDamages_C:"
local TIMELINE = "/Game/Gameplay/Battle/SkillCombos/BP_BattleSequenceTimeline.BP_BattleSequenceTimeline_C:"
local STATS = "/Game/jRPGTemplate/Blueprints/Components/AC_jRPG_CharacterBattleStats.AC_jRPG_CharacterBattleStats_C:"

local ACTION_EFFECT = 4      -- EBattleActionEvent::ActionEffect
local REASON_BUFF = 2        -- EDamageReason::BuffEffect (never defendable)
local REASON_LUMINA = 6      -- EDamageReason::Lumina     (never defendable)
local KEYFRAME_ACTION = "ActionType_7_0B741BF041C3787D2F89AEB5282B2A8B"

-------------------------------------------------------------------------------
-- small helpers
-------------------------------------------------------------------------------

local function valid(obj)
  return obj ~= nil and obj.IsValid ~= nil and obj:IsValid()
end

local KSL = nil
local function gameTime(ctx)
  if not valid(KSL) then KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
  return KSL:GetGameTimeInSeconds(ctx)
end

local function isEnemy(char) return char["Enemy?"] == true end

-- t01 = how far into the outer window (0 = edge of the vanilla window, 1 = far edge)
local function reductionAt(t01)
  if t01 < 0 then t01 = 0 elseif t01 > 1 then t01 = 1 end
  return cfg.MaxReduction - (cfg.MaxReduction - cfg.MinReduction) * t01
end

-- Does a move of this kind count against an attack with these flags?
local function moveFits(kind, atk)
  if atk.jumpable then return kind == "jump" and cfg.GrazeJump end
  if atk.gradient then return kind == "gradient" and cfg.GrazeGradient end
  if kind == "dodge" then return cfg.GrazeDodge and not atk.undodgeable end
  if kind == "parry" then return cfg.GrazeParry and not atk.unblockable end
  return false
end

local function attackFlags(sourceStats)
  return {
    jumpable = sourceStats.IsCurrentAttackJumpable == true,
    gradient = sourceStats.IsCurrentAttackGradient == true,
    unblockable = sourceStats.IsCurrentAttackUnblockable == true,
    undodgeable = sourceStats.IsCurrentAttackUndodgeable == true,
  }
end

-- One letter per learned hit: j(ump) g(radient) u(nblockable) d (undodgeable) n(ormal).
-- The attacker's IsCurrentAttack* flags only switch to a hit's kind when that
-- hit lands, so before it they still describe the previous hit; the kind has
-- to be learned like the timing.
local function flagsCode(f)
  if f.jumpable then return "j" end
  if f.gradient then return "g" end
  if f.unblockable then return "u" end
  if f.undodgeable then return "d" end
  return "n"
end

local function codeFlags(c)
  return { jumpable = c == "j", gradient = c == "g", unblockable = c == "u", undodgeable = c == "d" }
end

-------------------------------------------------------------------------------
-- state
-------------------------------------------------------------------------------

local lastMove = {}   -- hero address -> { kind, t, endt }
local lastHit = {}    -- hero address -> { t, full, hpBefore, stats, flags..., applied, refunded }
local timelines = {}  -- timeline address -> BP_BattleSequenceTimeline_C
local tickCount = 0   -- overlay ticks; used for throttling (game time restarts on a level load)

local ui = { msg = nil, msgUntil = 0, lateUntil = 0, ctx = nil }

-------------------------------------------------------------------------------
-- learned hit times, for attacks that do not declare them
-------------------------------------------------------------------------------

local attack = nil    -- running enemy sequence: { actor, attacker, name, t0, observed, declared }
local learned = {}    -- sequence name -> { seconds after sequence start, ..., kinds = { code, ... } }

local scriptDir = (debug.getinfo(1, "S").source or ""):match("^@?(.*[/\\])") or "ue4ss/Mods/GradedDefense/Scripts/"
local LEARN_FILE = scriptDir .. "gd_learned.txt"

local function loadLearned()
  local f = io.open(LEARN_FILE, "r")
  if not f then return end
  local n = 0
  for line in f:lines() do
    local name, list = line:match("^(.-)|(.*)$")
    if name and name ~= "" then
      -- "2.586j,3.799n"; files from older versions have no letter (kind unknown)
      local offs = { kinds = {} }
      for item in list:gmatch("[^,]+") do
        local num, code = item:match("^%s*([%d.]+)(%a?)")
        if tonumber(num) then
          offs[#offs + 1] = tonumber(num)
          offs.kinds[#offs] = code ~= "" and code or nil
        end
      end
      if #offs > 0 then learned[name] = offs; n = n + 1 end
    end
  end
  f:close()
  log("learned timings loaded for " .. n .. " attack(s)")
end

local function saveLearned()
  local f = io.open(LEARN_FILE, "w")
  if not f then
    log("could not write " .. LEARN_FILE)
    return
  end
  for name, offs in pairs(learned) do
    local parts = {}
    for i, o in ipairs(offs) do parts[i] = string.format("%.3f", o) .. (offs.kinds and offs.kinds[i] or "") end
    f:write(name, "|", table.concat(parts, ","), "\n")
  end
  f:close()
end

-- Store what was observed during the sequence that just ended.
local function commitAttack()
  local a = attack
  attack = nil
  if not a or #a.observed == 0 then return end
  local prev = learned[a.name]
  if prev and #prev > #a.observed then return end -- a cut-short run teaches nothing
  if prev and #prev == #a.observed then
    for i, o in ipairs(a.observed) do
      a.observed[i] = (o + prev[i]) / 2
      a.observed.kinds[i] = a.observed.kinds[i] or (prev.kinds and prev.kinds[i])
    end
  end
  learned[a.name] = a.observed
  local parts = {}
  for i, o in ipairs(a.observed) do parts[i] = string.format("%.2f", o) .. (a.observed.kinds[i] or "") end
  dbg("learned " .. a.name .. ": hits at " .. table.concat(parts, ", ") .. (a.declared and " (also declared)" or ""))
  pcall(saveLearned)
end

-- Post hook on BP_jRPG_Character_Battle_Base_C:OnBattleSequenceStarts.
local function onSequenceStarts(Context, BattleSequence)
  local char, seq = Context:get(), BattleSequence:get()
  commitAttack()
  if not valid(char) or not valid(seq) or not isEnemy(char) then return end
  local name = "?"
  pcall(function() name = seq.LevelSequence:GetFName():ToString() end)
  attack = { actor = seq, attacker = char, name = name, t0 = gameTime(char), observed = { kinds = {} }, declared = false }
  dbg("enemy sequence " .. name .. (learned[name] and " (timing known)" or " (timing not known yet)"))
end

-- Post hook on AC_jRPG_CharacterBattleStats_C:ReceiveDamageFromObject: a hit
-- reached a character, dodged or not.
local function onHitArrives(Context)
  local a = attack
  if not a then return end
  local stats = Context:get()
  if not valid(stats) then return end
  local hero = stats:GetOwner()
  if not valid(hero) or isEnemy(hero) then return end
  local off = gameTime(hero) - a.t0
  if off < 0 or off > 60 then return end
  local last = a.observed[#a.observed]
  if last and off - last < 0.05 then return end -- same hit on another party member
  a.observed[#a.observed + 1] = off
  local code = "?"
  pcall(function() code = flagsCode(attackFlags(a.attacker.AC_jRPG_CharacterStats)) end)
  if code ~= "?" then a.observed.kinds[#a.observed] = code end
  dbg(string.format("hit arrives %.3fs into %s (kind %s)", off, a.name, code))
end

local function showMessage(text, ctx)
  if not cfg.ShowGrazeText then return end
  ui.msg = text
  ui.msgUntil = gameTime(ctx) + 1.2
end

-------------------------------------------------------------------------------
-- 1. graded defense
-------------------------------------------------------------------------------

-- Post hook on BP_BattleDamages_C:ApplyDebugOverrides. Only reached when the hit
-- was NOT dodged / parried / jumped, right before the final rounding.
local function onDamageAboutToApply(Context)
  local dmg = Context:get()
  local reason = dmg.DamageReason
  if reason == REASON_BUFF or reason == REASON_LUMINA then return end

  local targetStats, sourceStats = dmg.TargetCharacter, dmg.SourceCharacter
  if not valid(targetStats) or not valid(sourceStats) then return end
  local hero, attacker = targetStats:GetOwner(), sourceStats:GetOwner()
  if not valid(hero) or not valid(attacker) then return end
  if isEnemy(hero) or not isEnemy(attacker) then return end

  local t = gameTime(hero)
  local hit = attackFlags(sourceStats)
  hit.t = t
  hit.full = dmg.CurrentInputDamages_Base
  hit.hpBefore = targetStats.CurrentHP
  hit.stats = targetStats
  hit.applied = 0
  ui.ctx = hero

  local key = hero:GetAddress()
  local mv = lastMove[key]
  if cfg.GradedDefense and mv and moveFits(mv.kind, hit) and cfg.OuterEarly > 0 then
    local late = t - mv.endt -- how long after the vanilla window closed the hit landed
    if late > 0 and late <= cfg.OuterEarly then
      local red = reductionAt(late / cfg.OuterEarly)
      dmg.CurrentInputDamages_Base = hit.full * (1 - red)
      hit.applied = red
      showMessage(string.format("GRAZE  -%d%%", math.floor(red * 100 + 0.5)), hero)
      dbg(string.format("early graze: %s pressed %.3fs too early -> -%d%% (%.0f -> %.0f)",
        mv.kind, late, math.floor(red * 100 + 0.5), hit.full, hit.full * (1 - red)))
    else
      dbg(string.format("hit landed, last %s was %.3fs outside the window", mv.kind, late))
    end
  else
    dbg(string.format("hit landed (%.0f), no matching press", hit.full))
  end

  lastHit[key] = hit
  if hit.applied == 0 and cfg.GradedDefense and cfg.OuterLate > 0 then
    ui.lateUntil = t + cfg.OuterLate
  end
end

-- Post hook on TryStartDodge / TryStartParry / TryStartJump / TryStartGradientParry.
local function makePressHook(kind)
  return function(Context, Success)
    local hero = Context:get()
    if not valid(hero) or isEnemy(hero) then return end
    local started = true
    pcall(function() started = Success:get() end)
    if not started then return end

    local t = gameTime(hero)
    local key = hero:GetAddress()
    lastMove[key] = { kind = kind, t = t, endt = hero.DefensiveMoveImmunityEndTime }
    ui.ctx = hero
    dbg(string.format("press %s at %.3f, immune until %.3f", kind, t, hero.DefensiveMoveImmunityEndTime))

    -- late side: this press came just after a hit that landed in full
    local hit = lastHit[key]
    if not (cfg.GradedDefense and cfg.OuterLate > 0 and hit) then return end
    if hit.refunded or hit.applied > 0 or not moveFits(kind, hit) then return end
    local late = t - hit.t
    if late < 0 or late > cfg.OuterLate then return end
    hit.refunded = true
    local stats = hit.stats
    if not valid(stats) or hero["Dead?"] == true then return end
    local cur = stats.CurrentHP
    if cur <= 0 then return end
    local lost = math.min(hit.hpBefore - cur, hit.full)
    local red = reductionAt(late / cfg.OuterLate)
    local refund = math.floor(lost * red + 0.5)
    if refund <= 0 then return end
    stats:SetHP(cur + refund)
    ui.lateUntil = 0
    showMessage(string.format("LATE GRAZE  -%d%%", math.floor(red * 100 + 0.5)), hero)
    dbg(string.format("late graze: %s pressed %.3fs after the hit -> %d HP handed back", kind, late, refund))
  end
end

-------------------------------------------------------------------------------
-- 2. timing circle
-------------------------------------------------------------------------------

local VIS_COLLAPSED, VIS_HIT_TEST_INVISIBLE = 1, 3
local DRAW_ROUNDED_BOX, ROUNDING_HALF_HEIGHT = 4, 1

local W = nil -- widgets, built lazily

local function setRGBA(structColor, c, a)
  structColor.R = c[1]; structColor.G = c[2]; structColor.B = c[3]; structColor.A = a
end

local function centerSlot(slot, z)
  slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
  slot:SetAlignment({ X = 0.5, Y = 0.5 })
  slot:SetZOrder(z)
end

-- A round image. outline > 0 makes it a ring with a nearly transparent fill.
local function makeDisc(canvas, tree, imageClass, z, outline)
  local img = StaticConstructObject(imageClass, tree)
  local brush = img.Brush
  brush.DrawAs = DRAW_ROUNDED_BOX
  brush.OutlineSettings.RoundingType = ROUNDING_HALF_HEIGHT
  brush.OutlineSettings.bUseBrushTransparency = false
  brush.OutlineSettings.Width = outline
  setRGBA(brush.OutlineSettings.Color.SpecifiedColor, { 1, 1, 1 }, outline > 0 and 1 or 0)
  setRGBA(brush.TintColor.SpecifiedColor, { 1, 1, 1 }, 1)
  local slot = canvas:AddChildToCanvas(img)
  centerSlot(slot, z)
  return { img = img, slot = slot }
end

local function buildWidgets()
  local owner = UEHelpers.GetGameInstance()
  if not valid(owner) then return nil end
  local userWidgetClass = StaticFindObject("/Script/UMG.UserWidget")
  local treeClass = StaticFindObject("/Script/UMG.WidgetTree")
  local canvasClass = StaticFindObject("/Script/UMG.CanvasPanel")
  local imageClass = StaticFindObject("/Script/UMG.Image")
  local textClass = StaticFindObject("/Script/UMG.TextBlock")

  local w = { rings = {} }
  w.root = StaticConstructObject(userWidgetClass, owner)
  w.root.WidgetTree = StaticConstructObject(treeClass, w.root)
  local tree = w.root.WidgetTree
  local canvas = StaticConstructObject(canvasClass, tree)
  tree.RootWidget = canvas

  w.zoneGraze = makeDisc(canvas, tree, imageClass, 0, 0)
  w.zoneDodge = makeDisc(canvas, tree, imageClass, 1, 0)
  w.zonePerfect = makeDisc(canvas, tree, imageClass, 2, 0)
  for i = 1, cfg.MaxRings do
    w.rings[i] = makeDisc(canvas, tree, imageClass, 3, cfg.RingThickness)
  end
  w.core = makeDisc(canvas, tree, imageClass, 4, 0)

  local function makeText(z, size)
    local text = StaticConstructObject(textClass, tree)
    pcall(function() text.Font.Size = size end)
    local slot = canvas:AddChildToCanvas(text)
    centerSlot(slot, z)
    slot:SetAutoSize(true)
    return { text = text, slot = slot, shown = nil }
  end
  w.label = makeText(5, 20)
  w.message = makeText(6, 26)

  w.root:AddToViewport(50)
  w.root:SetVisibility(VIS_COLLAPSED)
  w.visible = false
  dbg("overlay built")
  return w
end

local function place(disc, radius, c, alpha, offY)
  if radius <= 0 then
    disc.img:SetVisibility(VIS_COLLAPSED)
    return
  end
  disc.img:SetVisibility(VIS_HIT_TEST_INVISIBLE)
  disc.slot:SetPosition({ X = cfg.OffsetX, Y = cfg.OffsetY + (offY or 0) })
  disc.slot:SetSize({ X = radius * 2, Y = radius * 2 })
  disc.img:SetColorAndOpacity({ R = c[1], G = c[2], B = c[3], A = alpha })
end

local function setText(entry, str, y)
  if str == nil then
    entry.text:SetVisibility(VIS_COLLAPSED)
    return
  end
  entry.text:SetVisibility(VIS_HIT_TEST_INVISIBLE)
  entry.slot:SetPosition({ X = cfg.OffsetX, Y = cfg.OffsetY + y })
  if entry.shown ~= str then
    entry.text:SetText(FText(str))
    entry.shown = str
  end
end

-- Collect the upcoming hits of one timeline. Returns nil when it is a running
-- enemy attack, otherwise the reason it was skipped.
local function scanTimeline(tl, out)
  if not valid(tl) then return "gone" end
  local seq = tl.CurrentBattleSequence
  if not valid(seq) then return "no sequence" end
  local attacker = tl.BattleCharacter
  if not valid(attacker) then return "no attacker" end
  if not isEnemy(attacker) then return "player attack" end
  local seqActor = seq.LevelSequenceActor
  if not valid(seqActor) then return "no sequence actor" end
  local player = seqActor.SequencePlayer
  if not valid(player) or not player:IsPlaying() then return "not playing" end

  local timeOut = {}
  tl:GetCurrentBattleSequenceTime(timeOut)
  local now = timeOut.Time
  if type(now) ~= "number" then return "no clock" end
  local rate = player:GetPlayRate()
  if type(rate) ~= "number" or rate <= 0 then rate = 1 end

  tl.CurrentBattleSequenceTimeline:ForEach(function(k, v)
    local at, keyframe = k:get(), v:get()
    if keyframe[KEYFRAME_ACTION] == ACTION_EFFECT then
      out[#out + 1] = { remaining = (at - now) / rate, attacker = attacker }
    end
  end)
  return nil
end

-- Timelines are normally registered by the hook on their Declare function.
-- That hook was seen to stop delivering after the first fight, so every live
-- timeline object is also picked up here.
local pollFound = 0
local function pollTimelines()
  if not FindAllOf then return end
  local all = FindAllOf("BP_BattleSequenceTimeline_C")
  if not all then return end
  for _, tl in ipairs(all) do
    if valid(tl) then
      local key = tl:GetAddress()
      if timelines[key] == nil then pollFound = pollFound + 1 end
      timelines[key] = tl
    end
  end
end

-- Window lengths of the party for the current attack, cached briefly.
local windowsCache = { at = -1000 }
local function heroWindows(attacker)
  if tickCount - windowsCache.at < 50 and windowsCache.value then return windowsCache.value end
  local value = { dodge = 0.22, parry = 0.15, jump = 0.65, gradient = 0.15 }
  pcall(function()
    local manager = attacker.BattleManagerReference
    manager.PlayerCharacters:ForEach(function(_, elem)
      local hero = elem:get()
      if valid(hero) and hero["Dead?"] ~= true then
        value.dodge = hero:GetDodgeImmuneDuration()
        value.parry = hero:GetParryImmuneDuration()
        value.jump = hero.JumpImmuneDuration
        value.gradient = hero.GradientParryImmuneDuration
        return true
      end
    end)
  end)
  windowsCache.at, windowsCache.value = tickCount, value
  return value
end

local function hideOverlay()
  if W and W.visible and valid(W.root) then
    W.root:SetVisibility(VIS_COLLAPSED)
    W.visible = false
  end
end

local lastPredictLog = -1000
local lastGameTime = 0
local lastSummary, lastSummaryAt = "", 0

-- Debug: one line whenever the set of tracked timelines changes state.
local function logSummary(counts, hitCount)
  local parts = {}
  for why, n in pairs(counts) do parts[#parts + 1] = n .. " " .. why end
  if #parts == 0 then return end
  table.sort(parts)
  local text = table.concat(parts, ", ") .. "; " .. hitCount .. " hit(s) ahead"
  local now = os.time()
  if text ~= lastSummary and now ~= lastSummaryAt then
    lastSummary, lastSummaryAt = text, now
    dbg("timelines: " .. text .. " (found by poll so far: " .. pollFound .. ")")
  end
end

local function tickOverlay()
  if not cfg.Visualizer and not cfg.ShowGrazeText then return end
  tickCount = tickCount + 1
  if tickCount % 10 == 0 then pollTimelines() end

  local hits, counts = {}, {}
  for key, tl in pairs(timelines) do
    local ok, why = pcall(scanTimeline, tl, hits)
    if not ok then why = "error: " .. tostring(why) end
    if not ok or why == "gone" then timelines[key] = nil end
    why = why or "running"
    counts[why] = (counts[why] or 0) + 1
  end
  if cfg.Debug then logSummary(counts, #hits) end

  -- attack without declared hit times: use what was learned earlier
  local learning = false
  if attack then
    local ok = pcall(function()
      local a = attack
      if not valid(a.actor) or not valid(a.attacker) or a.actor.IsFinished == true then
        commitAttack()
        return
      end
      if counts.running then a.declared = true end
      local elapsed = gameTime(a.attacker) - a.t0
      local offs = learned[a.name]
      if offs then
        -- observed arrival times beat the declared ones: for ranged attacks
        -- the declared keyframe is the launch, not the impact
        for i = #hits, 1, -1 do hits[i] = nil end
        for i, o in ipairs(offs) do
          hits[#hits + 1] = { remaining = o - elapsed, attacker = a.attacker, kind = offs.kinds and offs.kinds[i] }
        end
      elseif not a.declared then
        learning = elapsed < 30
        if learning then ui.ctx = a.attacker end
      end
    end)
    if not ok then attack = nil end
  end

  local ctx = (hits[1] and hits[1].attacker) or ui.ctx
  if not valid(ctx) then
    hideOverlay()
    return
  end
  local t = gameTime(ctx)
  if t + 1 < lastGameTime then
    -- a level was loaded: the game clock started again, forget timed state
    ui.msgUntil, ui.lateUntil = 0, 0
    lastMove, lastHit = {}, {}
    attack = nil
    dbg("game clock restarted, state cleared")
  end
  lastGameTime = t
  local msgActive = ui.msg ~= nil and t < ui.msgUntil and t > ui.msgUntil - 5
  local lateActive = t < ui.lateUntil and t > ui.lateUntil - 5

  table.sort(hits, function(a, b) return a.remaining < b.remaining end)
  local upcoming = {}
  if cfg.Visualizer then
    for _, h in ipairs(hits) do
      -- the same hit can be reported by two timeline objects; keep one
      local prev = upcoming[#upcoming]
      local twin = prev and math.abs(prev.remaining - h.remaining) < 0.02
      if not twin and h.remaining >= 0 and h.remaining <= cfg.LeadTime and #upcoming < cfg.MaxRings then
        upcoming[#upcoming + 1] = h
      end
    end
  end

  if #upcoming == 0 and not msgActive and not lateActive and not learning then
    hideOverlay()
    return
  end

  if not W or not valid(W.root) or not W.root:IsInViewport() then
    W = buildWidgets()
    if not W then return end
  end
  if not W.visible then
    W.root:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    W.visible = true
  end

  local speed, core = cfg.RingSpeed, cfg.CoreRadius
  local labelText, zoneRadius = nil, 0

  if #upcoming > 0 then
    local attacker = upcoming[1].attacker
    -- the live flags still describe the previous hit; trust them only when the
    -- kind of this hit has not been learned yet
    local kind = upcoming[1].kind
    local flags = kind and codeFlags(kind) or attackFlags(attacker.AC_jRPG_CharacterStats)
    local win = heroWindows(attacker)

    -- perfect = the narrow window, wide = the widest vanilla window for this attack
    -- jump / gradient attacks get their own colour from the moment the ring appears
    local perfect, wide
    local perfectColor, farColor, coreColor = cfg.ColorPerfect, cfg.ColorFar, { 1, 1, 1 }
    if flags.jumpable then
      perfect, wide, labelText = win.jump, win.jump, "JUMP"
      perfectColor = cfg.ColorJump or { 1.00, 0.45, 0.00 }
      farColor, coreColor = perfectColor, perfectColor
    elseif flags.gradient then
      perfect, wide, labelText = win.gradient, win.gradient, "GRADIENT PARRY"
      perfectColor = cfg.ColorGradient or { 0.70, 0.35, 1.00 }
      farColor, coreColor = perfectColor, perfectColor
    elseif flags.unblockable then
      perfect, wide, labelText = win.dodge, win.dodge, "DODGE"
    elseif flags.undodgeable then
      perfect, wide, labelText = win.parry, win.parry, "PARRY"
    else
      perfect, wide, labelText = win.parry, win.dodge, "DODGE / PARRY"
    end
    local outer = cfg.GradedDefense and cfg.OuterEarly or 0

    zoneRadius = core + (wide + outer) * speed
    place(W.zoneGraze, outer > 0 and zoneRadius or 0, cfg.ColorGraze, 0.16)
    place(W.zoneDodge, wide > perfect and (core + wide * speed) or 0, cfg.ColorDodge, 0.22)
    place(W.zonePerfect, core + perfect * speed, perfectColor, 0.30)

    for i, ring in ipairs(W.rings) do
      local h = upcoming[i]
      if h then
        local r = h.remaining
        local color = farColor
        if r <= perfect then color = perfectColor
        elseif r <= wide then color = cfg.ColorDodge
        elseif r <= wide + outer then color = cfg.ColorGraze end
        place(ring, core + r * speed, color, 0.06)
        -- the outline is the visible ring; recolour it in place
        pcall(function() setRGBA(ring.img.Brush.OutlineSettings.Color.SpecifiedColor, color, 1) end)
      else
        ring.img:SetVisibility(VIS_COLLAPSED)
      end
    end
    place(W.core, core, coreColor, 0.95)

    if cfg.Debug and tickCount - lastPredictLog >= 25 then
      lastPredictLog = tickCount
      dbg(string.format("next hit in %.3fs (%s, kind %s), windows parry %.2f dodge %.2f jump %.2f",
        upcoming[1].remaining, labelText, kind or "live flag", win.parry, win.dodge, win.jump))
    end
  else
    place(W.zoneGraze, 0); place(W.zoneDodge, 0); place(W.zonePerfect, 0)
    for _, ring in ipairs(W.rings) do ring.img:SetVisibility(VIS_COLLAPSED) end
    if lateActive then
      -- a hit just landed: the dot drains while a late press can still graze
      local left = (ui.lateUntil - t) / cfg.OuterLate
      place(W.core, core * left, cfg.ColorLate, 0.95)
    else
      place(W.core, 0)
    end
    if learning then labelText = "NEW ATTACK - LEARNING TIMING" end
  end

  setText(W.label, cfg.ShowLabel and labelText or nil, math.min(zoneRadius, 170) + 22)
  setText(W.message, msgActive and ui.msg or nil, -(math.min(zoneRadius, 170) + 30))
end

-------------------------------------------------------------------------------
-- hook registration (the battle Blueprints load after the mod does)
-------------------------------------------------------------------------------

local hooks = {
  { path = DAMAGES .. "ApplyDebugOverrides", fn = onDamageAboutToApply },
  { path = CHAR .. "TryStartDodge", fn = makePressHook("dodge") },
  { path = CHAR .. "TryStartParry", fn = makePressHook("parry") },
  { path = CHAR .. "TryStartJump", fn = makePressHook("jump") },
  { path = CHAR .. "TryStartGradientParry", fn = makePressHook("gradient") },
  { path = TIMELINE .. "DeclareBattleSequenceTimingsAsList", fn = function(Context)
      local tl = Context:get()
      if valid(tl) then
        timelines[tl:GetAddress()] = tl
        dbg("attack timeline declared (hook)")
      end
    end },
  { path = CHAR .. "OnBattleSequenceStarts", fn = onSequenceStarts },
  { path = STATS .. "ReceiveDamageFromObject", fn = onHitArrives },
}

local function guarded(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then log("error in " .. name .. ": " .. tostring(err)) end
  end
end

-- Registers every hook whose function is loaded; re-registers if the Blueprint
-- was unloaded and loaded again (a new UFunction at a new address).
local function ensureHooks()
  for _, h in ipairs(hooks) do
    local fnObj = StaticFindObject(h.path)
    if valid(fnObj) then
      local addr = fnObj:GetAddress()
      if h.addr ~= addr then
        local ok, err = pcall(RegisterHook, h.path, guarded(h.path, h.fn))
        if ok then
          h.addr = addr
          log("hooked " .. h.path)
        else
          log("could not hook " .. h.path .. ": " .. tostring(err))
        end
      end
    end
  end
end

local function everyMs(ms, fn)
  local safe = guarded("timer", fn)
  if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(ms, function() safe() end)
  else
    local queued = false
    LoopAsync(ms, function()
      if not queued then
        queued = true
        ExecuteInGameThread(function()
          queued = false
          safe()
        end)
      end
      return false
    end)
  end
end

pcall(loadLearned)
everyMs(3000, ensureHooks)
everyMs(10, tickOverlay)

log(string.format("loaded (graded defense %s, early %.2fs, late %.2fs, max -%d%%; visualizer %s)",
  tostring(cfg.GradedDefense), cfg.OuterEarly, cfg.OuterLate,
  math.floor(cfg.MaxReduction * 100 + 0.5), tostring(cfg.Visualizer)))
