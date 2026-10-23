# MTL_HUD_ELEMENTS suppresses every added HUD row

Feedback on `feature/mac-stats`, tested against `d11f3cc` and re-checked
against head `b8d0238`. The headline is a bug **in MetalHUDmenu itself**, not
in Wine or CrossOver: the app sets an environment variable that suppresses its
own Mac Stats rows. Confirmed on **macOS 26, on the `reportLegacy` path**. On
macOS 27 the StateReporting path is taken instead, so this may never have been
visible to anyone developing there — while being present for everyone on the
shipping OS.

## The bug

`MTL_HUD_ELEMENTS` is an absolute allow-list of element names, and a row added
through `addLabel:after:` is not in it under any spelling. We tried the label
ids themselves, the bare name `user` (despite `com.apple.hud-label.user`
existing inside `libMTLHud`), and `MTL_HUD_EXTRA_ELEMENTS`. None render. While
that variable is set to anything, Apple's HUD draws its own stats and drops
every added label.

**Scope, stated precisely.** Confirmed on macOS 26.4.1, where `reportLegacy`
and `addLabel:after:` are the path taken. We have no macOS 27 machine, so we
have **not** tested whether the StateReporting path is gated the same way — and
there is reason to think it is not, since the `MTL_HUD_EXTRA_ELEMENTS` names
(`client`, `statereporter`) look like element names the allow-list would
recognise.

The dylib loads, the timer runs, `addLabel:after:` returns `YES` for every row,
and the HUD draws none of them. Nothing in any log says why.

### Where it comes from

Two call sites set the variable, and `mhud_stats.mm` at `b8d0238` never clears
it — it only appends to `MTL_HUD_EXTRA_ELEMENTS`, which does not help:

```swift
// HUDSettingsManager.swift:103
runLaunchctl(["setenv", "MTL_HUD_ENABLED", "1",
              "MTL_HUD_ELEMENTS", selectedElements.sorted().joined(separator: ","), ...])

// LaunchConnection.swift:28
environment["MTL_HUD_ELEMENTS"] = elements.sorted().joined(separator: ",")
```

The first writes it into the launchd session, so it reaches anything launched
from the Dock afterwards. The second writes it straight into each launched
game's environment — four lines after injecting the stats library into that
same dictionary.

That second one matters most, because it is not an edge case: it is the
supported path. For a native app, custom metrics require launching through the
app or with the copied launch option, and both go through `launchEnvironment`.

**This also affects the Wine runtime patch.** `WineRuntimePatch` does its job —
`winemac.so` carries the weak dependency and the library reaches wine processes
— but on macOS 26 the rows are then suppressed by the variable the settings
code wrote. The visible result is a game with Apple's HUD and no custom
metrics, which looks exactly like an injection failure and is not one.

**One case not tested:** when `elements` is empty, that line sets
`MTL_HUD_ELEMENTS=""`. Whether an empty value suppresses added rows the way a
populated list does is unknown.

## The fix

`mtl-hud-elements-fix.diff` in this directory — one hunk against `b8d0238`,
applies cleanly and compile-checks:

```
git checkout feature/mac-stats
git apply mtl-hud-elements-fix.diff
```

It clears the variable in the constructor, which runs when the library is
inserted; Apple's HUD reads the variable later, when the Metal device is
created, so clearing it there is in time. Guarded by `statsEnabled()`, and it
logs what it cleared under `MHUD_DEBUG`.

**The trade-off:** Apple's HUD then falls back to its built-in default element
set inside apps carrying the library, so a user's own element choice is ignored
there. Their panel settings are untouched system-wide. There is no middle
ground — it is not *which* elements are listed, it is that a non-empty list
drops every added label.

## Verified

M1 Max, macOS 26.4.1, CrossOver 26.3.

| Target | Result |
| --- | --- |
| Path of Exile (DX12 / D3DMetal, x86_64 under Rosetta) | All 18 rows live |
| Diablo IV (DX12 / D3DMetal, via Battle.net) | All 18 rows live, under load |
| Mordheim: City of the Damned | Rows live |
| Graveyard Keeper (32-bit) | Rows live |
| Native Metal window, arm64 and x86_64 | Rows live on both |

"18 rows" is 22 selected metrics, with directional pairs sharing a line.
Confirmed visually on screen in each case, not only in the log.

### Ruled out along the way

Recorded because each looked plausible and cost time:

- **Not the macOS 26 label path.** `reportLegacy` works correctly on 26.4.1.
- **Not a stalled timer.** A watchdog on a separate queue showed the dispatch
  timer healthy throughout.
- **Not a competing writer.** D3DMetal and DXMT both contain
  `_CADeveloperHUDProperties`, `addLabel:after:` and `remove:`. With both
  methods hooked in the live game process, neither ever called them.
- **Not Rosetta.** An x86_64 build of a native test window renders the rows
  fine under translation.

## On CrossOver

We reached CrossOver a different way before seeing `WineRuntimePatch.swift`:
entitling the wine loader with
`com.apple.security.cs.allow-dyld-environment-variables` and putting the
library in each bottle's `cxbottle.conf` under `[EnvironmentVariables]`. It
works, on four games. **But the `winemac.so` approach is better**, and we
checked why rather than assuming:

- **There is no global environment hook in CrossOver.** `CXBottle.pm` reads
  `$WINEPREFIX/cxbottle.conf` and nothing else. The bottle templates are Perl
  modules (`CXBT_win10_64.pm` plus `setup`), not a config skeleton that could
  be seeded, so a newly created bottle cannot inherit the setting either. The
  per-bottle route is therefore per-bottle forever.
- Only `CX_BOTTLE` and `WINEPREFIX` are refused in that section;
  `DYLD_INSERT_LIBRARIES` is explicitly permitted.
- It must go in directly rather than through `CX_ENV`: `bin/wine` captures
  `CX_ENV` from the environment at line ~125, long before it reads the bottle
  config at line ~722, so a `CX_ENV` written into `cxbottle.conf` is parsed
  after the capture and silently never takes effect.

Both approaches share a cost worth naming: **each modifies CodeWeavers'
shipped binaries and breaks on every CrossOver update.** Entitling the loader
re-signs their binary just as adding a load command does. The difference is the
failure mode — the entitlement route is version-agnostic and re-appliable by
the user, the patch route is pinned to verified hashes, so a new CrossOver
release leaves users waiting for a new MetalHUDmenu release.

### A trap for the optional dylib-insert route

A game started from a CrossOver-built launcher is run by LaunchServices and
**hosted in the launcher's own process** — `<game>.app/Contents/MacOS/Menu
Helper`. There is no separate game executable. For Path of Exile and Diablo IV,
`Menu Helper` was the process at 129% CPU with `libMTLHud` mapped. Bottle
environment never reaches it, so that bundle needs the entitlement too. Testing
only Windows-launcher games would suggest the route works, then produce bug
reports from Battle.net and POE users.

### The fix that would retire both

If CodeWeavers shipped `com.apple.security.cs.allow-dyld-environment-variables`
on the wine loader, neither patch would be needed: the library could be
injected by environment alone, with no binary modification and nothing to redo
after an update. They already ship `disable-library-validation`, so the ask is
narrow.

## Mac App Store apps

MAS binaries are Apple-signed and carry library validation without
`com.apple.security.cs.disable-library-validation`, so dyld refuses any
inserted library not signed by the same team identifier. There is no workaround
short of the developer shipping that entitlement — the same wall CrossOver only
avoids because CodeWeavers do ship it.
