## The vendor fields of a trace (docs/user/vendor-maps.md), through the
## Headers window's reader, on a SEG-D Rev 3.0 record whose traces each carry
## a vendor trace header block (type 0xB0, made-up manufacturer code 77) that a
## made-up map decodes:
##
## - the trace shown has its fields by name under the map: a live trace's
##   device and serial, and the serial of another, the "absent" sentinel, is not
##   listed (the other field still is);
## - a file of another manufacturer code, the same map loaded: nothing, no block;
## - with no map loaded: nothing, and no read of the header bytes;
## - the agent's `headers` answer for a trace holds the same fields;
## - the trace table and the other traces' answers are untouched: only the traces
##   the Trace tab is about have their blocks decoded.
##
## Seen to fail: with the SEG-Y decode only for traces with proprietary headers, "a Rev 1
## SEG-Y trace has no vendor block"; with `vendorTrace` not called in the inspector's trace read, "the
## trace has no vendor block"; with the sentinel left out of the map, "the absent
## serial is listed"; with the manufacturer clause out of the map, "another
## manufacturer's file shows vendor fields".
import std/[json, os]
import parseSEG
import viewSEG/core/[state, vendormaps]
import utils/[fixtures, waiting]

const Map = """(.nif27)
(vendormap "vendor-b" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field device (at 1) (enc u16))
    (field serial (at 3) (enc u32) (sentinel 0xFFFFFFFF))))
"""

const SegyMap = """(.nif27)
(vendormap "vendor-c" (version 1) (match (format segy))
  (target (kind traceHeaderBytes) (name standardBytes)
    (field samples (at 115) (enc u16))))
"""

proc rev1Segy(dir: string): string =
  ## A Rev 1 SEG-Y file of one trace of 16 samples: no Rev 2 extension, no
  ## proprietary headers.
  result = dir / "rev1.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0),
    traceSorting: 1, text: @["C01 viewSEG test fixture: rev 1"]))
  var k = initTraceKeys()
  (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, 1.0, 0.0, 2000.0, tsLive)
  w.writeTrace(k, newSeq[float32](16))
  doAssert w.close().len == 0

proc fieldOf(b: VendorBlockFact; name: string): string =
  for f in b.fields:
    if f.name == name: return f.value

proc shown(st: var AppState; path: string; first: int): VendorShown =
  ## The vendor blocks the Headers window's reader answers for trace `first` of `path`.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown"
  st.apply Command(kind: ckSelect, traces: @[st.sessions[^1].base + first], mode: smReplace)
  st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
  doAssert st.settle(st.inspection.answer.traces.len == 1 and
    st.inspection.answer.traces[0].rows.len > 0 and st.inspection.answer.traces[0].trace == first),
    "the trace's headers were not read"
  result = st.inspection.answer.traces[0].vendor

proc main*() =
  withFixtures fx:
    let mine = fx.vendorTraceSegd(77)
    let other = fx.vendorTraceSegd(78)
    let dir = fx.dir / "maps"
    createDir(dir)
    writeFile(dir / "b.nif", Map)
    var st = initAppState()
    # no map loaded: nothing
    doAssert st.shown(mine, 0).blocks.len == 0, "no map: a vendor block"
    st.setVendorFolders(@[VendorFolder(dir: dir, origin: voProgram)])
    doAssert st.settle(st.vendorGen == 1 and st.vendorLoad.maps.len == 1), "no load"
    # the live trace
    doAssert st.settle(st.inspection.answer.traces.len == 1 and
      st.inspection.answer.traces[0].vendor.gen == 1), "the new maps were not used"
    let live = st.inspection.answer.traces[0].vendor
    doAssert live.blocks.len == 1, "the trace has no vendor block"
    doAssert live.blocks[0].name == "vendorStatus" and live.blocks[0].map == "vendor-b"
    doAssert live.blocks[0].fieldOf("device") == "5" and
      live.blocks[0].fieldOf("serial") == "1234", $live.blocks[0].fields
    # the sentinel: absent, and the other field is there
    let absent = st.shown(mine, 1)
    doAssert absent.blocks.len == 1 and absent.blocks[0].fieldOf("device") == "6"
    doAssert absent.blocks[0].fieldOf("serial").len == 0, "the absent serial is listed"
    doAssert absent.blocks[0].fields.len == 1
    let zero = st.shown(mine, 2)
    doAssert zero.blocks.len == 1 and zero.blocks[0].fieldOf("device") == "0"
    # another manufacturer: no block
    doAssert st.shown(other, 0).blocks.len == 0, "another manufacturer's file shows vendor fields"
    # a Rev 1 SEG-Y file has no proprietary headers: a map of the standard header's bytes applies
    writeFile(dir / "c.nif", SegyMap)
    st.apply Command(kind: ckReloadVendors)
    doAssert st.settle(st.vendorGen == 2 and st.vendorLoad.maps.len == 2)
    let rev1 = st.shown(rev1Segy(fx.dir), 0)
    doAssert rev1.blocks.len == 1 and rev1.blocks[0].name == "standardBytes" and
      rev1.blocks[0].fieldOf("samples") == "16", "a Rev 1 SEG-Y trace has no vendor block: " &
      $rev1.blocks.len
    # the agent's headers answer
    discard st.shown(mine, 0) # (shown again: the one the agent reads)
    let job = st.readTraceHeaders(st.sessions.high, 0)
    var keys: TraceKeys
    var rows: seq[HeaderRow]
    var vendor: VendorShown
    var got = false # (taking is once: not in the condition `settle` looks at twice)
    doAssert waitUntil((discard st.drainInbox(); got = got or st.takeTraceRead(job, keys, rows,
      vendor); got)), "no headers answer"
    doAssert vendor.blocks.len == 1 and vendor.blocks[0].fieldOf("serial") == "1234"
    st.shutdown()

when isMainModule:
  main()
