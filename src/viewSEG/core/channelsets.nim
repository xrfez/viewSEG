## The SEG-D channel set of a trace, for the display header, the readout, the
## trace table and the sort: its number and, in words, its channel type, both
## from parseSEG's index and headers (nothing is guessed from the numbers).
## SEG-Y and SEG-2 traces have no channel set.

import parseSEG
import headers

func channelSetIndexOf*(f: SeismicFile; trace: int): int =
  ## The 0-based channel set of trace `trace` within its scan type; -1 when it
  ## has none (SEG-Y, SEG-2) or the index does not know it.
  if f.kind == skSegd and trace >= 0 and trace < f.index.entries.len:
    f.index.entries[trace].channelSetIndex
  else: -1

func shownSetNumber*(index: int): int =
  ## The number shown for the channel set at 0-based `index`: counted from 1
  ## (the order the scan type's descriptors come in); 0 for none (-1).
  if index >= 0: index + 1 else: 0

func channelSetText*(f: SeismicFile; trace: int): string =
  ## "2 · seismic": the trace's channel set number and its channel type as
  ## `channelTypeName` words it; "" for a trace with no channel set.
  let at = f.channelSetIndexOf(trace)
  if at < 0: return ""
  let e = f.index.entries[trace]
  $shownSetNumber(at) & " · " & channelTypeName(f.index.segdRecords[int(
      e.record)].isRev3,
    int(e.channelType))
