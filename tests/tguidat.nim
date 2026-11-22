## The signature files in the program's window: a synthetic `.dat` and a synthetic `.vib` opened
## by the command line show their traces in the Seismic window (Aux on: all are auxiliary) with
## the Headers window's Summary saying "Signature file"; the Files list names both kinds in its
## Type column; a `.vib` of another kind and an empty one are refused in the Messages. With
## `VIEWSEG_SCREENSHOTS` set, a picture of each is saved there (synthetic files only).
##
## Seen to fail: with `fileKindOf` not telling the signature kinds, the Files list found no
## `vibrator .dat` entry; with `signatureLines` returning nothing, the Summary did not show
## its "Signature file" heading.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[filelist, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, sigfiles, waiting]

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

proc shoot(file: string; picture: string; tmp: string; wantAux: bool; refusal = "") =
  ## Opens `file` as the command line does, waits for what it shows, saves `picture`.
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  if shots.len > 0: createDir(shots)
  var stage = 0
  var wait = 0
  let since = getMonoTime()
  var saved = false
  var failed = ""
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if refusal.len > 0:
      var said = false
      for e in f.core.log:
        if refusal in e.text and e.severity == sevError: said = true
      if said and wait > 30:
        doAssert f.core.sessions.len == 0, "a refused file was shown"
        if shots.len > 0: saved = f.savePng(shots / picture)
        f.stop()
    else:
      case stage
      of 0:
        if f.core.sessions.len == 1 and f.panel.laidOut and wait > 10:
          var flt = f.panel.layers[0].filter
          flt.auxiliary = true
          f.apply Command(kind: ckFilter, panel: MainPanel, filter: flt)
          (stage, wait) = (1, 0)
      else:
        if f.panel.laidOut and wait > 40 and f.shown("headers.summary.heading"):
          doAssert f.core.sessions[0].isSignature
          doAssert f.panel.layers[0].filter.auxiliary
          if shots.len > 0: saved = f.savePng(shots / picture)
          f.stop()
    if overdue(f.index, 3000, since): (failed = "not shown"; f.stop())
  let code = run(RunOptions(openPaths: @[file], windowSize: (1500, 900),
    theme: forceDark, userThemeDir: some(tmp / "no-user-themes"),
    indexCacheDir: some(tmp / "cache"), onFrame: onFrame))
  doAssert code == 0 and failed.len == 0, failed
  doAssert shots.len == 0 or saved, "no picture of " & picture

proc main*() =
  withFixtures fx:
    let dat = datFile(fx.dir / "files", "0042_20010203T040506.789000000Z.dat")
    let vib = vibFile(fx.dir / "files" / "0042" / "20010203", "0007.VIB")
    block listed:
      var st = initAppState()
      st.apply Command(kind: ckBrowse, paths: @[fx.dir / "files"])
      doAssert st.settle(not st.fileList.scanning)
      var kinds: seq[string]
      for e in st.fileList.entries: kinds.add $e.kind
      doAssert "vibrator .dat" in kinds, $kinds
      st.apply Command(kind: ckSubfolders, subfolders: true)
      doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 2)
      kinds.setLen 0
      for e in st.fileList.entries: kinds.add $e.kind
      doAssert "vibrator .vib" in kinds and "vibrator .dat" in kinds, $kinds
      st.shutdown()
    shoot(dat, "signature-dat.png", fx.dir / "a", true)
    shoot(vib, "signature-vib.png", fx.dir / "b", true)
    writeBytes(fx.dir / "other.vib", synthOtherKind(50))
    shoot(fx.dir / "other.vib", "signature-vib-kind6-refused.png", fx.dir / "c", false,
      "a .vib file of another kind (6 values per record, 36-byte records)")
    writeFile(fx.dir / "empty.vib", "")
    shoot(fx.dir / "empty.vib", "signature-vib-empty-refused.png", fx.dir / "d", false,
      "empty.vib is empty: not opened.")
  echo "tguidat: ok"

when isMainModule:
  main()
