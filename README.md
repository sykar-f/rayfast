# rayfast

A tiny native macOS launcher: open apps, bind global hotkeys to apps, and quick conversions
(math, units, currency, time zones). Raycast-style layout. Objective-C + AppKit, no Swift, no WebKit, no Node.

```
make            # build/rayfast.app
make run        # start it
make install    # copy to ~/Applications and start at login (LaunchAgent)
make uninstall
```

Working on it while the installed rayfast keeps `⌘Space`:

```
make dev        # rebuild + relaunch a test copy, opened with hyper+9 (DEV_KEY=... to change)
make dev-stop   # stop the test copy
make ship       # push the committed code and switch the nix config (NIXCFG) to it
```

With Nix, `nix build` gives the same `rayfast.app` under `result/Applications`, and the flake's
home-manager module replaces `make install` (use one or the other, not both):

```nix
# flake inputs
rayfast = { url = "github:sykar-f/rayfast"; inputs.nixpkgs.follows = "nixpkgs"; };

# home-manager
imports = [ inputs.rayfast.homeManagerModules.default ];
services.rayfast.enable = true;
```

## Using it

| | |
|---|---|
| `⌘Space` | toggle the launcher (change `toggle` in the config) |
| type | fuzzy app search (`vsc` → Visual Studio Code), ranked by how often you open things |
| `↩` | open app / copy answer |
| `⌘K` on an app | record a global hotkey for it (`⌫` removes, `esc` cancels). Pressing an app's hotkey while it's frontmost hides it |
| `⌘,` | edit `~/.config/rayfast/config` |
| `⌘↩` on 2+ words | ask Codex (also `↩` on the "Ask Codex" row, shown when nothing else matches) |

Conversions: `5 km to mi`, `72f`, `3 cups in ml`, `1 gib in mb`, `100 usd to inr`, `€50`, `20% of 150`,
`sqrt(2)*pi`, `time in nyc`, `london time`, `3pm pst to ist`, `noon tokyo to nyc`.
Exchange rates come from open.er-api.com (fetched by `/usr/bin/curl`, cached 6h in `~/Library/Caches`).

**Codex.** Asking switches the launcher into a conversation: a `Codex` chip in the search bar, the transcript in
place of the results, and `↩` sends a follow-up. The conversation survives hiding the launcher; `esc` ends it and
returns to the launcher. Each turn is a separate `codex exec --json` process (`codex exec resume` for follow-ups), so
nothing runs between turns. Defaults: model `gpt-6-luna`, sandbox `workspace-write` run from `$TMPDIR/rayfast-codex`
(codex can write there and in `/tmp`, not in your home, and has no network). The config can override them
with `codex = /path/to/codex`, `codex_model = …` and `codex_sandbox = read-only`. Answers are rendered with Foundation's
markdown parser (inline styles); headings, lists, code blocks and tables are handled line by line.

## Numbers

Measured on an M5 MacBook (60 Hz display) with `footprint` (Activity Monitor's "Memory") and QuickKey's
ScreenCaptureKit benchmark (keypress → first frame where the panel has settled), interleaved runs:

| | Raycast | QuickKey | rayfast |
|---|---|---|---|
| memory at rest | ~175–187 MiB | ~14 MiB | **~11–13 MiB** |
| memory while open | | | ~14 MiB |
| open after idle (median) | 95 ms | 52 ms | **50 ms** |
| rapid re-open (median) | 61 ms | 46 ms | 46–49 ms |
| slowest open | 127 ms | 78 ms | **61 ms** |

About 37 ms of every open is the window server (two 60 Hz frames from commit to scan-out) and ~3 ms is key
delivery; rayfast's own work is ~3 ms of it.

## How

- **Respawn after use.** Using a window fragments AppKit's heap (~10 MB that's never returned). Four seconds after
  the launcher hides, rayfast `execv()`s itself: same pid, hotkeys re-registered, memory back to its cold size.
- **Pre-shown, pre-rendered.** On startup (and after every respawn) the window is built, rendered and shown once
  invisibly off-screen, so the window server's first-show cost is paid up front. Every hide immediately re-renders
  the empty launcher, so a show is just "order this window in".
- **No view draws itself.** A window this size that updates through AppKit's `drawRect:` gets a fixed ~40 MB GPU
  pool from Core Animation (plus 64-bit float buffers when wide-gamut colours are drawn on a P3 display). rayfast
  paints each frame on the CPU into a pair of **grayscale IOSurfaces** (1 byte/px, ~2.8 MB for both) used directly
  as layer contents. The only colour (app icons, logo, caret) lives in tiny separate layers, and the caret blinks
  via a render-server animation, so blinking never repaints. The open window went from ~84 MB to ~14 MB.
- **No NSTextField.** The search box is a small `NSTextInputClient` view (IME, dead keys and emoji still work);
  NSTextField's TextKit field editor cost ~30 ms on cold opens.
- **Icon cache.** App icons are rendered once into 48×48 bitmaps in `~/Library/Caches/rayfast-icons.bin`, which is
  `mmap()`ed read-only: file-backed pages don't count toward the footprint, and IconServices only loads for apps
  that aren't cached yet (or have changed).
- **Global hotkeys** use Carbon's `RegisterEventHotKey` (no Accessibility permission). App launching goes through
  LaunchServices; networking stays out of process (`curl`), so CFNetwork never loads.
- **`MallocSpaceEfficient=1`** (set by re-execing once at startup) trims ~1 MB of allocator slack.

Code: `core.m` (config, hotkeys, launching, respawn, `main`), `ui.m` (window, renderer, search, conversions), `codex.m` (Codex turns, markdown),
`rf.h` (the interface between them).

## Testing hooks

`kill -USR1 <pid>` toggles the launcher. Environment variables: `RF_CONFIG_DIR` (another config dir),
`RF_NOHOTKEY=1` (register no hotkeys) with `RF_TOGGLE=hyper+9` (a private toggle), `RF_DEBUG=1` (log hotkey→commit
latency to stderr), `RF_SNAP=/path/x` (`kill -USR2` renders the window with the query in `/path/x.q` to
`/path/x.png`). `rayfast --eval "5 km to mi"` runs the conversion engine from the command line.

`make test-app` builds a separately named copy (`rayfast-test`) so tests never touch the running instance.
`tests/lat.sh` measures resting memory and in-process latency, `tests/active.sh` the open window.
`tests/bench.sh`, `tests/breakdown.sh` and `tests/h2h.sh` drive QuickKey's ScreenCaptureKit benchmark (built from
`QuickKey/tests/RenderLatency.m` plus `tests/RenderLatency.patch`; set `$BENCH` to the binary).
`tests/codex-trigger.sh` checks that conversions and Codex never compete for a query.
`tests/e2e*.sh` type into the real UI with synthetic keystrokes, so run them with nothing important frontmost.

## License

MIT, see [LICENSE](LICENSE).
