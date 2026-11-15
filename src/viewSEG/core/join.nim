## The geometry join behind File > Import > Survey (the user imports a
## survey; parseSEG and this code call it a join): survey files joined to an
## open seismic file's trace keys, so that traces whose headers give
## stations only (or record and channel numbers only) get their sources'
## and receivers' coordinates. **In memory only:** the file is never
## changed; what the join gives lives in the keys parseSEG holds
## (`applySurvey`, `applyGeometry`), and goes when the file is closed.
##
## What can be joined (`JoinFile`):
##
## - **SPS** S, R and X (or O) files, read with parseSEG (`addSps`): the
##   stations' coordinates, and the relations that give a trace without
##   stations its stations from its record and channel (`joinStations`);
## - **SEG P1** files (`addP1`): shotpoints, as sources;
## - **a CSV table** of stations (`addCsv`): a line, a point, an easting and
##   a northing per row (and an index and an elevation where given), with a
##   column saying which are sources and which receivers, or one role for
##   the whole table; joined by station (`applyGeometry`).
##
## The options (`JoinOptions`) are parseSEG's: a map of line names to
## numbers (`mapLine`), the trailing digits of line names that are not
## numbers (`trailingDigits`), several channels per station
## (`multiComponent`); and whether the coordinates the headers give are kept
## or replaced. Coordinates at (0, 0) are a header left empty: when every
## coordinate the headers give is (0, 0), they are replaced whatever the
## option says.
##
## Before anything changes, the join is worked out on copies of the keys
## (`planJoin`): how each trace was matched, which stations the survey has,
## how far the headers' coordinates are from the survey's, and which traces
## stay unmatched (`JoinPlan`); `planWords` says it in plain words, and
## `whyUnmatched` why a join matches nothing (the line numbering, text line
## names, record numbers not in the relation file). The plan is what the
## join then does, trace for trace.
##
## Units are labels: nothing is converted. `SurveyUnit` names them as the
## headers give them (SPS H20 and H201, the seismic file's own) and as the
## user confirms them.

import std/[algorithm, math, os, strutils, tables]
import parseSEG
import processSEG/qc/record
import session, survey

export RecordMatch, TraceMatch

type
  JoinFileKind* = enum
    jkSps = "SPS"
    jkP1 = "SEG P1"
    jkCsv = "CSV table"

  CsvRole* = enum
    ## Which stations the rows of a CSV table are.
    crColumn = "as its kind column says"
    crSources = "sources"
    crReceivers = "receivers"

  JoinFile* = object
    ## A survey file to join.
    path*: string
    kind*: JoinFileKind
    role*: CsvRole ## CSV: which stations its rows are

  HeaderCoordinates* = enum
    ## What the join does with the coordinates the headers give.
    hcFill = "fill those the headers lack"
    hcReplace = "replace those the headers give"

  LineName* = object
    ## A text line name and the line number it stands for (`mapLine`).
    name*: string
    line*: float64

  JoinOptions* = object
    ## How survey files are joined; every default works for SPS 2.1.
    trailingDigits*: bool
      ## a line name that is not a number (SPS 1.0, P1) is the number its
      ## trailing digits make: CLT4960 is line 4960
    multiComponent*: bool
      ## an X record's channel increment k covers k channels per station
      ## (components 1 .. k); else only every k-th channel is in it
    lineNames*: seq[LineName]
      ## line names mapped to numbers, before the trailing digits
    coordinates*: HeaderCoordinates
    recordMatch*: RecordMatch
      ## the records' check against the relation records: how a record
      ## finds its X record
    traceMatch*: TraceMatch
      ## and how its traces find their channels

  SurveyUnit* = enum
    ## The unit of coordinates, as the headers give it or the user confirms it.
    suNotGiven = "not given"
    suMetres = "metres"
    suFeet = "feet"
    suUsFeet = "US survey feet"
    suDegrees = "degrees"
    suArcSeconds = "arc seconds"
    suDms = "degrees, minutes and seconds"

  JoinUnits* = object
    ## The units of a join's coordinates: as the user chose them, or what
    ## the headers say, worked out by the import from the files it reads
    ## (`...FromHeaders`: never a guess made before they were read).
    survey*: SurveyUnit ## the survey files': the coordinates the join gives
    file*: SurveyUnit ## the seismic file's own: the coordinates its headers give
    surveyFromHeaders*: bool
      ## `survey` is what the survey files' headers say (`surveyUnitsSaid`),
      ## not the user's: the import works it out as it reads them
    fileFromHeaders*: bool
      ## `file` is what the file's headers say, following the survey's where
      ## they say nothing or only feet (`fileUnitOf`), not the user's

  HeadUnit* = object
    ## What a survey file's headers say of its coordinates' unit.
    unit*: SurveyUnit
    said*: string
      ## what they say, as written: "\"feet\" (H20), 0.3048006096 m a unit
      ## (H201)"; "" when they say nothing of it
    warning*: string
      ## what in them contradicts itself (H20's name against H201's factor),
      ## in words; "" when nothing does

  SurveyHead* = object
    ## What one survey file's headers say, as read for the import's window.
    file*: JoinFile
    done*: bool      ## read (or failed); false while its job runs
    head*: HeadUnit
    problem*: string ## why it could not be read, in plain words; "" when it was

  Extent* = object
    ## The smallest and largest of some numbers; empty while `lo > hi`.
    lo*: float64 = Inf
    hi*: float64 = -Inf

  JoinSurvey* = object
    ## What the survey files gave the join.
    files*: seq[string]
      ## their names, in the order read
    stations*: array[PointRole, int]
      ## with coordinates
    relations*: int
      ## relation records (X and O) kept
    records*: Extent
      ## the field records they describe
    lines*, points*: array[PointRole, Extent]
      ## the stations' lines and points
    unresolved*: seq[string]
      ## line names that are not numbers and have no mapping (the first few)
    unresolvedRecords*: int
      ## records passed by for them
    gridUnit*: GridUnit
      ## the unit the first SPS file that says gives
    notes*: seq[string]
      ## what the SPS headers say of the datum, the projection and the units
      ## (H12 to H201), each once, as written
    csvRows*: int
      ## rows taken from CSV tables
    csvSkipped*: int
      ## rows of CSV tables that could not be used
    heads*: seq[SurveyHead]
      ## what each file's headers say of its unit, as the join read them

  JoinPlan* = object
    ## What a join does to a file's traces, worked out on copies of their keys.
    traces*, seismic*: int
    matches*: array[JoinMatch, int]
      ## how each trace's stations were found (`joinStations`)
    found*: array[PointRole, int]
      ## seismic traces whose station the survey has
    matched*: int
      ## seismic traces whose source and receiver it has both
    matchedBy*: array[JoinMatch, int]
      ## of those, how their stations were found
    given*: array[PointRole, int]
      ## seismic traces with coordinates in their headers, not (0, 0)
    zero*: array[PointRole, int]
      ## at (0, 0) in their headers
    zeroKept*: array[PointRole, int]
      ## of those, the traces that keep their (0, 0) though the survey has
      ## their station (the headers' coordinates are kept, and others are real)
    replace*: bool
      ## the join replaces the coordinates the headers give
    changes*: int
      ## traces whose keys it changes
    differ*: array[PointRole, float64]
      ## the farthest a header's coordinates are from the survey's; NaN: none compared
    unplaced*: array[PointRole, int]
      ## seismic traces left without coordinates (or at (0, 0))
    unmatched*: seq[int]
      ## the seismic traces whose source or receiver the survey lacks (their
      ## index in the file)
    headerStations*: array[PointRole, int]
      ## seismic traces whose header names the station
    headerLines*, headerPoints*: array[PointRole, Extent]
      ## the lines and points the headers name
    headerRecords*: Extent
      ## the field record numbers the headers give

