# Everything We Did — Steal An Egg

A map of the whole conversation, so it does not have to be remembered.

Game: **Steal An Egg**, placeId `107778070777162`. Loaded through an executor, not
a published build.

---

## 1. The three repos

```
┌──────────────────────────────────────────────────────────────────────────┐
│  github.com/dertmo01                                                      │
│                                                                          │
│   virexhub ───────────────► virexhub-archive      virex-antihit          │
│   PARKED                   full history,          THE LIVE ONE           │
│   27 commits              frozen                 3 commits               │
│   no longer developed     1aa8c98                62cf438                 │
│                            │                      │                        │
└────────────────────────────────────────────────────────────────────────┘
```

| repo | state | what it is |
|---|---|---|
| `virexhub` | parked at `de748f3` | the complex project. Every later bug lived here. |
| `virexhub-archive` | frozen at `1aa8c98` | all 27 commits + the two oldest scripts as files |
| `virex-antihit` | **live** at `62cf438` | one file, two functions, a window |

### Current loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dertmo01/virex-antihit/master/antihit.lua"))()
```

---

## 2. How we got here

```
  FIRST SCRIPT
  one 2015-line monolith, GUI, instant-TP steal engine
  "I have a bad feeling about this"
        │
        ▼
  ADDED EVERYTHING ── module split into src/, tabs, probe, RSPY
  Auto Fetch · egg rarity · FLOW / HOP / GLIDE / TP · self-tests
        │
        ▼
  THE PROBLEMS STARTED
  the split silently deleted things        → nil transport constants
  classifyEgg never existed               → crash on first egg scan
  the deposit got interrupted by a dodge   → egg lost
  clipboard "failed" on a read Roblox allowed to block
  minimize lost the body, window reopened dead
  self-test passed everything that mattered
        │
        ▼
  0.5 SECONDS OF TRAVEL
  the thing all that machinery was for
        │
        ▼
  CUT IT ALL AWAY
  two functions, one file
```

---

## 3. Why there is no teleport any more

This is the whole design in one picture.

```
    SAFE ZONE  ──────────────►  HOME
     550,70,-431                 657,68,-363
                127 studs

    at WalkSpeed 264  ──►  0.48 seconds
    at default 16     ──►  7.9 seconds
```

The safe zone is **127 studs** from home. Walking takes half a second. A teleport
bought nothing.

And teleporting was the *unreliable* option:

```
   client writes position
          │
          ▼
   server checks the MAGNITUDE OF THE DELTA
   not the absolute position
          │
    ┌─────┴──────────────┐
    ▼                    ▼
  ~37 studs          90+ and 1770 studs
  accepted           SILENTLY CORRECTED
```

So the old script looked like it was teleporting successfully and was not.
Walking cannot be corrected. That is the whole argument.

---

## 4. The server rules, and what they cost

Facts from live logs. Each one is here because it cost real debugging time.

```
┌────────────────────────────────────┬──────────────────────────────────────┐
│ RULE                               │ WHAT IT KILLED                      │
├────────────────────────────────────┼──────────────────────────────────────┤
│ WalkSpeed clamped to 264           │ every "make it faster" idea.         │
│ every frame, client writes lose    │ The number cannot be raised. Asking  │
│                                    │ every step is the only way to hold  │
│                                    │ it.                                 │
├────────────────────────────────────┼──────────────────────────────────────┤
│ Server validates the DELTA         │ FLOW / HOP / GLIDE / TP. All four.   │
│ magnitude, not position            │ Short jumps stick, long ones lie.   │
├────────────────────────────────────┼──────────────────────────────────────┤
│ Knockback beats MoveTo             │ Walking home did not work until     │
│                                    │ stripPushBack() ran every step.     │
├────────────────────────────────────┼──────────────────────────────────────┤
│ No position writes during          │ First teleport after spawning       │
│ post-spawn warmup                  │ silently did nothing.               │
└────────────────────────────────────┴──────────────────────────────────────┘
```

Two signals mean a guard is on you, and both are watched:

```
   DropHeldEgg.Enabled  ──┐
                          ├──►  DODGE
   ProximityPrompt      ──┘      │
                                 ▼
                        SAFE ZONE, 1 second
                                 │
                                 ▼
                    CLEAR SPOT (516,72,-366)
                    NOT back where you were hit —
                    that is why it kept catching up
