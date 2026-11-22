## Named display presets: a display (how a plot's traces are drawn) kept
## under a name, to be put back on any plot with one click.
##
## A preset holds the whole of a layer's display but which way the plot is
## turned: the mode, the fills, the overlap, the colours, the density
## colour map, the gain type with every setting of its drop-down, the gain
## amount and the clip percentile. Applying it keeps the plot's
## orientation (a preset says how amplitudes look, not how the plot is
## laid out). They are kept in the settings (`Settings.displayPresets`),
## in the order they were made; names are unique, compared without case
## (Unicode's, so "ä" and "Ä" are one name) and surrounding spaces.
##
## The procs here are pure: `core/state` applies them for the `display
## preset` command, and says in the log what one could not do.

import std/[math, strutils, unicode]
import panels

type
  DisplayPreset* = object
    ## A display kept under a name.
    name*: string
    display*: DisplaySettings ## its orientation is not used (`withPreset`)

  PresetAction* = enum
    ## What a `display preset` command does.
    paApply = "apply"   ## draw the panel as the preset says
    paSave = "save"     ## keep the panel's display under the name (replacing one so named)
    paRename = "rename" ## give a preset another name
    paDelete = "delete" ## forget a preset

const
  MaxDisplayPresets* = 32 ## presets kept, at most
  MaxPresetName* = 64     ## the longest name, in characters (Unicode code points)

func asPreset*(d: DisplaySettings): DisplaySettings =
  ## What a preset keeps of `d`: all of it, shown, the orientation left at
  ## its default, each number within its control's range (`bounded`). The
  ## first-break overlay is not a look to keep: it is left off.
  result = bounded(d)
  result.visible = true
  result.orientation = DisplaySettings().orientation
  result.firstBreaks = false

func withPreset*(shown, preset: DisplaySettings): DisplaySettings =
  ## `preset` drawn on a plot whose display is `shown`: its orientation
  ## and its first-break overlay kept.
  result = asPreset(preset)
  result.orientation = shown.orientation
  result.firstBreaks = shown.firstBreaks

func sameValue[T](a, b: T): bool =
  ## `a == b`, field by field, a number that is not a number equal to
  ## itself (as the settings file has it).
  when T is SomeFloat: a == b or (a.isNaN and b.isNaN)
  elif T is object:
    result = true
    for x, y in fields(a, b):
      if not sameValue(x, y): return false
  else: a == b

func sameLook*(a, b: DisplaySettings): bool =
  ## Whether `a` and `b` draw a plot alike but for its orientation.
  sameValue(asPreset(a), asPreset(b))

func samePresets*(a, b: openArray[DisplayPreset]): bool =
  ## Whether the two lists hold the same presets in the same order, a
  ## number that is not a number equal to itself.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].name != b[i].name or not sameValue(a[i].display, b[i].display): return false
  true

func cleanName*(name: string): string = strutils.strip(name)
  ## `name` as a preset is named: without the spaces around it.

func find*(presets: openArray[DisplayPreset]; name: string): int =
  ## The index of the preset named `name` (case, in Unicode, and
  ## surrounding spaces ignored); -1 for none.
  let n = cleanName(name)
  for i, p in presets:
    if cmpRunesIgnoreCase(p.name, n) == 0: return i
  -1

func shownPreset*(presets: openArray[DisplayPreset]; d: DisplaySettings): int =
  ## The index of the first preset that draws as `d` does (`sameLook`); -1
  ## for none. A preset with no Fixed amplitude (its gain takes it from the
  ## record shown) is shown whatever amplitude the record gave.
  for i, p in presets:
    var shown = d
    if p.display.fixedClip.isNaN: shown.fixedClip = NaN
    if sameLook(p.display, shown): return i
  -1

func nameProblem*(name: string): string =
  ## Why `name` cannot name a preset; "" when it can.
  let n = cleanName(name)
  if n.len == 0: "a display preset needs a name"
  elif validateUtf8(n) >= 0: "a display preset's name is not text (not UTF-8)"
  elif n.runeLen > MaxPresetName: "a display preset's name is at most " & $MaxPresetName &
    " characters long"
  elif n.contains({'\0'..'\31', '\127'}): "a display preset's name holds no control characters"
  else: ""

func saved*(presets: seq[DisplayPreset]; name: string; d: DisplaySettings;
    why: var string): seq[DisplayPreset] =
  ## `presets` with `d` kept under `name`: in place of the preset so named
  ## (which keeps its place and its spelling), else last. `presets` as it
  ## is, and why in `why`, when `name` cannot name one or the list is full.
  result = presets
  why = nameProblem(name)
  if why.len > 0: return
  let i = presets.find(name)
  if i >= 0: result[i].display = asPreset(d)
  elif presets.len >= MaxDisplayPresets:
    why = "at most " & $MaxDisplayPresets & " display presets are kept; delete one first"
  else: result.add DisplayPreset(name: cleanName(name), display: asPreset(d))

func renamed*(presets: seq[DisplayPreset]; name, newName: string;
    why: var string): seq[DisplayPreset] =
  ## `presets` with the one named `name` named `newName`; as it is, and
  ## why in `why`, when there is none so named, `newName` cannot name one,
  ## or another preset has that name.
  result = presets
  let i = presets.find(name)
  why = nameProblem(newName)
  if i < 0: why = "no display preset is named \"" & cleanName(name) & "\""
  elif why.len == 0:
    let j = presets.find(newName)
    if j >= 0 and j != i: why = "a display preset is named \"" & presets[j].name & "\" already"
    else: result[i].name = cleanName(newName)

func deleted*(presets: seq[DisplayPreset]; name: string; why: var string): seq[DisplayPreset] =
  ## `presets` without the one named `name`; as it is, and why in `why`,
  ## when there is none so named.
  result = presets
  let i = presets.find(name)
  if i < 0: why = "no display preset is named \"" & cleanName(name) & "\""
  else:
    why = ""
    result.delete(i)

func cleaned*(presets: openArray[DisplayPreset]): seq[DisplayPreset] =
  ## `presets` without those that cannot be used (a name that is not one, a
  ## name given twice: the first counts), at most `MaxDisplayPresets`, each
  ## display as a preset keeps it.
  for p in presets:
    if nameProblem(p.name).len == 0 and result.find(p.name) < 0 and
        result.len < MaxDisplayPresets:
      result.add DisplayPreset(name: cleanName(p.name), display: asPreset(p.display))