func incl*(s: var Extent; x: float64) {.inline.} =
  if not x.isNaN:
    s.lo = min(s.lo, x)
    s.hi = max(s.hi, x)

func isEmpty*(s: Extent): bool {.inline.} = s.lo > s.hi

func `$`*(s: Extent): string =
  ## "100" or "100 to 236".
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)
  if s.isEmpty: "none"
  elif s.lo == s.hi: num(s.lo)
  else: num(s.lo) & " to " & num(s.hi)

func overlaps(a, b: Extent): bool {.inline.} =
  not (a.isEmpty or b.isEmpty) and a.lo <= b.hi and b.lo <= a.hi

# ----------------------------------------------------------------- units --

func abbreviation*(u: SurveyUnit): string =
  ## How the status bar and the map write the unit: "m", "ft", "ftUS"; ""
  ## when not given.
  const words: array[SurveyUnit, string] = ["", "m", "ft", "ftUS", "°", "″", "DMS"]
  words[u]

func metresPerUnit*(u: SurveyUnit): float64 =
  ## How many metres one unit of `u` is, exactly (1 ft = 0.3048 m; 1 ftUS =
  ## 1200/3937 m); NaN for a unit that is not a length, or not given.
  case u
  of suMetres: 1.0
  of suFeet: 0.3048
  of suUsFeet: 1200 / 3937
  else: NaN

func unitNamed*(name: string): SurveyUnit =
  ## The unit a name says, as files and CRS texts write it: any case, its
  ## dots and apostrophes left out ("U.S." is "US"), other punctuation and
  ## brackets as blanks, so that "U.S. Survey Foot", "Feet (US Survey)",
  ## "US Survey Feet (ftUS)", "Meters (m)", "Intl feet" and "foot_us" read
  ## as they say. Its words are a metre (m, metre, meter, mtr, plurals), a
  ## foot (ft, foot, feet), US or survey, international (intl), a degree,
  ## and blank words such as "grid units"; a foot with US or survey is the
  ## US survey foot, without it the international foot. A name with any
  ## other word ("Clarke's foot", "Indian foot", "kilometre") or with words
  ## that disagree names no unit known.
  var text = ""
  for c in name.toLowerAscii:
    if c in {'.', '\''}: discard
    elif c in {'a' .. 'z', '0' .. '9'}: text.add c
    else: text.add ' '
  var metre, foot, us, intl, degree, other = false
  for w in text.splitWhitespace:
    case w
    of "m", "meter", "meters", "metre", "metres", "mtr", "mtrs": metre = true
    of "ft", "foot", "feet": foot = true
    of "ftus", "usft": (foot, us) = (true, true)
    of "us", "usa", "survey", "american": us = true
    of "international", "intl", "intnl", "int", "iso": intl = true
    of "deg", "degs", "degree", "degrees": degree = true
    of "grid", "unit", "units", "linear", "length", "in", "of", "the": discard
    else: other = true
  if other or metre and (foot or degree) or foot and degree or us and intl: suNotGiven
  elif foot: (if us: suUsFeet else: suFeet)
  elif metre and not (us or intl): suMetres
  elif degree and not (us or intl): suDegrees
  else: suNotGiven

func unitOf*(g: GridUnit): SurveyUnit =
  ## The unit an SPS header gives (H201's factor to metres, else H20's word,
  ## `unitNamed`). Files round the factor (0.3048006, 0.304801): it names
  ## the foot it is nearest, international (0.3048) or US survey (1200/3937,
  ## 2 parts in a million more), when it is within 1e-5 of either.
  if g.metres > 0:
    if abs(g.metres - 1) <= 1e-6: return suMetres
    let (ft, us) = (abs(g.metres - 0.3048), abs(g.metres - 1200 / 3937))
    if min(ft, us) <= 1e-5: return (if us < ft: suUsFeet else: suFeet)
  unitNamed(g.name)

func unitOf*(c: CoordinateUnits): SurveyUnit =
  ## The unit a seismic file's headers give its coordinates in.
  case c
  of cuMeters: suMetres
  of cuFeet: suFeet
  of cuDegrees: suDegrees
  of cuArcSeconds: suArcSeconds
  of cuDms: suDms
  of cuUnknown, cuLength: suNotGiven

func describe*(g: GridUnit): string =
  ## What an SPS header says of its grid units, in words; "" when nothing.
  var parts: seq[string]
  if g.name.strip.len > 0: parts.add "\"" & g.name.strip & "\" (H20)"
  if g.metres > 0: parts.add $g.metres & " m a unit (H201)"
  parts.join(", ")

