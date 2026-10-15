# MODLOG — Expedition 33: graded defense + timing circle

## Goal
1. Graded defense: wider outer window around dodge/parry/jump; press in outer-but-not-perfect window => damage reduced proportionally to closeness.
2. Visualizer: circle that shrinks + changes colour as the correct press time approaches.

## Facts (2026-10-12)
- Install: ~/.local/share/Steam/steamapps/common/Expedition 33 (Steam 1903340, buildid 23765773), Linux/Proton 7.0-100 prefix at steamapps/compatdata/1903340
- Engine: Unreal 5 (project "Sandfall", exe Sandfall/Binaries/Win64/SandFall-Win64-Shipping.exe), IoStore, 67 paks. No anti-cheat. No loader installed.
- Saves: compatdata/1903340/pfx/drive_c/users/steamuser/AppData/Local/Sandfall/Saved/SaveGames/76561198127749629
- Community: Nexus mod 28 (Caites) only changes window sizes; vanilla dodge 0.35/0.22/0.22 s, parry 0.25/0.15/0.15 s per difficulty. No existing visual-indicator mod found.

## Route (tentative)
UE4SS Lua mod (hook blueprint functions for dodge/parry/jump + damage; draw circle via UMG/HUD). Reason: logic lives in Blueprints, UE4SS can hook BP functions without recooking assets.

## Log

