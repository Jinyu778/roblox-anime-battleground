# Anime Battleground: combat system

This is a server-authoritative melee combat system in Luau, synced into Studio with Rojo. All names, values and animations are original placeholders.

## Setup

1. Run `rojo serve` in this folder.
2. In Studio, go to Plugins → Rojo → Connect.
3. Optional: put your own `rbxassetid://` ids in `Config.Animations` and `Config.Sounds`. Empty ids are skipped.
4. Optional: set `Config.Block.GamepassId` to raise the Black Flash chain for gamepass owners.

| Studio location | File |
|---|---|
| ServerScriptService/Combat/CombatService | `src/server/Combat/CombatService.server.luau`: remotes, input handlers, `ApplyHit` |
| ServerScriptService/Combat/StateMachine | `src/server/Combat/StateMachine.luau`: per-character state and data |
| ServerScriptService/Combat/Hitbox | `src/server/Combat/Hitbox.luau`: `GetPartBoundsInBox` queries and the wall raycast |
| ServerScriptService/Combat/Ragdoll | `src/server/Combat/Ragdoll.luau`: swaps Motor6Ds for BallSocketConstraints, then restores them |
| ReplicatedStorage/Combat/Config | `src/shared/Combat/Config.luau`: every number. `-- TUNE` marks a placeholder |
| StarterPlayerScripts/CombatClient | `src/client/CombatClient.client.luau`: input, animations, sounds, highlight flashes, shake, dash cooldown UI |

## Working together (Git + Rojo)

Each person runs their own Rojo against their own Studio place. Git keeps the code in sync.

1. Clone once, then start Rojo:
   ```bash
   git clone https://github.com/Jinyu778/roblox-anime-battleground.git
   cd roblox-anime-battleground
   rojo serve
   ```
   In Studio, open your **own** place file or unpublished copy, not a shared Team Create place, then go to Plugins → Rojo → Connect.
2. Start each feature on a branch:
   ```bash
   git switch -c dash-tuning
   ```
3. When it works, commit and push, then open a pull request on GitHub:
   ```bash
   git add -A
   git commit -m "Tune dash distances"
   git push -u origin dash-tuning
   ```
4. After a PR is merged, everyone pulls. Rojo syncs the new code into Studio by itself:
   ```bash
   git switch main
   git pull
   ```
5. To publish, one person builds the place and publishes it from Studio:
   ```bash
   rojo build -o game.rbxlx
   ```

**Things built in Studio (maps, models, UI)** are only in the place file of the person who made them. To share them, right-click the model → Save to File → `.rbxm`, put it in the repo (for example `assets/`), commit it, and map it in `default.project.json` with `"$path": "assets/Map.rbxm"`. Place files (`*.rbxl`, `*.rbxlx`) are ignored by Git on purpose.

## Controls

| Input | Action |
|---|---|
| Left click | M1 |
| F (hold) | Block |
| Q | Dash. Hold W, S, A or D for forward, back, left or right. With no key held, it dashes forward |
| 1 | Shove (guard break) |
| 2 | Uppercut (guard break, starts a wall combo) |
| 3 | Normal Punch (guard break within 4 studs) |
| 4 | Downslam (ragdolls, starts a wall combo) |

## Testing checklist

Use Test → Clients and Servers → 2 Players. Turn on the `CombatState` attribute on each character (Properties → Attributes) to watch state changes. A Rig Builder dummy also works as a target.