func headerUnitOf*(c: FileCrs): SurveyUnit =
  ## The unit a seismic file's headers give its coordinates in: SEG-Y's
  ## measurement system or a coordinate unit (`summary.coordinateUnits`),
  ## made exact by the unit of length its CRS names (`lengthUnit`: "feet"
  ## and a CRS in US survey feet are US survey feet); the CRS's unit when
  ## nothing else says.
  let named = unitNamed(c.lengthUnit)
  result = unitOf(c.units)
  if result == suNotGiven or result == suFeet and named == suUsFeet: result = named

# ------------------------------------------------ the import's units --
# What each survey file's headers say of its coordinates' unit is read as
# soon as the file is chosen, from its first `HeadBytes` only (`headUnitOf`,
# on a job: the file may be on a network drive); the survey's unit is the
# first file's that says (`surveyUnitsSaid`), and the seismic file's follows
# it where its own headers say nothing or only "feet" (`fileUnitOf`). What
# the user chooses by hand is kept apart (`ImportUnits`), and no later
# derivation replaces it.

const HeadBytes* = 64 * 1024
  ## the bytes at the start of a survey file read for what its headers say

type
  SurveyUnitsSaid* = object
    ## The survey's unit as its files' headers say it.
    unit*: SurveyUnit
      ## the first file's that says; not given when none does
    words*: seq[string]
      ## what they say, a sentence a kind of file: "The SPS headers say ..."
    disagree*: string
      ## the files that give other units, named, with theirs; "" when they agree
    warnings*: seq[string]
      ## each file whose headers contradict themselves, named, with how

  FileUnit* = object
    ## The unit of a seismic file's coordinates, as the import takes it.
    unit*: SurveyUnit
    note*: string
      ## a dim line: what the headers say, when the unit was taken otherwise
    conflict*: string
      ## a warning: the headers and the survey give units that cannot both
      ## be right (metres and feet); "" when they agree
    byHand*: bool
      ## the user chose it

  UnitChoice* = object
    ## A unit the user chose in the Import survey window, or took back.
    survey*: seq[string]
      ## the survey's files (their paths, in any order): the unit is the
      ## survey's; empty: it is seismic file `file`'s
    file*: string
      ## the seismic file (its path), when `survey` is empty
    unit*: SurveyUnit
    byHand*: bool
      ## true: `unit` is the user's; false: back to what the headers say

  ImportUnits* = object
    ## The units the user chose by hand (`UnitChoice`), kept while the
    ## program runs (a project keeps them with it): a survey's, by its set of
    ## files, and a seismic file's, by its path. What the headers say never
    ## replaces them; a survey of other files has its own (none: the
    ## headers'). At most `MaxUnitChoices` of each, the oldest dropped.
    surveys*: seq[tuple[files: seq[string]; unit: SurveyUnit]]
      ## the files sorted
    files*: seq[tuple[path: string; unit: SurveyUnit]]

func gridConflict(g: GridUnit; nameAt, factorAt: string): string =
  ## When a grid unit's name and its factor to metres name different units:
  ## what each says, and that the factor is taken (or, a factor of no unit
  ## known, the name); "" when they agree, or one says nothing. "Feet" with
  ## the US survey foot's factor agrees: the factor only says which foot.
  if g.name.strip.len == 0 or not (g.metres > 0): return
  let named = unitNamed(g.name)
  let factored = unitOf(GridUnit(metres: g.metres))
  if named != suNotGiven and named != factored and
      not (named == suFeet and factored == suUsFeet):
    result = "its " & nameAt & " says " & $named & " and its " & factorAt & " " & $g.metres &
      " m a unit" & (if factored == suNotGiven: ", which is no unit known: the " & nameAt &
        " is taken" else: " (" & $factored & "): the " & factorAt & " is taken")

func headUnitOf*(g: GridUnit): HeadUnit =
  ## What an SPS file's grid unit (H20, H201) says, in words, with a
  ## warning when the two contradict each other.
  HeadUnit(unit: unitOf(g), said: describe(g), warning: gridConflict(g, "H20", "H201"))

func headLines(head: string; whole: bool): seq[string] =
  ## The lines of the start of a file: cut at its line ends (the last,
  ## possibly cut short, left out unless `head` is the `whole` file), else
  ## as 80-byte cards; a UTF-8 BOM passed by.
  var at = if head.startsWith("\xEF\xBB\xBF"): 3 else: 0
  var ends = false
  var lo = at
  for i in at ..< head.len:
    if head[i] in {'\n', '\r'}:
      ends = true
      if i > lo: result.add head[lo ..< i]
      lo = i + 1
  if ends:
    if whole and lo < head.len: result.add head[lo .. ^1]
  else:
    while at + 80 <= head.len:
      result.add head[at ..< at + 80]
      at += 80
    if whole and at < head.len: result.add head[at .. ^1]

proc spsHeadUnit(lines: openArray[string]): HeadUnit =
  ## H20 and H201 of the header records the file starts with (parseSEG's
  ## `gridUnit`), up to its first point or relation record.
  var text = ""
  for line in lines:
    if line.len > 0 and line[0] in {'S', 'R', 'X', 'O'}: break
    if line.len > 0 and line[0] == 'H': text.add line & "\n"
  var g = GridUnit()
  try: g = parseSps(text).gridUnit
  except CatchableError: discard # (header text never raises; an odd file says nothing)
  headUnitOf(g)

func p1HeadUnit(lines: openArray[string]): HeadUnit =
  ## A UKOOA P1/90 file's grid units: its H2000 record (a unit code, the
  ## unit's name and its factor to metres, from column 33; the code may be
  ## written against the name, "1METRES", and the factor left out).
  for line in lines:
    if line.startsWith("H2000") and line.len > 32:
      var names: seq[string] = @[]
      var metres = NaN
      let words = line[32 .. ^1].splitWhitespace
      for i, raw in words:
        var w = raw
        var k = 0
        while k < w.len and w[k] in Digits: inc k
        if i == 0 and k > 0:
          w = w[k .. ^1] # the code: "1", or "1METRES" the code and the name
        if w.len > 0:
          var v = NaN
          try: v = parseFloat(w)
          except ValueError: discard
          if v.isNaN: names.add w
          elif v > 0 and v < Inf: metres = v
      let g = GridUnit(name: names.join(" "), metres: metres)
      var said: seq[string] = @[]
      if g.name.len > 0: said.add "\"" & g.name & "\""
      if g.metres > 0: said.add $g.metres & " m a unit"
      return HeadUnit(unit: unitOf(g), said: said.join(", ") & " (H2000)",
        warning: gridConflict(g, "H2000 name", "H2000 factor"))
    if line.len > 0 and line[0] != 'H': return

