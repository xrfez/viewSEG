## Runs alone: a seismic file's open is timed (it must not wait the 3 s a
## lane waits for a job that does not answer).
##
## The survey import's units in `core`, without a window: what survey files'
## headers say of their coordinates' unit, read as soon as a file is chosen,
## and the seismic file's unit following the survey's, so that the user
## enters a unit once at most (Project > Import survey):
##
## - unit names in any spelling files and CRS texts use (a table: case,
##   dots, brackets, plurals, US / U.S. / survey / intl), and names of other
##   feet (Clarke's, Indian) read as no unit known;
## - the start of an SPS file (H20, H201: 0.3048006096 m a unit is the US
##   survey foot, 0.3048 the international, 1 the metre; a rounded factor;
##   80-byte cards without line ends; a last line without a line end when
##   the whole file was read; an H20 and an H201 that contradict each other:
##   the factor taken, and a warning that names both), a SEG P1 file's H2000, a CSV table's
##   comment or its first row's x or y column ("x (m)", which the table is
##   then read with; not an elevation's unit); P1's H2000 with or without
##   a factor, and OGP P1/11's projection parameters' unit;
## - the survey's unit as its files say it, and the files that disagree
##   named;
## - the seismic file's unit: the survey's where its headers say nothing, or
##   only "feet" while the survey says US survey feet (with a dim line that
##   says so); metres against feet a conflict; a unit the user chose by hand
##   never replaced by a later derivation, kept per survey (its set of
##   files) and per seismic file, taken back to the headers on request, in
##   the state (`ckChooseUnit`);
## - a seismic file's headers made exact by the unit of length its CRS text
##   names (parseSEG's `crs`);
## - `ckSurveyUnits` reads the headers of the files it names on jobs (a file
##   once; one that cannot be read says why, and is read again when asked
##   again), on a lane of their own: a file on a drive that does not answer
##   holds no seismic file's open;
## - SEG-Y "feet" against a survey in US survey feet is no disagreement for
##   the map; an import whose units nobody chose works them out from the
##   files it reads (an agent's with none given, the window's while it still
##   reads), never from a guess made before; after an import the units it
##   was made with label the file.
##
## Seen to fail: with a hand choice kept for every survey (keyed by no
## file), "another survey shows the first one's hand choice"; with the
## import's units taken as sent (not worked out
## from the files it read), "the import's units, read by it: (survey: not
## given, ...)"; with the units' reads on the interactive lane, "the
## seismic file waited for the survey file's headers: 3003 ms"; with an H20 and H201 that contradict each other passed
## over, "no warning for Metres + 0.3048006096"; with a P1 unit code taken for the factor, "1 FEET: (unit:
## metres, ...)"; with P1/11 not read, "P1/11: (unit: not given, ...)"; with
## a CSV unit taken from any column, "an elevation's
## unit taken: (unit: metres, ...)"; with the last line without a line end left out of a whole
## file, "a last line without a line end: (unit: feet, ...)"; with the unit
## words matched whole, as first written,
## "unit words read wrong: \"Meters (m)\": not given, ..."; with H201's
## factor left out of the SPS reading (the name only), "the land survey's
## headers: feet" (not US survey feet); with
## `fileUnitOf` taking the headers' "feet" as it is, "feet, US survey feet:
## feet"; with `unitsDisagree` counting SEG-Y's "feet" against US survey
## feet, "the units disagree: The coordinates' units disagree (...)".

