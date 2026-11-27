# Prompt: Malevolent Shrine skill

Paste everything below into Claude (in this project's folder). Fill in the two lines under "My assets" first.

---

Add a new skill, **Malevolent Shrine**, to my existing server-authoritative Roblox combat system (Luau, Rojo; `src/shared/Modules/{Config,StateHandler,HitboxService,AnimationController,Moves,ProceduralAnimations}`, `src/server/{CombatServer,Ragdoll}`, `src/character/CombatClient`). Read those files first and follow their conventions: every number in `Config` (tag guesses `-- TUNE`), `--!strict`, assert self-checks for new logic, server decides everything, the client only sends inputs and plays visuals. Do not rewrite unrelated systems.

## My assets (I already added these)
- Shrine model: named **`sukunago`**, located at **[WHERE: e.g. ReplicatedStorage.Assets / ServerStorage / a .rbxm file at assets/sukunago.rbxm]**
- Slash effect: named **`slash sukuna`** (it has a space in its name, so use `:FindFirstChild("slash sukuna")`), located at **[WHERE]**
- Names are exactly as I typed them; match the real spelling and capitalization in Explorer, and tell me if they differ.
- Before writing code, inspect both (structure, parts, attachments, ParticleEmitters, whether parts are anchored, size via `GetExtentsSize`). If you can't see them, ask me to paste the Explorer tree instead of guessing names. If they are `.rbxm` files in the repo, map them in `default.project.json`; if they only exist in my Studio place, tell me to export them to `assets/` so my teammate gets them through Git.

## Behaviour
1. **Input:** pressing **1** sends `Input:FireServer("Skill", "MalevolentShrine")`. The server validates the string, that the character is free to act (`StateHandler.CanAct`, not blocking), the cooldown is ready (`Config.MalevolentShrine.Cooldown`, e.g. 60s, `-- TUNE`) and the caster has no shrine already active. Reject anything else. Rate limit already exists; reuse it.
2. **Rise:** the server clones the shrine model and places it **behind the caster** (opposite the root's LookVector, `Config.MalevolentShrine.BehindDistance` studs), on the ground found by a raycast down, facing the same way as the caster. It starts buried and **rises out of the ground** over `RiseTime` seconds. Do the rise as a client-side tween (server fires an `Effects` event with the model and times) so it is smooth for everyone, and have the server set the final CFrame when the rise ends. The caster is locked in an `Attacking` state during the rise (`CastTime`, `-- TUNE`), then free.
3. **Slashes:** once risen, play the slash effect **repeatedly at random positions inside the radius** for the whole duration (client-side visuals, fired by the server on a timer, e.g. a few per 0.1s, `-- TUNE`). Clone the effect, scatter it by random angle/offset, and clean every clone up.
4. **Radius = the slash area.** Derive the attack radius from the slash effect's real size (the horizontal extent of where slashes can appear, from `GetExtentsSize` of the effect and the scatter range), not a separate guessed number. Expose `Config.MalevolentShrine.Radius` as an optional override (`nil` = auto). Add a debug ring (`Config.MalevolentShrine.DebugRadius`) so I can see the area.
5. **Damage:** the attack lasts **15 seconds** (`Duration`) and deals **1% of each target's MaxHealth per second** (`DamagePercentPerSecond = 0.01`), so 15 ticks of 1% = 15% total. A single server loop ticks once per second: every living character (players and NPC dummies via `StateHandler.Ensure`) whose root is inside the radius (horizontal distance from the shrine center, plus a vertical limit `HeightLimit`) takes a tick. Never the caster, never teammates (`HitboxService.SameTeam`), skip dead targets. Config toggles: `IgnoresBlock = true` (blocking does not stop it), `IgnoresIFrames = false`, `StunsTargets = false` (no stun by default). Use `Humanoid:TakeDamage`. Send an `Effects` hit flash per tick (small, not spammy).
6. **End:** after 15s, or earlier if the caster dies or leaves (`CancelOnCasterDeath = true`), stop the loops, sink/fade the shrine and slashes over `FadeTime`, then destroy everything. Cooldown starts when the skill is cast. No leaked clones, tweens, connections or loops after respawn, death, leave or the shrine being destroyed.

## Animations and sound
- Add `MalevolentShrine` to `Config.Animations` (placeholder `rbxassetid://0`, comment "-- Replace with your own uploaded animation ID", priority Action2) and a pose to `Config.Poses` so it works with the procedural fallback.
- Add `Config.Sounds` entries (`ShrineRise`, `ShrineSlash`, empty ids) played in 3D from the shrine via the existing `play3D` helper.
- Camera shake for nearby players when the shrine finishes rising (reuse the existing shake).

## Rules to respect
- Server is authoritative: damage, timing, radius and cooldown are server-side; the client only plays tweens, slashes and sounds.
- All timestamps use `workspace:GetServerTimeNow()`; no `task.wait` timers for state that other code can interrupt.
- Keep it in one new module if it helps (e.g. `src/server/MalevolentShrine.luau`) plus small hooks in `CombatServer` / `CombatClient` / `Config`.
- Add a self-test: the tick math (15 ticks x 1% = 15% of MaxHealth), the radius containment check, and that a caster/teammate is never hit.

## Deliver
1. Full code for every file you change, with paths.
2. The new `Config.MalevolentShrine` group (all `-- TUNE`).
3. A two-player Studio test checklist (rise behind me, slashes cover the debug ring, target inside loses 1% per second for 15s, target outside takes nothing, I take nothing, ends cleanly on death and on timeout).
4. Assumptions and exploits guarded against (input spam, casting while stunned, casting twice, leftover instances).