proc p111HeadUnit(lines: openArray[string]): HeadUnit =
  ## An OGP P1/11 file's grid units: the unit of length its projection's
  ## parameters are given in (HC,1,5,2 records, read by parseSEG's
  ## `parseCrsText`).
  var text = ""
  for line in lines:
    if line.startsWith("HC,"): text.add line & "\n"
  var unit = ""
  try: unit = lengthUnitOf(parseCrsText(text))
  except CatchableError: discard # (a header that says nothing)
  if unit.len > 0: result = HeadUnit(unit: unitNamed(unit), said: "\"" & unit & "\" (HC,1,5,2)")

type CsvColumn = enum
  ccKind, ccLine, ccPoint, ccIndex, ccX, ccY, ccZ

func columnOf(name: string): int =
  ## The column a header cell names (`CsvColumn`); -1 for none. A unit in
  ## brackets after the name ("x (ftUS)", "Easting [m]") is passed by.
  var n = ""
  for c in name.toLowerAscii:
    if c in {'(', '['}: break
    if c in {'a' .. 'z', '0' .. '9'}: n.add c
  case n
  of "kind", "type", "role", "recordtype", "pointtype", "code": ord(ccKind)
  of "line", "lineno", "linenumber", "linename", "ln": ord(ccLine)
  of "point", "pointno", "pointnumber", "station", "stationno", "stationnumber", "pt", "sp",
      "shotpoint": ord(ccPoint)
  of "index", "idx", "pointindex", "pi": ord(ccIndex)
  of "x", "easting", "east", "e", "xcoord", "xcoordinate": ord(ccX)
  of "y", "northing", "north", "n", "ycoord", "ycoordinate": ord(ccY)
  of "z", "elevation", "elev", "height", "h", "zcoord", "depth": ord(ccZ)
  else: -1

func cells(line: string; delimiter: char): seq[string] =
  ## The cells of a row, quotes and blanks trimmed; split at runs of blanks
  ## when `delimiter` is ' '.
  let parts = if delimiter == ' ': line.splitWhitespace() else: line.split(delimiter)
  for p in parts: result.add p.strip.strip(chars = {'"', '\''}).strip

func delimiterOf(line: string): char =
  if '\t' in line: '\t'
  elif ';' in line: ';'
  elif ',' in line: ','
  else: ' '

func csvHeadUnit(lines: openArray[string]): HeadUnit =
  ## A CSV table's unit: a comment before its first row that names one ("#
  ## units: US survey feet"), or a unit in brackets in its first row's x or
  ## y column ("x (ftUS)", "Easting [m]"; an elevation's unit is not the
  ## grid's).
  for line in lines:
    let l = line.strip
    if l.startsWith('#'):
      let at = l.toLowerAscii.find("unit")
      let sep = if at >= 0: l.find({':', '='}, at) else: -1
      if sep > 0:
        let word = l[sep + 1 .. ^1].strip.strip(chars = {'"', '\'', ';', '.'})
        let u = unitNamed(word)
        if u != suNotGiven: return HeadUnit(unit: u, said: "\"" & l[1 .. ^1].strip & "\"")
    elif l.len > 0:
      for cell in cells(l, delimiterOf(l)):
        let a = if columnOf(cell) in [ord(ccX), ord(ccY)]: cell.find({'(', '['}) else: -1
        let b = if a >= 0: cell.find({')', ']'}, a) else: -1
        if b > a + 1:
          let u = unitNamed(cell[a + 1 ..< b])
          if u != suNotGiven:
            return HeadUnit(unit: u, said: "\"" & cell.strip & "\" (its first row)")
      return

proc headUnitOf*(head: string; kind: JoinFileKind; whole = false): HeadUnit =
  ## What the start of a survey file, `head` (its first `HeadBytes` or
  ## fewer), says of its coordinates' unit: SPS H20 and H201 (H201's factor
  ## names the foot: 0.3048006096 is the US survey foot, 0.3048 the
  ## international), SEG P1's H2000 (OGP P1/11: its projection parameters'
  ## unit), or a CSV table's comment or first row.
  ## `whole`: `head` is the whole file, so its last line is read even
  ## without a line end. Never raises: a file that says nothing gives
  ## `suNotGiven`.
  let lines = headLines(head, whole)
  var ogp = false # an OGP P1/11 file, whatever its name made it
  for line in lines:
    if line.startsWith("HC,1,"): ogp = true
  if ogp and kind != jkCsv: return p111HeadUnit(lines)
  case kind
  of jkSps: spsHeadUnit(lines)
  of jkP1: p1HeadUnit(lines)
  of jkCsv: csvHeadUnit(lines)

func surveyUnitsSaid*(heads: openArray[SurveyHead]): SurveyUnitsSaid =
  ## The survey's unit as the headers of `heads` (the import's survey files,
  ## in order) say it: the first that says; what each kind of file says, in
  ## words; and, when files say different units, which say what.
  var units: seq[SurveyUnit]
  var names: seq[seq[string]]
  var told: seq[(JoinFileKind, string)]
  for h in heads:
    if h.done and h.head.unit != suNotGiven:
      if result.unit == suNotGiven: result.unit = h.head.unit
      let k = units.find(h.head.unit)
      if k < 0:
        units.add h.head.unit
        names.add @[h.file.path.extractFilename]
      else: names[k].add h.file.path.extractFilename
      if h.head.warning.len > 0 and result.warnings.len < 4:
        result.warnings.add h.file.path.extractFilename & ": " & h.head.warning & "."
      if (h.file.kind, h.head.said) notin told and told.len < 4:
        told.add (h.file.kind, h.head.said)
        let kind = case h.file.kind
          of jkSps: "SPS headers say "
          of jkP1: "SEG P1 headers say "
          of jkCsv: "CSV table says "
        result.words.add "The " & kind & h.head.said & "."
  if units.len > 1:
    var parts: seq[string]
    for k, u in units:
      let few = if names[k].len > 3: names[k][0 .. 2].join(", ") & " and " &
        $(names[k].len - 3) & " more" else: names[k].join(", ")
      parts.add few & (if names[k].len == 1: " says " else: " say ") & $u
    result.disagree = "The survey files disagree: " & parts.join("; ") & ". The first is " &
      "taken; choose the unit that is right."

