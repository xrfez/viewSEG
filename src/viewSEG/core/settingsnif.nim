## The settings as a NIF document (`core/nif`), as `settings.nif` holds
## them and Tools > Export settings writes them:
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (settings
##  (version 1)
##  (theme "everforest-dark")
##  (units metric)
##  (window (x 120) (y 80) (width 1280) (height 800) (maximized false))
##  (recentFiles "/data/shot1.sgd")
##  (recentFolders "/data")
##  (recentProjects "/jobs/Land 2026")
##  (lastProject "/jobs/Land 2026")
##  (reopenProject true)
##  (plot
##   (orientation timeDown)
##   (mode wiggle)
##   (fills positive)
##   ...
##   (order (key rcvLine) (key offset descending))
##   (header auto)
##   (seismic true)
##   (auxiliary false)
##   (templateOnly false)
##   (processing (dc none) (band bandPass) (f1 4.0) (f2 8.0) (f3 60.0) (f4 80.0)
##    (notch (on true) (hz 60.0) (width 2.0) (harmonics 3)) (aux false)))
##  (aux (mode wiggle) (fills positive negative) (gain normalized) (header auto))
##  (scale (length inch) (speed false))
##  (calibrations (monitor "DELL U2720Q 3840x2160" 163.2))
##  (readout time trace channel receiver)
##  (sortPresets (preset "Line/Station" (key rcvLine) (key rcvPoint)))
##  (customOrder (key offset))
##  (messages (autoScroll true) (hide info))
##  (cursorLine false)
##  (files (followLatest false) (prepareNext true) (listSignatureFiles false))
##  (map (info popup) (lengths survey) (hide recorded) (templateBox false) (folderShots true)
##   (filters noisy clipped)
##   (template (shape patch) (lines 8) (channels 120) (inline 1500.0) (crossline 500.0)))
##  (noise (area auto) (timeMs 100.0) (radius 500.0) (steps 8) (allLines false)
##   (templateOnly true))
##  (join (trailingDigits false) (multiComponent false) (coordinates fill)
##   (recordMatch auto) (traceMatch auto) (lineNames (line "CLT4960" 4960)))
##  (headers (tab summary) (traceTab header) (followPointer true) (asDisplayed false)
##   (columns description bytes) (tableFields "keys.record" "keys.channel")
##   (tableScope record))
##  (shotLog (followPlot false))
##  (cutGather (recordMs 10000.0))
##  (output (segyRevision same) (segdRevision same))
##  (hideKilled false)
##  (spectrum
##   (window (scale db) (logFrequency false) (time whole) (raw true) (processed true)
##    (response true) (phase false) (phasePicture unwrapped))
##   (live (scale db) (logFrequency false) (time visible) (raw true) (processed true)
##    (response true) (phase false) (phasePicture unwrapped)))
##  (plotOptions
##   (spectrogram (windowMs 128.0) (overlap 75.0) (floorDb -60.0) (colourMap viridis))
##   (phase (phaseWithinDb 20.0) (phasePicture unwrapped))
##   (correlation (maxLagMs 250.0) (phaseShow absolute))
##   (envelope (phaseAgainst reference) (phaseShow absolute))
##   (vibrator (reactionMassKg 3500.0) (harmonics 5) (limitsOn false) (limits (phaseDeg 10.0)))
##   (fk (floorDb -60.0) (colourMap viridis) (raw false)))
##  (displayPresets
##   (preset "Section" (mode density) (colourMap viridis) (gain none) ...))
##  (tray (icon true) (minimize false))
##  (componentColours (hydrophone "#2e6bb0") (vertical "#1e8a45") (inline "#b0860b")
##   (crossline "#0e8a86")))
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

import std/[math, strutils]
import analysis, breakmodel, geometry, join, log, nif, noisearea, outputrevision, panels,
  plotoptions, readout, scales, settings, tracetable, units

export nif

const
  SettingsVersion* = 1 ## the version `settingsDocument` writes
  MaxRecent* = 10      ## recent files kept, and recent folders
  MaxPresets* = 12     ## sort presets kept
  MaxText = 4096       ## the longest path or name taken

  OrientationNames: array[Orientation, string] = ["timeDown", "timeAcross"]
  BreakSizeNames: array[BreakSize, string] = ["small", "medium", "large"]
  PickBasisNames: array[PickBasis, string] = ["smoothed", "asRecorded"]
  ModeNames: array[DisplayMode, string] = ["density", "wiggle", "wiggleDensity"]
  BandNames: array[PassBand, string] = ["none", "lowCut", "highCut", "bandPass"]
  DcNames: array[DcRemoval, string] = ["none", "mean", "trend"]
  FillNames: array[WiggleFill, string] = ["positive", "negative"]
  ColourNames: array[PlotColours, string] = ["paper", "theme", "custom", "redPaper"]
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
    "unlisted", "duplicate", "auxiliary", "noPosition", "reversed", "spreadDiffers", "louder",
    "notJudged"]
  CoordinateNames: array[HeaderCoordinates, string] = ["fill", "replace"]
  RecordMatchNames: array[RecordMatch, string] = ["auto", "source", "ffid"]
  TraceMatchNames: array[TraceMatch, string] = ["auto", "station", "channel"]
  MaxLineNames = 1000  ## line names mapped to numbers, kept
  FieldNames: array[HeaderField, string] = ["rcvLine", "rcvPoint", "component", "channel",
    "channelSet", "traceId", "ffid", "srcLine", "srcPoint", "offset", "cdp", "inline", "crossline",
    "trace", "startTime", "vendor"]
  SeverityNames: array[Severity, string] = ["info", "warning", "error", "fatal"]
  HeadersTabNames: array[HeadersTab, string] = ["summary", "fileHeaders", "trace", "traceTable"]
  TableScopeNames: array[TableScope, string] = ["record", "file"]
  OutputRevisionNames: array[OutputRevision, string] = ["same", "segy0", "segy1", "segy20",
    "segy21", "segd30", "segd31"]
  TraceTabNames: array[TraceTab, string] = ["header", "data"]
  HeaderColumnNames: array[HeaderColumn, string] = ["description", "name", "bytes", "offset"]
  SpectrumScaleNames: array[SpectrumScale, string] = ["db", "linear"]
  SpectrumTimeNames: array[SpectrumTime, string] = ["whole", "visible"]
  PhasePictureNames: array[PhasePicture, string] = ["unwrapped", "magnitude", "signed",
    "delayRemoved"]
  PhaseAgainstNames: array[PhaseAgainst, string] = ["reference", "trace"]
  PhaseShowNames: array[PhaseShow, string] = ["absolute", "signed"]
  ReadoutNames: array[ReadoutField, string] = ["time", "trace", "channel", "receiver",
    "source", "ffid", "offset", "amplitude", "shotTime", "cursorUtc", "sample", "cdp",
    "inline", "crossline", "sourceXY", "receiverXY", "midpointXY", "sourceZ", "receiverZ",
    "component", "status", "rawAmplitude", "traceId", "channelSet"]

