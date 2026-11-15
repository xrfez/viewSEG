## The settings as a NIF document (`core/nif`), as `settings.nif` holds
## them and File > Export > Settings writes them:
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (settings
##  (version 1)
##  (theme "everforest-dark")
##  (window (x 120) (y 80) (width 1280) (height 800) (maximized false))
##  (recentFiles "/data/shot1.sgd")
##  (recentFolders "/data")
##  (plot
##   (orientation timeDown)
##   (mode wiggle)
##   (fills positive)
##   ...
##   (order (key rcvLine) (key offset descending))
##   (header auto)
##   (processing (dc none) (band bandPass) (f1 4.0) (f2 8.0) (f3 60.0) (f4 80.0)
##    (notch (on true) (hz 60.0) (width 2.0) (harmonics 3)) (aux false)))
##  (scale (length inch) (speed false))
##  (calibrations (monitor "DELL U2720Q 3840x2160" 163.2))
##  (readout time trace channel receiver)
##  (sortPresets (preset "Line/Station" (key rcvLine) (key rcvPoint)))
##  (customOrder (key offset))
##  (messages (autoScroll true) (hide info))
##  (cursorLine false)
##  (files (followLatest false) (prepareNext true))
##  (map (info popup) (lengths survey) (hide recorded) (templateBox false) (folderShots true)
##   (filters noisy clipped)
##   (template (shape patch) (lines 8) (channels 120) (inline 1500.0) (crossline 500.0)))
##  (join (trailingDigits false) (multiComponent false) (coordinates fill)
##   (recordMatch auto) (traceMatch auto) (lineNames (line "CLT4960" 4960)))
##  (headers (tab summary) (traceTab header) (followPointer true) (asDisplayed false)
##   (columns description bytes))
##  (hideKilled false)
##  (spectrum
##   (window (scale db) (logFrequency false) (time whole) (raw true) (processed true)
##    (phase false))
##   (live (scale db) (logFrequency false) (time visible) (raw true) (processed true)
##    (phase false)))
##  (displayPresets
##   (preset "Section" (mode density) (colourMap viridis) (gain none) ...)))
## ```
##
## Reading is forgiving where it can be and says what it did: a setting that
## is missing keeps the value it had (a default), a setting it does not
## know is skipped, and a value it cannot use (the wrong kind, out of range)
## leaves that one setting as it was. Each of these is a *problem*, one line
## in plain words with the document's line. A document that is not NIF at
## all raises `NifError` (`core/nif`) instead: the caller decides what then.
##
## The names written for choices (`wiggle`, `rcvLine`, `inch`) are this
## module's own, not the program's labels, so a label can change without
## making old files unreadable.

import std/strutils
import geometry, join, log, nif, panels, readout, scales, settings

export nif

const
  SettingsVersion* = 1 ## the version `settingsDocument` writes
  MaxRecent* = 10      ## recent files kept, and recent folders
  MaxPresets* = 12     ## sort presets kept
  MaxText = 4096       ## the longest path or name taken

  OrientationNames: array[Orientation, string] = ["timeDown", "timeAcross"]
  ModeNames: array[DisplayMode, string] = ["density", "wiggle", "wiggleDensity"]
  BandNames: array[PassBand, string] = ["none", "lowCut", "highCut", "bandPass"]
  DcNames: array[DcRemoval, string] = ["none", "mean", "trend"]
  FillNames: array[WiggleFill, string] = ["positive", "negative"]
  ColourNames: array[PlotColours, string] = ["paper", "theme", "custom"]
  ColourMapNames: array[ColourMap, string] = ["grey", "redWhiteBlue", "viridis", "redBlack"]
  GainNames: array[DisplayGain, string] = ["auto", "none", "fixed", "normalized",
    "exponential", "float", "agc"]
  TimeGainNames: array[TimeGain, string] = ["dbPerSecond", "power"]
  ScopeNames: array[NormScope, string] = ["trace", "panel"]
  StatNames: array[NormStat, string] = ["peak", "rms", "percentile"]
  LengthNames: array[LengthUnit, string] = ["inch", "cm"]
  MapInfoNames: array[MapInfo, string] = ["popup", "strip"]
  MapLengthNames: array[MapLengths, string] = ["survey", "metres", "feet", "usFeet"]
  MapGroupNames: array[MapGroup, string] = ["preplot", "recorded"]
  TemplateShapeNames: array[TemplateShape, string] = ["patch", "box"]
  MapFilterNames: array[MapFilter, string] = ["dead", "undecodable", "killed", "noisy",
    "clipped", "spiky", "constant", "weak", "dcOffset", "allZero", "notANumber", "missing",
    "unlisted", "duplicate", "auxiliary", "noPosition", "reversed", "spreadDiffers"]
  CoordinateNames: array[HeaderCoordinates, string] = ["fill", "replace"]
  RecordMatchNames: array[RecordMatch, string] = ["auto", "source", "ffid"]
  TraceMatchNames: array[TraceMatch, string] = ["auto", "station", "channel"]
  MaxLineNames = 1000  ## line names mapped to numbers, kept
  FieldNames: array[HeaderField, string] = ["rcvLine", "rcvPoint", "component", "channel",
    "ffid", "srcLine", "srcPoint", "offset", "cdp", "inline", "crossline", "trace"]
  SeverityNames: array[Severity, string] = ["info", "warning", "error", "fatal"]
  HeadersTabNames: array[HeadersTab, string] = ["summary", "fileHeaders", "trace"]
  TraceTabNames: array[TraceTab, string] = ["header", "data"]
  HeaderColumnNames: array[HeaderColumn, string] = ["description", "name", "bytes", "offset"]
  SpectrumScaleNames: array[SpectrumScale, string] = ["db", "linear"]
  SpectrumTimeNames: array[SpectrumTime, string] = ["whole", "visible"]
  ReadoutNames: array[ReadoutField, string] = ["time", "trace", "channel", "receiver",
    "source", "ffid", "offset", "amplitude", "shotTime", "cursorUtc", "sample", "cdp",
    "inline", "crossline", "sourceXY", "receiverXY", "midpointXY", "sourceZ", "receiverZ",
    "component", "status", "rawAmplitude"]

type
  Reading = object
    ## A document being taken in, and what it said that could not be used.
    name: string
    problems: seq[string]

func persistedNames*(): seq[seq[string]] =
  ## Every table of names written for a choice (for tests: each must be a
  ## NIF identifier and unique in its table).
  @[@ModeNames, @BandNames, @DcNames, @FillNames, @ColourNames, @ColourMapNames, @GainNames,
    @TimeGainNames, @ScopeNames,
    @StatNames, @LengthNames, @FieldNames, @ReadoutNames, @SeverityNames, @HeadersTabNames,
    @TraceTabNames, @HeaderColumnNames, @SpectrumScaleNames, @SpectrumTimeNames]

# ----------------------------------------------------------------- writing --

func colourText*(c: Rgba): string =
  ## `c` as "#rrggbb", or "#rrggbbaa" when it is not opaque.
  result = "#" & toHex(c.r.int, 2).toLowerAscii & toHex(c.g.int, 2).toLowerAscii &
    toHex(c.b.int, 2).toLowerAscii
  if c.a != 255: result.add toHex(c.a.int, 2).toLowerAscii

proc value(w: var NifWriter; tag: string; x: float64) =
  w.open(tag)
  w.add x
  w.close()

proc value(w: var NifWriter; tag: string; i: int) =
  w.open(tag)
  w.add int64(i)
  w.close()

proc value(w: var NifWriter; tag: string; s: string) =
  w.open(tag)
  w.add s
  w.close()

proc value(w: var NifWriter; tag: string; b: bool) =
  w.open(tag)
  w.add b
  w.close()

proc choice(w: var NifWriter; tag, name: string) =
  w.open(tag)
  w.ident name
  w.close()

proc keys(w: var NifWriter; order: openArray[SortKey]) =
  for k in order:
    w.open("key")
    w.ident FieldNames[k.field]
    if k.descending: w.ident "descending"
    w.close()

proc display(w: var NifWriter; d: DisplaySettings; turned = true) =
  ## `d`'s settings; its orientation only when `turned` (a display preset
  ## has none).
  if turned: w.choice("orientation", OrientationNames[d.orientation])
  w.choice("mode", ModeNames[d.mode])
  w.open("fills")
  for f in d.fills: w.ident FillNames[f]
  w.close()
  w.value("overlap", d.overlap)
  w.choice("colours", ColourNames[d.colours])
  w.open("custom")
  for (tag, c) in [("background", d.custom.background), ("line", d.custom.line),
      ("positive", d.custom.positive), ("negative", d.custom.negative),
      ("hover", d.custom.hover), ("selected", d.custom.selected)]:
    w.value(tag, colourText(c))
  w.close()
  w.choice("colourMap", ColourMapNames[d.colourMap])
  w.choice("gain", GainNames[d.gain])
  w.value("gainDb", d.gainDb)
  w.value("agcWindowMs", d.agcWindowMs)
  if d.fixedClip > 0 and d.fixedClip < Inf: w.value("fixedClip", d.fixedClip)
  w.choice("normScope", ScopeNames[d.normScope])
  w.choice("normStat", StatNames[d.normStat])
  w.choice("timeGain", TimeGainNames[d.timeGain])
  w.value("dbPerS", d.dbPerS)
  w.value("power", d.power)
  w.value("untilMs", d.untilMs)
  w.value("clipPercentile", d.clipPercentile)

proc writeProcessing*(w: var NifWriter; p: Processing) =
  ## `p` as the settings file holds it, in a `(processing ...)` tree (how
  ## a plot is shown, raw or processed, is not written). The same tree can
  ## keep a file's own filters with what is remembered about the file
  ## (`readProcessing` takes it back).
  w.open("processing")
  w.choice("dc", DcNames[p.dc])
  w.choice("band", BandNames[p.band])
  for (tag, x) in [("f1", p.f1), ("f2", p.f2), ("f3", p.f3), ("f4", p.f4)]: w.value(tag, x)
  for n in p.notches:
    w.open("notch")
    w.value("on", n.on)
    w.value("hz", n.hz)
    w.value("width", n.widthHz)
    w.value("harmonics", n.harmonics)
    w.close()
  w.value("aux", p.aux)
  w.close()

proc spectrumDisplay(w: var NifWriter; tag: string; d: SpectrumDisplay) =
  w.open(tag)
  w.choice("scale", SpectrumScaleNames[d.scale])
  w.value("logFrequency", d.logFrequency)
  w.choice("time", SpectrumTimeNames[d.time])
  w.value("raw", d.raw)
  w.value("processed", d.processed)
  w.value("phase", d.phase)
  w.close()

proc settingsDocument*(s: Settings): string =
  ## `s` as a NIF document, every setting written (a calibration or a
  ## float that is not finite is not: `cleaned` drops them first).
  var w = initNifWriter()
  w.open("settings")
  w.value("version", SettingsVersion)
  w.value("theme", s.theme)
  if s.window.width > 0 and s.window.height > 0:
    w.open("window")
    w.value("x", s.window.x)
    w.value("y", s.window.y)
    w.value("width", s.window.width)
    w.value("height", s.window.height)
    w.value("maximized", s.window.maximized)
    w.close()
  w.open("recentFiles")
  for f in s.recentFiles: w.add f
  w.close()
  w.open("recentFolders")
  for f in s.recentFolders: w.add f
  w.close()
  w.open("plot")
  w.display(s.plot.display)
  w.open("order")
  w.keys(s.plot.order)
  w.close()
  w.open("header")
  if s.plot.header.auto: w.ident "auto"
  else:
    for f in s.plot.header.fields: w.ident FieldNames[f]
  w.close()
  w.writeProcessing(s.plot.processing)
  w.close()
  w.open("scale")
  w.choice("length", LengthNames[s.scale.length])
  w.value("speed", s.scale.speed)
  w.close()
  w.open("calibrations")
  for c in s.calibrations:
    if c.ppi > 0 and c.ppi < Inf:
      w.open("monitor")
      w.add c.monitor
      w.add c.ppi
      w.close()
  w.close()
  w.open("readout")
  for f in s.readout: w.ident ReadoutNames[f]
  w.close()
  w.open("sortPresets")
  for p in s.sortPresets:
    w.open("preset")
    w.add p.name
    w.keys(p.keys)
    w.close()
  w.close()
  w.open("customOrder")
  w.keys(s.customOrder)
  w.close()
  w.open("messages")
  w.value("autoScroll", s.messages.autoScroll)
  w.open("hide")
  for v in s.messages.hidden: w.ident SeverityNames[v]
  w.close()
  w.close()
  w.value("cursorLine", s.cursorLine)
  w.open("files")
  w.value("followLatest", s.files.followLatest)
  w.value("prepareNext", s.files.prepareNext)
  w.close()
  w.open("map")
  w.choice("info", MapInfoNames[s.map.info])
  w.choice("lengths", MapLengthNames[s.map.lengths])
  w.open("hide")
  for g in s.map.hiddenGroups: w.ident MapGroupNames[g]
  w.close()
  w.value("templateBox", s.map.templateBox)
  w.value("folderShots", s.map.folderShots)
  w.open("filters")
  for f in s.map.filters: w.ident MapFilterNames[f]
  w.close()
  w.open("template")
  w.choice("shape", TemplateShapeNames[s.map.spreadTemplate.shape])
  w.value("lines", s.map.spreadTemplate.lines)
  w.value("channels", s.map.spreadTemplate.channels)
  w.value("inline", s.map.spreadTemplate.inlineHalf)
  w.value("crossline", s.map.spreadTemplate.crosslineHalf)
  w.close()
  w.close()
  w.open("join")
  w.value("trailingDigits", s.join.trailingDigits)
  w.value("multiComponent", s.join.multiComponent)
  w.choice("coordinates", CoordinateNames[s.join.coordinates])
  w.choice("recordMatch", RecordMatchNames[s.join.recordMatch])
  w.choice("traceMatch", TraceMatchNames[s.join.traceMatch])
  w.open("lineNames")
  for n in s.join.lineNames:
    w.open("line")
    w.add n.name
    w.add n.line
    w.close()
  w.close()
  w.close()
  w.open("headers")
  w.choice("tab", HeadersTabNames[s.headers.tab])
  w.choice("traceTab", TraceTabNames[s.headers.traceTab])
  w.value("followPointer", s.headers.followPointer)
  w.value("asDisplayed", s.headers.asDisplayed)
  w.open("columns")
  for c in s.headers.columns: w.ident HeaderColumnNames[c]
  w.close()
  w.close()
  w.value("hideKilled", s.hideKilled)
  w.open("spectrum")
  w.spectrumDisplay("window", s.spectrum.window)
  w.spectrumDisplay("live", s.spectrum.live)
  w.close()
  w.open("displayPresets")
  for p in s.displayPresets:
    w.open("preset")
    w.add p.name
    w.display(p.display, turned = false)
    w.close()
  w.close()
  w.close()
  w.finish

# ----------------------------------------------------------------- reading --

template problem(r: var Reading; n: NifNode; text: string) =
  ## Adds a problem at `n`; past the first `WordedProblems`, counted only
  ## (an empty line), and `text` is not made.
  if r.problems.len < WordedProblems: r.problems.add r.name & " line " & $n.line & ": " & text
  else: r.problems.add ""

proc unusable(r: var Reading; n: NifNode; tag, needs: string) =
  ## `(tag ...)` at `n` holds what it should not.
  r.problem(n, "(" & tag & ") needs " & needs & ", not " & describe(n) &
    "; that setting keeps its value.")

proc single(r: var Reading; n: NifNode; needs: string): bool =
  ## Whether node `(tag v)` has exactly one value.
  result = n.kids.len == 1
  if not result:
    r.problem(n, "(" & n.tag & ") needs " & needs & ", not " & $n.kids.len &
      " values; that setting keeps its value.")

proc number(r: var Reading; n: NifNode; lo, hi: float64; x: var float64) =
  ## `(tag v)`: `x` = v when it is a number in `lo .. hi`.
  let needs = "a number from " & $lo & " to " & $hi
  if r.single(n, needs):
    let v = n.kids[0]
    let f = case v.kind
      of nkFloat: v.floatVal
      of nkInt: float64(v.intVal)
      else: NaN
    if f >= lo and f <= hi: x = f
    else: r.unusable(v, n.tag, needs)

proc integer(r: var Reading; n: NifNode; lo, hi: int; x: var int) =
  ## `(tag v)`: `x` = v when it is an integer in `lo .. hi`.
  let needs = "a whole number from " & $lo & " to " & $hi
  if r.single(n, needs):
    let v = n.kids[0]
    if v.kind == nkInt and v.intVal >= lo and v.intVal <= hi: x = int(v.intVal)
    else: r.unusable(v, n.tag, needs)

proc flag(r: var Reading; n: NifNode; x: var bool) =
  ## `(tag true)` or `(tag false)`.
  if r.single(n, "true or false"):
    let v = n.kids[0]
    if v.kind == nkIdent and v.text in ["true", "false"]: x = v.text == "true"
    else: r.unusable(v, n.tag, "true or false")

func usableText(s: string): bool =
  ## A path or a name: not empty, not too long, no control characters.
  s.len in 1..MaxText and not s.contains({'\0'..'\31', '\127'})

proc text(r: var Reading; n: NifNode; x: var string; allowEmpty = false) =
  ## `(tag "...")`.
  if r.single(n, "a string"):
    let v = n.kids[0]
    if v.kind == nkString and (usableText(v.text) or (allowEmpty and v.text.len == 0)):
      x = v.text
    else: r.unusable(v, n.tag, "a string")

proc pick[T: enum](r: var Reading; v: NifNode; names: array[T, string]; tag: string;
    x: var T): bool =
  ## `x` = the choice `v` names; false, with a problem, when it names none.
  result = false
  if v.kind == nkIdent:
    for e, name in names:
      if name == v.text:
        x = e
        return true
  r.unusable(v, tag, "one of " & names.join(", "))

proc choice[T: enum](r: var Reading; n: NifNode; names: array[T, string]; x: var T) =
  ## `(tag name)`.
  if r.single(n, "one of " & names.join(", ")):
    discard r.pick(n.kids[0], names, n.tag, x)

proc colour(r: var Reading; n: NifNode; x: var Rgba) =
  ## `(tag "#rrggbb")` or `"#rrggbbaa"`.
  const needs = "a colour such as \"#ff8000\""
  if r.single(n, needs):
    let v = n.kids[0]
    var ok = v.kind == nkString and v.text.len in [7, 9] and v.text[0] == '#' and
      v.text[1 .. ^1].allCharsInSet(HexDigits)
    if ok:
      let h = v.text
      x = Rgba(r: uint8(parseHexInt(h[1..2])), g: uint8(parseHexInt(h[3..4])),
        b: uint8(parseHexInt(h[5..6])), a: (if h.len == 9: uint8(parseHexInt(h[7..8]))
        else: 255'u8))
    else: r.unusable(v, n.tag, needs)

proc unknown(r: var Reading; n: NifNode; within: string) =
  r.problem(n, (if n.kind == nkTree: "(" & n.tag & ")" else: describe(n)) & " in (" &
    within & ") is not a setting this version knows; skipped.")

proc keys(r: var Reading; n: NifNode; first: int; x: var seq[SortKey]) =
  ## The `(key field [descending])` nodes of `n` from kid `first` on: a
  ## field given twice counts once, as its first.
  var got: seq[SortKey]
  for i in first ..< n.kids.len:
    let k = n.kids[i]
    var key = SortKey()
    if not k.isTree("key") or k.kids.len notin 1..2:
      r.unusable(k, n.tag, "(key field) or (key field descending)")
    elif r.pick(k.kids[0], FieldNames, "key", key.field):
      if k.kids.len == 2:
        if k.kids[1].kind == nkIdent and k.kids[1].text in ["ascending", "descending"]:
          key.descending = k.kids[1].text == "descending"
        else:
          r.unusable(k.kids[1], "key", "ascending or descending")
      var seen = false
      for g in got:
        if g.field == key.field: seen = true
      if not seen: got.add key
  x = got

proc strings(r: var Reading; n: NifNode; x: var seq[string]) =
  ## `(tag "..." ...)`: the usable strings, each once, at most `MaxRecent`.
  var got: seq[string]
  for v in n.kids:
    if v.kind != nkString or not usableText(v.text): r.unusable(v, n.tag, "strings")
    elif v.text notin got and got.len < MaxRecent: got.add v.text
  x = got

proc display(r: var Reading; n: NifNode; d: var DisplaySettings) =
  for c in n.kids:
    if c.kind != nkTree:
      r.unknown(c, "plot")
    else:
      case c.tag
      of "orientation": r.choice(c, OrientationNames, d.orientation)
      of "mode": r.choice(c, ModeNames, d.mode)
      of "fills":
        var fills: set[WiggleFill]
        var ok = true
        for v in c.kids:
          var f = wfPositive
          if r.pick(v, FillNames, "fills", f): fills.incl f
          else: ok = false
        if ok: d.fills = fills
      of "overlap": r.number(c, MinOverlap, MaxOverlap, d.overlap)
      of "colours": r.choice(c, ColourNames, d.colours)
      of "custom":
        for k in c.kids:
          if k.kind != nkTree: r.unknown(k, "custom")
          else:
            case k.tag
            of "background": r.colour(k, d.custom.background)
            of "line": r.colour(k, d.custom.line)
            of "positive": r.colour(k, d.custom.positive)
            of "negative": r.colour(k, d.custom.negative)
            of "hover": r.colour(k, d.custom.hover)
            of "selected": r.colour(k, d.custom.selected)
            else: r.unknown(k, "custom")
      of "colourMap": r.choice(c, ColourMapNames, d.colourMap)
      of "gain": r.choice(c, GainNames, d.gain)
      of "gainDb": r.number(c, -MaxGainDb, MaxGainDb, d.gainDb)
      of "agcWindowMs": r.number(c, MinAgcWindowMs, MaxAgcWindowMs, d.agcWindowMs)
      of "fixedClip": r.number(c, MinFixedClip, MaxFixedClip, d.fixedClip)
      of "normScope": r.choice(c, ScopeNames, d.normScope)
      of "normStat": r.choice(c, StatNames, d.normStat)
      of "timeGain": r.choice(c, TimeGainNames, d.timeGain)
      of "dbPerS": r.number(c, -MaxDbPerS, MaxDbPerS, d.dbPerS)
      of "power": r.number(c, -MaxPower, MaxPower, d.power)
      of "untilMs": r.number(c, MinUntilMs, MaxUntilMs, d.untilMs)
      of "clipPercentile": r.number(c, MinClipPercentile, 100, d.clipPercentile)
      else: r.unknown(c, "plot")

proc readTree(r: var Reading; n: NifNode; p: var Processing) =
  ## `p` from a `(processing ...)` tree, as `settings` reads it.
  var notches: seq[NotchFilter]
  var notched = false
  for c in n.kids:
    if c.kind != nkTree: r.unknown(c, "processing")
    else:
      case c.tag
      of "dc": r.choice(c, DcNames, p.dc)
      of "band": r.choice(c, BandNames, p.band)
      of "f1": r.number(c, 0, MaxFilterHz, p.f1)
      of "f2": r.number(c, 0, MaxFilterHz, p.f2)
      of "f3": r.number(c, 0, MaxFilterHz, p.f3)
      of "f4": r.number(c, 0, MaxFilterHz, p.f4)
      of "aux": r.flag(c, p.aux)
      of "notch":
        notched = true
        var x = NotchFilter()
        for k in c.kids:
          if k.kind != nkTree: r.unknown(k, "notch")
          else:
            case k.tag
            of "on": r.flag(k, x.on)
            of "hz": r.number(k, MinNotchHz, MaxFilterHz, x.hz)
            of "width": r.number(k, MinNotchWidthHz, MaxNotchWidthHz, x.widthHz)
            of "harmonics": r.integer(k, 1, MaxHarmonics, x.harmonics)
            else: r.unknown(k, "notch")
        if notches.len < MaxNotches: notches.add x
        else: r.unusable(c, "notch", "at most " & $MaxNotches & " notches")
      else: r.unknown(c, "processing")
  if notched: p.notches = notches
  p = remembered(bounded(p))

proc readProcessing*(n: NifNode; name: string; base: Processing;
    problems: var seq[string]): Processing =
  ## The filters a `(processing ...)` tree written by `writeProcessing`
  ## holds, over `base`: what is missing or cannot be used keeps `base`'s
  ## value, and is said in `problems` (`name`: the document's, for them).
  var r = Reading(name: name)
  result = base
  r.readTree(n, result)
  problems.add r.problems

proc plot(r: var Reading; n: NifNode; p: var PlotDefaults) =
  var rest = NifNode(kind: nkTree, line: n.line, tag: n.tag)
  for c in n.kids:
    if c.isTree("processing"): r.readTree(c, p.processing)
    elif c.isTree("order"): r.keys(c, 0, p.order)
    elif c.isTree("header"):
      if c.kids.len == 1 and c.kids[0].kind == nkIdent and c.kids[0].text == "auto":
        p.header = HeaderChoice(auto: true)
      else:
        var fields: seq[HeaderField]
        for v in c.kids:
          var f = hfTrace
          if r.pick(v, FieldNames, "header", f) and f notin fields: fields.add f
        if fields.len > 0: p.header = HeaderChoice(auto: false, fields: fields)
        else: r.unusable(c, "header", "auto, or the fields to show")
    else: rest.kids.add c
  r.display(rest, p.display)

proc window(r: var Reading; n: NifNode; w: var WindowPlacement) =
  var got = w
  for c in n.kids:
    if c.kind != nkTree: r.unknown(c, "window")
    else:
      case c.tag
      of "x": r.integer(c, -1_000_000, 1_000_000, got.x)
      of "y": r.integer(c, -1_000_000, 1_000_000, got.y)
      of "width": r.integer(c, 1, 100_000, got.width)
      of "height": r.integer(c, 1, 100_000, got.height)
      of "maximized": r.flag(c, got.maximized)
      else: r.unknown(c, "window")
  if got.width > 0 and got.height > 0: w = got
  else: r.problem(n, "(window) needs a width and a height; the window opens at its " &
    "default size.")

proc calibrations(r: var Reading; n: NifNode; x: var seq[Calibration]) =
  var got: seq[Calibration]
  for c in n.kids:
    if c.isTree("monitor") and c.kids.len == 2 and c.kids[0].kind == nkString and
        usableText(c.kids[0].text) and c.kids[1].kind in {nkFloat, nkInt}:
      let ppi = if c.kids[1].kind == nkFloat: c.kids[1].floatVal
                else: float64(c.kids[1].intVal)
      if ppi >= 10 and ppi <= 10_000:
        var s = Settings(calibrations: got)
        s.calibrate(c.kids[0].text, ppi) # a monitor given twice: the last counts
        got = s.calibrations
      else: r.unusable(c.kids[1], "monitor", "pixels per inch from 10 to 10000")
    else: r.unusable(c, "calibrations", "(monitor \"name\" pixels-per-inch)")
  x = got

proc presets(r: var Reading; n: NifNode; x: var seq[SortPreset]) =
  var got: seq[SortPreset]
  for c in n.kids:
    if c.isTree("preset") and c.kids.len >= 2 and c.kids[0].kind == nkString and
        usableText(c.kids[0].text) and c.kids[0].text.len <= 64:
      var p = SortPreset(name: c.kids[0].text)
      r.keys(c, 1, p.keys)
      var named = false
      for q in got:
        if q.name == p.name: named = true
      if named: r.problem(c, "the sort preset \"" & p.name & "\" is given twice; the " &
        "first counts.")
      elif p.keys.len > 0 and got.len < MaxPresets: got.add p
    else:
      r.unusable(c, "sortPresets", "(preset \"name\" (key field) ...)")
  if got.len > 0 or n.kids.len == 0: x = got

proc displayPresets(r: var Reading; n: NifNode; x: var seq[DisplayPreset]) =
  ## `(displayPresets (preset "name" (mode ...) ...) ...)`: a preset that
  ## is not one, or whose name is taken, is left out and said.
  var got: seq[DisplayPreset]
  for c in n.kids:
    if c.isTree("preset") and c.kids.len >= 1 and c.kids[0].kind == nkString and
        nameProblem(c.kids[0].text).len == 0:
      var rest = NifNode(kind: nkTree, line: c.line, tag: "preset")
      for i in 1 ..< c.kids.len: rest.kids.add c.kids[i]
      var d = DisplaySettings()
      r.display(rest, d)
      if got.find(c.kids[0].text) >= 0:
        r.problem(c, "the display preset \"" & c.kids[0].text & "\" is given twice; the " &
          "first counts.")
      elif got.len < MaxDisplayPresets:
        got.add DisplayPreset(name: cleanName(c.kids[0].text), display: asPreset(d))
    else:
      r.unusable(c, "displayPresets", "(preset \"name\" (mode ...) ...)")
  x = got

proc join(r: var Reading; n: NifNode; x: var JoinOptions) =
  for k in n.kids:
    if k.kind != nkTree: r.unknown(k, "join")
    else:
      case k.tag
      of "trailingDigits": r.flag(k, x.trailingDigits)
      of "multiComponent": r.flag(k, x.multiComponent)
      of "coordinates": r.choice(k, CoordinateNames, x.coordinates)
      of "recordMatch": r.choice(k, RecordMatchNames, x.recordMatch)
      of "traceMatch": r.choice(k, TraceMatchNames, x.traceMatch)
      of "lineNames":
        var got: seq[LineName]
        for c in k.kids:
          if c.isTree("line") and c.kids.len == 2 and c.kids[0].kind == nkString and
              usableText(c.kids[0].text) and c.kids[0].text.strip.len > 0 and
              c.kids[1].kind in {nkFloat, nkInt}:
            let v = if c.kids[1].kind == nkFloat: c.kids[1].floatVal
                    else: float64(c.kids[1].intVal)
            if abs(v) < Inf:
              if got.len < MaxLineNames: got.add LineName(name: c.kids[0].text.strip, line: v)
            else: r.unusable(c.kids[1], "line", "a line number")
          else: r.unusable(c, "lineNames", "(line \"name\" number)")
        x.lineNames = got
      else: r.unknown(k, "join")

proc spectrumDisplay(r: var Reading; n: NifNode; d: var SpectrumDisplay) =
  for k in n.kids:
    if k.isTree("scale"): r.choice(k, SpectrumScaleNames, d.scale)
    elif k.isTree("logFrequency"): r.flag(k, d.logFrequency)
    elif k.isTree("time"): r.choice(k, SpectrumTimeNames, d.time)
    elif k.isTree("raw"): r.flag(k, d.raw)
    elif k.isTree("processed"): r.flag(k, d.processed)
    elif k.isTree("phase"): r.flag(k, d.phase)
    else: r.unknown(k, n.tag)

proc readSettings*(doc: openArray[NifNode]; name: string; base: Settings;
    problems: var seq[string]): Settings =
  ## The settings document `doc` (`parseNif`) taken over `base`: each
  ## setting it holds replaces `base`'s, the others keep theirs. What could
  ## not be used is added to `problems`, one line each (past the first
  ## `WordedProblems`, an empty line each). Raises `NifError` when `doc` is
  ## not a settings document at all.
  var r = Reading(name: name)
  result = base
  var root = -1
  for i, n in doc:
    if n.kind == nkTree and n.tag.startsWith("."): discard # directives
    elif root < 0 and n.isTree("settings"): root = i
    else: r.unknown(n, "the document")
  if root < 0:
    var e = newException(NifError, name & " holds no (settings ...)")
    e.line = (if doc.len > 0: doc[0].line else: 0)
    raise e
  var version = 0
  for c in doc[root].kids:
    if c.kind != nkTree:
      r.unknown(c, "settings")
    else:
      case c.tag
      of "version": r.integer(c, 1, high(int32), version)
      of "theme": r.text(c, result.theme, allowEmpty = true)
      of "window": r.window(c, result.window)
      of "recentFiles": r.strings(c, result.recentFiles)
      of "recentFolders": r.strings(c, result.recentFolders)
      of "plot": r.plot(c, result.plot)
      of "scale":
        for k in c.kids:
          if k.isTree("length"): r.choice(k, LengthNames, result.scale.length)
          elif k.isTree("speed"): r.flag(k, result.scale.speed)
          else: r.unknown(k, "scale")
      of "calibrations": r.calibrations(c, result.calibrations)
      of "readout":
        var fields: seq[ReadoutField]
        for v in c.kids:
          var f = rfTime
          if r.pick(v, ReadoutNames, "readout", f) and f notin fields: fields.add f
        # None of them usable: the setting keeps its value (`(readout)` is no fields).
        if fields.len > 0 or c.kids.len == 0: result.readout = fields
      of "sortPresets": r.presets(c, result.sortPresets)
      of "customOrder": r.keys(c, 0, result.customOrder)
      of "messages":
        for k in c.kids:
          if k.isTree("autoScroll"): r.flag(k, result.messages.autoScroll)
          elif k.isTree("hide"):
            var hidden: set[Severity]
            for v in k.kids:
              var x = sevInfo
              if r.pick(v, SeverityNames, "hide", x): hidden.incl x
            result.messages.hidden = hidden
          else: r.unknown(k, "messages")
      of "cursorLine": r.flag(c, result.cursorLine)
      of "files":
        for k in c.kids:
          if k.isTree("followLatest"): r.flag(k, result.files.followLatest)
          elif k.isTree("prepareNext"): r.flag(k, result.files.prepareNext)
          else: r.unknown(k, "files")
      of "map":
        for k in c.kids:
          if k.isTree("info"): r.choice(k, MapInfoNames, result.map.info)
          elif k.isTree("lengths"): r.choice(k, MapLengthNames, result.map.lengths)
          elif k.isTree("hide"):
            var hidden: set[MapGroup]
            for v in k.kids:
              var g = mgPreplot
              if r.pick(v, MapGroupNames, "hide", g): hidden.incl g
            result.map.hiddenGroups = hidden
          elif k.isTree("templateBox"): r.flag(k, result.map.templateBox)
          elif k.isTree("folderShots"): r.flag(k, result.map.folderShots)
          elif k.isTree("filters"):
            var on: set[MapFilter]
            for v in k.kids:
              var f = mfDead
              if r.pick(v, MapFilterNames, "filters", f): on.incl f
            result.map.filters = on
          elif k.isTree("template"):
            template t: untyped = result.map.spreadTemplate
            for v in k.kids:
              if v.isTree("shape"): r.choice(v, TemplateShapeNames, t.shape)
              elif v.isTree("lines"): r.integer(v, 1, MaxTemplateLines, t.lines)
              elif v.isTree("channels"): r.integer(v, 1, MaxTemplateChannels, t.channels)
              elif v.isTree("inline"): r.number(v, 1e-6, 1e12, t.inlineHalf)
              elif v.isTree("crossline"): r.number(v, 1e-6, 1e12, t.crosslineHalf)
              else: r.unknown(v, "template")
          else: r.unknown(k, "map")
      of "join": r.join(c, result.join)
      of "headers":
        for k in c.kids:
          if k.isTree("tab"): r.choice(k, HeadersTabNames, result.headers.tab)
          elif k.isTree("traceTab"): r.choice(k, TraceTabNames, result.headers.traceTab)
          elif k.isTree("followPointer"): r.flag(k, result.headers.followPointer)
          elif k.isTree("asDisplayed"): r.flag(k, result.headers.asDisplayed)
          elif k.isTree("columns"):
            var shown: set[HeaderColumn]
            for v in k.kids:
              var x = hcDescription
              if r.pick(v, HeaderColumnNames, "columns", x): shown.incl x
            result.headers.columns = shown
          else: r.unknown(k, "headers")
      of "hideKilled": r.flag(c, result.hideKilled)
      of "spectrum":
        for k in c.kids:
          if k.isTree("window"): r.spectrumDisplay(k, result.spectrum.window)
          elif k.isTree("live"): r.spectrumDisplay(k, result.spectrum.live)
          else: r.unknown(k, "spectrum")
      of "displayPresets": r.displayPresets(c, result.displayPresets)
      else: r.unknown(c, "settings")
  if version == 0:
    r.problem(doc[root], "(settings) gives no (version); read as version " &
      $SettingsVersion & ".")
  elif version > SettingsVersion:
    r.problem(doc[root], "written by a newer viewSEG (settings version " & $version &
      "; this one reads " & $SettingsVersion & "): what it does not know is skipped.")
  problems.add r.problems

proc readSettings*(text, name: string; base: Settings; problems: var seq[string]): Settings =
  ## `readSettings` of the document in `text`. Raises `NifError` when it is
  ## not NIF, or not a settings document.
  readSettings(parseNif(text, name), name, base, problems)