func fileUnitOf*(headers, survey: SurveyUnit; chosen = suNotGiven; byHand = false): FileUnit =
  ## The unit an import takes a seismic file's coordinates in: `chosen` when
  ## the user chose it (`byHand`); else what its `headers` say, but the
  ## survey's unit where they say nothing, or say only "feet" (SEG-Y cannot
  ## tell the international foot from the US survey foot) while the survey
  ## says US survey feet. Units that cannot both be right (metres and feet,
  ## a length and degrees) are a conflict, said in words; feet against US
  ## survey feet only a note.
  result.byHand = byHand
  if byHand:
    result.unit = chosen
    if headers != suNotGiven and headers != chosen:
      result.note = "The headers say " & $headers & "."
  elif headers == suNotGiven:
    result.unit = survey
    if survey != suNotGiven:
      result.note = "The headers do not say; taken as " & $survey & ", as the survey says."
  elif headers == suFeet and survey == suUsFeet:
    result.unit = suUsFeet
    result.note = "The headers say feet; taken as US survey feet, as the survey says."
  else:
    result.unit = headers
    if headers == suUsFeet and survey == suFeet:
      result.note = "The headers say US survey feet, the survey files international feet."
  let (a, b) = (result.unit, survey)
  if a != suNotGiven and b != suNotGiven and a != b and
      not ({a, b} == {suFeet, suUsFeet}):
    result.conflict = "The headers' coordinates are in " & $a & " and the survey's in " & $b &
      ": one of them is wrong, and the import converts nothing. Choose what each is in."

const MaxUnitChoices* = 64 ## hand choices kept, of surveys and of files each

func surveyKey(files: openArray[string]): seq[string] =
  ## A survey's files as its choice is kept by: sorted, each once.
  result = @[]
  for f in files:
    if f notin result: result.add f
  result.sort()

func chosenFor*(u: ImportUnits; survey: openArray[string]; unit: var SurveyUnit): bool =
  ## Whether the user chose the unit of the survey of files `survey` (any
  ## order); `unit` then.
  let key = surveyKey(survey)
  for (files, chosen) in u.surveys:
    if files == key:
      unit = chosen
      return true

func surveyUnit*(u: ImportUnits; survey: openArray[string]; said: SurveyUnitsSaid): SurveyUnit =
  ## The unit the window shows for the survey of files `survey`: the
  ## user's, else what their headers say.
  result = said.unit
  discard u.chosenFor(survey, result)

func fileUnit*(u: ImportUnits; path: string; headers, survey: SurveyUnit): FileUnit =
  ## The unit the window shows for seismic file `path`, whose `headers` say
  ## what they say, with the survey's unit `survey` (`fileUnitOf`).
  for (p, unit) in u.files:
    if p == path: return fileUnitOf(headers, survey, unit, byHand = true)
  fileUnitOf(headers, survey)

func resolved*(u: JoinUnits; heads: openArray[SurveyHead]; headers: SurveyUnit): JoinUnits =
  ## `u` with the units to be worked out from the headers worked out: the
  ## survey's from `heads` (as the import read its files), the seismic
  ## file's from what its own headers say (`headers`), following the
  ## survey's (`fileUnitOf`). What the user chose stays as it is.
  result = u
  if u.surveyFromHeaders: result.survey = surveyUnitsSaid(heads).unit
  if u.fileFromHeaders: result.file = fileUnitOf(headers, result.survey).unit

proc choose*(u: var ImportUnits; c: UnitChoice) =
  ## Keeps the user's choice `c`, in place of one for the same survey or
  ## file; takes it away when `c` is back to the headers (`byHand` false).
  if c.survey.len > 0:
    let key = surveyKey(c.survey)
    for i in 0 ..< u.surveys.len:
      if u.surveys[i].files == key:
        u.surveys.delete(i)
        break
    if c.byHand:
      u.surveys.add (key, c.unit)
      if u.surveys.len > MaxUnitChoices: u.surveys.delete(0)
  elif c.file.len > 0:
    for i in 0 ..< u.files.len:
      if u.files[i].path == c.file:
        u.files.delete(i)
        break
    if c.byHand:
      u.files.add (c.file, c.unit)
      if u.files.len > MaxUnitChoices: u.files.delete(0)

# ------------------------------------------------------------ line names --

proc parseLineNames*(text: string; problems: var seq[string]): seq[LineName] =
  ## Line names mapped to numbers, as the dialog takes them: `name = number`,
  ## one per line (or separated by `;`). What cannot be used is said in
  ## `problems` and passed by.
  for raw in text.split({'\n', ';'}):
    let item = raw.strip
    if item.len > 0:
      let eq = item.find('=')
      if eq < 0:
        problems.add "\"" & item & "\" has no '=': write a line name as name = number"
      else:
        let name = item[0 ..< eq].strip
        let number = item[eq + 1 .. ^1].strip
        var line = NaN
        try: line = parseFloat(number)
        except ValueError: discard
        if name.len == 0: problems.add "\"" & item & "\" names no line"
        elif line.isNaN or abs(line) == Inf:
          problems.add "\"" & number & "\" (for " & name & ") is not a number"
        else: result.add LineName(name: name, line: line)

func lineNamesText*(names: openArray[LineName]): string =
  ## `names` as `parseLineNames` reads them back, one per line.
  for i, n in names:
    if i > 0: result.add '\n'
    let x = n.line
    result.add n.name & " = " & (if x == round(x) and abs(x) < 1e15: $int64(x) else: $x)

