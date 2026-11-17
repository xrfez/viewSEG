## The Vendor groups of the Headers window, in the running frontend, headless:
## a SEG-D Rev 3.0 file (made-up manufacturer code) whose traces carry a vendor
## trace header block a map decodes (`RunOptions.vendorFolders`).
##
## - The Trace tab, Header: the trace selected has a "Vendor" group above its
##   header table, with the block under the map that decoded it and its fields by
##   name; a file of another manufacturer code, the same map loaded, has none.
##
## Seen to fail: with `drawVendorBlocks` not called from `drawTraceHeader`, "the
## Vendor group never came"; with the group drawn whatever the answer holds, "a
## file no map applies to has a Vendor group".
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves vendormaps-headers.png there: the Headers
## window alone.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[agentshot, app]
import utils/[fixtures, waiting]

let shots = getEnv("VIEWSEG_SCREENSHOTS")

proc shootWindow(f: FrameInfo; name: string) =
  if shots.len > 0:
    let r = f.markOf("headers")
    let (x0, y0) = (max(0, int(r.pos.x)), max(0, int(r.pos.y)))
    let (x1, y1) = (min(f.width, int(r.pos.x + r.size.x)), min(f.height, int(r.pos.y + r.size.y)))
    doAssert x1 > x0 and y1 > y0, "the Headers window is not on screen: " & $r
    let all = f.readFrame()
    var part = newSeq[Rgba]((x1 - x0) * (y1 - y0))
    for y in y0 ..< y1:
      for x in x0 ..< x1: part[(y - y0) * (x1 - x0) + x - x0] = all[y * f.width + x]
    let (png, why) = encodePng(part, x1 - x0, y1 - y0)
    doAssert why.len == 0, why
    createDir(shots)
    writeFile(shots / name, png)

proc showGroup(path: string; maps: seq[VendorFolder]; dir: string; expectGroup: bool) =
  var stage = 0
  var wait = 0
  var since = getMonoTime()
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0:
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      if p.laidOut and p.layout.traces > 0 and wait > 3:
        var s = f.core.settings
        (s.headers.tab, s.headers.traceTab) = (htTrace, ttHeader)
        f.apply Command(kind: ckSettings, settings: s)
        f.apply Command(kind: ckSelect, traces: @[f.core.sessions[0].base], mode: smReplace)
        next 1
      doAssert not overdue(wait, 2000, since), "the file was not shown"
    of 1: # the trace's headers come, with its vendor fields or none
      let a = f.core.inspection.answer
      if f.core.vendorGen >= 1 and a.traces.len == 1 and a.traces[0].rows.len > 0 and
          a.traces[0].vendor.gen >= 1 and f.markOf("headers.trace tab header").size.x > 0 and
          wait > 15:
        let group = f.markOf("headers.vendor trace 0")
        if expectGroup:
          doAssert group.size.x > 0 or f.markOf("headers.vendor field serial").size.x > 0,
            "the Vendor group never came"
          doAssert f.markOf("headers.vendor field serial").size.x > 0
          f.shootWindow("vendormaps-headers.png")
        else:
          doAssert f.markOf("headers.vendor field serial").size.x == 0,
            "a file no map applies to has a Vendor group"
        f.stop()
        stage = 9
      doAssert not overdue(wait, 2000, since), "the trace's headers never came"
    else: discard
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), persist: true,
    configDir: some(dir / "config"), logDir: some(dir / "logs"), vendorFolders: some(maps),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 9, "stopped at stage " & $stage

proc main*() =
  withFixtures fx:
    let maps = fx.dir / "program" / "vendormaps"
    createDir(maps)
    writeFile(maps / "b.nif", "(.nif27)\n(vendormap \"vendor-b\" (version 1) " &
      "(match (format segd) (rev 3.0 3.1) (manufacturer 77))\n" &
      "  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)\n" &
      "    (field device (at 1) (enc u16))\n" &
      "    (field serial (at 3) (enc u32) (sentinel 0xFFFFFFFF))))\n")
    let folders = @[VendorFolder(dir: maps, origin: voProgram)]
    showGroup(fx.vendorTraceSegd(77), folders, fx.dir, true)
    showGroup(fx.vendorTraceSegd(78), folders, fx.dir, false)

when isMainModule:
  main()
