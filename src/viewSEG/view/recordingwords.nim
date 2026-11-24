## The short names of the kinds of recording a file can be.

import ../core/recordingkind

func kindWords*(k: RecordingKind): string =
  ## The name of what a file is, as a noun phrase.
  case k
  of rkShotGather: "shot gather"
  of rkReceiverContinuous: "continuous receiver gather"
  of rkReceiverSliced: "time-sliced receiver gather"

func kindTitle*(k: RecordingKind): string =
  ## `kindWords` as a title, for a table cell: "Shot gather".
  case k
  of rkShotGather: "Shot gather"
  of rkReceiverContinuous: "Continuous receiver gather"
  of rkReceiverSliced: "Time-sliced receiver gather"