import std/[monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/[session, state]
import viewSEG/view/maplayers
import utils/[faultyfs, fixtures, waiting]

const LandHeaders = """H00 SPS format version num.     SPS 2.1;
H01 Description of survey area  ,Test area;
H12 Geodetic datum,-spheroid    Clarke 1866;
H18 Projection type             State Plane Coordinate System;
H20 Description of grid units   feet;
H201Factor to meters            0.3048006096;
H232Grid coord. at origin       00001000.00E 00002000.00N;
S          1.00         1.00  1V1                         1000.0   2000.0  10.0      0
"""

func sps(grid, factor: string): string =
  "H00 SPS format version num.     SPS 2.1;\n" &
    (if grid.len > 0: "H20 Description of grid units   " & grid & ";\n" else: "") &
    (if factor.len > 0: "H201Factor to meters            " & factor & ";\n" else: "")

proc main*() =

  block unitWords:
    # Unit names as files and CRS texts write them: any case, punctuation,
    # plurals, abbreviations, a symbol in brackets.
    const table = [
      ("m", suMetres), ("M", suMetres), ("metre", suMetres), ("Metres", suMetres),
      ("meter", suMetres), ("METERS", suMetres), ("Meters (m)", suMetres), ("mtr", suMetres),
      ("ft", suFeet), ("Feet", suFeet), ("foot", suFeet), ("ft.", suFeet),
      ("international feet", suFeet), ("Intl feet", suFeet), ("Int'l foot", suFeet),
      ("international foot (ft)", suFeet), ("Feet (international)", suFeet),
      ("US survey feet", suUsFeet), ("U.S. survey feet", suUsFeet),
      ("U.S. Survey Foot", suUsFeet), ("Feet (US Survey)", suUsFeet),
      ("US Survey Feet (ftUS)", suUsFeet), ("survey ft", suUsFeet), ("ftUS", suUsFeet),
      ("US-ft", suUsFeet), ("foot_us", suUsFeet), ("usft", suUsFeet), ("US feet", suUsFeet),
      ("U.S. feet", suUsFeet), ("feet, US survey", suUsFeet), ("[ftUS]", suUsFeet),
      ("degrees", suDegrees), ("Deg", suDegrees),
      ("", suNotGiven), ("N/A", suNotGiven), ("Clarke's foot", suNotGiven),
      ("Indian foot", suNotGiven), ("British foot (Sears 1922)", suNotGiven),
      ("chains", suNotGiven), ("metres and feet", suNotGiven), ("kilometre", suNotGiven)]
    var wrong: seq[string]
    for (word, unit) in table:
      let got = unitOf(GridUnit(name: word))
      if got != unit: wrong.add "\"" & word & "\": " & $got & ", not " & $unit
    doAssert wrong.len == 0, "unit words read wrong: " & wrong.join("; ")
    # A CRS's unit name the same way.
    doAssert headerUnitOf(FileCrs(units: cuFeet, lengthUnit: "U.S. Survey Foot")) == suUsFeet

  block spsHeaders:
    let m = headUnitOf(LandHeaders, jkSps)
    doAssert m.unit == suUsFeet, "the land survey's headers: " & $m.unit
    doAssert m.said == "\"feet\" (H20), 0.3048006096 m a unit (H201)", m.said
    doAssert headUnitOf(sps("feet", "0.3048"), jkSps).unit == suFeet
    doAssert headUnitOf(sps("Metres", "1.0"), jkSps).unit == suMetres
    doAssert headUnitOf(sps("", "0.304801"), jkSps).unit == suUsFeet # rounded
    doAssert headUnitOf(sps("US survey feet", ""), jkSps).unit == suUsFeet
    doAssert headUnitOf(sps("feet", ""), jkSps).unit == suFeet
    # H20 and H201 that contradict each other: the factor is taken, and said.
    for (grid, factor, unit, says) in [("Metres", "0.3048006096", suUsFeet, "metres"),
        ("US survey feet", "0.3048", suFeet, "US survey feet"), ("feet", "1.0", suMetres, "feet"),
        ("metres", "0.5", suMetres, "metres")]:
      let h = headUnitOf(sps(grid, factor), jkSps)
      doAssert h.unit == unit, grid & " + " & factor & ": " & $h
      doAssert h.warning.startsWith("its H20 says " & says & " and its H201 " & factor &
        " m a unit"), "no warning for " & grid & " + " & factor & ": " & $h
    for (grid, factor) in [("feet", "0.3048006096"), ("feet", "0.3048"), ("Metres", "1.0"),
        ("US survey feet", "0.3048006096"), ("", "0.3048"), ("feet", "")]:
      doAssert headUnitOf(sps(grid, factor), jkSps).warning == "", grid & " + " & factor
    let none = headUnitOf(sps("", ""), jkSps)
    doAssert none.unit == suNotGiven and none.said == "", $none
    doAssert headUnitOf("", jkSps).unit == suNotGiven
    # Header records after the first point record are not read.
    doAssert headUnitOf("H00 SPS format version num.     SPS 2.1;\n" & LandHeaders.splitLines[^2] &
      "\n" & sps("Metres", "1.0"), jkSps).unit == suNotGiven
    # 80-byte cards without line ends; a last line cut short is passed by.
    var cards = ""
    for line in sps("feet", "0.3048006096").splitLines:
      if line.len > 0: cards.add line.alignLeft(80)
    doAssert headUnitOf(cards, jkSps).unit == suUsFeet
    doAssert headUnitOf(sps("feet", "") & "H201Factor to met", jkSps).unit == suFeet
    # The whole file read: its last line without a line end is read too.
    let unterminated = sps("feet", "0.3048006096").strip(leading = false)
    doAssert headUnitOf(unterminated, jkSps, whole = true).unit == suUsFeet,
      "a last line without a line end: " & $headUnitOf(unterminated, jkSps, whole = true)
    doAssert headUnitOf(unterminated, jkSps).unit == suFeet # (cut short, as far as one knows)

  block p1Headers:
    let p1 = "H0100SURVEY AREA                  NORTH SEA\n" &
      "H2000GRID UNITS                   1US SURVEY FEET           0.304800609601\n" &
      "S1001        1001       1                 0000000.0N00000000.0E 609601.2 1000.0\n"
    let h = headUnitOf(p1, jkP1)
    doAssert h.unit == suUsFeet, $h
    doAssert h.said == "\"US SURVEY FEET\", 0.304800609601 m a unit (H2000)", h.said
    doAssert headUnitOf("H2000GRID UNITS                   1METRES                   1.0\n",
      jkP1).unit == suMetres
    doAssert headUnitOf("H0100SURVEY AREA                  X\n", jkP1).unit == suNotGiven
    # The unit code apart from the name, and no factor: the name says.
    let feet = headUnitOf("H2000GRID UNITS                   1 FEET\n", jkP1)
    doAssert feet.unit == suFeet and feet.said == "\"FEET\" (H2000)", "1 FEET: " & $feet
    doAssert headUnitOf("H2000GRID UNITS                   2 US SURVEY FEET\n", jkP1).unit ==
      suUsFeet
    # OGP P1/11: the unit its projection's grid parameters are given in.
    let p111 = "HC,1,0,0,Reference Systems Summary,2,1,2,1\n" &
      "HC,1,4,0,CRS Number/EPSG Code/Type/Name,1,32050,1,projected,NAD27 / West Virginia North\n" &
      "HC,1,5,0,Map Projection,1,15301,SPCS27 West Virginia North zone\n" &
      "HC,1,5,1,Projection Method,1,9802,Lambert Conic Conformal (2SP),6\n" &
      "HC,1,5,2,Latitude of false origin,1,8821,38.5,3,degree\n" &
      "HC,1,5,2,Easting at false origin,1,8826,2000000,2,US survey foot\n" &
      "HC,1,5,2,Northing at false origin,1,8827,0,2,US survey foot\n"
    let ogp = headUnitOf(p111, jkP1)
    doAssert ogp.unit == suUsFeet, "P1/11: " & $ogp
    doAssert headUnitOf(p111, jkSps).unit == suUsFeet # whatever its name made it

  block csvHeaders:
    doAssert headUnitOf("# units: US survey feet\nline,point,x,y\n1,1,10,20\n", jkCsv).unit ==
      suUsFeet
    let c = headUnitOf("line;point;x (m);y (m)\n1;1;10;20\n", jkCsv)
    doAssert c.unit == suMetres and c.said == "\"x (m)\" (its first row)", $c
    doAssert headUnitOf("line,point,x,y\n1,1,10,20\n", jkCsv).unit == suNotGiven
    # Only the x and y columns' units are the grid's.
    let elevation = headUnitOf("line,point,elevation [m],easting [ft],northing [ft]\n", jkCsv)
    doAssert elevation.unit == suFeet, "an elevation's unit taken: " & $elevation
    doAssert headUnitOf("x,y,z (m)\n1,2,3\n", jkCsv).unit == suNotGiven
    # The table is read with its units in brackets.
    var g = initSurveyGeometry()
    var problems: seq[string]
    var skipped = 0
    doAssert g.addCsv("kind,line,point,Easting [ftUS],Northing [ftUS]\nS,1,1,10,20\n",
      "t.csv", crColumn, problems, skipped) == 1, $problems

  block surveyUnits:
    proc head(name: string; unit: SurveyUnit; said = "x"; done = true): SurveyHead =
      SurveyHead(file: JoinFile(path: "/d/" & name, kind: jkSps), done: done,
        head: HeadUnit(unit: unit, said: said))
    let said = "\"feet\" (H20), 0.3048006096 m a unit (H201)"
    let three = surveyUnitsSaid([head("a.sps", suUsFeet, said), head("a.rps", suUsFeet, said),
      head("a.xps", suUsFeet, said)])
    doAssert three.unit == suUsFeet and three.disagree == "", $three
    doAssert three.words == @["The SPS headers say " & said & "."], $three.words
    # A file that says nothing, or is still being read, is no disagreement.
    let some = surveyUnitsSaid([head("a.sps", suNotGiven, ""), head("a.rps", suMetres, "m", false),
      head("a.xps", suUsFeet, said)])
    doAssert some.unit == suUsFeet and some.disagree == "", $some
    let mixed = surveyUnitsSaid([head("a.sps", suUsFeet, said), head("a.rps", suUsFeet, said),
      head("b.rps", suMetres, "\"Metres\" (H20)")])
    doAssert mixed.unit == suUsFeet
    doAssert mixed.disagree == "The survey files disagree: a.sps, a.rps say US survey feet; " &
      "b.rps says metres. The first is taken; choose the unit that is right.", mixed.disagree
    doAssert mixed.words.len == 2, $mixed.words
    let torn = surveyUnitsSaid([SurveyHead(file: JoinFile(path: "/d/t.sps", kind: jkSps),
      done: true, head: HeadUnit(unit: suUsFeet, said: "x", warning: "its H20 says metres"))])
    doAssert torn.warnings == @["t.sps: its H20 says metres."], $torn.warnings

  block fileUnits:
    # What the headers say, followed by the survey's where they say less.
    let silent = fileUnitOf(suNotGiven, suUsFeet)
    doAssert silent.unit == suUsFeet and silent.conflict == "", $silent
    doAssert silent.note == "The headers do not say; taken as US survey feet, as the survey says."
    let feet = fileUnitOf(suFeet, suUsFeet)
    doAssert feet.unit == suUsFeet, "feet, US survey feet: " & $feet.unit
    doAssert feet.note == "The headers say feet; taken as US survey feet, as the survey says."
    doAssert feet.conflict == ""
    let same = fileUnitOf(suMetres, suMetres)
    doAssert same.unit == suMetres and same.note == "" and same.conflict == ""
    let clash = fileUnitOf(suMetres, suUsFeet)
    doAssert clash.unit == suMetres and clash.conflict.startsWith("The headers' coordinates " &
      "are in metres and the survey's in US survey feet"), $clash
    doAssert fileUnitOf(suNotGiven, suNotGiven).unit == suNotGiven
    doAssert fileUnitOf(suUsFeet, suFeet).conflict == "" # a note only
    # By hand: kept, whatever the headers or the survey say.
    let chosen = fileUnitOf(suFeet, suUsFeet, suFeet, byHand = true)
    doAssert chosen.unit == suFeet and chosen.conflict == "", $chosen
    doAssert fileUnitOf(suNotGiven, suUsFeet, suMetres, byHand = true).conflict.len > 0

  block byHand:
    # A unit chosen by hand is the survey's of those files, and the seismic
    # file's of that path: another survey shows what its headers say, and a
    # choice taken back is the headers' again.
    var u = ImportUnits()
    let usFeet = SurveyUnitsSaid(unit: suUsFeet)
    let a = @["/d/a.s", "/d/a.r"]
    doAssert u.surveyUnit(a, usFeet) == suUsFeet
    doAssert u.surveyUnit(a, SurveyUnitsSaid()) == suNotGiven
    u.choose(UnitChoice(survey: a, unit: suMetres, byHand: true))
    doAssert u.surveyUnit(a, usFeet) == suMetres, "the user's survey unit replaced"
    doAssert u.surveyUnit(@["/d/a.r", "/d/a.s"], usFeet) == suMetres # any order
    doAssert u.surveyUnit(@["/d/b.s", "/d/b.r"], usFeet) == suUsFeet,
      "another survey shows the first one's hand choice"
    doAssert u.surveyUnit(a & "/d/a.x", usFeet) == suUsFeet # another set of files
    var unit = suNotGiven
    doAssert u.chosenFor(a, unit) and unit == suMetres
    u.choose(UnitChoice(survey: a, unit: suNotGiven, byHand: true)) # "not given" on purpose
    doAssert u.surveyUnit(a, usFeet) == suNotGiven and u.surveys.len == 1
    u.choose(UnitChoice(survey: a, byHand: false)) # back to the headers
    doAssert u.surveyUnit(a, usFeet) == suUsFeet and not u.chosenFor(a, unit)
    u.choose(UnitChoice(file: "/d/a.sgy", unit: suFeet, byHand: true))
    doAssert u.fileUnit("/d/a.sgy", suNotGiven, suUsFeet).unit == suFeet
    doAssert u.fileUnit("/d/a.sgy", suNotGiven, suUsFeet).byHand
    doAssert u.fileUnit("/d/b.sgy", suNotGiven, suUsFeet).unit == suUsFeet # another file
    u.choose(UnitChoice(file: "/d/a.sgy", unit: suMetres, byHand: true))
    doAssert u.fileUnit("/d/a.sgy", suFeet, suUsFeet).unit == suMetres and u.files.len == 1
    u.choose(UnitChoice(file: "/d/a.sgy", byHand: false))
    doAssert u.fileUnit("/d/a.sgy", suFeet, suUsFeet).unit == suUsFeet and u.files.len == 0
    # Bounded.
    for i in 0 .. MaxUnitChoices:
      u.choose(UnitChoice(survey: @["/d/" & $i], unit: suFeet, byHand: true))
    doAssert u.surveys.len == MaxUnitChoices and u.surveyUnit(@["/d/0"], usFeet) == suUsFeet
    # In the state, by a command (a project keeps them with it).
    var st = initAppState()
    st.apply Command(kind: ckChooseUnit, unitChoice: UnitChoice(survey: a, unit: suFeet,
      byHand: true))
    doAssert st.unitChoices.surveyUnit(a, usFeet) == suFeet
    st.apply Command(kind: ckChooseUnit, unitChoice: UnitChoice(survey: a, byHand: false))
    doAssert st.unitChoices.surveys.len == 0

  block crsUnits:
    doAssert headerUnitOf(FileCrs(units: cuFeet, lengthUnit: "US survey foot")) == suUsFeet
    doAssert headerUnitOf(FileCrs(units: cuFeet)) == suFeet
    doAssert headerUnitOf(FileCrs(units: cuUnknown, lengthUnit: "metre")) == suMetres
    doAssert headerUnitOf(FileCrs(units: cuMeters, lengthUnit: "US survey foot")) == suMetres
    doAssert headerUnitOf(FileCrs()) == suNotGiven
    var c = CoordinateReference()
    c.projection.parameters = @[CrsParameter(name: "latitude of origin", value: 1, unit: "degree"),
      CrsParameter(name: "scale factor", value: 1, unit: "unity"),
      CrsParameter(name: "false easting", value: 2000000, unit: "US survey foot")]
    doAssert lengthUnitOf(c) == "US survey foot", lengthUnitOf(c)

  block readInState:
    withFixtures fx:
      let us = fx.surveySpsIn("usft", "feet", "0.3048006096")
      let plain = fx.surveySps()
      var st = initAppState()
      let files = @[JoinFile(path: us.s, kind: jkSps), JoinFile(path: us.r, kind: jkSps),
        JoinFile(path: plain.x, kind: jkSps), JoinFile(path: fx.dir / "none.sps", kind: jkSps)]
      st.apply Command(kind: ckSurveyUnits, unitsOf: files)
      doAssert st.heads.len == 4
      doAssert st.settle(st.heads.len == 4 and st.heads[0].done and st.heads[1].done and
        st.heads[2].done and st.heads[3].done)
      for i in 0 .. 1:
        doAssert st.heads[i].head.unit == suUsFeet and st.heads[i].problem == "", $st.heads[i]
      doAssert st.heads[2].head.unit == suNotGiven and st.heads[2].problem == ""
      doAssert st.heads[3].problem.startsWith("its headers cannot be read"), $st.heads[3]
      doAssert surveyUnitsSaid(st.heads).unit == suUsFeet
      # Once: asked again, a file read is not read again; one that failed is.
      let jobs = st.jobs.list.len
      st.apply Command(kind: ckSurveyUnits, unitsOf: files)
      doAssert st.jobs.list.len == jobs + 1, $(st.jobs.list.len - jobs)
      doAssert st.settle(st.heads[3].done)
      doAssert st.heads.len == 4

  block unitsOnTheMap:
    withFixtures fx:
      # A SEG-Y file whose binary header says feet, beside survey files in US
      # survey feet: the map's unit is US survey feet, with no disagreement.
      let segy = fx.surveySegy(measurementSystem = 2)
      let sps = fx.surveySpsIn("usft", "feet", "0.3048006096")
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      doAssert headerUnitOf(st.sessions[0].crs) == suFeet, $st.sessions[0].crs.units
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
      doAssert st.settle(st.survey.findFile(sps.s) >= 0 and st.survey.findFile(sps.r) >= 0)
      doAssert st.unitsOf == "ftUS", st.unitsOf
      doAssert st.unitsDisagree == "", "the units disagree: " & st.unitsDisagree
      # Imported with the units chosen by hand: the file's confirmed.
      let files = @[JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
        JoinFile(path: sps.x, kind: jkSps)]
      let before = st.joinReport.serial
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files,
        joinUnits: JoinUnits(survey: suUsFeet, file: suUsFeet))
      doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob)
      doAssert st.joinedOf(st.sessions[0].id) >= 0, $st.joinReport.words
      var named: seq[string]
      for (what, u) in st.unitSources: named.add what & ": " & $u
      doAssert "the units confirmed for " & segy.extractFilename & "'s headers: US survey feet" in
        named, $named
      doAssert st.unitsOf == "ftUS" and st.unitsDisagree == "", st.unitsDisagree
      # A survey file in metres does disagree.
      let (ms, _) = fx.mapSpsIn("mapm", "Metres", "1.0")
      st.apply Command(kind: ckLoadSurvey, paths: @[ms])
      doAssert st.settle(st.survey.findFile(ms) >= 0)
      doAssert st.unitsDisagree.len > 0

  block theFirstBreakKeyTakesTheSurveysUnitWhereTheFileNamesNone:
    # The first-break overlay's velocity label (nothing is converted): a file whose binary
    # header names no measurement system takes the project's survey's unit (US survey feet);
    # one that names metres keeps metres, whatever the survey says, with no warning.
    withFixtures fx:
      let sps = fx.surveySpsIn("keyunit", "feet", "0.3048006096")
      for (system, unit, fromSurvey) in [(0'i16, suUsFeet, true), (1'i16, suMetres, false),
          (2'i16, suFeet, false)]:
        let segy = fx.surveySegy(measurementSystem = system)
        var st = initAppState()
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
        doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
        let k = st.findPanel(MainPanel)
        doAssert st.breakOffsetUnit(k) == (if system == 0: suNotGiven else: unit),
          "no survey yet: the file's own unit"
        doAssert not st.breakUnitFromSurvey(k)
        st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
        doAssert st.settle(st.survey.findFile(sps.s) >= 0 and st.survey.findFile(sps.r) >= 0)
        doAssert st.breakOffsetUnit(k) == unit, "measurement system " & $system & ": " &
          $st.breakOffsetUnit(k)
        doAssert st.breakUnitFromSurvey(k) == fromSurvey, "measurement system " & $system

  block notReadFirst:
    withFixtures fx:
      # An import whose units nobody chose (an agent's with none given, or the
      # window's Import while the files are still being read), for survey
      # files neither on the map nor read: the import works the units out from
      # the files it reads. A SEG-Y file's "feet" is then US survey feet, as
      # the survey says, and nothing disagrees.
      let segy = fx.surveySegy(measurementSystem = 2)
      let sps = fx.surveySpsIn("unread", "feet", "0.3048006096")
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      doAssert st.heads.len == 0 and st.survey.findFile(sps.s) < 0
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[JoinFile(
        path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps), JoinFile(path: sps.x,
        kind: jkSps)], joinUnits: JoinUnits(surveyFromHeaders: true, fileFromHeaders: true))
      doAssert st.settle(st.joinReport.serial > 0 and st.joinUnderWay.job == NoJob)
      let j = st.joinedOf(st.sessions[0].id)
      doAssert j >= 0, $st.joinReport.words
      let u = st.joins[j].units
      doAssert u.survey == suUsFeet and u.file == suUsFeet and u.surveyFromHeaders and
        u.fileFromHeaders, "the import's units, read by it: " & $u
      doAssert st.unitsOf == "ftUS" and st.unitsDisagree == "", st.unitsDisagree
      var named: seq[string]
      for (what, unit) in st.unitSources: named.add what & ": " & $unit
      doAssert segy.extractFilename & "'s headers, as imported: US survey feet" in named, $named

  block aHungShare:
    # A survey file on a drive that does not answer holds only the units'
    # reads, on their own lane: a seismic file opens meanwhile, well before a
    # lane would go on beside the stalled job (`StallAfter`).
    install()
    withFixtures fx:
      let sps = fx.surveySpsIn("hung", "feet", "0.3048006096")
      let segy = fx.surveySegy()
      var st = initAppState()
      fault(sps.s, fkHang)
      st.apply Command(kind: ckSurveyUnits, unitsOf: @[JoinFile(path: sps.s, kind: jkSps)])
      doAssert st.settle(hung() == 1), "the file does not answer"
      let t0 = getMonoTime()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let took = getMonoTime() - t0
      doAssert took < StallAfter, "the seismic file waited for the survey file's headers: " &
        $took.inMilliseconds & " ms"
      for j in st.jobs.list:
        if j.spec.title.startsWith("Read the units of"):
          doAssert j.spec.lane == jlPeeks, $j.spec.lane
      doAssert hung() == 1 and not st.heads[0].done
      release(sps.s)
      doAssert st.settle(st.heads[0].done)
      doAssert st.heads[0].head.unit == suUsFeet, $st.heads[0]
      doAssert uiCalls().len == 0, $uiCalls()
    echo "tjoinunits: done"

when isMainModule:
  main()