type
  Reading = object
    ## A document being taken in, and what it said that could not be used.
    name: string
    problems: seq[string]

func persistedNames*(): seq[seq[string]] =
  ## Every table of names written for a choice (for tests: each must be a
  ## NIF identifier and unique in its table).
  @[@ModeNames, @BreakSizeNames, @PickBasisNames, @BandNames, @DcNames, @FillNames, @ColourNames,
    @ColourMapNames,
    @GainNames,
    @TimeGainNames, @ScopeNames,
    @StatNames, @LengthNames, @FieldNames, @ReadoutNames, @SeverityNames, @HeadersTabNames,
    @TraceTabNames, @HeaderColumnNames, @SpectrumScaleNames, @SpectrumTimeNames,
    @PhasePictureNames, @PhaseAgainstNames, @PhaseShowNames, @TableScopeNames, @UnitNames,
    @OutputRevisionNames]

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
    if k.field == hfVendor: w.value("vendor", k.name)
    else: w.ident FieldNames[k.field]
    if k.descending: w.ident "descending"
    w.close()

const BreakSourceNames: array[BreakModelSource, string] = ["fitted", "given"]

proc writeBreakModel*(w: var NifWriter; m: BreakModel) =
  ## `m` as a `(breakModel ...)` tree (the project document keeps one too).
  w.open("breakModel")
  w.choice("source", BreakSourceNames[m.source])
  w.value("v1", m.v1)
  w.value("interceptMs", m.interceptMs)
  w.value("v2", m.v2)
  w.value("crossover", m.crossover)
  w.close()

