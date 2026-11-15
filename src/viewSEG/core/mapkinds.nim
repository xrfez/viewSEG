## What the map's Layers list is made of, as the settings keep it: the
## groups its layers are in, the template, the filters. A module of its own,
## with no dependency but parseSEG's station keys, so that the settings
## (`core/settings`), the inbox and the map's state (`core/mapstate`) all
## name them.
##
## **Groups.** The survey files (SPS, SEG P1) are the **Preplot**: the
## sources and receivers the survey planned. What the seismic files say of
## themselves (their traces' own positions, as their headers give them or
## as a join with the survey files made them) is **Recorded**. Planned
## against recorded reads at a glance; each group is shown or hidden as
## one, and each of its layers on its own.
##
## **The template** (`TemplateSpec`): the spread planned for each shot is
## read from the relation records (SPS X, and O for receiver gathers); when
## no relation file is loaded, the map has it generated from a template the
## user gives, a patch of lines × channels or a distance box (processSEG's
## `generateRelations`).
##
## **Filters** (`MapFilter`): what the map can mark on the record shown, each
## its own toggle with its count: traces that failed (dead in the headers,
## not decodable, killed by the user), the amplitude flags of processSEG's
## `qc/amplitude` (noisy, clipped, spiky, constant, weak, DC offset, all
## zero, not a number), the stations the template plans that the record
## lacks, its traces at stations the template does not list and stations
## recorded twice (processSEG's `recordCompleteness`), auxiliary traces,
## traces without a position, reversed traces, and the shots whose listed
## spread differs from the template (processSEG's `compareRelations`). What
## each finds is a `FilterHits`: today for the record shown (and the
## survey-wide spread check); the survey-wide QC passes fill the same.
##
## **Marks** (`FilterMark`): each filter marks its stations on the map with
## a glyph of its own: a colour for its kind of finding (`FlagFamily`: a
## failed trace, an amplitude flag, the user's edit, the spread; the theme
## gives each its role) and a shape within the kind (`FlagShape`), so no two
## filters mark alike.

import parseSEG

export StationKey

type
  MapGroup* = enum
    ## A group of the map's layers.
    mgPreplot = "Preplot"
      ## the survey files: the sources and receivers the survey planned
    mgRecorded = "Recorded"
      ## what the seismic files say: their traces' own positions

  TemplateShape* = enum
    ## How a template gives the receivers planned for a shot.
    tsPatch = "lines × channels"
      ## the receiver lines nearest the source, so many stations each, centred on it
    tsBox = "box"
      ## every receiver within a distance of the source, along and across the receiver lines

  TemplateSpec* = object
    ## The template planned spreads are generated from when no relation
    ## file is loaded; distances in the survey's units.
    shape*: TemplateShape
    lines*: int = 8 ## a patch's receiver lines
    channels*: int = 120 ## a patch's stations on each line
    inlineHalf*: float64 = 1500.0 ## a box's half-width along the receiver lines
    crosslineHalf*: float64 = 500.0
      ## a box's half-width across the receiver lines

  MapFilter* = enum
    ## What the map's filters mark.
    mfDead = "dead in the headers"          ## seismic traces the file marks dead
    mfUndecodable = "not decodable"         ## traces whose samples could not be decoded
    mfKilled = "killed"                     ## traces the user killed
    mfNoisy = "noisy"                       ## RMS far above the record's
    mfClipped = "clipped"                   ## runs of samples at the maximum
    mfSpiky = "spiky"                       ## samples far above their neighbours
    mfConstant = "constant"                 ## every sample the same, not zero
    mfWeak = "weak"                         ## RMS far below the record's
    mfDcOffset = "DC offset"                ## a mean large against the deviation
    mfAllZero = "all zero"                  ## every sample 0, whatever the header says
    mfNotANumber = "not a number"           ## a NaN or infinite sample
    mfMissing = "missing from the template" ## stations planned that the record lacks
    mfUnlisted = "not in the template"      ## traces at stations the plan does not list
    mfDuplicate = "recorded twice"          ## stations with two traces of one component
    mfAuxiliary = "auxiliary"               ## traces that are not seismic
    mfNoPosition = "without a position"     ## seismic traces the map cannot place
    mfReversed = "reversed"                 ## traces whose polarity the user reversed
    mfSpreadDiffers = "spread not the template"
      ## shots whose listed receivers differ from those the template plans

  FlagFamily* = enum
    ## What kind of finding a filter's mark says, in its colour.
    ffFailed = "failed traces" ## dead, not decodable, all zero, not a number
    ffAmplitude = "amplitude"  ## noisy, clipped, spiky, constant, weak, DC offset
    ffEdited = "your edits"    ## killed, reversed
    ffSpread = "the spread"    ## missing, not in the template, twice, ... spread differs

  FlagShape* = enum
    ## The glyph a filter's mark is drawn as, round its station.
    shCircle = "circle"
    shSquare = "square"
    shDiamond = "diamond"
    shTriangle = "triangle"
    shPlus = "plus"
    shCross = "cross"

  FilterMark* = tuple[family: FlagFamily; shape: FlagShape]
    ## how a filter's points are marked on the map

  FilterState* = enum
    ## How far a filter's finding is.
    fsOff = "off"                ## not asked for
    fsComputing = "computing"    ## its job runs
    fsDone = "done"
    fsNotChecked = "not checked" ## it cannot be found here (`FilterHits.note` says why)

  FilterHits* = object
    ## What one filter finds.
    state*: FilterState
    traces*: seq[int]          ## the survey-wide ids of the traces it marks
    stations*: seq[StationKey] ## stations it marks that have no trace (planned, missing)
    sources*: seq[StationKey]  ## sources it marks (shots whose spread differs)
    count*: int                ## what its label counts (traces, stations or shots)
    note*: string              ## what it counts, or why it is not checked

