## The short names of the kinds of recording a file can be.

import ../core/[recordingkind, traceorder]

func kindWords*(k: RecordingKind): string =
  ## The name of what a file is, as a noun phrase.
  case k
  of rkShotGather: "shot gather"
  of rkReceiverContinuous: "continuous receiver gather"
  of rkReceiverSliced: "time-sliced receiver gather"

const
  NotKnownWords* = "Open the file to see its kind."
    ## what the Files panel says of a file too large to be opened for its kind
  MultiplexedWords* = "A multiplexed SEG-D file is not read for its kind in the list. " &
    NotKnownWords
    ## what the Files panel says of a multiplexed SEG-D file

func kindShort*(k: RecordingKind): string =
  ## `kindWords` in a word or two, for a table cell: "Shot".
  case k
  of rkShotGather: "Shot"
  of rkReceiverContinuous: "Continuous"
  of rkReceiverSliced: "Sliced"

func kindTitle*(k: RecordingKind): string =
  ## `kindWords` as a title, for a table cell: "Shot gather".
  case k
  of rkShotGather: "Shot gather"
  of rkReceiverContinuous: "Continuous receiver gather"
  of rkReceiverSliced: "Time-sliced receiver gather"

const
  OrderNotKnownWords* = "No order by station or time could be told: the traces are out of " &
    "order, their grouping is irregular, the key never changes, or there are too few."
    ## what the Order column says of a file whose traces are in no order that can be told
  UncodedWords = " Some traces share a station and start time without a component code, " &
    "so the grouping cannot be told."

const
  ForcedMark* = " *" ## after the word of a cell whose value the user set
  ForcedWords* = "Set by you: right-click to return to automatic. Automatic says: "

func orderShort*(o: TraceOrder): string =
  ## The order of the traces in a word or two, for a table cell: "Station", "Flag · station";
  ## "?" when it is not known.
  let sub = case o.subSort
    of tsByStation: "station"
    of tsByTime: "time"
    of tsNotKnown: ""
  if sub.len == 0: "?"
  else:
    case o.grouping
    of tgNone, tgNotKnown: (if o.subSort == tsByStation: "Station" else: "Time")
    of tgByFlag: "Flag · " & sub
    else: "Component · " & sub

func orderTitle*(o: TraceOrder): string =
  ## The order as a sentence, for a tooltip.
  if o.subSort == tsNotKnown: OrderNotKnownWords
  else:
    let sub = if o.subSort == tsByStation: "by station" else: "by time"
    let sIn = o.sortInRecords and o.subSort == tsByStation
    let gIn = o.groupInRecords
    case o.grouping
    of tgNone, tgNotKnown:
      (if sIn: "Inside each record, traces are sorted by station."
        else: "Traces are sorted " & sub & ".") & (if o.grouping == tgNotKnown: UncodedWords
        else: "")
    of tgByFlag:
      let head = "Traces are grouped by flag (the components of a " &
        (if o.subSort == tsByStation: "station" else: "time") & " together)"
      if gIn and sIn: head & " inside each record, and sorted by station."
      elif gIn: head & " inside each record, sorted " & sub & "."
      elif sIn: head & ", sorted by station inside each record."
      else: head & ", sorted " & sub & "."
    else:
      if gIn and sIn:
        "Inside each record, traces are grouped by component, and inside each component " &
          "sorted by station."
      elif gIn:
        "Traces are grouped by component inside each record, and inside each component " &
          "sorted " & sub & "."
      elif sIn:
        "Traces are grouped by component, and inside each component sorted by station " &
          "inside each record."
      else: "Traces are grouped by component, and inside each component sorted " & sub & "."