# ------------------------------------------------------------ CSV tables --

func roleOfCell(cell: string): int =
  ## 0 for a source ("S", "source", "shot", "src"), 1 for a receiver ("R",
  ## "receiver", "rcv", "G"); -1 for neither.
  let c = cell.toLowerAscii
  if c.len == 0: -1
  elif c in ["s", "src", "source", "sources", "shot", "sp", "shotpoint"]: 0
  elif c in ["r", "rcv", "rec", "receiver", "receivers", "g", "geophone", "node"]: 1
  else: -1

proc number(cell: string): float64 =
  result = NaN
  if cell.len > 0:
    try: result = parseFloat(cell)
    except ValueError: discard

proc addCsv*(g: var SurveyGeometry; text, name: string; role: CsvRole;
    problems: var seq[string]; skipped: var int): int =
  ## Adds the stations of the CSV table `text` (named `name` in what it
  ## says) to `g`'s table as `role` says, and returns how many rows were
  ## taken. The first row that is not blank or a comment (`#`) names the
  ## columns (`line`, `point` or `station`, `index`, `x` or `easting`, `y` or
  ## `northing`, `z` or `elevation`, and `kind` with S or R per row; any
  ## case), else the columns are line, point, x, y and z in that order (after
  ## the kind with `crColumn`). Cells are separated by tabs, semicolons,
  ## commas or blanks, as the first row is. Rows that cannot be used are
  ## counted in `skipped` and the first few said in `problems`. A station
  ## given twice: the later one counts.
  var cols: array[CsvColumn, int] = [-1, -1, -1, -1, -1, -1, -1]
  var delimiter = ','
  var started = false
  var lineNo = 0
  var said = 0
  template skip(why: string) =
    inc skipped
    if said < 20:
      inc said
      problems.add name & " line " & $lineNo & ": " & why & "; the row is passed by"
  for raw in text.splitLines:
    inc lineNo
    let line = raw.strip
    var data = line.len > 0 and not line.startsWith('#')
    if data and not started:
      started = true
      delimiter = delimiterOf(line)
      let head = cells(line, delimiter)
      var named = false
      for i, h in head:
        let c = columnOf(h)
        if c >= 0 and cols[CsvColumn(c)] < 0:
          cols[CsvColumn(c)] = i
          named = true
      if named:
        data = false # the row names the columns
      else:
        # No header: line, point, x, y[, z], after the kind when it is in a column.
        let first = if role == crColumn: 1 else: 0
        if role == crColumn: cols[ccKind] = 0
        (cols[ccLine], cols[ccPoint], cols[ccX], cols[ccY], cols[ccZ]) =
          (first, first + 1, first + 2, first + 3, first + 4)
      if cols[ccLine] < 0 or cols[ccPoint] < 0 or cols[ccX] < 0 or cols[ccY] < 0:
        problems.add name & ": its first row names no line, point, x and y columns " &
          "(it reads: " & head.join(", ") & "), so the table was not used"
        return
      if role == crColumn and cols[ccKind] < 0:
        problems.add name & ": no column says which rows are sources and which receivers " &
          "(a kind column with S or R), so the table was not used: choose its role"
        return
    if data:
      let c = cells(line, delimiter)
      template at(col: CsvColumn): string =
        (if cols[col] >= 0 and cols[col] < c.len: c[cols[col]] else: "")
      let (l, p, x, y) = (number(at(ccLine)), number(at(ccPoint)), number(at(ccX)),
        number(at(ccY)))
      if l.isNaN or p.isNaN: skip("its line or point is not a number")
      elif x.isNaN or y.isNaN or abs(x) == Inf or abs(y) == Inf:
        skip("its x or y is not a number")
      else:
        let r = case role
          of crSources: 0
          of crReceivers: 1
          of crColumn: roleOfCell(at(ccKind))
        if r < 0: skip("its kind (\"" & at(ccKind) & "\") is neither S nor R")
        else:
          let ix = number(at(ccIndex))
          let index = if ix.isNaN: 0'i16 else: int16(clamp(ix, -32768, 32767))
          let z = number(at(ccZ))
          if r == 0: g.addSource(l, p, index, x, y, z) else: g.addReceiver(l, p, index, x, y, z)
          inc result

# ----------------------------------------------------------------- plan --

func lookup(t: Table[StationKey, Coordinates]; line, point: float64; index: int16;
    c: var Coordinates): bool =
  ## The station as parseSEG's join finds it: the same index, else one given
  ## for any index (0), else, for a trace without an index (0), the first
  ## position (1).
  if line.isNaN or point.isNaN: return false
  for i in 0 .. (if index == 0: 2 else: 1):
    let key = stationKey(line, point, [index, 0'i16, 1'i16][i])
    if key in t:
      c = t[key]
      return true

func usable(x, y: float64): bool {.inline.} =
  ## Coordinates that place a point: finite, and not (0, 0).
  abs(x) < Inf and abs(y) < Inf and not (x == 0 and y == 0)

const
  PlanChunk = 65_536 ## traces whose keys are copied at a time
  SharedRelations* = compiles((var k = initTraceKeys();
    discard k.applySurvey(initSurveyGeometry(), initSurveyGeometry())))
    ## parseSEG joins with the stations of one geometry and the relations of
    ## another: an import uses the relation file the map has read, not a
    ## copy of it (one read, one copy in memory)

proc applyBoth(k: var TraceKeys; g, relations: SurveyGeometry; overwrite: bool): bool =
  ## `applySurvey` with the stations of `g` and the relations of `relations`
  ## (`g`'s own when parseSEG cannot keep them apart: then they are one).
  when SharedRelations: k.applySurvey(g, relations, overwrite)
  else: k.applySurvey(g, overwrite)

