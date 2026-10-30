# Test harnesses

Command-line harnesses used while building Kitbag. Most run against your own Arma 3 install and Steam Workshop folder, so their results depend on which mods you have.

Build one with:

```bash
zsh Tests/build.sh <harness>
```

That writes `Tests/<harness>/run`.

| Harness | What it checks |
|---|---|
| `conflicts` | Dependency and conflict analysis (`ConflictAnalysis.swift`), with a synthetic self-test |
| `gamebuild` | Whether the Apple Silicon build's fixed memory reservation overlaps the system library cache |
| `gamelog` | The Eon game-log reader, using a synthetic log in the formats the wrapper writes; some checks expect CBA and ACE installed |
| `health` | The whole Health Check pipeline on your installed mods |
| `indexer` | The config indexer and its cache, with a synthetic library |
| `modlinks` | That log lines under `!Kitbag/<n>` links are traced back to the right mod |
| `rap` | The binarized `config.bin` reader: self-test, fuzzing, and your installed mods |
| `sigs` | Signature verification (`.bikey` and `.bisign`) on your installed mods |
| `textconfig` | The `config.cpp` preprocessor and parser: self-test, fuzzing, and your installed mods |
| `workshop` | Steam's Workshop records and the online Workshop lookup |

Several harnesses take a mode argument (for example `run selftest`); see the comment at the top of each `main.swift`.
