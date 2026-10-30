# Kitbag

A native Arma 3 mod manager for macOS. Pick your mods, keep them in playsets, check them for problems, and start the game with one click.

## Features

- **Finds your mods automatically.** Steam Workshop subscriptions in every Steam library, `@mods` in the Arma 3 folder, and `@mod` folders inside any extra folders you add.
- **Playsets.** Turn mods on and off, keep several sets, and launch them in a sensible order (frameworks like CBA and ACE first, compat patches last).
- **One-click Play.** Starts the game directly with your playset. If Steam isn't running or signed in yet, Kitbag opens it and launches as soon as it's ready.
- **Health Check.** Reads every mod's configs (PBOs, binarized `config.bin`, and `config.cpp` with the preprocessor) and reports:
  - missing dependencies, with one-click Enable when the mod you need is installed, or a Steam link to it when its Workshop page lists it as required (needs the online check)
  - undefined base classes, duplicate addons, and file-path clashes between mods
  - Steam download state: updates waiting, incomplete downloads, removed Workshop items, and the authors' "Required items"
  - multiplayer signature problems, verified against each mod's keys
  - known issues with specific mods, each with a source link
  - mod extensions that failed to load and missing-addon errors from the last game Kitbag started, and the crash report if it crashed
- **Performance options.** Balanced and Max FPS profiles, plus individual launch options.
- **Game build choice** on Apple Silicon Macs: Automatic, Apple Silicon, or Intel (Rosetta).

## Requirements

- macOS 14 or later, on Apple Silicon or Intel
- Arma 3 from Steam, and the Steam client

## Install

Download `Kitbag.dmg` from [Releases](../../releases), open it, and drag Kitbag to Applications. If there's no release yet, [build it from source](#build-from-source); it takes about a minute.

Kitbag isn't notarized by Apple, so macOS blocks it the first time. Open **System Settings → Privacy & Security** and click **Open Anyway**.

## Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`), not Xcode itself.

```bash
./build.sh
```

This writes a universal (Apple Silicon and Intel) `dist/Kitbag.app` and `dist/Kitbag.dmg`.

## The Apple Silicon build on macOS 27

Steam ships two Mac versions of Arma 3: the standard Intel build, which runs through Rosetta, and an experimental Apple Silicon build (`ArmA3 AS Native.app`). On macOS 27 the Apple Silicon build crashes about a second after starting, whoever launches it. While starting, it reserves memory at a fixed address (`0x300000000`), and macOS 27's larger system library cache now always occupies that address.

Kitbag checks for this before every launch and starts the Intel build instead. If an update to the Apple Silicon build fixes it, Kitbag notices and uses it again. You can also choose the build yourself in **Performance → Game build**. Choosing Apple Silicon on macOS 27 starts it with an experimental workaround; it gets as far as drawing the game, but it crashed within a few minutes in testing.

## How Kitbag passes mods to the game

Arma 3 on macOS can crash when its window opens if the `-mod` list is very long: 114 mods given as full paths (over 11,000 characters) crashed both the Intel and the Apple Silicon build, while the same mods given as short paths ran fine. Like Arma's official launcher with its `!Workshop` folder, Kitbag links your playset's mods into a `!Kitbag` folder inside the Arma 3 folder and passes short paths such as `!Kitbag/12`. The links are rebuilt on every launch; your mods themselves are never moved or changed.

## Privacy

Everything runs on your Mac, with one exception: the **Check Steam Workshop online** checkbox at the bottom of the Health Check window. It's on by default. After each scan Kitbag sends the Workshop IDs of all your installed Workshop mods to Steam's public Workshop API and reads their Workshop pages, to find removed items and required mods. Results are cached for a day. Uncheck it and Kitbag makes no network requests of its own; links you click still open in your browser or in Steam.

Kitbag stores its settings, saved game logs and the game's console output in `~/Library/Application Support/Kitbag`, its config index and Workshop lookup cache in `~/Library/Caches/Kitbag`, and the mod links in `Arma 3/!Kitbag`.

## Development

- `Sources/` holds the app. `Kitbag.swift` is the SwiftUI app and mod scanner; the other files are the config readers, the Workshop, signature and game-log readers, the game-build check, and the Health Check engine.
- `Tests/` holds developer harnesses that run against your own Arma 3 install; see [Tests/README.md](Tests/README.md).

## Disclaimer

Kitbag isn't affiliated with or endorsed by Bohemia Interactive, Valve, or Virtual Programming. Arma is a trademark of Bohemia Interactive.

## License

[MIT](LICENSE)
