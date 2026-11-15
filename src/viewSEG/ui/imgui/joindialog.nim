## The "Join geometry" window (File > Join geometry...): survey files joined
## to an open file's traces, in memory (`ckJoin`, `core/join`).
##
## From the top: the seismic file (the one the plot shows, or another open
## file) with the units its headers give its coordinates in and its CRS as
## the file gives it; the survey files, the loaded ones ticked, others added
## with "Add files..." (SPS, SEG P1, CSV tables, a CSV table's role), with
## the units their headers give; the join's options (the trailing digits of
## line names, line names mapped to numbers, several channels per station,
## the headers' coordinates kept or replaced, how the records are checked
## against the relation records); Join; then what the join did, in plain
## words, with "Select unmatched traces". **Units and the CRS come from the
## headers first:** each dropdown starts at what the headers say, and the
## user only confirms or corrects; the units the join is made with label
## the map and the status bar. The options are remembered (the settings);
## the units chosen for a file are kept while the program runs.
##
## A floating window like any other: Tab moves between its controls, and
## the click that brings it forward does only that (Join and Select act only
## in a window that had the focus).

import std/[options, os, strutils, tables]
import imguin/cimgui
import parseSEG
import ../../core/[filekinds, geometry, state]
import ../../view/theme
import chrome, focus, icons, style

type
  JoinUi* = object
    ## The window's own state between frames.
    shown*: bool                    ## the window is open
    bringUp: bool                   ## bring it forward next frame
    focus: FocusClicks
    session: SessionId              ## the file chosen; `NoSession`: the one the plot shows
    added: seq[JoinFile]            ## the files added with "Add files..."
    unticked: seq[string]           ## loaded survey files left out (their paths)
    units: Table[string, JoinUnits] ## per seismic file (its path): the units the user chose
    lineText: array[4096, char]     ## the line names, as typed
    lineFrom: seq[LineName]         ## the settings' line names the text was made from
    lineProblems: seq[string]
    about: SessionId                ## the file `crs` and `fileUnits` are of
    crs: seq[char]                  ## its CRS text, for a read-only box
    crsFormat: string
    fileUnits: SurveyUnit           ## what its headers say
    reported: int                   ## the join report shown last (its serial)

  JoinOutput* = object
    commands*: seq[Command]
    addFiles*: bool ## show the file dialog for survey files to add

func kindByName*(path: string): JoinFileKind =
  ## What a file added to the join is, by its name (the join reads its first
  ## bytes to be sure): a CSV table (`.csv`, `.txt`, `.tsv`), SEG P1, or SPS.
  case path.splitFile.ext.toLowerAscii
  of ".csv", ".txt", ".tsv": jkCsv
  of ".p1", ".p190", ".ukooa": jkP1
  else: jkSps

proc open*(ui: var JoinUi) =
  ## Shows the window, in front.
  ui.shown = true
  ui.bringUp = true

proc addFiles*(ui: var JoinUi; paths: openArray[string]) =
  ## Adds `paths` (from the file dialog) to the survey files to join.
  for p in paths:
    var known = false
    for f in ui.added:
      if f.path == p: known = true
    if not known: ui.added.add JoinFile(path: p, kind: kindByName(p))

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc dim(text: string; t: Theme) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc wrapped(text: string; colour: Rgba) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc marked(marks: var Marks; name: string) =
  ## Marks the item drawn last as `name`, and as "join.focused <name>" while
  ## it has the keyboard focus (Tab moves it).
  marks.mark(name)
  if igIsItemFocused(): marks.mark("join.focused " & name)

proc unitCombo(id: string; u: var SurveyUnit; marks: var Marks; name: string): bool =
  ## A dropdown of the units; true when the user chose one.
  igSetNextItemWidth(igGetFontSize() * 14)
  if igBeginCombo(id.cstring, ($u).cstring, 0):
    for v in SurveyUnit:
      if igSelectable_Bool(($v).cstring, v == u, 0, ImVec2_c(x: 0, y: 0)):
        u = v
        result = true
    igEndCombo()
  marks.marked(name)

proc enumCombo[T: enum](id: string; v: var T; width: float32): bool =
  igSetNextItemWidth(width)
  if igBeginCombo(id.cstring, ($v).cstring, 0):
    for x in T:
      if igSelectable_Bool(($x).cstring, x == v, 0, ImVec2_c(x: 0, y: 0)):
        v = x
        result = true
    igEndCombo()

proc setText(buf: var array[4096, char]; text: string) =
  let n = min(text.len, buf.len - 1)
  for i in 0 ..< n: buf[i] = text[i]
  buf[n] = '\0'

