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
| W + Q | Front dash; its first 0.15 s is the Dash Jab hitbox |
| Hold Space while clicking the 4th M1 | Uppercut (target flies up, lands, ragdolled 1.5 s) |
| Space, then click within 0.15 s (not mid-combo) | Uppercut opener (after a landed jab: Mini Uppercut) |
| Tap Space between swings or from neutral, then click in the air | Downslam (ragdolled 1.5 s) |
| Click during a side dash | Cancels the dash into an M1 |
| 1 | Shove (guard break) |
| 3 | Normal Punch (guard break within 4 studs) |

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
- **Dash Jab:** front-dash into P2. P2 takes 4 % (5.3 % from 3 studs or closer) and shows `Stunned` for 1.0 s, and P1's dash stops on contact. Back and side dashes into P2 do nothing.
- **Blocked jab:** P2 holds F early, so the jab does no damage or stun and P1 is stuck in `Attacking` for 0.4 s. P2 presses F just before contact, so the jab is perfect-blocked (gold flash).
- **Jab follow-ups:** after a landed jab, M1 (starts at hit 1), Space+click (Mini Uppercut) and jump + 4th click (Downslam) all land inside the 1.0 s stun.
- **Anti stun-lock:** jab P2, wait for the stun to end, then jab again within 3 s. The second stun lasts 0.5 s. A jab stun that runs out with no follow-up gives P2 0.5 s of stun immunity.
- **Uppercut:** click 3 M1s on P2, then hold Space and click the 4th. You don't jump. P2 takes 5 %, rises about 8 studs, lands, and stays `Ragdolled` about 1.5 s after landing. With P2 blocking, it still hits (guard break). Your next M1 is locked for 0.8 s.
- **No jumping mid-combo:** hold Space from the 1st click onward. You stay on the ground for the whole string.
- **Faster M1s / shorter whiff:** each swing takes about 0.25 s, and a missed 4th hit stuns you for 0.5 s.
- **M1 out of a side dash:** A+Q or D+Q, then click during the dash. The dash stops and M1_1 comes out.
- **Uppercut dash tech:** land a jab, then Space+click (Mini Uppercut, 3 %, about 4 studs), then W+Q right away. The dash starts during the Mini Uppercut's endlag.
- **Downslam:** tap Space, wait a moment, then click while in the air (or mid-combo: tap Space between swings, then click). P2 is slammed, ragdolled for 1.5 s and takes 6 %, and you see the ring, dust and rocks plus camera shake. Downslam then has a 3 s cooldown and your M1 is locked for 0.8 s.
- **True Downslam:** click, click, tap Space, click in the air. P2's back or side dash cannot cancel this ragdoll; a downslam from neutral can be cancelled.
- **Black Flash:** with a Black Flash buff, a Mini Uppercut or Downslam deals 24 %.
- **Leaving mid-move:** P2 leaves (or is killed) during an uppercut launch, a ragdoll or a jab stun. P1 is not stuck, the server Output shows no errors, and nothing is left on the map.
- **Ragdoll cancel:** while P2 is ragdolled on the ground, a back or side dash stands them up at once and starts that dash's cooldown. A forward dash does nothing. After getting up, P2 cannot be stunned for 0.5 s.
- **Wall combo:** push P2 against a wall (within 4 studs). Land the 4th M1, an Uppercut (either size) or a Downslam, then press Q with W within 0.2 s. You should see a purple flash and 12 % damage, then a 5 s wall-combo cooldown.
- **Spam:** an autoclicker above 20 inputs per second has the extra inputs dropped and the server stays responsive.
- **Startup self-check:** if any Config change breaks an assert in CombatService, the server Output shows it immediately.

## Assumptions

- Percentages are a share of the target's MaxHealth.
- Range, i-frames and the hitbox window are not in the spec's numbers, so they are `-- TUNE` placeholders.
- "Tile" = `Config.TileSize` studs (4 by default).
- A blocked 4th M1 counts as connected, so it gives the cooldown, not the whiff stun.
- Black Flash chain means consecutive Black Flash hits. It resets when the buff expires or a Critical hit is used.
- Hits on a ragdolled target still deal damage but don't add stun.
- The jump-held flag sent with each M1 only chooses between moves; the server still checks you're grounded, it's the 4th hit, and the cooldown is ready.
- The opener uppercut needs the jump to start on the server's copy of your character (Humanoid state Jumping), then the click within `Moves.Uppercut.InputWindow`.
- Mini Uppercut is the opener input within the jab stun after a landed jab. Both sizes share one cooldown.
- Jump lock is client-side (it's your own character's input). The server separately sets JumpHeight 0 during swings.
- Airborne is not a combat state: you can still attack in the air. It's checked from the Humanoid state plus a floor raycast. Launched is a real state, set on the uppercut's target.
- Stun immunity now also blocks ragdolls (finisher and downslam), except a downslam that uses the upside-down tech.
- Combo damage decay is off by default (`Config.Combo`).
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