proc writeHeader(w: var NifWriter; h: HeaderChoice) =
  ## A window's display header: `auto`, or the fields, top row first.
  w.open("header")
  if h.auto: w.ident "auto"
  else:
    for f in h.fields:
      if f.field == hfVendor: w.value("vendor", f.name)
      else: w.ident FieldNames[f.field]
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
  if d.firstBreaks: w.value("firstBreaks", true)
  if d.breakModel != BreakModel(): w.writeBreakModel(d.breakModel)
  if d.breakPickColour.a != 0: w.value("breakPickColour", colourText(d.breakPickColour))
  if d.breakModelColour.a != 0: w.value("breakModelColour", colourText(d.breakModelColour))
  if not d.breakShowPicks: w.value("breakShowPicks", false)
  if not d.breakShowModel: w.value("breakShowModel", false)
  if d.breakShowWeak: w.value("breakShowWeak", true)
  if d.breakPickOn != DisplaySettings().breakPickOn:
    w.choice("breakPickOn", PickBasisNames[d.breakPickOn])
  if d.breakSize != DisplaySettings().breakSize: w.choice("breakSize", BreakSizeNames[d.breakSize])
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
  w.value("response", d.response)
  w.value("phase", d.phase)
  w.choice("phasePicture", PhasePictureNames[d.phasePicture])
  w.close()

proc writePlotOptions(w: var NifWriter; o: PlotOptions) =
  ## The New plot windows' remembered options, a tree per kind. A mass or a
  ## limit that is not set is left out.
  w.open("plotOptions")
  w.open("spectrogram")
  w.value("windowMs", o.spectrogram.windowMs)
  w.value("overlap", o.spectrogram.overlap)
  w.value("floorDb", o.spectrogram.floorDb)
  w.choice("colourMap", ColourMapNames[o.spectrogram.colourMap])
  w.close()
  w.open("phase")
  w.value("phaseWithinDb", o.phase.phaseWithinDb)
  w.choice("phasePicture", PhasePictureNames[o.phase.phasePicture])
  w.close()
  w.open("correlation")
  w.value("maxLagMs", o.correlation.maxLagMs)
  w.choice("phaseShow", PhaseShowNames[o.correlation.phaseShow])
  w.close()
  w.open("envelope")
  w.choice("phaseAgainst", PhaseAgainstNames[o.envelope.phaseAgainst])
  w.choice("phaseShow", PhaseShowNames[o.envelope.phaseShow])
  w.close()
  w.open("vibrator")
  if not o.vibrator.reactionMassKg.isNaN: w.value("reactionMassKg", o.vibrator.reactionMassKg)
  if not o.vibrator.baseplateMassKg.isNaN: w.value("baseplateMassKg", o.vibrator.baseplateMassKg)
  w.value("harmonics", o.vibrator.harmonics)
  w.choice("phaseShow", PhaseShowNames[o.vibrator.phaseShow])
  w.value("projectReference", o.vibrator.projectReference)
  w.value("rolesOpen", o.vibrator.rolesOpen)
  w.value("noteOpen", o.vibrator.noteOpen)
  w.value("details", o.vibrator.details)
  if o.vibrator.setupSet: w.value("setupOpen", o.vibrator.setupOpen)
  w.value("qcWindowMs", o.vibrator.qcWindowMs)
  w.open("qc")
  for name, x in fieldPairs(o.vibrator.qc):
    if not x.isNaN: w.value(name, x)
  w.close()
  if not o.vibrator.targetPct.isNaN: w.value("targetPct", o.vibrator.targetPct)
  if not o.vibrator.forceHundredPct.isNaN: w.value("forceHundredPct",
      o.vibrator.forceHundredPct)
  if not o.vibrator.forceHundredWeighted.isNaN:
    w.value("forceHundredWeighted", o.vibrator.forceHundredWeighted)
  w.value("forceHundredScoped", true)
  w.open("tops")
  for t in o.vibrator.tops:
    w.open("top")
    w.add t.reference
    w.add t.hz
    w.close()
  w.close()
  w.close()
  w.open("fk")
  w.value("floorDb", o.fk.floorDb)
  w.choice("colourMap", ColourMapNames[o.fk.colourMap])
  w.value("raw", o.fk.raw)
  w.close()
  w.close()

proc writeJoinOptions*(w: var NifWriter; j: JoinOptions) =
  ## The survey import's options in a `(join ...)` tree, as the settings
  ## file holds them (a project keeps its import's the same way).
  w.open("join")
  w.value("trailingDigits", j.trailingDigits)
  w.value("multiComponent", j.multiComponent)
  w.choice("coordinates", CoordinateNames[j.coordinates])
  w.choice("recordMatch", RecordMatchNames[j.recordMatch])
  w.choice("traceMatch", TraceMatchNames[j.traceMatch])
  w.open("lineNames")
  for n in j.lineNames:
    w.open("line")
    w.add n.name
    w.add n.line
    w.close()
  w.close()
  w.close()

