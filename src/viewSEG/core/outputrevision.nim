## The revision of the file the Output window writes: the source's own, or one
## explicit revision of the standard written. Plain words only, so the settings
## can hold the choice.

type
  OutputRevision* = enum
    ## The words are the settings' spelling. `orSame` keeps the source's own
    ## revision (a file of another standard is written as SEG-Y 2.1 or SEG-D 3.0).
    orSame = "same"
    orSegy0 = "segy0"
    orSegy1 = "segy1"
    orSegy20 = "segy20"
    orSegy21 = "segy21"
    orSegd30 = "segd30"
    orSegd31 = "segd31"

const
  SegyRevisions* = [orSegy0, orSegy1, orSegy20, orSegy21]
  SegdRevisions* = [orSegd30, orSegd31]

func isSegy*(r: OutputRevision): bool =
  ## An explicit SEG-Y revision.
  r in {orSegy0 .. orSegy21}

func isSegd*(r: OutputRevision): bool =
  ## An explicit SEG-D revision.
  r in {orSegd30, orSegd31}

func major*(r: OutputRevision): uint8 =
  ## The revision's major number (0 for `orSame`).
  case r
  of orSame: 0
  of orSegy0: 0
  of orSegy1: 1
  of orSegy20, orSegy21: 2
  of orSegd30, orSegd31: 3

func minor*(r: OutputRevision): uint8 =
  ## The revision's minor number.
  case r
  of orSegy21, orSegd31: 1
  else: 0

func revisionLabel*(r: OutputRevision): string =
  ## How the window and the result lines name the choice.
  case r
  of orSame: "Same as the source"
  of orSegy0: "Rev 0"
  of orSegy1: "Rev 1"
  of orSegy20: "Rev 2.0"
  of orSegy21: "Rev 2.1"
  of orSegd30: "Rev 3.0"
  of orSegd31: "Rev 3.1"