```

`HoldDuration = 0` on every prompt — measured **98/98 accepted**. A prompt you
cannot press in time is a prompt the guard interrupts.

---

## 5. The two functions

```
   ┌─────────────────────────────────────────────────────┐
   │  ANTI HIT                            on by default  │
   │                                                     │
   │  watches both guard signals                         │
   │  safe zone 1s ─► clear spot                         │
   │  cooldown 4s so a re-armed guard is not a new one   │
   └──────────────────────┬──────────────────────────────┘
                          │  a dodge PAUSES the walk home
                          │  and hands control back when done
                          ▼
   ┌─────────────────────────────────────────────────────┐
   │  AUTO RUN                            R, or the      │
   │                                     toggle         │
   │  WalkSpeed 264 + MoveTo home                        │
   │  no teleport, no velocity hack                      │
   │  gives up after 25s rather than nag                 │
   └─────────────────────────────────────────────────────┘
```

**Why they take turns.** Both write your position. Letting them fight is how the
old script dragged you back into the guard it had just dodged, and how a dodge
cancelled a deposit mid-animation. Safe beats fast.

---

## 6. The window

```
   ┌────────────────────────────────────────┐
   │ VIREX ANTI-GUARD              _   X    │  drag anywhere
   ├────────────────────────────────────────┤
   │  Anti Hit            on / off     [ () ]│
   │  watch the guard, move you clear      │
   ├────────────────────────────────────────┤
   │  Auto Run            idle      [ () ] │
   │  R also toggles this                  │
   ├────────────────────────────────────────┤
   │  [warn] Dodge via DropHeldEgg.Enabled │
   │  [ ok  ] Dodge done, moved clear      │  live log,
   │  [ ok  ] Auto Run: home, 12 studs…    │  last 60 lines
   ├────────────────────────────────────────┤
   │  Anti Hit on | Auto Run idle          │  status strip
   └────────────────────────────────────────┘
```

| control | what it does |
|---|---|
| **R** | walk home / cancel |
| `_` | minimize / restore |
| `X` | hide the window — **features keep running** |
| `VIREX_DISABLE()` | actually stop both |
| `VIREX_START()` | Anti Hit back on |
| `VIREX_AUTORUN.start()` | walk home |

Two sinks, and the order matters: **the executor console is primary.** Every line
prints there too, because that is what gets pasted back when something breaks — the
window and the clipboard were the two things that broke in the old project.

---

## 7. What is deliberately gone

```
   virex-antihit                virexhub (parked)
   ─────────────                ────────────────
   Anti Hit        ✓            Auto Fetch       ✗ classifyEgg never existed
   Auto Run        ✓            egg rarity       ✗ nil after the split
   window          ✓            FLOW/HOP/GLIDE   ✗ the server corrects them
   zero-config     ✓            TP               ✗ silently corrected
                                probe / RSPY     ✗
                                self-tests       ✗ passed everything
                                3 tabs           ✗
                                src/ split       ✗ deleted things silently
```

Nothing was deleted from the old repo. It is parked in full, history intact, and
the two oldest scripts are checked in as files:

| file | commit | lines | note |
|---|---|---|---|
| `archive/v1-original-monolith.lua` | `aea65c6` | 2015 | the very first version |
| `archive/v2-antihit-autobase-only.lua` | `2ac2168` | 1217 | already Anti Hit + Auto Run |

`v1` is kept for history, not as a base — its `AutoSteal` calls `classifyEgg()`,
which does not exist in that file, so every scan throws.

---

## 8. Mistakes made along the way

Worth writing down, because each was silent at load and wrong at run time.

| what | why it mattered |
|---|---|
| `autoRun` declared *after* `beginDodge` used it | would have been a nil global at the exact moment the guard hits you |
| stuck check subtracted `nil` on the first second | every walk raised instead of measuring |
| `PromptTriggered` connected inside `watch()` | every re-enable added another; dodges fired twice |
| my `.gitignore` listed `antihit.lua` | first push shipped the README only and the loader URL **404'd** |
| shipped console-only after asking | nothing on screen to show it had loaded |
| `flowTp` logged `dest.Magnitude` | world coordinates, not distance travelled — produced impossible "755 studs in 0.3s" |
| self-test probed a 3-stud hop | every method passed while long jumps were being rejected |

---

## 9. Open

- **No live testing yet.** Everything above is from static checks and live logs
  from the old project. Nothing has been run in Roblox since the rewrite.
- **Window size** is 340×340. Unverified against the user's screen.
- **Not tested:** an actual guard encounter, an actual walk home, a respawn.

The next useful thing is a console paste from one real guard hit and one `R`.