## What the map's Layers list is made of, as the settings keep it: the
## groups its layers are in. A module of its own, without dependencies, so
## that the settings (`core/settings`) and the map's state (`core/mapstate`)
## both name them.
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

const
  MaxTemplateLines* = 1000       ## a patch's lines, at most
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