proc writeDisplayPresets*(w: var NifWriter; presets: openArray[DisplayPreset]) =
  ## Named displays in a `(displayPresets ...)` tree, as the settings file
  ## holds them (a project keeps its own the same way).
  w.open("displayPresets")
  for p in presets:
    w.open("preset")
    w.add p.name
    w.display(p.display, turned = false)
    w.close()
  w.close()

proc settingsDocument*(s: Settings): string =
  ## `s` as a NIF document, every setting written (a calibration or a
  ## float that is not finite is not: `cleaned` drops them first).
  var w = initNifWriter()
  w.open("settings")
  w.value("version", SettingsVersion)
  w.value("theme", s.theme)
  w.choice("units", UnitNames[s.units])
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
  w.open("recentProjects")
  for f in s.recentProjects: w.add f
  w.close()
  w.value("lastProject", s.lastProject)
  w.value("reopenProject", s.reopenProject)
  w.value("referenceId", s.referenceId)
  if s.vibRoles.len > 0:
    w.open("vibRoles")
    for c in s.vibRoles: w.add c
    w.close()
  w.open("plot")
  w.display(s.plot.display)
  w.value("seismic", s.plot.seismic)
  w.value("auxiliary", s.plot.auxiliary)
  w.value("templateOnly", s.plot.templateOnly)
  w.open("order")
  w.keys(s.plot.order)
  w.close()
  w.writeHeader(s.plot.header)
  w.writeProcessing(s.plot.processing)
  w.close()
  w.open("aux")
  w.display(s.aux.display)
  w.writeHeader(s.aux.header)
  w.close()
  if not (s.forceScale.datCountsPerLbf.isNaN and s.forceScale.vibAccMvPerCount.isNaN):
    w.open("forceScale")
    if not s.forceScale.datCountsPerLbf.isNaN:
      w.value("datCountsPerLbf", s.forceScale.datCountsPerLbf)
    if not s.forceScale.vibAccMvPerCount.isNaN:
      w.value("vibAccMvPerCount", s.forceScale.vibAccMvPerCount)
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
  if s.files.subfolders: w.value("subfolders", true)
  w.value("prepareNext", s.files.prepareNext)
  if not s.files.listSignatureFiles: w.value("listSignatureFiles", false)
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
  w.open("noise")
  w.choice("area", NoiseChoiceNames[s.noise.choice])
  w.value("timeMs", s.noise.edgeMs)
  w.value("radius", s.noise.radius)
  w.value("steps", s.noise.steps)
  w.value("allLines", s.noise.allLines)
  w.value("templateOnly", s.noise.templateOnly)
  w.close()
  w.writeJoinOptions(s.join)
  w.open("headers")
  w.choice("tab", HeadersTabNames[s.headers.tab])
  w.choice("traceTab", TraceTabNames[s.headers.traceTab])
  w.value("followPointer", s.headers.followPointer)
  w.value("asDisplayed", s.headers.asDisplayed)
  w.open("columns")
  for c in s.headers.columns: w.ident HeaderColumnNames[c]
  w.close()
  w.open("tableFields")
  for f in s.headers.tableFields: w.add f
  w.close()
  w.choice("tableScope", TableScopeNames[s.headers.tableScope])
  w.close()
  w.open("shotLog")
  w.value("followPlot", s.shotLog.followPlot)
  w.close()
  w.open("cutGather")
  w.value("recordMs", s.cutGather.recordMs)
  w.close()
  w.open("output")
  w.choice("segyRevision", OutputRevisionNames[s.output.segyRevision])
  w.choice("segdRevision", OutputRevisionNames[s.output.segdRevision])
  w.close()
  w.value("hideKilled", s.hideKilled)
  w.open("spectrum")
  w.spectrumDisplay("window", s.spectrum.window)
  w.spectrumDisplay("live", s.spectrum.live)
  w.close()
  w.writePlotOptions(s.plotOptions)
  w.writeDisplayPresets(s.displayPresets)
  w.open("tray")
  w.value("icon", s.tray.icon)
  w.value("minimize", s.tray.minimize)
  w.close()
  w.open("componentColours")
  const colourNames = ["hydrophone", "vertical", "inline", "crossline"]
  for i, c in s.componentColours: w.value(colourNames[i], colourText(c))
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
  var shown: seq[string]
  for e, name in names:
    when T is HeaderField:
      if e == hfVendor: continue # (a vendor line is written `(vendor "name")`)
    shown.add name
  r.unusable(v, tag, "one of " & shown.join(", "))

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
  ## The `(key field [descending])` nodes of `n` from kid `first` on, a vendor
  ## field written `(key (vendor "name") [descending])`: a field given twice
  ## counts once, as its first.
  var got: seq[SortKey]
  if n.kids.len - first > MaxSortKeys:
    r.unusable(n, n.tag, "at most " & $MaxSortKeys & " keys")
    return
  for i in first ..< n.kids.len:
    let k = n.kids[i]
    var key = SortKey()
    var ok = false
    if not k.isTree("key") or k.kids.len notin 1..2:
      r.unusable(k, n.tag, "(key field) or (key field descending)")
    elif k.kids[0].isTree("vendor"):
      # a name no vendor map defines is kept: it sorts as all absent
      var name = ""
      r.text(k.kids[0], name)
      if name.len > 0 and not usableLineName(name):
        r.unusable(k.kids[0], "vendor", "a name of 1 to 200 characters")
      elif name.len > 0:
        key = vendorKey(name)
        ok = true
    elif r.pick(k.kids[0], FieldNames, "key", key.field) and key.field == hfVendor:
      r.unusable(k.kids[0], "key", "a built-in field, or (vendor \"name\") for a vendor field")
    elif r.pick(k.kids[0], FieldNames, "key", key.field):
      ok = true
    if ok:
      if k.kids.len == 2:
        if k.kids[1].kind == nkIdent and k.kids[1].text in ["ascending", "descending"]:
          key.descending = k.kids[1].text == "descending"
        else:
          r.unusable(k.kids[1], "key", "ascending or descending")
      var seen = false
      for g in got:
        if g.sameField(key): seen = true
      if not seen: got.add key
  x = got

