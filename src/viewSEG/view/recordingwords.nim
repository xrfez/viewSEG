## The short names of the kinds of recording a file can be.

import ../core/recordingkind

func kindWords*(k: RecordingKind): string =
  ## The name of a kind, as a noun phrase.
  case k
  of rkContinuous: "continuous recording"
  of rkShotRecord: "shot record"
  of rkSlicedGather: "receiver gather cut by shot"