proc planJoin*(file: ptr SeismicFile; g, relations: SurveyGeometry; opts: JoinOptions;
    progress: proc (done, total: int): bool): JoinPlan =
  ## Works out what joining `g` (its relation records those of `relations`:
  ## `SharedRelations`; else `g` holds both and is passed twice) to the open
  ## file `file` does, on copies of its keys (a chunk at a time, so any file
  ## takes bounded memory): reads only, so readers may go on reading the
  ## file meanwhile. `progress` is asked between chunks; false stops it (a
  ## cancel) with an empty plan. Raises `ValueError` for a file opened
  ## without keys.
  let n = file[].len
  result = JoinPlan(traces: n, differ: [NaN, NaN])
  var keys = newSeq[TraceKeys](min(n, PlanChunk))
  # First the coordinates the headers give: every one of them at (0, 0) is a
  # header left empty, and the join fills it as if none were given.
  var t = 0
  while t < n:
    let m = min(keys.len, n - t)
    file[].traceKeysInto(t ..< t + m, keys.toOpenArray(0, m - 1))
    for k in keys.toOpenArray(0, m - 1):
      if k.isSeismic:
        inc result.seismic
        for (r, x, y) in [(prSource, k.srcX, k.srcY), (prReceiver, k.rcvX, k.rcvY)]:
          if usable(x, y): inc result.given[r]
          elif x == 0 and y == 0: inc result.zero[r]
        if not (k.srcLine.isNaN or k.srcPoint.isNaN):
          inc result.headerStations[prSource]
          result.headerLines[prSource].incl k.srcLine
          result.headerPoints[prSource].incl k.srcPoint
        if not (k.rcvLine.isNaN or k.rcvPoint.isNaN):
          inc result.headerStations[prReceiver]
          result.headerLines[prReceiver].incl k.rcvLine
          result.headerPoints[prReceiver].incl k.rcvPoint
        result.headerRecords.incl k.record
    t += m
    if not progress(t, 2 * n): return JoinPlan()
  result.replace = opts.coordinates == hcReplace or
    (result.given[prSource] + result.given[prReceiver] == 0 and
      result.zero[prSource] + result.zero[prReceiver] > 0)
  t = 0
  while t < n:
    let m = min(keys.len, n - t)
    file[].traceKeysInto(t ..< t + m, keys.toOpenArray(0, m - 1))
    for i in 0 ..< m:
      let k = keys[i]
      var s = k
      let match = s.joinStations(relations)
      inc result.matches[match]
      var j = k
      if j.applyBoth(g, relations, result.replace): inc result.changes
      if match != jmAuxiliary and k.isSeismic:
        var both = true
        let ends = [(prSource, s.srcLine, s.srcPoint, s.srcIndex, k.srcX, k.srcY, j.srcX,
          j.srcY), (prReceiver, s.rcvLine, s.rcvPoint, s.rcvIndex, k.rcvX, k.rcvY, j.rcvX,
          j.rcvY)]
        for (r, line, point, index, hx, hy, jx, jy) in ends:
          var c: Coordinates
          # (by address: an `if` that gives the table copies it, every
          # station of the survey, for each trace)
          let table = if r == prSource: addr g.table.sources else: addr g.table.receivers
          if table[].lookup(line, point, index, c):
            inc result.found[r]
            if usable(hx, hy):
              let d = hypot(hx - c.x, hy - c.y)
              if result.differ[r].isNaN or d > result.differ[r]: result.differ[r] = d
            elif hx == 0 and hy == 0 and not result.replace:
              inc result.zeroKept[r]
          else:
            both = false
          if not usable(jx, jy): inc result.unplaced[r]
        if both:
          inc result.matched
          inc result.matchedBy[match]
        else: result.unmatched.add t + i
    t += m
    if not progress(n + t, 2 * n): return JoinPlan()

proc planJoin*(file: ptr SeismicFile; g: SurveyGeometry; opts: JoinOptions;
    progress: proc (done, total: int): bool): JoinPlan =
  ## `planJoin` of a geometry that holds the stations and the relations.
  planJoin(file, g, g, opts, progress)

proc surveyOf*(g: SurveyGeometry; files: openArray[string];
    relations: ptr SurveyGeometry = nil): JoinSurvey =
  ## What geometry `g`, read from `files`, holds; its relation records those
  ## of `relations` when given (kept apart: `SharedRelations`).
  result = JoinSurvey(files: @files, gridUnit: g.gridUnit)
  # (by address: an array of the tables would copy them)
  for (r, table) in [(prSource, addr g.table.sources), (prReceiver, addr g.table.receivers)]:
    for k, c in table[]:
      if usable(c.x, c.y):
        inc result.stations[r]
        result.lines[r].incl k.line
        result.points[r].incl k.point
  let r = if relations.isNil: addr g else: relations
  for d in RelationDomain:
    result.relations += r[].relationCount(d)
    for rec in r[].records(d): result.records.incl float64(rec)

# ------------------------------------------------------------ in words --

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func wordsUnit*(confirmed: SurveyUnit; grid: GridUnit; headers: SurveyUnit): SurveyUnit =
  ## The unit an import's words give its distances in: the one the user
  ## confirmed, else the survey files' grid unit (SPS H20, H201), else the
  ## seismic file's headers'; not given when nothing says.
  if confirmed != suNotGiven: confirmed
  elif grid.known and unitOf(grid) != suNotGiven: unitOf(grid)
  else: headers

func wordsUnit*(confirmed: SurveyUnit; g: SurveyGeometry; headers: SurveyUnit): SurveyUnit
    {.inline.} =
  ## `wordsUnit` with the grid unit of the survey files read into `g`.
  wordsUnit(confirmed, g.gridUnit, headers)

func distanceWords(d: float64; unit: SurveyUnit): string =
  ## "0.1 ftUS"; "0.1 units" when nothing names the unit.
  let u = if unit.abbreviation.len > 0: " " & unit.abbreviation else: " units"
  (if d < 0.05: formatFloat(d, ffDecimal, 3) elif d < 100: formatFloat(d, ffDecimal, 1)
    else: $int64(round(d))) & u

