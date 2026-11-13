# viewSEG

A high-performance viewer for SEG-Y and SEG-D seismic data, written in Nim on top of
[parseSEG](https://github.com/xrfez/parseSEG) (reading, indexing, headers) and
[processSEG](https://github.com/xrfez/processSEG) (filtering, gain, spectra, stacking).

**Status:** early development; nothing usable yet.

## Building

Requires Nim 2.4.0. Dependencies are pinned in `atlas.lock` and checked out into `deps/`;
`nim.cfg` holds their search paths.

```sh
atlas rep atlas.lock    # fresh clone: check out the pinned dependencies
nim test                # run the test suite
nim nimRelease          # build bin/viewSEG for this machine
nim winRelease          # cross-build bin/viewSEG.exe for Windows (zig)
```

SDL3 is linked statically, so neither binary needs an SDL library at run time. On Linux
it comes from `pkg-config sdl3` (`libSDL3.a`). For Windows, `nim winRelease` first
cross-builds SDL 3.4.18 with zig (`tools/sdl3-windows.sh`: git, CMake, Ninja; once, into
`~/.cache/viewSEG/`, or `$SDL3_WINDOWS_PREFIX`).

`nim depsCheck` verifies that `atlas.lock`, `nim.cfg` and `deps/` agree
(`tools/deps.nim`). `nim help` lists every task.

## License

MIT
