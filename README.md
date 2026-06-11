# exclude-icloud-artifacts

Keep build artifacts and caches out of iCloud Drive, Dropbox, Google Drive,
and OneDrive.

A tiny macOS background tool that watches your cloud-synced folders
(`~/Documents`, `~/Desktop`, and `~/Library/CloudStorage` by default) and
marks build-artifact folders —
`.build`, `node_modules`, `DerivedData`, `target`, and friends — with the
File Provider *ignore* extended attribute (`com.apple.fileprovider.ignore#P`,
macOS 12.3+). Tagged folders:

- show a slashed-cloud badge in Finder,
- stay on your Mac (nothing is deleted locally),
- stop uploading and stop counting against your iCloud storage,
- and previously uploaded copies are removed from iCloud automatically.

No renaming, no `.nosync` suffixes, no symlinks — your build tools never
notice a thing.

## Why

If you keep your projects in `~/Documents` with *Desktop & Documents Folders*
sync enabled, every `swift build` or `npm install` ships gigabytes of
regenerable junk to iCloud: it wastes quota, burns bandwidth and battery, and
churns sync state on every build. This tool tags those folders once, the
moment they appear, and iCloud skips them from then on.

## Requirements

- macOS 13 Ventura or later (the ignore attribute works on macOS 12.3+)
- Swift 6 toolchain (Xcode 16+) to build
- Any File Provider cloud: iCloud Drive, Dropbox, Google Drive, OneDrive,
  Box, ... (without one the tag is harmless)

## Install

```sh
git clone https://github.com/amosavian/exclude-icloud-artifacts.git
cd exclude-icloud-artifacts
./install.sh
```

This builds the release binary, copies it to `~/.local/bin`, installs a
default config to `~/.config/exclude-icloud-artifacts/config.yaml` (if none
exists), and loads a login LaunchAgent
(`com.mousavian.exclude-icloud-artifacts`) that keeps the watcher running.
Logs go to `~/Library/Logs/exclude-icloud-artifacts.log` (stderr redirected
by the agent; also browsable in Console.app under Log Reports).

After changing the config, run `./install.sh` again, or:

```sh
launchctl kickstart -k "gui/$(id -u)/com.mousavian.exclude-icloud-artifacts"
```

## Usage

```
exclude-icloud-artifacts                  # sweep once, then watch via FSEvents
exclude-icloud-artifacts --sweep          # one-shot tagging pass, then exit
exclude-icloud-artifacts --report         # size + sync status of every artifact folder
exclude-icloud-artifacts --config <path>  # use an alternative config.yaml
```

`--report` output:

```
     3.22 GB  excluded  /Users/you/Documents/Projects/MyApp/.build
    272.7 MB  excluded  /Users/you/Documents/Projects/Lib/.build
      ...
     4.16 GB  total
```

## Configuration

Read from `~/.config/exclude-icloud-artifacts/config.yaml`; see
[config.example.yaml](config.example.yaml) for the annotated default. Every
key is optional:

```yaml
roots:                # cloud-synced folders to keep clean
  - ~/Documents
  - ~/Desktop
  - ~/Library/CloudStorage    # Dropbox, Google Drive, OneDrive, ...
latency: 10           # seconds FSEvents batches events (higher = less battery)
skipCloudOnly: false  # true = never tag folders whose files are evicted
                      # (cloud-only); see "Notes & FAQ"
presets:              # rule bundles to enable, see table below
  - swift
  - node
  - python
  - java
  - rust
  - general
rules: []             # extra rules on top of the presets
```

### Custom rules

Rules match folders by name. Names and conditions support shell-style globs.
Generic names should be guarded by a condition so ordinary folders are never
excluded:

```yaml
rules:
  - folder: MyRenderCache                  # always excluded
  - folder: output
    ifSiblingExists: [project.toml]        # only next to such a file
  - folder: scratch
    ifChildExists: [.regenerable]          # only when it contains the marker
```

### Presets