proc strings(r: var Reading; n: NifNode; x: var seq[string]) =
  ## `(tag "..." ...)`: the usable strings, each once, at most `MaxRecent`.
  var got: seq[string]
  for v in n.kids:
    if v.kind != nkString or not usableText(v.text): r.unusable(v, n.tag, "strings")
    elif v.text notin got and got.len < MaxRecent: got.add v.text
  x = got

proc breakModel(r: var Reading; n: NifNode; m: var BreakModel) =
  for c in n.kids:
    if c.kind != nkTree: r.unknown(c, "breakModel")
    else:
      case c.tag
      of "source": r.choice(c, BreakSourceNames, m.source)
      of "v1": r.number(c, 0, MaxBreakVelocity, m.v1)
      of "interceptMs": r.number(c, -MaxBreakIntercept, MaxBreakIntercept, m.interceptMs)
      of "v2": r.number(c, 0, MaxBreakVelocity, m.v2)
      of "crossover": r.number(c, 0, MaxBreakCrossover, m.crossover)
      else: r.unknown(c, "breakModel")
  m = m.bounded

proc readBreakModel*(n: NifNode; name: string; base: BreakModel;
    problems: var seq[string]): BreakModel =
  ## The model a `(breakModel ...)` tree written by `writeBreakModel` holds, over `base`.
  var r = Reading(name: name)
  result = base
  r.breakModel(n, result)
  problems.add r.problems

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
      of "firstBreaks": r.flag(c, d.firstBreaks)
      of "breakModel": r.breakModel(c, d.breakModel)
      of "breakPickColour": r.colour(c, d.breakPickColour)
      of "breakModelColour": r.colour(c, d.breakModelColour)
      of "breakShowPicks": r.flag(c, d.breakShowPicks)
      of "breakShowModel": r.flag(c, d.breakShowModel)
      of "breakShowWeak": r.flag(c, d.breakShowWeak)
      of "breakPickOn": r.choice(c, PickBasisNames, d.breakPickOn)
      of "breakSize": r.choice(c, BreakSizeNames, d.breakSize)
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

proc header(r: var Reading; c: NifNode; h: var HeaderChoice) =
  if c.kids.len == 1 and c.kids[0].kind == nkIdent and c.kids[0].text == "auto":
    h = HeaderChoice(auto: true)
  else:
    var fields: seq[HeaderRef]
    for v in c.kids:
      if v.isTree("vendor"):
        # a name no vendor map defines is kept: the line shows it as unknown
        var name = ""
        r.text(v, name)
        if name.len > 0 and not usableLineName(name):
          r.unusable(v, "vendor", "a name of 1 to 200 characters")
        elif name.len > 0 and vendorRef(name) notin fields:
          if fields.len >= MaxHeaderLines: r.unusable(v, "header", "at most " & $MaxHeaderLines & " lines")
          else: fields.add vendorRef(name)
        continue
      var f = hfTrace
      if r.pick(v, FieldNames, "header", f):
        if f == hfVendor: r.unusable(v, "header", "(vendor \"name\") for a vendor field")
        elif headerRef(f) notin fields:
          if fields.len >= MaxHeaderLines: r.unusable(v, "header", "at most " & $MaxHeaderLines & " lines")
          else: fields.add headerRef(f)
    if fields.len > 0: h = HeaderChoice(auto: false, fields: fields)
    else: r.unusable(c, "header", "auto, or the fields to show")