const
  FilterMarks*: array[MapFilter, FilterMark] = [(ffFailed, shSquare), (ffFailed, shPlus),
    (ffEdited, shCross), (ffAmplitude, shCircle), (ffAmplitude, shSquare),
    (ffAmplitude, shTriangle), (ffAmplitude, shDiamond), (ffAmplitude, shPlus),
    (ffAmplitude, shCross), (ffFailed, shDiamond), (ffFailed, shTriangle), (ffSpread, shTriangle),
    (ffSpread, shSquare), (ffSpread, shDiamond), (ffSpread, shPlus), (ffSpread, shCross),
    (ffEdited, shDiamond), (ffSpread, shCircle)]
    ## each filter's mark, in `MapFilter`'s order: no two alike, and the
    ## filters most used of different shapes too (dead a square, killed an X
    ## over its station, noisy a circle, missing from the template a
    ## triangle, reversed a diamond); auxiliary traces and those without a
    ## position are counted, not marked
  TraceFilters* = {mfDead, mfUndecodable, mfNoisy, mfClipped, mfSpiky, mfConstant, mfWeak,
    mfDcOffset, mfAllZero, mfNotANumber, mfMissing, mfUnlisted, mfDuplicate, mfAuxiliary}
    ## the filters found by reading the record shown on a job (`core/recordqc`)
  MaxTemplateLines* = 1000 ## a patch's lines, at most
  MaxTemplateChannels* = 100_000 ## a patch's stations on a line, at most

func bounded*(t: TemplateSpec): TemplateSpec =
  ## `t` with each value in its range: a patch of 1 to `MaxTemplateLines`
  ## lines and 1 to `MaxTemplateChannels` stations, a box's half-widths
  ## positive and finite (else their defaults).
  result = t
  result.lines = clamp(t.lines, 1, MaxTemplateLines)
  result.channels = clamp(t.channels, 1, MaxTemplateChannels)
  if not (t.inlineHalf > 0 and t.inlineHalf < Inf): result.inlineHalf = TemplateSpec().inlineHalf
  if not (t.crosslineHalf > 0 and t.crosslineHalf < Inf):
    result.crosslineHalf = TemplateSpec().crosslineHalf