### Recon results (decompiled with retoc 0.1.5 -> kismet-analyzer + usmap from TheNaeem/Unreal-Mappings-Archive; dumps in ~/e33-extract, NOT in this folder)
- UE 5.4. Tools in tools/: retoc, ka/ (kismet-analyzer), e33.usmap, kdump.py (pretty-printer), ref/E33-AutoParryAnim (community UE4SS C++ mod, great comments).
- Verdict lives in `AC_jRPG_CharacterBattleStats_C:ReceiveDamageFromObject` (defender's stats component):
  jumpable attack -> success iff owner.IsJumping && owner:IsInImmunityPhase(); else TryParryHitFromCharacter (owner.IsParrying / IsGradientParrying for gradient attacks) then TryDodgeHitFromCharacter (owner.IsDodging).
  Attack flags are on the ATTACKER's stats comp: IsCurrentAttackJumpable/Gradient/Unblockable/Undodgeable.
- Press: `BP_jRPG_Character_Battle_Base_C:TryStartDodge/TryStartParry/TryStartJump/TryStartGradientParry(out Success)` -> StartDefensiveMove sets DefensiveMoveImmunityStartTime = now(+warmup), EndTime = start + immune duration (GetGameTimeInSeconds clock). Ubergraph tick clears IsDodging/IsParrying/IsJumping + EndTime=0 once now > EndTime.
  => vanilla window: press in [hit - immuneDuration, hit]. Pressing after the hit is always too late.
  Durations: GetDodgeImmuneDuration(), GetParryImmuneDuration() (include window modifiers), JumpImmuneDuration (0.65), GradientParryImmuneDuration.
- If the hit lands: BP_BattleDamages pipeline ... ApplyClamp -> shield -> `ApplyDebugOverrides()` -> ApplyTargetClampAndRounding -> ApplyDeathtouch -> Finish -> ReduceHP(GetFinalDamages). Damage value = BP_BattleDamages.CurrentInputDamages_Base (double); TargetCharacter/SourceCharacter are stats comps.
  => graze hook: post-hook BP_BattleDamages_C:ApplyDebugOverrides, scale CurrentInputDamages_Base.
- Stats comp: SetHP(value) = clean HP write + OnHPChanged broadcast (used for the late-press refund).
- Hit timing: attacker spawns BP_BattleSequenceTimeline_C per track (DeclareBattleSequenceTimingsAsList); `CurrentBattleSequenceTimeline` = TMap<double seqTime, {ActionType_7_..., CameraType_5_...}>; ActionType 4 = ActionEffect (the hit, -> BattleCharacter:ActivateActionEffect()). Keyframes added through AddBattleSequenceActionKeyframe(time, actionType); clock = timeline:GetCurrentBattleSequenceTime(out Time); ticked every frame via TickBattleSequenceTimeline; entries removed as reached.
- UE4SS Lua hooks on BP functions are POST-only (per reference mod) -> design uses post hooks only.

## Route (final)
UE4SS Lua mod, post hooks only + runtime-built UMG overlay. No pak edits, no game files shipped.

### Build (2026-10-12)
- Mod: mod/GradedDefense/Scripts/{main.lua,gd_config.lua}, enabled.txt. install.sh / uninstall.sh. UE4SS experimental 1165 staged in tools/ue4ss_stage (NOT yet installed in the game).
- Hooks (all post): BP_BattleDamages_C:ApplyDebugOverrides (scale CurrentInputDamages_Base), TryStartDodge/Parry/Jump/GradientParry (record press, late refund via stats:SetHP), BP_BattleSequenceTimeline_C:DeclareBattleSequenceTimingsAsList (register timeline). Overlay = runtime UMG (UserWidget+CanvasPanel+Image RoundedBox brushes), driven every 10 ms.
- Verified so far: logic only, in a mock harness under luajit (early/late graze maths, kind matching, no double refund, DoT ignored, ring radii). NOT yet verified in the real game.
- Saves backed up: ~/.universal-modder/backups/e33-saves/20261012-104412.zip (restore: um backup restore).
- Open questions for the in-game test: (1) does UE4SS 1165 inject under this Proton; (2) do RoundedBox brushes render as circles; (3) do ActionEffect keyframes match the real damage moment for projectile attacks; (4) TMap ForEach on CurrentBattleSequenceTimeline.
- Next: get OK to install, user sets launch option, play one fight with Debug=true, read ue4ss/UE4SS.log.
- 2026-10-12 10:45:53 installed UE4SS 1165 + GradedDefense into the game folder with user OK (undo: ./uninstall.sh --all). Launch option still to be set by the user.

### Launch problems (2026-10-12)
- Proton 7.0: "failed to load UE4SS.dll" - Wine 7 has no bcryptprimitives.dll, which UE4SS 1165 imports. Fix: newer Proton.
- Proton 9.0-4: UE4SS loads and scans fine (engine 5.4 detected, log OK), but THE GAME crashes ~0 s in, EXCEPTION_ACCESS_VIOLATION reading 0x3a0, in SandFall-Win64-Shipping.exe+0x6A2AFA1 right after vkd3d-proton creates the D3D12 device on the GTX 1060 Max-Q (driver 580.178.04, Wayland, hybrid Intel UHD 630).
  Same crash with the loader disabled (dwmapi.dll renamed) and with NVIDIA PRIME env vars -> not caused by the mod.
- GE-Proton11-7 downloaded to ~/.local/share/Steam/compatibilitytools.d (checksum verified). Could not test it outside Steam: needs Steam Linux Runtime 4.0 (tool 4183110), which Steam installs on first launch.
- Unknown: whether the game has ever started on this machine (Steam shows 726 min playtime; game was installed today).
- Diagnostic launcher: scratchpad runtest.sh (direct Proton run with PROTON_LOG).
- Next: user picks Proton Experimental or GE-Proton11-7 in Steam > Properties > Compatibility and launches; read compatdata/.../Saved/Crashes and ue4ss/UE4SS.log.

## 2026-10-12 — first real play session (game starts after the Proton switch)
- Session log kept at scratchpad `UE4SS.session1.log`. Works in game: UMG overlay builds and draws, TMap ForEach on the
  timeline map, hit prediction ("next hit in …"), early graze (many), late graze (1× at 09:42:38, 4 HP handed back).
- User report: "dodge window didn't show up on the next fights".
- Log reading: worlds 1–3 are the same fight retried (party wiped twice; game clock restarts at each reload, a fight
  starts ~15–20 s after load, "overlay built" once per world). In the later fights of world 3 (09:37+, game time 841+)
  press and damage hooks still log, but there is not a single "next hit" line → no timeline was scanned successfully.
  Cause NOT proven. Candidates: the Declare hook on BP_BattleSequenceTimeline_C stops delivering, or scanTimeline
  rejects/errors (errors were swallowed and the timeline dropped).
- Own bug found: debug throttles and caches compared against game time, which restarts on level load
  (suppressed "next hit" logging in worlds 2 and 3 until t passed the old value).
- Change (v2 main.lua, v1 saved as scratchpad `main.lua.v1`): timelines also found by polling
  `FindAllOf("BP_BattleSequenceTimeline_C")` every 10 ticks; scanTimeline returns a skip reason; debug line
  "timelines: N running, N not playing, … (found by poll so far: N)" on every change; "attack timeline declared (hook)"
  per hook call; throttles use a tick counter; timed state cleared when the game clock goes backwards; duplicate hits
  from two timeline objects merged. Harness still passes. NOT yet verified in game.
- Next: user plays 2+ different fights; read the "timelines:" lines to see which candidate it was.

## 2026-10-12 — session 2 result and v3
- User: "it didn't work properly in the first fight now". Log (scratchpad `UE4SS.session2.log`): the Declare hook fires
  fine, FindAllOf poll found nothing extra. Real cause: enemy hits landed (10:26:29, 10:26:40–42) with NO timeline
  declared at all, while another attack in the same fight (10:26:34) was declared and predicted correctly.
- RE (`~/e33-extract/json/BP_EpicBattleSequenceActor.json`): every attack is a BP_EpicBattleSequenceActor.
  `StartSequenceInternal` → `OwnerCharacter->OnBattleSequenceStarts(self)` → `TryRegisterKeyframes`, which calls the
  character's DeclareBattleSequenceTimingsAsList ONLY if the sequence has a 'BattleKeyframes' / '_Track2' / '_Track3'
  (or '…_Diegetic*' when BattleManager.UseDiegeticQTE) track with keyframes. Other sequences fire hits from inside the
  sequence (`TriggerActionEffect(index)` → OnActionEffect delegate → character). So hit times are not available up front
  for those. Session 1's first fight (prologue enemy) happened to use only declared sequences.
- v3 (v2 saved as scratchpad `main.lua.v2`): learned timing. Hooks `CHAR:OnBattleSequenceStarts` (enemy sequence start,
  name = LevelSequence FName, t0 = game time) and `AC_jRPG_CharacterBattleStats_C:ReceiveDamageFromObject` (hit reaches a
  hero, dodged or not). Offsets saved per sequence name in `Scripts/gd_learned.txt` (next to main.lua, in the game folder);
  replayed as rings when the same sequence plays without a declared timeline. First sighting shows
  "NEW ATTACK - LEARNING TIMING". Declared timings win when present. Clock for learned hits = game time since start
  (not sequence time) — unverified whether hit-stop / slow-mo makes it drift.
- Mock harness covers learn → save → replay. NOT verified in game: whether the two new hooks fire (OnBattleSequenceStarts
  is called through an object context, ReceiveDamageFromObject caller unknown), GetFName():ToString(), io.open path.

## 2026-10-12 — session 3: works; ranged timing fixed in v4
- User: works now, only ranged attack timing "quite off". Both new hooks fire in game, gd_learned.txt is written,
  learned offsets repeat within ±0.02 s across 10+ plays (game-time clock is fine).
- Log: SEQ_ChevaliereB_* (ranged) are DECLARED; declared first hit ≈0.62 s, real arrival 1.08 s → the declared
  ActionEffect keyframe is the projectile launch. Melee SEQ_ChevaliereCAC_* are undeclared and use learned times.
- v4: learned times replace declared ones whenever they exist; declared is only used on first sighting (so the first
  time a ranged attack is seen its ring is still ~0.45 s early). "LEARNING" label only for undeclared attacks.
  Harness passes; not yet verified in game.

## 2026-10-13 — v5: ring colour by attack kind
- User asked for a different colour for normal (dodge/parry) vs gradient vs jump attacks.
- main.lua tickOverlay: jump attacks use `ColorJump` (orange), gradient attacks `ColorGradient` (purple) for the far ring,
  the ring inside the window, the window disc and the centre dot. Normal attacks unchanged (white ring, green/blue discs).
  Graze zone stays yellow for all kinds. Defaults are also hard-coded in main.lua in case an older gd_config.lua is kept.
- Syntax-checked with luajit and installed; NOT yet seen in game (needs a fight with a jump and a gradient attack).

## 2026-10-14 — v6: attack kind learned per hit (jump labels were wrong)
- Log review (UE4SS.log of 2026-10-13, 7955 lines): no Lua errors, every hook registered once, no "error in" lines.
- Bug: `IsCurrentAttackJumpable/Gradient/...` on the attacker's stats only switch to a hit's kind WHEN that hit lands;
  before it they still describe the previous hit. The ring read them live, so labels lagged one hit:
  SEQ_Cruler_JumpAOE, SEQ_MirrorRenoir_Skill_4 and hit 3 of SEQ_CultistHeavy_Skill1 were jumped successfully but shown
  "DODGE / PARRY"; SEQ_MM_BlackSmith_HammerSmash hit 2 and SEQ_Chorale_AoeAttack1 hit 2 showed "JUMP" after a jumpable hit
  (HammerSmash hit 2 is not jumpable: a jump 0.58 s early failed and the flag was false at damage time).
  The graze maths was not affected: at ApplyDebugOverrides the flags describe the hit being applied.
- v6 (v5 saved as scratchpad `main.lua.v5`): ReceiveDamageFromObject records the kind per hit; gd_learned.txt entries
  get a letter (`2.586j` jump, g gradient, u unblockable, d undodgeable, n normal). The ring uses the learned kind and
  falls back to the live flag only when unknown (first sighting, or entries from older files until replayed once).
  Harness passes (old format still loads). NOT yet seen in game.
- Side note: one press is logged up to 3x with identical times (cause not checked, likely one call per party member); no effect on results.