| Preset | Folders |
|---|---|
| `swift` | `.build`, `DerivedData`, `Pods`, `Carthage`, `.docc-build` |
| `node` | `node_modules`, `.npm`, `.next`, `.nuxt`, `.astro`, `.docusaurus`, `.turbo`, `.parcel-cache`, `.angular`, `.expo`, `.metro-cache` |
| `python` | `__pycache__`, `.venv`, `venv`*, `.pixi`, `.tox`, `.nox`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.hypothesis`, `.ipynb_checkpoints` |
| `java` | `.gradle`, `.m2`, `.kotlin`, `.cxx`, `build`*, `target`* |
| `rust` | `target`* (next to `Cargo.toml`) |
| `dotnet` | `bin`*, `obj`* (next to `*.csproj`/`*.sln`) |
| `go` | `vendor`* (next to `go.mod`) |
| `php` | `vendor`* (next to `composer.json`) |
| `ruby` | `vendor`* (next to `Gemfile`), `.jekyll-cache`, `_site`* |
| `dart` | `.dart_tool`, `build`* (next to `pubspec.yaml`) |
| `elixir` | `_build`, `deps`* (next to `mix.exs`) |
| `haskell` | `.stack-work`, `dist-newstyle` |
| `scala` | `target`* (next to `build.sbt`), `.bloop`, `.metals`, `.bsp` |
| `zig` | `.zig-cache`, `zig-cache`, `zig-out` |
| `cpp` | `cmake-build-*`, `.clangd`, `.ccls-cache` |
| `unity` | `Library`/`Temp`/`Logs`/`obj` (next to `ProjectSettings`) |
| `cloud` | `.terraform`, `.terragrunt-cache`, `.vagrant`, `.serverless`, `.firebase`, `cdk.out`, `.aws-sam` |
| `general` | `.cache`, plus any folder containing a [`CACHEDIR.TAG`](https://bford.info/cachedir/) marker |

\* = condition-guarded. Defaults: `swift`, `node`, `python`, `java`, `rust`,
`general`.

The `general` preset deserves a note: any folder containing a `CACHEDIR.TAG`
file (the [Cache Directory Tagging Specification](https://bford.info/cachedir/))
is excluded regardless of its name. Cargo writes this marker into every
`target/` directory, and other well-behaved tools do the same — so caches from
tools not listed above are often caught automatically.

## How it works

- **Tagging.** iCloud Drive's File Provider skips any item carrying the
  `com.apple.fileprovider.ignore#P` extended attribute. The tool sets it with
  a single `setxattr(2)` call — equivalent to
  `xattr -w 'com.apple.fileprovider.ignore#P' 1 <folder>`.
- **Watching.** FSEvents — the kernel's change-notification stream used by
  Spotlight and Time Machine — reports new directories. Events are coalesced
  (default 10 s), so even a heavy build wakes the watcher a few times a
  minute with one batch instead of thousands of times. Between batches the
  process sleeps at 0.0 % CPU in a few MB of memory.
- **No subprocesses, no polling.** Matching and tagging happen in-process.
  Events inside artifact trees are skipped by path pattern alone — no
  syscalls — with an xattr ancestor walk (memoized) as the precise check.
  If the kernel event queue overflows under heavy build load, the watcher
  rescans just the invalidated subtree, at most once a minute.
- **Sweeps run only when needed.** A full catch-up sweep runs on first
  install and whenever the configuration changes (tracked via a fingerprint
  stamp); plain agent restarts skip the walk entirely. Run
  `exclude-icloud-artifacts --sweep` to force one.

## Other cloud providers

The ignore attribute is enforced by macOS's `fileproviderd`, not by iCloud:
every cloud client built on the File Provider framework honors it. Dropbox,
Google Drive, and OneDrive all live under `~/Library/CloudStorage`, which is
watched by default — artifacts there get tagged and skipped exactly like in
iCloud Drive. Two provider-specific notes:

- **Google Drive:** only the default *streaming* mode (the
  `~/Library/CloudStorage` location) goes through File Provider. The legacy
  *mirror* mode syncs a plain folder on its own and ignores the attribute.
- **OneDrive** also has a built-in name-pattern ignore list
  (`defaults write com.microsoft.OneDrive EnableODIgnore -array node_modules`),
  but it cannot express this tool's marker-file guards.

## Notes & FAQ

**Is anything deleted?** Nothing local. The folder stays on disk; only its
*sync* is disabled. But note the flip side: if a folder was *already
uploaded*, tagging it removes the cloud copy — and therefore the copy on
your other devices. For regenerable artifacts that is the intended cleanup.
Deleting the attribute (`xattr -d`) re-syncs it.

**What about folders whose files are evicted (cloud-only)?** By default they
are tagged like everything else — artifact folders are regenerable, so the
cloud copy is cleaned up even when the local files are dataless placeholders
("Optimize Mac Storage" / Files On-Demand evictions). If you'd rather err on
the safe side, set `skipCloudOnly: true`: the watcher then refuses to tag
any folder containing evicted files — since the server holds their only full
copy — and logs a warning instead. Download the folder first if you want it
excluded anyway.

**These folders are not backed up then?** Right — that is the point: they are
regenerable from source. Keep anything precious out of artifact folders.

**A new folder synced for a few seconds before being tagged.** Expected:
events are batched for `latency` seconds. iCloud removes the partial upload
as soon as the tag lands.

**Does it follow symlinks?** No. Symlinks are never followed, and rules never
descend into matched folders.

**Why not put projects outside iCloud?** Also a fine solution. This tool is
for people who *want* source files synced (or are stuck with Desktop &
Documents sync) without paying for the artifacts.

## Uninstall

```sh
./install.sh --uninstall                              # remove agent + binary
xattr -d 'com.apple.fileprovider.ignore#P' <folder>   # re-sync one folder
```

Already-tagged folders keep their attribute until you remove it.

## License

[MIT](LICENSE)