func whyUnmatched*(p: JoinPlan; s: JoinSurvey; opts: JoinOptions): seq[string] =
  ## Why the survey has no stations for the plan's unmatched traces, in
  ## plain words, the likeliest first: what the headers give against what
  ## the survey files hold (line numbering, text line names, record numbers
  ## not in the relation file).
  let none = p.seismic > 0 and p.matched == 0
  if p.seismic == 0:
    return @["the file has no seismic traces: auxiliary traces are never matched"]
  if s.unresolved.len > 0 and not opts.trailingDigits:
    result.add "the survey files name lines with text (\"" & s.unresolved[0] & "\"" &
      (if s.unresolved.len > 1: ", \"" & s.unresolved[1] & "\"" else: "") & "), so " &
      plural(s.unresolvedRecords, "record was", "records were") & " passed by: turn on " &
      "\"Use the trailing digits of line names\", or map the names to numbers"
  elif s.unresolved.len > 0:
    result.add "some line names have no trailing digits (\"" & s.unresolved[0] &
      "\"): map them to numbers"
  for r in PointRole:
    let role = $r
    let have = p.headerStations[r] > 0
    if s.stations[r] == 0:
      if p.found[r] < p.seismic:
        result.add "no survey file gives " & role & " stations with coordinates"
    elif have and p.found[r] == 0:
      let (hl, sl) = (p.headerLines[r], s.lines[r])
      if not overlaps(hl, sl):
        var why = "the headers' " & role & " lines (" & $hl & ") are not the survey's (" & $sl &
          ")"
        for f in [10.0, 100.0, 1000.0, 10000.0]:
          if overlaps(Extent(lo: hl.lo * f, hi: hl.hi * f), sl):
            why.add ": the survey numbers its lines " & $int(f) & " times larger, so the line " &
              "numbering differs"
          elif overlaps(Extent(lo: sl.lo * f, hi: sl.hi * f), hl):
            why.add ": the headers number their lines " & $int(f) & " times larger, so the " &
              "line numbering differs"
        result.add why
      elif not overlaps(p.headerPoints[r], s.points[r]):
        result.add "the headers' " & role & " points (" & $p.headerPoints[r] &
          ") are not the survey's (" & $s.points[r] & ")"
      else:
        result.add "none of the headers' " & role & " stations (lines " & $hl & ", points " &
          $p.headerPoints[r] & ") is in the survey files"
    elif not have and p.found[r] < p.seismic:
      if s.relations == 0:
        result.add "the headers give no " & role & " stations, and no relation file (SPS X) " &
          "was imported to find them from the record and channel numbers"
      elif not overlaps(p.headerRecords, s.records):
        result.add "the headers give no " & role & " stations, and their field record " &
          "numbers (" & $p.headerRecords & ") are not in the relation file (records " &
          $s.records & ")"
  if p.matches[jmConflict] > 0:
    result.add plural(p.matches[jmConflict], "trace's header contradicts",
      "traces' headers contradict") & " the relation file (a station other than its own)"
  if p.matches[jmAmbiguous] > 0:
    result.add plural(p.matches[jmAmbiguous], "trace is", "traces are") & " ambiguous: " &
      "the records of its station disagree on the channel"
  if result.len == 0 and none:
    result.add "the stations the headers and the relation file give are not in the survey " &
      "files' station lists"

func planWords*(p: JoinPlan; s: JoinSurvey; opts: JoinOptions; unit = suNotGiven):
    seq[string] =
  ## The join's statistics in plain words, a sentence each: what matched and
  ## how, what did not and why, what became of the headers' coordinates.
  let aux = p.traces - p.seismic
  if p.seismic == 0:
    result.add "The file has no seismic traces, so nothing was matched."
  elif p.matched == 0:
    result.add "No seismic trace was matched to the survey."
  else:
    var how: seq[string]
    let ways = [(jmStations, "by the stations in their headers"),
      (jmRecord, "by record and channel, through the relation file"),
      (jmSource, "by the source station's relation records"),
      (jmReceiver, "by the receiver station's relation records")]
    for (m, words) in ways:
      if p.matchedBy[m] > 0: how.add $p.matchedBy[m] & " " & words
    result.add $p.matched & " of " & plural(p.seismic, "seismic trace", "seismic traces") &
      " matched the survey: their source and receiver stations are in it" &
      (if how.len > 0: " (" & how.join("; ") & ")." else: ".")
  if p.seismic > 0 and p.unmatched.len > 0:
    let n = p.unmatched.len
    let lacking = [p.seismic - p.found[prSource], p.seismic - p.found[prReceiver]]
    let them = if n == 1: "it" else: "them"
    let what =
      if lacking[0] == n and lacking[1] == n: "neither their source nor their receiver station"
      else:
        var parts: seq[string]
        for r in PointRole:
          if lacking[ord(r)] > 0:
            parts.add "no " & $r & " station for " & (if lacking[ord(r)] == n: them
              else: $lacking[ord(r)] & " of " & them)
        parts.join(" and ")
    result.add plural(n, "seismic trace is", "seismic traces are") & " not matched: the " &
      "survey has " & what & "."
    let why = whyUnmatched(p, s, opts)
    if why.len > 0: result.add "Why: " & why.join("; ") & "."
  if p.seismic > 0 and p.matched > 0:
    let given = p.given[prSource] + p.given[prReceiver]
    let zero = p.zero[prSource] + p.zero[prReceiver]
    var far = NaN
    for d in p.differ:
      if not d.isNaN and (far.isNaN or d > far): far = d
    if given == 0 and zero > 0:
      result.add "The headers' coordinates were all (0, 0), so the survey's take their place."
    elif given > 0 and p.replace:
      result.add "The coordinates the headers give were replaced by the survey's" &
        (if far.isNaN: "." else: " (they were up to " & distanceWords(far, unit) & " apart).")
    elif given > 0:
      result.add "The coordinates the headers give are kept" &
        (if far.isNaN: "."
          elif far <= 1e-6: ": they are the survey's."
          else: "; the survey's are up to " & distanceWords(far, unit) & " from them.")
      let kept = p.zeroKept[prSource] + p.zeroKept[prReceiver]
      if kept > 0:
        result.add plural(kept, "coordinate", "coordinates") & " at (0, 0) in the headers " &
          "stay so, though the survey has their stations: choose \"" & $hcReplace &
          "\" to replace them."
  if aux > 0: result.add plural(aux, "auxiliary trace is", "auxiliary traces are") &
    " left alone."
  if p.seismic > 0:
    result.add (if p.changes == 0: "No trace's keys changed"
      else: plural(p.changes, "trace's keys changed", "traces' keys changed")) &
      "; the file itself is never changed."