proc learn(ui: var JoinUi; st: AppState; i: int) =
  ## What the headers of open file `sessions[i]` say: its CRS and units.
  let s = st.sessions[i]
  if ui.about == s.id: return
  ui.about = s.id
  var text = ""
  ui.crsFormat = ""
  ui.fileUnits = suNotGiven
  try:
    let sum = s.file.summary
    ui.fileUnits = unitOf(sum.coordinateUnits)
    if sum.crsFormat != ctNone:
      text = s.file.crsText
      ui.crsFormat = $sum.crsFormat
  except CatchableError:
    discard # a file whose summary cannot be made says nothing of its units
  ui.crs = newSeq[char](text.len + 1)
  for k, c in text: ui.crs[k] = c

proc drawOptions(ui: var JoinUi; opts: var JoinOptions; t: Theme; marks: var Marks): bool =
  ## The join's options; true when one changed.
  if igCheckbox("Use the trailing digits of line names (CLT4960 is line 4960)",
      addr opts.trailingDigits):
    result = true
  marks.marked("join.trailing digits")
  tip("For survey files whose line names are not numbers (SPS 1.0, P1), after the names " &
    "mapped below")
  if opts.lineNames != ui.lineFrom:
    ui.lineFrom = opts.lineNames
    ui.lineText.setText(lineNamesText(opts.lineNames))
  igTextUnformatted("Line names as numbers, one per line (name = number):", nil)
  if igInputTextMultiline("##linenames", cast[cstring](addr ui.lineText[0]),
      csize_t(ui.lineText.len), ImVec2_c(x: -1, y: igGetTextLineHeight() * 3), 0, nil, nil):
    ui.lineProblems.setLen 0
    let names = parseLineNames($cast[cstring](addr ui.lineText[0]), ui.lineProblems)
    if ui.lineProblems.len == 0 and names != opts.lineNames:
      opts.lineNames = names
      ui.lineFrom = names
      result = true
  marks.marked("join.line names")
  for p in ui.lineProblems: wrapped(p, t.roles[rlWarning])
  if igCheckbox("Several channels per station (multi-component X records)",
      addr opts.multiComponent):
    result = true
  marks.marked("join.components")
  tip("An X record's channel increment k covers k channels per station, components 1 to k; " &
    "off, only every k-th channel is in it")
  igAlignTextToFramePadding()
  igTextUnformatted("Coordinates the headers give:", nil)
  igSameLine(0, -1)
  if enumCombo("##coordinates", opts.coordinates, igGetFontSize() * 16): result = true
  marks.marked("join.coordinates")
  tip("Keep them and fill only those the headers lack, or replace them by the survey's. " &
    "Coordinates at (0, 0) count as none when every coordinate the headers give is (0, 0).")
  igTextUnformatted("The records' check against the relation records (Records, Missing):", nil)
  igAlignTextToFramePadding()
  igTextUnformatted("a record by", nil)
  igSameLine(0, -1)
  if enumCombo("##recordmatch", opts.recordMatch, igGetFontSize() * 6): result = true
  igSameLine(0, -1)
  igTextUnformatted("its traces by", nil)
  igSameLine(0, -1)
  if enumCombo("##tracematch", opts.traceMatch, igGetFontSize() * 6): result = true
  tip("processSEG's record completeness: auto finds a record's X record by its source " &
    "station, else its field record number, and its traces by their receiver stations, " &
    "else their channel numbers")

