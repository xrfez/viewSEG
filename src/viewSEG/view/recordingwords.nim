## The short names of the kinds of recording a file can be.

import ../core/recordingkind

func kindWords*(k: RecordingKind): string =
  ## The name of what a file is, as a noun phrase.
  case k
  of rkShotGather: "shot gather"
  of rkReceiverContinuous: "continuous receiver gather"
  of rkReceiverSliced: "time-sliced receiver gather"