- **Combo timing:** land 4 M1s on P2 and check damage of 3, 3, 4 and 4 in P2's Humanoid.Health. Wait more than 1 s between clicks and the next hit should be M1_1 again. Click at about 0.5 s intervals and the combo should continue.
- **Finisher:** a landed 4th hit should knock P2 back and ragdoll them, and P1's next M1 should be blocked for 1.5 s. A missed 4th hit should stun P1 (`CombatState = Stunned` for 0.8 s).
- **Stun:** while P2 shows `Stunned`, P2's M1, F and Q should do nothing. On long strings each consecutive stun gets shorter (decay).
- **Block:** with P2 holding F and facing P1, M1s do 0 damage. Hit P2 from behind and the hits land. Five blocked hits in quick succession break the guard (P2 stunned 1.5 s). Shove breaks the guard at once.
- **Perfect block:** P2 presses F just as P1's M1 lands, so a gold flash appears. P2's next M1 does 3× damage (9). Perfect block again while buffed and the next M1 does 6× (Black Flash, dark red flash). The buff expires after 4 s.
- **Dash direction:** with `Config.Dash.Debug` on, the server Output prints `dir=`, `vector=` and `distance=` for each dash. W+Q (or Q alone) prints `Front` and 18 studs. A+Q and D+Q print `Left`/`Right` and 12 studs at full health, and the character visibly moves sideways relative to the camera. S+Q prints `Back` and moves toward the camera. W+A prints `Front` unless `DiagonalBehavior = "Side"`.
- **Dash while stunned:** land an M1 on P2, then have P2 press Q while `CombatState = Stunned`. Nothing should print and P2 shouldn't move.
- **Dash animations:** with ids filled in, each direction plays its own DashFront/Back/Left/Right animation once (no double play on your own screen). Getting stunned or ragdolled mid-swing or mid-dash stops the animation.
- **Dash cooldown sharing:** front dash, then back dash at once. The back dash should be refused and the UI should show the shared 5 s timer. A side dash should still work and has its own 2 s timer.
- **Side dash scaling:** set Health to 0.01 × MaxHealth in the Properties panel. The side dash should travel about 40 % of its full-health distance.
- **Dash hit:** forward-dash into P2 from 5–6 studs away for 4 % damage. From 3 studs or closer it does 5.3 % plus knockback.
- **Ragdoll cancel:** while P2 is ragdolled on the ground, a back or side dash stands them up at once and starts that dash's cooldown. A forward dash does nothing. After getting up, P2 cannot be stunned for 0.5 s.
- **Wall combo:** push P2 against a wall (within 4 studs). Land the 4th M1, Uppercut or Downslam, then press Q with W within 0.2 s. You should see a purple flash and 12 % damage, then a 5 s wall-combo cooldown.
- **Spam:** an autoclicker above 20 inputs per second has the extra inputs dropped and the server stays responsive.
- **Startup self-check:** if any Config change breaks an assert in CombatService, the server Output shows it immediately.

## Assumptions

- Percentages are a share of the target's MaxHealth.
- Range, i-frames and the hitbox window are not in the spec's numbers, so they are `-- TUNE` placeholders.
- "Tile" = `Config.TileSize` studs (4 by default).
- A blocked 4th M1 counts as connected, so it gives the cooldown, not the whiff stun.
- Black Flash chain means consecutive Black Flash hits. It resets when the buff expires or a Critical hit is used.
- Hits on a ragdolled target still deal damage but don't add stun.
- The wall-combo forward dash may cancel the endlag of the triggering move. Otherwise the 0.2 s window would close before the endlag ends. It still needs the forward dash off cooldown.
- No buffering: inputs sent during a swing are ignored.
- Skills are four placeholder guard breakers and wall-combo starters, enough to test the rules. They aren't a moveset.

## Exploits guarded against

- **Remote spam:** each player gets a fixed one-second budget (`Config.RemoteRateLimit`). Inputs over the budget are dropped before any work is done.
- **Fake inputs:** every argument is type-checked. Dash directions are whitelisted, skill names must exist in Config, and cooldowns, states and ranges live only on the server.
- **Teleport or long dash:** distance, speed, duration and i-frames are computed on the server. The client's timestamp can only back-date the start by 150 ms, and NaN or infinite timestamps are clamped or rejected.
- **Hitbox desync:** hitboxes run on the server against server positions, with one hit per target per swing. Generous `-- TUNE` box sizes absorb normal ping.
- **Infinite combos:** stun decay, stun immunity after ragdoll, and the finisher cooldown.

Not covered: general movement exploits (client-side teleport or speed hacks, since characters are client-owned), and spamming F to fish for perfect blocks within the rate limit. Add a short cooldown on re-entering block if that becomes a problem.
