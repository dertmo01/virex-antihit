# Virex Anti-Guard

Anti Hit and Auto Run. That is the whole thing — one file, no config, no window.

For *Steal An Egg* (placeId `107778070777162`).

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dertmo01/virex-antihit/master/antihit.lua"))()
```

## The two functions

**1. Anti Hit** — on by default, nothing to set up.

It watches both signals the guard uses: the `DropHeldEgg.Enabled` flag the server
flips, and the prompt it fires. When either fires it moves you to the safe zone
(`550, 70, -431`), waits a second, then leaves you at `(516, 72, -366)` — clear of
the guard, not back where you were hit from. Returning to the exact spot you were
hit from is the reason the guard kept catching up again in the old script.

**2. Auto Run** — walk home at full speed.

Press **R**, or `getgenv().VIREX_AUTORUN.start()`. R again cancels.

| | |
|---|---|
| Speed | 264 studs/s |
| Safe zone to home | 127 studs |
| Time | about **0.5 seconds** |

## No teleport, on purpose

The old script had four transport methods and every one of them was a source of
bugs. The server validates the **magnitude of a position delta**, not the
absolute position: short jumps around 37 studs are accepted, and 90-stud or
1770-stud jumps are silently corrected back. That is why long teleports looked
like they worked and then did not.

None of that matters here. The game lets you run at 264 studs/s and home is 127
studs away, so walking is half a second and cannot be corrected by the server.
A teleport had nothing left to offer.

## Controls

| input | what it does |
|---|---|
| **R** | walk home / cancel |
| `getgenv().VIREX_DISABLE()` | turn both off |
| `getgenv().VIREX_START()` | turn Anti Hit back on |
| `getgenv().VIREX_AUTORUN.start()` | walk home |
| `getgenv().VIREX_AUTORUN.stop()` | cancel the walk |

## How the two cooperate

Both write your position, so they take turns rather than fight. A dodge pauses
the walk home and hands control back when it is done. Letting them run at the
same time is how the old script ended up dragging you back into the guard it had
just dodged, and how a dodge cancelled a deposit mid-animation.

## Things the server will not let you do

Recorded here so nobody spends an afternoon rediscovering them:

- **`WalkSpeed` is clamped to 264 every frame.** Client writes never win. The
  script asks for it every step rather than once, because asking once does not
  hold it. You cannot go faster by raising the number.
- **The guard's knockback beats `MoveTo`.** That is why `stripPushBack()` runs
  every step: without it you stop walking and never arrive.
- **The server refuses position writes during post-spawn warmup.**

## What is not here

Auto Fetch, egg rarity, RSPY-style probe logging, self-tests, the three tabs, the
`src/` module split, and the GUI. Those are in
[`dertmo01/virexhub-archive`](https://github.com/dertmo01/virexhub-archive),
along with the full history of the project this was cut from.

## Credits

Anti Hit guard detection, the fast click (`HoldDuration = 0`, measured 98/98),
the safe-zone idea and the glide came from the `stealvip2` reference. That
project is credited in the archive README.