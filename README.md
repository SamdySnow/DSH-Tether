# Tether

English · [简体中文](README.zh-CN.md)

A small native macOS companion for the **DeepSeek Harness** CLI. It starts
`npx @deepseek-ai/dsh web` for you, shows the service's terminal output in a real
window, and keeps a menu bar item in the top-right so you can stop the service
without hunting for a terminal.

*Tether* — a line that holds something in place, and the word a harness is made
of. The app keeps the DSH service tethered to your menu bar.

Targets **macOS 27**, and uses APIs that are genuinely new there (verified against
the macOS 27.0 SDK — see [macOS 27 features](#macos-27-features)).

## What it does

| Requirement | Where it lives |
|---|---|
| Auto-start the service on launch | `AppModel.performInitialStartIfNeeded()` from the console window's `.task` |
| Desktop window showing the background terminal | `Views/ConsoleView.swift` |
| Menu bar icon, click to expand, easy shutdown | `Views/StatusMenu.swift` (`MenuBarExtra`) |
| Custom port | `SettingsStore.port`, editable in the toolbar and in Settings |
| Change the app icon in Settings | `Core/IconManager.swift` + `IconSettingsPane` |
| Bundled app icon | `Resources/icon.png` rendered by `Scripts/make-icon.swift` into `Resources/AppIcon.icns` (both committed) |

![icon](Resources/AppIcon.icns)

## App icon

The bundle icon is **generated from committed artwork**. `Scripts/make-icon.swift`
renders the source bitmap into a `.iconset`, and `iconutil` packs it into
`Resources/AppIcon.icns`. Both the PNG and the built `.icns` are committed, so a
fresh clone assembles an app that already carries its icon. `Scripts/build-app.sh`
regenerates the `.icns` whenever the artwork or the geometry changes, so the PNG
stays the single source of truth.

Committing `Resources/` is deliberate: while it was excluded, a clone built an app
with the generic system icon, and the build still reported success — a defect that
only surfaced on someone else's machine.

### The source image is discovered, not hardcoded

Priority order:

1. `Resources/icon.png` — a finished 1024×1024 icon supplied directly.
2. Any image in `Sources/bitmap/` (`.png`, `.PNG`, `.jpg`, `.jpeg`, `.heic`,
   `.tif`, `.tiff`, `.bmp`).
3. `ICON_SOURCE=/path/to/image.png` overrides both.

This is deliberate. The path was once hardcoded to `IMG_2124.PNG`; when the artwork
was replaced as `IMG_2,124.png` the script silently found nothing and kept shipping
the old icon, which looks exactly like "the icon is wrong" rather than "the build
did not run". Regeneration also triggers when the *source filename* changes
(tracked in `Resources/.icon-source`), and a missing source prints a warning
instead of being skipped quietly. The build always reports either
`Generating AppIcon.icns from <file>` or `Icon up to date (<file>)`.

### macOS does **not** round app icon corners for you

This was measured, not assumed. Extracting Apple's own `Calculator.app` icon and
reading its raw pixels:

```
Calculator 256   corner(0,0) alpha=0   edge-middle alpha=0    transparent 33.01%
```

The corners are **transparent in the file**, so Apple bakes the rounded shape into
the artwork. A square, full-bleed image therefore renders as a hard square in the
Dock, which looks out of place on macOS. The generator applies the shape itself.

Comparing the shipped icon with Apple's on the same metrics:

| | corner alpha | edge-middle alpha | transparent |
|---|---|---|---|
| Shipped (`full`) | 0 (rounded) | 255 (fills) | 4.11% |
| Apple Calculator | 0 (rounded) | 0 (inset) | 33.01% |

Both are rounded, confirming the shape must be in the file. The difference is
coverage: this app fills the icon, Apple's artwork is inset with its own margin.
Use `ICON_GEOMETRY=inset` to match Apple's proportions.

### Trimming

**Trimming is on by default** and removes a transparent border from the source, so
the *visible* artwork fills the icon. It is a no-op for an opaque edge-to-edge
image. Disable with `ICON_TRIM=0` for artwork that is meant to float with its own
padding.

For a source that already carries macOS-style rounded corners with a transparent
margin (a conventional macOS icon export), use `ICON_TRIM=0 ICON_GEOMETRY=sharp`:
trimming would crop to the artwork and then re-round it, producing a double-rounded
shape.

### Geometry

```sh
ICON_GEOMETRY=full  ./Scripts/build-app.sh   # default: artwork fills the icon
ICON_GEOMETRY=inset ./Scripts/build-app.sh   # Apple's stock layout (824/1024, transparent margin)
ICON_GEOMETRY=sharp ./Scripts/build-app.sh   # fills the icon, square corners

ICON_TRIM=0         ./Scripts/build-app.sh   # keep the source's transparent border
ICON_SOURCE=/x.png  ./Scripts/build-app.sh   # use a specific source
```

Corners are rounded to Apple's squircle ratio (185.4 / 824, from the standard icon
geometry) so the result reads as a macOS icon rather than a pasted square.

Non-square sources are scaled to fill and centre-cropped, never squashed.

Finder caches icons per bundle path, so if the old icon persists, run
`killall Finder`. Note that macOS adds its own presentation padding when it draws
an app icon on screen, so a full-bleed icon still appears slightly inset in the
Dock and in Finder; that spacing is the system's, not the file's.

### Changing the icon at runtime

`Settings → App Icon` changes the Dock and app-switcher icon without touching the
bundle. macOS does not persist that override, so the choice is stored as a
security-scoped bookmark and reapplied at launch — `AppModel.bootstrap()` calls
`IconManager.applyStoredIcon()` for exactly this reason.

## Build

```sh
./Scripts/build-app.sh          # produces dist/Tether.app
open dist/Tether.app
```

For a plain build without bundling:

```sh
swift build
```

### Important: use Xcode's toolchain

`Scripts/build-app.sh` sets `DEVELOPER_DIR` to Xcode automatically. This is not
cosmetic — it is **required**:

> The SwiftUI macro plugin (`libSwiftUIMacros.dylib`) ships with Xcode and is *not*
> part of the bare Command Line Tools. Building against CLT alone fails with
> `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
> for macro 'State()'`.

If you build by hand and see that error, prefix the command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

## How the service is launched

The app runs the npm CLI's JavaScript entry point directly rather than relying on
the `npx` shell shim:

```sh
/usr/local/bin/node \
  /usr/local/lib/node_modules/npm/bin/npx-cli.js \
  --yes --package=@deepseek-ai/dsh@latest -- dsh web --port 8787
```

Three details matter here:

1. **`--package=<spec> --`** routes arguments unambiguously, so `--port` cannot be
   misread as an option for npm itself.
2. **`--port` belongs to the web app, not the launcher.** Per the DSH README,
   `dsh --profile web --port 8080` works because the launcher hands everything it
   does not recognise to the booted profile.
3. **`node <npx-cli.js>`** avoids depending on the `npx` shim being executable and
   sidesteps `#!/usr/bin/env node` resolution against a `PATH` that a
   Finder-launched app does not inherit.

### PATH and Node discovery

A GUI app launched from Finder inherits almost nothing from a login shell, so
`node` is usually invisible even when it is installed. `ExecutionTargetResolver`
searches Homebrew, `/usr/local`, Volta, fnm, asdf and nvm locations directly. Set
`DSH_HARNESS_NODE` to override:

```sh
DSH_HARNESS_NODE=/path/to/node open dist/Tether.app
```

If Node.js is not found, Tether offers either to install it with Homebrew or open
the official Node.js download page. Homebrew must already be installed; the app
runs `brew install node` only after you confirm.

### Shutdown

`npx` means the process you spawn is only the root of a chain. Signalling just the
root leaves the actual server holding the port, so `ProcessTree` walks the
descendants via `ps` and signals the whole tree — `SIGTERM` first, `SIGKILL` after
an 8-second grace period. After stopping, the app waits for the socket to be
released before reporting idle, so an immediate restart does not trip the port
check.

Quitting with **Quit and Stop Service** stops the tree first, so no orphaned server
is left behind.

#### If the app is killed outright

A force quit, a crash, or `kill -9` gives the app no chance to clean up, and the
DSH tree is reparented to `launchd` where it keeps running and keeps holding its
port. Nothing in-process can prevent that, so the app sidesteps it:

- On launch it records the child's pid and command line in `UserDefaults`.
- On the next start it checks for that pid and terminates it if it is genuinely an
  orphan.

Two guards must both hold before anything is signalled, because process ids are
recycled and killing an unrelated process would be far worse than leaking one:

1. **Orphaned** — the process must have been reparented (`ppid == 1`). If it still
   has a live parent it belongs to a running app and is not ours to reap.
2. **Shape** — its command line must look like a DSH web launch for the recorded
   port.

The recorded command line cannot be compared verbatim, because npm's exec layer
rewrites the child's argv: the process reports as `npm exec dsh web --port <n>`,
not the `node …/npx-cli.js …` form that was launched. Verification is on shape plus
port instead. A successful reap is reported in the console:

```
[app] terminating orphaned DSH from a previous run (pid 11395)
```

#### Releasing a port the server still holds

Terminating the recorded pid does not always free the port: the real `dsh web`
server can sit outside the tree rooted at that pid, so something is still
listening. Rather than reporting a conflict the user cannot act on, the app
releases the port itself — but **only when every listener looks like DSH**:

```
[app] port 8789 still held by 1 leftover DSH process(es); releasing
```

If any listener is not DSH, nothing is signalled and the app says so:

```
[app] port 8789 is held by a non-DSH process; leaving it alone
```

That distinction matters because you may deliberately be running `dsh web` in your
own terminal, and killing an unrelated tool that happens to hold the port would be
far worse than reporting the conflict.

#### A clean exit is not a failure

If the server exits with status 0 — stopped from outside, or by a signal it handles
— the app reports `Stopped`, not `Failed`. Only a non-zero exit or a fatal signal
is treated as an error.

## Renaming and migration

The app was previously called `DSHHarness` with the bundle identifier
`dev.deepseek.dshharness`. Two things were wrong with that: the identifier claimed
a domain the project does not own, which would read as an official DeepSeek
product, and the data folder name was hardcoded in four separate places.

The app is now `Tether` (`dev.tether.dsh`). Any rename moves data behind the user's
back, so both migrations are automatic and run once:

| What | Where | Why it matters |
|---|---|---|
| Data folder | `AppPaths.migrateLegacyDataIfNeeded()` moves `Application Support/DSHHarness` → `…/Tether` | The npm cache is over a gigabyte on a warm install; stranding it forces a full re-download |
| Preferences | `PreferencesMigration.migrateIfNeeded()` copies owned keys from the old `UserDefaults` domain | A new bundle identifier gets a fresh domain, so port, language and icon choice would silently reset |

Both migrations are deliberately one-shot and never overwrite a value the user has
already set in the current location. A failed data move is non-fatal and simply
results in a cold cache.

Paths now live in one place, `AppPaths`, so a future rename is a single edit rather
than four.

## State and files
Everything the app manages lives under `~/Library/Application Support/Tether`:

| Path | Purpose |
|---|---|
| `Workspace/` | Working directory of the DSH process (its workspace root) |
| `DSHHome/` | `DSH_HOME`, isolated so app state never mixes with your CLI profiles |
| `NpmCache/` | Private npm cache, so a root-owned shared cache cannot break startup |
| `dsh-web.log` | Full transcript of every run, appended across launches |

Preferences are in `UserDefaults` under the `dsh.*` keys.

## macOS 27 features

Everything below was confirmed against the macOS 27.0 SDK's SwiftUI
`.swiftinterface` rather than assumed. Two plausibly-new candidates had to be
**rejected** after checking:

- `reorderContainer(for:isEnabled:move:)` — **macOS 27.0**. Used in the Launch
  Presets window (`Views/PresetsView.swift`) for drag-and-drop reordering persisted
  to `UserDefaults`. Its closure delivers a `ReorderDifference<ItemID, CollectionID>`,
  which is converted into a new ordering. The type is not `Sendable`, so it is
  consumed synchronously.
- `TabsPickerStyle` / `.pickerStyle(.tabs)` — **macOS 27.0**. Used in Settings as the
  section switcher, falling back to `.segmented` on older systems.
- `DialogSeverity` — **macOS 13**, not 27. Rejected.
- `backgroundExtensionEffect()`, `ToolbarSpacer`, `safeAreaBar(edge:…)`,
  `labelIconToTitleSpacing` — **macOS 26**, not 27. Rejected.
- `glassEffect(_:in:)` — **does not exist** in this SDK (zero occurrences).
  Rejected.

Both macOS 27 APIs are gated, so the app degrades to a plain list and a segmented
control elsewhere instead of failing to load.

Also from the macOS 27 API surface, verified but not used here: the `Document`
protocol family (`ReadableDocument` / `WritableDocument` / `DocumentReader` /
`DocumentWriter`), `NavigationTransition`'s `AnyNavigationTransition`,
`URLDocumentConfiguration`, and `ToolbarItemVisibilityPriority`.

## Console rendering

DSH colourises its output. Rather than showing literal `ESC[32m` text,
`Support/ANSIParser.swift` translates the SGR subset (16-colour, 256-colour and
24-bit true colour, plus bold/dim/italic/underline) into an `AttributedString`.
Parsing happens once per line as it arrives, so the transcript is not re-parsed on
every redraw. Escape sequences are stripped for search, copy and export.

Auto-scroll pins to the bottom while you are already there; scrolling up unpins and
shows a **Follow Output** button to resume.

## App icon

macOS draws the Dock icon from the bundle's `CFBundleIconFile`, which cannot be
rewritten inside a signed bundle at runtime. The supported path is
`NSApplication.applicationIconImage`, which the app sets from an image you pick in
**Settings → App Icon**. That override is not persisted by the system, so the
choice is saved as a security-scoped bookmark and reapplied at every launch. The
bundle on disk is never modified, so the code signature stays intact.

## Menu bar

The item shows a terminal glyph plus the active port, so the state is readable
without opening anything. The menu contains, in order: state, **Show Console**,
Open in Browser, Copy Service URL, **Restart / Stop Service**, a Port submenu
(including "pick a free port automatically"), Settings, and **Quit and Stop
Service**.

Closing the console window does not quit the app
(`applicationShouldTerminateAfterLastWindowClosed` returns `false`), because the
menu bar item is the point — the service keeps running until you stop it.

## Layout

```
Sources/Tether/
  App/
    TetherApp.swift         scenes, menu bar item, menu commands
    AppModel.swift         main-actor bridge between actor and SwiftUI
  Core/
    DSHService.swift       actor owning the child process + output
    ExecutionTarget.swift  finds Node and npm's npx entry point
    SettingsStore.swift    persisted preferences
    Localization.swift     AppLanguage, string keys, translations
    IconManager.swift      runtime app icon
    LaunchAtLogin.swift    SMAppService wrapper
    DSHConfiguration.swift npm specifier and extra arguments
    LogEntry.swift         one parsed transcript line
  Support/
    ANSIParser.swift       SGR -> AttributedString
    ConsoleTheme.swift     dark-surface palette + keyword highlighting
    ServiceEndpoint.swift  parses DSH's authenticated startup URL
    PortProbe.swift        port availability and readiness checks
    ProcessTree.swift      recursive process termination
    NpxLock.swift          clears abandoned npx package-cache locks
Scripts/
    build-app.sh           builds and assembles dist/Tether.app
    make-icon.swift        renders the source bitmap into a macOS .icns
    check-macos27-api.sh   lists macOS 27-gated SDK declarations
  Views/
    ConsoleView.swift      the terminal window
    SettingsView.swift     General / App Icon / Diagnostics
    StatusMenu.swift       menu bar item and pull-down
    PresetsView.swift      reorderable presets (macOS 27)
```

## Troubleshooting: `ECOMPROMISED` / `Lock compromised`

If the console shows

```
npm error code ECOMPROMISED
npm error Lock compromised
```

the cause is npx's package-cache lock, not DSH. `npx --package=…` resolves the
package under the npm cache and guards it with an advisory lock
(`libnpmexec/lib/with-lock.js`) implemented as a directory whose modification time
is refreshed once a second and treated as stale after 60s. Killing an `npx` run
while it holds the lock leaves that lock behind, and the next run aborts
immediately.

The app clears abandoned locks on every start (`Support/NpxLock.swift`) and reports
how many it removed in the transcript. If you launch DSH yourself, avoid running
two `npx` resolutions of the same specifier at once.

## Troubleshooting: npm `EEXIST` / `EACCES: permission denied, mkdir …`

Older builds shared `~/.npm/_cacache` with your command-line npm. If that cache
contains entries owned by `root` — which happens after any `sudo npm …` — npm
cannot create files inside them and fails with a misleading error:

```
npm error code EEXIST
npm error syscall mkdir
npm error EACCES: permission denied, mkdir '/Users/…/.npm/_cacache/content-v2/sha512/1d/a0'
npm error File exists: …
```

This is **not recoverable without root**, so the app no longer uses the shared
cache. It keeps its own at
`~/Library/Application Support/Tether/NpmCache` and passes it via
`npm_config_cache`, which also means the app can never perturb your own npm state.

You can check whether your shared cache is affected:

```sh
find ~/.npm/_cacache ! -user "$(whoami)" 2>/dev/null | wc -l
```

A non-zero count means some entries are owned by another user. Fixing that
requires `chown -R` as root, so only do it if you know why those files are
root-owned; otherwise leave it alone and let this app use its own cache.

## The signed-in URL

DSH prints an authenticated URL at startup:

```
dsh web: http://127.0.0.1:8787/?token=ayMiNWn6lD_qNb9aIn4VU6_2Pf5VLSltYzKfWKepTmw
```

The `token` query item is required, so the bare `http://127.0.0.1:<port>/` is not
equivalent. The app captures the announced URL from the output
(`Support/ServiceEndpoint.swift`) and uses it for **Open in Browser** and **Copy
Service URL**. The address shown in the toolbar and menu deliberately omits the
token, since it is a credential and that string is on screen.

## Console appearance

The console is a dark surface, which drives two rules in `Support/ConsoleTheme.swift`:

- Default text is near-white. Using the system label colour produced black text on
  a black background whenever the system was in light mode, which made output
  unreadable.
- ANSI "black" (`ESC[30m`) is remapped to a visible grey. Tools emit it for
  secondary text assuming a light terminal; taken literally it vanishes on a dark
  one. Any colour whose luminance is too low to read on this background is lifted
  automatically, including 256-colour and true-colour values.

Beyond the process's own colours, `KeywordHighlighter` colours keywords by
category — errors, warnings, success, informational, URLs, paths, numbers — so the
shape of the output is readable at a glance. It applies **only to text that
carries no explicit colour**, because a process that picked a colour knows better
than a heuristic. It uses `NSRegularExpression` by default; define the
`USE_SWIFT_REGEX` compilation condition to select the Swift `Regex` implementation
instead.

## Language

English and Simplified Chinese, switchable in **Settings → General → Language** and
persisted in `UserDefaults` under `dsh.language`.

The language is resolved once, on first launch, from the system (`zh*` → Chinese,
otherwise English) and then stored as a concrete choice rather than a "follow
system" flag. That way the picker always shows what is actually in effect, and the
interface does not change underneath you if the system language later changes.

`Core/Localization.swift` holds the mechanism and all the strings:

- `AppLanguage` — the languages, each named in its own script so the picker is
  readable to someone who cannot read the other language.
- `Loc` — a symbolic key per string. Symbolic rather than English-as-key because
  identical English words should be free to diverge in translation.
- `entries` — English and Chinese side by side, so a translation is never edited
  without the source in view.

Two details worth knowing:

- **Placeholders are all `%@`, never `%d`.** `String(format:)` reads `%d` as an
  integer, so passing a `String` for it reads a pointer and renders garbage such as
  `port 1687781658`. Since the API takes `CVarArg`, the compiler cannot catch that
  mistake, so the type is normalised away: every numeric argument is stringified at
  the call site and every placeholder is `%@`.
- **A missing key falls back to English**, so a gap degrades to readable text rather
  than showing a raw key.

Views read strings through `AppModel.string(_:)`, which touches the observable
`settings.language` — that access is what makes the whole interface re-render when
the language changes. The service layer runs on an actor with no access to that
store, so it uses `L10n.text(_:)`, which reads the stored language directly.

Coverage: 122 keys, with a validation pass confirming no duplicates, no keys
missing from either table, and no placeholder mismatches between the two languages.

**Technical output in the console is never translated.** Process output, paths,
URLs and npm errors are shown verbatim — translating them would make bug reports
harder to reproduce. Only the app's own messages and chrome are localized.

### Verifying a localization change

```sh
# Duplicate keys, orphan keys, and %-placeholder mismatches between languages:
# (see the validation described above; run it after editing the entries table)
```

To check the UI in each language without clicking through the picker:

```sh
defaults write dev.deepseek.dshharness dsh.language -string en      # or zh-Hans
```

## Troubleshooting: `a build appears to hang`

`swift build` takes an **exclusive lock** on `.build`. If another SwiftPM task is
already running — VS Code's "Resolve Package Dependencies", for example — a second
build blocks on that lock and looks like a hang. Only one build at a time.

To check and clear:

```sh
pgrep -fl 'swift-build|swiftpm|swift-frontend'   # anything running?
ls -l .build/.lock                               # lock present?
```

Kill the stray task rather than deleting the lock while a build holds it.

## Limitations

- The app does not open the DSH web UI itself; the server decides what it serves.
  **Open in Browser** points at `http://127.0.0.1:<port>/`.
- **A cold start is slow, by a lot.** Measured from npm's own debug log on a first
  run:

  | Metric | Value |
  |---|---|
  | Manifest requests during resolution | **1333+** |
  | Distinct packages resolved | **312** |
  | Private cache after a successful start | **1.2 GB** |

  npm resolves the entire 300+ package graph before downloading a single tarball,
  so on a cold cache there are minutes of registry round-trips with almost nothing
  in the console. Readiness polling allows 30 minutes and the toolbar shows an
  elapsed-time counter while starting. Later runs reuse the private cache.

  Confirmed working end to end: the app starts DSH, DSH binds its port, and the
  console logs `[app] Running on <port>`.
- If the first run is interrupted, just start it again — `Support/NpxLock.swift`
  clears the abandoned lock.
- `Launch at login` needs a real `.app` bundle; the toggle is disabled and explains
  itself when running from a raw binary.
- Verified on macOS 27.0.1 with Node v24.20.0 from `/usr/local`. Other Node
  layouts are handled by `ExecutionTargetResolver` but are untested.
