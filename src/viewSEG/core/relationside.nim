## Which side of the survey's relation records a gather is on, decided from
## its stations (line and point), never from a record number.
##
## One receiver and several sources (or none) is a receiver gather, checked
## against its O record by the receiver's station; several receivers (or none)
## and one source (or none) is a shot, checked against its X record by the
## source's station. One receiver and one source is open: one shot slice and a
## shot that one receiver recorded look alike. Several of both is told by what
## the gather's kind says, else it is neither. A gather whose headers name no
## station at all is a receiver's when the file's sorting says common-receiver.

import parseSEG

type
  Side* = enum
    sdShot     ## one shot: checked against its X record
    sdReceiver ## one receiver, or slices of it: checked against its O record
    sdOpen     ## one receiver and one source: one slice, or a shot of one receiver
    sdNeither  ## several sources and several receivers (or none)

  Verdict* = tuple[known: bool; receiver: bool; continuous: bool]
    ## What the recording kind says of the traces; `known` false when it does not

  Stations* = object
    ## The receiver and source stations (line and point) of some traces,
    ## counted up to two, and whether no component of them has two traces.
    receivers*, sources*: int
    receiver*, source*: StationKey
    components: set[uint8]
    oneEach*: bool

func hasStation*(line, point: float64): bool {.inline.} =
  ## A finite line and point that are not both 0 (a header left empty), as the
  ## record check reads a station.
  line == line and point == point and abs(line) < Inf and abs(point) < Inf and
    not (line == 0 and point == 0)

func initStations*(): Stations = Stations(oneEach: true)

proc note*(st: var Stations; k: TraceKeys) =
  ## Counts the stations of trace `k` (an auxiliary trace has none).
  if k.status != tsAuxiliary:
    if hasStation(k.rcvLine, k.rcvPoint):
      let r = stationKey(k.rcvLine, k.rcvPoint, 0)
      if st.receivers == 0: (st.receivers, st.receiver) = (1, r)
      elif st.receivers == 1 and r != st.receiver: st.receivers = 2
    if hasStation(k.srcLine, k.srcPoint):
      let s = stationKey(k.srcLine, k.srcPoint, 0)
      if st.sources == 0: (st.sources, st.source) = (1, s)
      elif st.sources == 1 and s != st.source: st.sources = 2
    if k.component in st.components: st.oneEach = false
    else: st.components.incl k.component

func sideOf*(st: Stations; verdict: Verdict): Side =
  ## Which check the traces counted in `st` get, the rule for a file and for a
  ## gather of a file it leaves to its gathers (`verdict` unknown). One receiver
  ## and several sources (or none, which leaves it unmatched) is a receiver;
  ## several receivers (or none) and one source (or none) is a shot; one of each
  ## is open, as one slice and a shot of one live receiver look alike; several
  ## of both is the recording kind's, or else neither.
  if st.receivers == 1: (if st.sources == 1: sdOpen else: sdReceiver)
  elif st.sources <= 1: sdShot
  elif verdict.known: (if verdict.receiver: sdReceiver else: sdShot)
  else: sdNeither

func isOneSlice*(st: Stations): bool =
  ## One receiver, one source and one trace for each component: one shot slice.
  st.receivers == 1 and st.sources == 1 and st.oneEach

func neitherWhy*(st: Stations): string =
  "the traces hold several source stations and " &
    (if st.receivers == 0: "no receiver station" else: "several receiver stations") &
    ": it is neither one shot nor one receiver, so no one relation record is theirs"

proc gatherSides*(keys: openArray[TraceKeys]; spans: openArray[Slice[int]];
    kinds: openArray[GatherKind] = []): seq[Side] =
  ## The side of each of `spans` (the gathers of a file whose trace keys are
  ## `keys`): `sideOf` on its stations, the gather's kind the verdict when it is
  ## a shot or a receiver gather. An open gather (one receiver, one source) takes
  ## the side most of the gathers that were not open took, and with none is a
  ## slice, a receiver's. A span with no trace is a shot.
  result = newSeq[Side](spans.len)
  var shots, receivers = 0
  for i, sp in spans:
    var st = initStations()
    for t in sp:
      if t in 0 ..< keys.len: st.note keys[t]
    let kind = if kinds.len == spans.len: kinds[i] else: gkUnknown
    let known = kind in {gkShot, gkReceiver}
    result[i] = st.sideOf((known: known, receiver: kind == gkReceiver, continuous: false))
    # No station in the headers at all (the place decides later): the kind the file's
    # sorting gives, a common-receiver gather being a receiver's.
    if st.receivers == 0 and st.sources == 0 and kind == gkReceiver: result[i] = sdReceiver
    case result[i]
    of sdShot: inc shots
    of sdReceiver: inc receivers
    else: discard
  let open = if shots > receivers: sdShot else: sdReceiver
  for s in result.mitems:
    if s == sdOpen: s = open