proc drawJoin*(ui: var JoinUi; title: string; st: AppState; t: Theme;
    marks: var Marks): JoinOutput =
  ## The window, titled `title`, while it is open.
  if not ui.shown: return
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  # First over the left of the main window (the file list): the plot and the
  # map, which show what the join does, stay in sight.
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + igGetFontSize(), y: vp.WorkPos.y +
    igGetFontSize() * 5), ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 34, y: min(igGetFontSize() * 40,
    vp.WorkSize.y - igGetFontSize() * 6)), ImGui_Cond_FirstUseEver.cint)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("join")
    let underWay = st.joinUnderWay
    let busy = underWay.job != NoJob
    var opts = st.settings.join
    var changed = false
    var files: seq[JoinFile]
    var units: JoinUnits
    var target = -1 # the file chosen: its index in `sessions`
                    # The window's content scrolls; Join, Close and the progress stay below
                    # it, in sight. Tab goes through both (a flattened child).
    let footer = igGetFrameHeightWithSpacing() + igGetStyle().ItemSpacing.y
    discard igBeginChild_Str("##content", ImVec2_c(x: 0, y: -footer),
      ImGui_ChildFlags_NavFlattened.cint, 0)
    # -- the seismic file
    igSeparatorText("Seismic file")
    let k = st.findPanel(MainPanel)
    let shown = if k >= 0: st.shownFile(k) else: -1
    var i = st.findSession(ui.session)
    if i < 0: i = shown
    if i < 0 and st.sessions.len > 0: i = 0
    target = i
    if i < 0:
      dim("No seismic file is open: open the file to join its traces with the survey.", t)
    else:
      template s: untyped = st.sessions[i]
      igSetNextItemWidth(-1)
      if igBeginCombo("##file", s.name.cstring, 0):
        for j in 0 ..< st.sessions.len:
          let name = st.sessions[j].name & (if j == shown: "  (in the plot)" else: "")
          igPushID_Int(cint(j))
          if igSelectable_Bool(name.cstring, j == i, 0, ImVec2_c(x: 0, y: 0)):
            ui.session = st.sessions[j].id
          igPopID()
        igEndCombo()
      marks.marked("join.file")
      tip(s.path)
      ui.learn(st, i)
      units = ui.units.getOrDefault(s.path, JoinUnits(file: ui.fileUnits, survey: suNotGiven))
      let joinedAt = st.joinedOf(s.id)
      if joinedAt >= 0:
        dim("Joined already with " & ($st.joins[joinedAt].files.len) & " survey files: a " &
          "join again starts from the keys as they are now.", t)
      igAlignTextToFramePadding()
      igTextUnformatted("Its headers' coordinates are in", nil)
      igSameLine(0, -1)
      var fileUnit = units.file
      if unitCombo("##fileunits", fileUnit, marks, "join.file units"):
        units.file = fileUnit
        ui.units[s.path] = units
      tip("What the file's headers say: " & $ui.fileUnits & ". Change it when the headers " &
        "are wrong; nothing is converted.")
      if ui.crs.len > 1:
        igTextUnformatted(("Its coordinate reference system, as the file gives it (" &
          ui.crsFormat & "):").cstring, nil)
        discard igInputTextMultiline("##crs", cast[cstring](addr ui.crs[0]), csize_t(ui.crs.len),
          ImVec2_c(x: -1, y: igGetTextLineHeight() * 4), ImGui_InputTextFlags_ReadOnly.cint,
          nil, nil)
        marks.marked("join.crs")
      else:
        dim("The file gives no coordinate reference system: the survey's headers say what " &
          "the join's coordinates are (below).", t)
      # -- the survey files
      igSeparatorText("Survey files")
      var derived = suNotGiven
      var said = ""
      var loaded = 0
      for li in 0 ..< st.survey.layers.len:
        template l: untyped = st.survey.layers[li]
        if l.origin == loSurveyFile:
          inc loaded
          igPushID_Int(cint(li))
          var on = l.path notin ui.unticked
          if igCheckbox((l.name & "  (" & $l.kind & ")").cstring, addr on):
            if on: ui.unticked.delete(ui.unticked.find(l.path))
            else: ui.unticked.add l.path
          marks.marked("join.survey " & l.name)
          tip(l.path & "\n" & l.summary)
          igPopID()
          if on:
            files.add JoinFile(path: l.path, kind: (if l.kind == fkP1: jkP1 else: jkSps))
            if derived == suNotGiven and l.gridUnit.known:
              derived = unitOf(l.gridUnit)
              said = describe(l.gridUnit)
      var drop = -1
      for a in 0 ..< ui.added.len:
        igPushID_Int(cint(10_000 + a))
        if igSmallButton(IconClose.cstring): drop = a
        tip("Leave it out")
        igSameLine(0, -1)
        igTextUnformatted((ui.added[a].path.extractFilename & "  (" & $ui.added[a].kind &
          ")").cstring, nil)
        tip(ui.added[a].path)
        if ui.added[a].kind == jkCsv:
          igSameLine(0, -1)
          var role = ui.added[a].role
          if enumCombo("##role", role, igGetFontSize() * 13): ui.added[a].role = role
          tip("Which stations its rows are: as its kind column says (S or R), or all " &
            "sources, or all receivers")
        igPopID()
        files.add ui.added[a]
      if drop >= 0: ui.added.delete(drop)
      if loaded == 0 and ui.added.len == 0:
        dim("No survey file is loaded: add the survey's S, R and X files (SPS), SEG P1 " &
          "files or a CSV table of stations.", t)
      if igButton((IconOpenFile & "  Add files...").cstring, ImVec2_c(x: 0, y: 0)):
        result.addFiles = true
      marks.marked("join.add")
      tip("SPS (S, R, X), SEG P1 files, or a CSV table of stations: line, point, x, y " &
        "(and index, elevation, kind) columns")
      if not ui.units.hasKey(s.path) or units.survey == suNotGiven and derived != suNotGiven:
        units.survey = derived
      igAlignTextToFramePadding()
      igTextUnformatted("Their coordinates are in", nil)
      igSameLine(0, -1)
      var surveyUnit = units.survey
      if unitCombo("##surveyunits", surveyUnit, marks, "join.survey units"):
        units.survey = surveyUnit
        ui.units[s.path] = units
      tip(if said.len > 0: "What the SPS headers say: " & said & ". Change it when they are " &
            "wrong; nothing is converted: the map and the status bar label the coordinates " &
            "with it."
          else: "No loaded survey file says. Choose what its coordinates are in: the map " &
            "and the status bar label them with it; nothing is converted.")
      if said.len > 0: dim("The SPS headers say " & said & ".", t)
      if units.file != suNotGiven and units.survey != suNotGiven and
          units.file != units.survey and opts.coordinates == hcFill:
        wrapped("The headers' coordinates are in " & $units.file & " and the survey's in " &
          $units.survey & ": the join does not convert them. Choose \"" & $hcReplace &
          "\" to have the survey's everywhere.", t.roles[rlWarning])
      # -- options
      if igCollapsingHeader_TreeNodeFlags("Options", 0):
        marks.marked("join.options")
        if ui.drawOptions(opts, t, marks): changed = true
      else:
        marks.marked("join.options")
      # -- what the last join did
      let r = st.joinReport
      if r.serial > 0 and r.session == s.id:
        igSeparatorText("Joined")
        if r.serial != ui.reported: # a new one: shown
          igSetScrollHereY(0)
          ui.reported = r.serial
        let colour = case r.outcome
          of joJoined: t.roles[rlText]
          of joNothing: t.roles[rlWarning]
          of joFailed: t.roles[rlError]
          else: t.roles[rlTextDim]
        for w in r.words: wrapped(w, colour)
        marks.marked("join.report")
        let j = st.joinedOf(s.id)
        if j >= 0:
          for n in st.joins[j].survey.notes: dim(n, t)
        if r.outcome == joJoined and r.unmatched > 0 and j >= 0:
          if igButton(("Select unmatched traces (" & $r.unmatched & ")").cstring,
              ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
            result.commands.add Command(kind: ckSelectUnmatched, unmatchedOf: s.id)
          marks.marked("join.unmatched")
          tip("Select the traces the survey has no source or receiver station for, in the " &
            "plot and on the map")
    igEndChild()
    # -- join
    igSeparator()
    let can = not busy and files.len > 0 and target >= 0
    igBeginDisabled(not can)
    if igButton((IconMap & "  Join").cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and can:
      let s = st.sessions[target]
      result.commands.add Command(kind: ckJoin, joinFile: s.id, joinFiles: files,
        joinOptions: opts, joinUnits: units)
      ui.units[s.path] = units
    igEndDisabled()
    marks.marked("join.run")
    tip(if busy: "A join is under way" elif target < 0: "No seismic file is open"
        elif files.len == 0: "Choose survey files first"
        else: "Join them to " & st.sessions[target].name & "'s traces, in memory: the file " &
          "is not changed")
    igSameLine(0, -1)
    if igButton("Close", ImVec2_c(x: 0, y: 0)): ui.shown = false
    marks.marked("join.close")
    if busy:
      igSameLine(0, -1)
      let info = st.jobs.info(underWay.job)
      var fraction = -float32(igGetTime())
      var text = $underWay.step
      if info.isSome:
        let p = info.get.progress
        if p.total > 0: fraction = float32(p.done) / float32(p.total)
        if p.phase.len > 0: text = p.phase
      igProgressBar(fraction, ImVec2_c(x: igGetFontSize() * 12, y: 0), text.cstring)
      marks.marked("join.progress")
      igSameLine(0, -1)
      if igSmallButton((IconClose & " Cancel").cstring):
        result.commands.add Command(kind: ckCancelJob, job: underWay.job)
      marks.marked("join.cancel")
    if changed:
      var s = st.settings
      s.join = opts
      result.commands.add Command(kind: ckSettings, settings: s)
    ui.focus.settle()
  igEnd()
  if not open: ui.shown = false