proc plot(r: var Reading; n: NifNode; p: var PlotDefaults) =
  var rest = NifNode(kind: nkTree, line: n.line, tag: n.tag)
  for c in n.kids:
    if c.isTree("processing"): r.readTree(c, p.processing)
    elif c.isTree("seismic"): r.flag(c, p.seismic)
    elif c.isTree("auxiliary"): r.flag(c, p.auxiliary)
    elif c.isTree("templateOnly"): r.flag(c, p.templateOnly)
    elif c.isTree("order"): r.keys(c, 0, p.order)
    elif c.isTree("header"): r.header(c, p.header)
    else: rest.kids.add c
  r.display(rest, p.display)

proc aux(r: var Reading; n: NifNode; p: var AuxDefaults) =
  var rest = NifNode(kind: nkTree, line: n.line, tag: n.tag)
  for c in n.kids:
    if c.isTree("header"): r.header(c, p.header)
    else: rest.kids.add c
  r.display(rest, p.display)
  p.display = forAux(remembered(p.display))

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
  ## is not one, or whose name is taken, is left out and said, as are those
  ## past `MaxDisplayPresets`.
  var got: seq[DisplayPreset]
  var over = 0
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
        inc over
    else:
      r.unusable(c, "displayPresets", "(preset \"name\" (mode ...) ...)")
  if over > 0:
    r.problem(n, "at most " & $MaxDisplayPresets & " display presets are kept; the " &
      $over & " after the " & $MaxDisplayPresets & "th are left out.")
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
    elif k.isTree("response"): r.flag(k, d.response)
    elif k.isTree("phase"): r.flag(k, d.phase)
    elif k.isTree("phasePicture"): r.choice(k, PhasePictureNames, d.phasePicture)
    else: r.unknown(k, n.tag)

proc ranged(r: var Reading; n: NifNode; range: SettingRange; x: var float64) =
  ## `(tag v)`: `x` = v when `range` allows it.
  var v = NaN
  r.number(n, -Inf, Inf, v)
  if v.isNaN: return # not a number: said already
  if range.allows(v): x = v
  else: r.unusable(n.kids[0], n.tag, "a number " & range.words)

