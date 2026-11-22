# floorzero

Roblox game managed with Rojo (`default.project.json`). Start the sync server with `Start Rojo.bat` (port 34872), then Connect from the Rojo plugin in Studio. Only one server can run at a time.

## File structure

| Path | Studio location | Purpose |
|------|-----------------|---------|
| `src/replicated/IntroCutscene.luau` | `ReplicatedStorage.IntroCutscene` | Intro cutscene + title menu ModuleScript (`.Play()`, `.IsPlaying()`) |
| `src/starterplayer/InitIntro.client.luau` | `StarterPlayerScripts.InitIntro` | Calls `IntroCutscene.Play()` on join |
| `src/server/IntroSpawn.server.luau` | `ServerScriptService.Server.IntroSpawn` | Disables auto-spawn; spawns the character when the client invokes `IntroSpawnRequest` (BEGIN). `HOLD_SPAWN_UNTIL_BEGIN = false` restores normal spawning |
| `src/shared/ReturnByDeathSequence.luau` | `ReplicatedStorage.Shared.ReturnByDeathSequence` | Older death cutscene. Currently not called by anything |
| `src/client/init.client.luau`, `src/server/init.server.luau`, `src/shared/Hello.luau` | `Client`, `Server`, `Shared` | Rojo template placeholders |

Re-trigger the intro while testing (Command Bar during playtest):
`require(game.ReplicatedStorage.IntroCutscene).Play()`

## IntroCutscene.luau — implemented

Status: written and builds with Rojo, but **not yet playtested in Studio**. Tuning (brightness, haze strength, ghosting, timings) needs eyes-on iteration.

- Procedural pawn-shop room at `CONFIG.RoomOrigin` (y=4000): plank floor/walls, crates, barrels, shelves, table, toppled chair, blood pool, warm lantern, moonlight crack, dust and floor mist. Destroyed after the cutscene.
- Look: dark and cold (blue-grey ambient/fog) with the orange flickering lantern as the warm accent. Grey ColorCorrection, DepthOfField, Bloom, grey haze, drifting clouds, messy dark-grey paint/blood-like splatters along the edges (blobs, drips, flecks) and fine scratch lines.
- Double vision: two ViewportFrame clones of the room (and figure) are blended over the real view at different yaw/pitch offsets. Amount grows with `prog = t/30` and spikes on nods/blur spikes/murmur. Blur, haze, vignette and DoF also build up with `prog`, so vision gets steadily worse.
- Consciousness loss: floor POV with 28° roll, breathing sway, FOV 56-70, blur spikes, small eyelid bars (scale 0.5 of screen max), and a dozing head-bob: slow droop, sharp jerk back up with a blur spike, groggy settle, repeating every ~4.5-7s.
- Heartbeat that slows and weakens, with `HapticService` pulses (gamepad / supported mobile).
- Ominous figure: tall faceless black silhouette made only of ellipsoids (Part + SpecialMesh Sphere): long coat with ragged tatters, peaked hood, thin long arms with 3 dangling fingers per hand. Highlight outline is hidden (no purple). Walks from the doorway, pauses mid-walk with a head tilt, stops about 10 studs away.
- Dialogue (typewriter, Enter/click to advance): italic narration of faint footsteps, 2 figure lines, "...ngh...", italic "You struggle to speak..." narration, "[Chuckles softly]".
- Ending: fast fall, head thumps the floor and bounces, eyelids slam, black. Then 0.6s black, then title menu.
- Title menu: grey/amber gradient backdrop, embers, text logo (`CONFIG.LogoImage` swaps in an image), `[ BEGIN ]` button with hover/click tweens. BEGIN fades out, requests spawn, restores camera/controls/CoreGui.
- `[ SKIP ]` button (top right) jumps to the title menu and cleans up everything.
- No purple anywhere; palette is greys with amber accents.

## Not done / notes

- All `SOUNDS` ids in IntroCutscene.luau are `0` (silent). Fill in asset ids.
- Set `Lighting.Technology = Future` in Studio for the best lantern/moonlight shadows.
- `GameTitle` ("FLOOR ZERO") is a placeholder.
- Ghost viewport clones the room once at start, so it adds some rendering cost.
