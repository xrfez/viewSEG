# viewSEG

A high-performance viewer for SEG-Y and SEG-D seismic data, written in Nim on top of
[parseSEG](https://github.com/xrfez/parseSEG) (reading, indexing, headers) and
[processSEG](https://github.com/xrfez/processSEG) (filtering, gain, spectra, stacking).

**Status:** early development. A file opens and its first record shows as greyscale
density, with zoom, pan, scales in traces and ms per inch, and a cursor readout
(`docs/user/QUICKSTART.md`).

## Building

Requires Nim 2.4.0. Dependencies are pinned in `atlas.lock` and checked out into `deps/`;
`nim.cfg` holds their search paths.

```sh
atlas rep atlas.lock    # fresh clone: check out the pinned dependencies
nim test                # run the test suite in parallel, each test on its own Xvfb display
nim nimRelease          # build bin/viewSEG for this machine
nim winRelease          # cross-build bin/viewSEG.exe for Windows (zig)
```

SDL3 is linked statically, so neither binary needs an SDL library at run time. On Linux
it comes from `pkg-config sdl3` (`libSDL3.a`). For Windows, `nim winRelease` first
cross-builds SDL 3.4.18 with zig (`tools/sdl3-windows.sh`: git, CMake, Ninja; once, into
`~/.cache/viewSEG/`, or `$SDL3_WINDOWS_PREFIX`).

`nim depsCheck` verifies that `atlas.lock`, `nim.cfg` and `deps/` agree
(`tools/deps.nim`). `nim help` lists every task.

## Packaging

`nim package` builds both release binaries (x86-64-v3, static SDL3; the Windows one as
`nim winRelease` does) and writes a self-contained folder and an archive for each OS into
`dist/`:

```
dist/viewSEG-<version>-linux-x64/      and  dist/viewSEG-<version>-linux-x64.tar.gz
dist/viewSEG-<version>-windows-x64/    and  dist/viewSEG-<version>-windows-x64.zip
  viewSEG | viewSEG.exe
  vendormaps/   vendor header maps (*.nif): parseSEG's and this repository's vendormaps/
  config/       settings; its presence makes the release portable
  assets/       themes, fonts (this repository's assets/)
  logs/         session logs
  licences/     viewSEG's licence and those of everything linked or bundled (see its README)
  docs/         README.md, QUICKSTART.md (docs/user/), BUILD.txt (commits it was built from)
```

The version comes from `viewSEG.nimble`. Running it again replaces the folders and
archives. It never reaches the network: the Windows SDL3 build must exist (run
`nim winRelease` once). `nim -d:packageTargets=linux package` (or `windows`) packages one
OS; `nim packageTest` packages, then checks `dist/` and runs the packaged Linux binary
(`tests/package/tpackage.nim`).

**Portable mode.** While `config/` next to the executable exists and is writable, viewSEG
writes everything (settings, `logs/`, `cache/`) inside its own folder. Without it, or in a
read-only location such as `Program Files`, it uses the per-user directories of the OS.
`viewSEG --paths` prints the directories in use and exits; `viewSEG --version` prints the
version.

## Agent control

An AI agent (any Model Context Protocol client: Claude Code, Claude Desktop, an editor) can
operate the running program while you watch: `viewSEG --mcp`, or File > Agent control, and
a client that starts `viewSEG --mcp-stdio`. Off by default, local only, every call shown in
Messages, nothing that writes a file, and what it changes is for that session only: your
saved settings and recent files stay as you left them. See `docs/agent-control.md`.

## License

MIT
