# GradedDefense — Clair Obscur: Expedition 33

A UE4SS Lua mod. No game files are changed or shipped.

## What it does

**Graded defense.** In the base game a dodge, parry or jump either cancels a hit completely or does
nothing. This mod adds an outer window around the game's own window:

| When you pressed | Result |
|---|---|
| inside the game's window | unchanged: no damage, counters and rewards as usual |
| too early, by up to `OuterEarly` (0.25 s) | the hit is reduced before it is applied |
| too late, by up to `OuterLate` (0.20 s) after the hit | the reduced share is handed back as HP |
| further out | full damage |

The reduction is `MaxReduction` (90 %) right at the edge of the game's window and falls linearly to
`MinReduction` (0 %) at the far edge. A jump only counts against jumpable attacks and a gradient
parry only against gradient attacks, as in the base game. A graze never triggers a counter attack.
The late side cannot undo a hit that killed the character.

**Timing circle.** For every upcoming enemy hit a ring shrinks onto a white dot and reaches it at
the moment the hit lands. The discs behind it are the windows at the same scale:

- green disc: parry window
- blue disc: dodge window
- yellow disc: the graze window this mod adds

Jump and gradient attacks are coloured differently so they can be told apart at once: the ring, the
centre dot and the window disc are orange for a jump attack and purple for a gradient attack
(`ColorJump`, `ColorGradient`). Normal dodge / parry attacks keep the white ring and green / blue discs.

Press while the ring is inside the disc for the move you want. The ring takes the colour of the
zone it is in, and the label under the circle names the move the attack asks for. After a hit lands
in full, the dot turns red and drains for as long as a late press can still graze.

## Install (Linux / Steam Proton)

1. `./install.sh` — copies UE4SS (experimental build 1165) and the mod into
   `Sandfall/Binaries/Win64/`.
2. Steam › Expedition 33 › Properties › Launch Options:
   `WINEDLLOVERRIDES="dwmapi=n,b" %command%`
3. Start the game. `Sandfall/Binaries/Win64/ue4ss/UE4SS.log` should contain `[GradedDefense] loaded`.

On Windows: unzip UE4SS next to `SandFall-Win64-Shipping.exe` and copy `mod/GradedDefense` into
`ue4ss/Mods/`. No launch option is needed.

Remove with `./uninstall.sh` (mod only) or `./uninstall.sh --all` (mod and UE4SS).

## Settings

`ue4ss/Mods/GradedDefense/Scripts/gd_config.lua` — window sizes, reduction, which moves can graze,
circle position, size, speed and colours. Restart the game after editing.

## Credits

Built with Claude Code and the universal-modder toolkit. Loader: RE-UE4SS. Blueprint reading:
retoc and kismet-analyzer by trumank, mappings from TheNaeem's Unreal Mappings Archive. Hook points
were cross-checked against uuuu790's E33-AutoParryAnim.