proc plotOptions(r: var Reading; n: NifNode; o: var PlotOptions) =
  for k in n.kids:
    if k.isTree("spectrogram"):
      for c in k.kids:
        if c.isTree("windowMs"): r.ranged(c, WindowMsRange, o.spectrogram.windowMs)
        elif c.isTree("overlap"): r.ranged(c, OverlapRange, o.spectrogram.overlap)
        elif c.isTree("floorDb"): r.ranged(c, FloorDbRange, o.spectrogram.floorDb)
        elif c.isTree("colourMap"): r.choice(c, ColourMapNames, o.spectrogram.colourMap)
        else: r.unknown(c, "spectrogram")
    elif k.isTree("phase"):
      for c in k.kids:
        if c.isTree("phaseWithinDb"): r.ranged(c, PhaseWithinRange, o.phase.phaseWithinDb)
        elif c.isTree("phasePicture"): r.choice(c, PhasePictureNames, o.phase.phasePicture)
        else: r.unknown(c, "phase")
    elif k.isTree("correlation"):
      for c in k.kids:
        if c.isTree("maxLagMs"): r.ranged(c, LagMsRange, o.correlation.maxLagMs)
        elif c.isTree("phaseShow"): r.choice(c, PhaseShowNames, o.correlation.phaseShow)
        else: r.unknown(c, "correlation")
    elif k.isTree("envelope"):
      for c in k.kids:
        if c.isTree("phaseAgainst"): r.choice(c, PhaseAgainstNames, o.envelope.phaseAgainst)
        elif c.isTree("phaseShow"): r.choice(c, PhaseShowNames, o.envelope.phaseShow)
        else: r.unknown(c, "envelope")
    elif k.isTree("vibrator"):
      var scoped = false # the 100 % force is kept per judged signal (older files: one value)
      for c in k.kids:
        if c.isTree("reactionMassKg"): r.ranged(c, MassKgRange, o.vibrator.reactionMassKg)
        elif c.isTree("baseplateMassKg"): r.ranged(c, MassKgRange, o.vibrator.baseplateMassKg)
        elif c.isTree("harmonics"):
          var h = o.vibrator.harmonics
          r.integer(c, int(HarmonicRange.lo), int(HarmonicRange.hi), h)
          o.vibrator.harmonics = h
        elif c.isTree("phaseShow"): r.choice(c, PhaseShowNames, o.vibrator.phaseShow)
        elif c.isTree("projectReference"): r.flag(c, o.vibrator.projectReference)
        elif c.isTree("limitsOn") or c.isTree("limits"):
          discard # the point limits are gone: an older file's are read and left out
        elif c.isTree("rolesOpen"): r.flag(c, o.vibrator.rolesOpen)
        elif c.isTree("noteOpen"): r.flag(c, o.vibrator.noteOpen)
        elif c.isTree("details"): r.flag(c, o.vibrator.details)
        elif c.isTree("setupOpen"):
          r.flag(c, o.vibrator.setupOpen)
          o.vibrator.setupSet = true
        elif c.isTree("qcWindowMs"): r.ranged(c, WindowMsRange,
            o.vibrator.qcWindowMs)
        elif c.isTree("targetPct"): r.ranged(c, TargetPctRange, o.vibrator.targetPct)
        elif c.isTree("forceHundredPct"): r.ranged(c, MassKgRange,
            o.vibrator.forceHundredPct)
        elif c.isTree("forceHundredWeighted"): r.ranged(c, MassKgRange,
            o.vibrator.forceHundredWeighted)
        elif c.isTree("forceHundredScoped"): scoped = true
        elif c.isTree("qc"):
          # a limit written is on; one left out is off
          o.vibrator.qc = QcLimits(avgPhaseDeg: NaN, peakPhaseDeg: NaN,
            avgDistortionPct: NaN,
            peakDistortionPct: NaN, avgForcePct: NaN, peakForcePct: NaN)
          for l in c.kids:
            var known = false
            for name, x in fieldPairs(o.vibrator.qc):
              if l.isTree(name):
                known = true
                r.ranged(l, NumberRange, x)
            if not known: r.unknown(l, "qc")
        elif c.isTree("tops"):
          var got: seq[TopFrequency] = @[]
          for t in c.kids:
            let shaped = t.isTree("top") and t.kids.len == 2
            let named = shaped and t.kids[0].kind == nkString and usableText(t.kids[0].text)
            if named and t.kids[1].kind in {nkFloat, nkInt}:
              let hz = if t.kids[1].kind == nkFloat: t.kids[1].floatVal
                       else: float64(t.kids[1].intVal)
              if t.kids[0].text == RecordedKey: discard # kept per file layout since: dropped
              elif TopHzRange.allows(hz): got = got.withTop(t.kids[0].text, hz)
              else: r.unusable(t.kids[1], "top", "a number " & TopHzRange.words)
            else: r.unusable(t, "tops", "(top \"reference\" hertz)")
          o.vibrator.tops = got
        else: r.unknown(c, "vibrator")
      if not scoped and not o.vibrator.forceHundredPct.isNaN and
          o.vibrator.reactionMassKg > 0 and o.vibrator.baseplateMassKg > 0:
        # the one value of an older file belongs to the signal judged then: with the masses
        # typed that was GF (M, B) (the recorded GF is judged alone only without them)
        (o.vibrator.forceHundredWeighted, o.vibrator.forceHundredPct) = (
          o.vibrator.forceHundredPct, NaN)
    elif k.isTree("fk"):
      for c in k.kids:
        if c.isTree("floorDb"): r.ranged(c, FloorDbRange, o.fk.floorDb)
        elif c.isTree("colourMap"): r.choice(c, ColourMapNames, o.fk.colourMap)
        elif c.isTree("raw"): r.flag(c, o.fk.raw)
        else: r.unknown(c, "fk")
    else: r.unknown(k, "plotOptions")

proc readJoinOptions*(n: NifNode; name: string; base: JoinOptions;
    problems: var seq[string]): JoinOptions =
  ## The options a `(join ...)` tree written by `writeJoinOptions` holds,
  ## over `base`; what cannot be used is said in `problems`.
  var r = Reading(name: name)
  result = base
  r.join(n, result)
  problems.add r.problems

