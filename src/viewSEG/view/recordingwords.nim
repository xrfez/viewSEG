## The short names of the kinds of recording a file can be.

import ../core/recordingkind

func kindWords*(k: RecordingKind): string =
  ## The name of what a file is, as a noun phrase.
  case k
  of rkShotGather: "shot gather"
  of rkReceiverContinuous: "continuous receiver gather"
  of rkReceiverSliced: "time-sliced receiver gather"

const NotKnownWords* = "Open the file to see its kind."
  ## what the Files panel says of a file too large to be opened for its kind

func kindShort*(k: RecordingKind): string =
  ## `kindWords` in a word or two, for a table cell: "Shot".
  case k
  of rkShotGather: "Shot"
  of rkReceiverContinuous: "Continuous"
  of rkReceiverSliced: "Time-sliced"

func kindTitle*(k: RecordingKind): string =
  ## `kindWords` as a title, for a table cell: "Shot gather".
  case k
  of rkShotGather: "Shot gather"
  of rkReceiverContinuous: "Continuous receiver gather"
  of rkReceiverSliced: "Time-sliced receiver gather"