proc readDisplayPresets*(n: NifNode; name: string; problems: var seq[string]):
    seq[DisplayPreset] =
  ## The presets a `(displayPresets ...)` tree written by
  ## `writeDisplayPresets` holds; what cannot be used is said in `problems`.
  var r = Reading(name: name)
  result = @[]
  r.displayPresets(n, result)
  problems.add r.problems

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
      of "units": r.choice(c, UnitNames, result.units)
      of "window": r.window(c, result.window)
      of "recentFiles": r.strings(c, result.recentFiles)
      of "recentFolders": r.strings(c, result.recentFolders)
      of "recentProjects": r.strings(c, result.recentProjects)
      of "lastProject": r.text(c, result.lastProject, allowEmpty = true)
      of "reopenProject": r.flag(c, result.reopenProject)
      of "referenceId": r.text(c, result.referenceId, allowEmpty = true)
      of "vibRoles": r.strings(c, result.vibRoles)
      of "forceScale":
        for k in c.kids:
          if k.isTree("datCountsPerLbf"):
            r.ranged(k, ForceScaleRange, result.forceScale.datCountsPerLbf)
          elif k.isTree("vibAccMvPerCount"):
            r.ranged(k, ForceScaleRange, result.forceScale.vibAccMvPerCount)
          else: r.unknown(k, "forceScale")
      of "plot": r.plot(c, result.plot)
      of "aux": r.aux(c, result.aux)
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
          elif k.isTree("subfolders"): r.flag(k, result.files.subfolders)
          elif k.isTree("prepareNext"): r.flag(k, result.files.prepareNext)
          elif k.isTree("listSignatureFiles"): r.flag(k, result.files.listSignatureFiles)
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
      of "noise":
        for k in c.kids:
          if k.isTree("area"): r.choice(k, NoiseChoiceNames, result.noise.choice)
          elif k.isTree("timeMs"): r.number(k, 1e-3, 1e9, result.noise.edgeMs)
          elif k.isTree("radius"): r.number(k, 1e-6, 1e12, result.noise.radius)
          elif k.isTree("steps"): r.integer(k, 0, MaxStations, result.noise.steps)
          elif k.isTree("allLines"): r.flag(k, result.noise.allLines)
          elif k.isTree("templateOnly"): r.flag(k, result.noise.templateOnly)
          else: r.unknown(k, "noise")
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
          elif k.isTree("tableFields"):
            var got: seq[string]
            for v in k.kids:
              if v.kind != nkString or not usableText(v.text) or v.text.len > 200:
                r.unusable(v, k.tag, "strings")
              elif v.text notin got and got.len < MaxTableColumns: got.add v.text
            result.headers.tableFields = got
          elif k.isTree("tableScope"): r.choice(k, TableScopeNames, result.headers.tableScope)
          else: r.unknown(k, "headers")
      of "shotLog":
        for k in c.kids:
          if k.isTree("followPlot"): r.flag(k, result.shotLog.followPlot)
          else: r.unknown(k, "shotLog")
      of "cutGather":
        for k in c.kids:
          if k.isTree("recordMs"): r.number(k, MinRecordMs, MaxRecordMs,
            result.cutGather.recordMs)
          else: r.unknown(k, "cutGather")
      of "output":
        for k in c.kids:
          if k.isTree("segyRevision"):
            r.choice(k, OutputRevisionNames, result.output.segyRevision)
          elif k.isTree("segdRevision"):
            r.choice(k, OutputRevisionNames, result.output.segdRevision)
          elif k.isTree("revision"):
            # the one word an earlier file held: it goes to the standard it names
            var old = orSame
            r.choice(k, OutputRevisionNames, old)
            if old.isSegy: result.output.segyRevision = old
            elif old.isSegd: result.output.segdRevision = old
          else: r.unknown(k, "output")
      of "hideKilled": r.flag(c, result.hideKilled)
      of "spectrum":
        for k in c.kids:
          if k.isTree("window"): r.spectrumDisplay(k, result.spectrum.window)
          elif k.isTree("live"): r.spectrumDisplay(k, result.spectrum.live)
          else: r.unknown(k, "spectrum")
      of "plotOptions": r.plotOptions(c, result.plotOptions)
      of "displayPresets": r.displayPresets(c, result.displayPresets)
      of "tray":
        for k in c.kids:
          if k.isTree("icon"): r.flag(k, result.tray.icon)
          elif k.isTree("minimize"): r.flag(k, result.tray.minimize)
          else: r.unknown(k, "tray")
      of "componentColours":
        const colourNames = ["hydrophone", "vertical", "inline", "crossline"]
        for k in c.kids:
          var i = -1
          for n, name in colourNames:
            if k.isTree(name): i = n
          if i >= 0: r.colour(k, result.componentColours[i])
          else: r.unknown(k, "componentColours")
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
