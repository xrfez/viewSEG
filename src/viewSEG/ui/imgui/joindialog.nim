## The "Import survey" window (Project > Import survey): a survey's files
## put on the map (as File > Open loads them) and matched to an open file's
## traces, in memory (`ckJoin`, `core/join`; the code keeps parseSEG's word,
## the join); with no file open, put on the map only.
##
## In the order of the work: the survey files, the loaded ones ticked,
## others added with "Add files..." (SPS, SEG P1, CSV tables, a CSV table's
## role), with the units their headers give; the seismic file whose traces
## they are matched to (the one the plot shows, or another open file), with
## the units its headers give its coordinates in and its CRS as the file
## gives it; the options (the trailing digits of line names, line names
## mapped to numbers, several channels per station, the headers'
## coordinates kept or replaced, how the records are checked against the
## relation records); Import; then what the import did, in plain words,
## with "Select unmatched traces". **Units and the CRS come from the
## headers first:** each dropdown starts at what the headers say, and the
## user only confirms or corrects; the units the survey is imported with
## label the map and the status bar. A survey file's headers are read as soon
## as it is chosen (its first bytes, on a job: `ckSurveyUnits`), so the
## survey's box shows what they say, and the files that disagree are named;
## the seismic file's box follows the survey's where its own headers say
## nothing, or only "feet" (SEG-Y cannot tell the US survey foot from the
## international), so the user enters a unit once at most; a metres-against-
## feet conflict is a warning. The options are remembered (the settings); the
## units the user chose by hand are the state's (`ckChooseUnit`,
## `unitChoices`): a survey's by its files, a seismic file's by its path;
## nothing the headers say replaces them, and "As the headers say" in the
## dropdown takes one back.
##
## A floating window like any other: Tab moves between its controls, and
## the click that brings it forward does only that (Import and Select act only
## in a window that had the focus).

import std/[options, os, strutils]
import imguin/cimgui
import parseSEG
import ../../core/[filekinds, geometry, state]
import ../../view/theme
import chrome, clearsurvey, focus, icons, style

type
  JoinUi* = object
    ## The window's own state between frames.
    shown*: bool                ## the window is open
    bringUp: bool               ## bring it forward next frame
    placeAgain: bool            ## put it back at its first place and size next frame
    focus: FocusClicks
    session: SessionId          ## the file chosen; `NoSession`: the one the plot shows
    added: seq[JoinFile]        ## the files added with "Add files..."
    unticked: seq[string]       ## loaded survey files left out (their paths)
    asked: seq[string]          ## survey files whose headers were asked for (`ckSurveyUnits`)
    drawn: JoinUnits            ## the units the window showed last
    drawnNote: string           ## and the dim line under the seismic file's
    lineText: array[4096, char] ## the line names, as typed
    lineFrom: seq[LineName]     ## the settings' line names the text was made from
    lineProblems: seq[string]
    about: SessionId            ## the file `crs` and `fileUnits` are of
    crs: seq[char]              ## its CRS text, for a read-only box
    crsFormat: string
    fileUnits: SurveyUnit       ## what its headers say (`headerUnitOf`)
    reported: int               ## the join report shown last (its serial)

  JoinOutput* = object
    commands*: seq[Command]
    addFiles*: bool    ## show the file dialog for survey files to add
    clearSurvey*: bool ## Clear survey was clicked: ask for its confirmation

func kindByName*(path: string): JoinFileKind =
  ## What a file added to the import is, by its name (the import reads its
  ## first bytes to be sure): a CSV table (`.csv`, `.txt`, `.tsv`), SEG P1,
  ## or SPS.
  case path.splitFile.ext.toLowerAscii
  of ".csv", ".txt", ".tsv": jkCsv
  of ".p1", ".p190", ".ukooa": jkP1
  else: jkSps

proc open*(ui: var JoinUi) =
  ## Shows the window, in front.
  ui.shown = true
  ui.bringUp = true

func units*(ui: JoinUi): JoinUnits {.inline.} =
  ## The units the window showed when last drawn: the survey's and the
  ## seismic file's, as Import would send them.
  ui.drawn

func fileNote*(ui: JoinUi): lent string {.inline.} =
  ## The dim line under the seismic file's unit when last drawn: why it is
  ## not what the headers say ("The headers say feet; taken as US survey
  ## feet, as the survey says"); "" for none.
  ui.drawnNote

proc placeAgain*(ui: var JoinUi) =
  ## Puts the window back at its first place and size when next drawn
  ## (Reset the windows).
  ui.placeAgain = true

proc addFiles*(ui: var JoinUi; paths: openArray[string]) =
  ## Adds `paths` (from the file dialog) to the survey files to import.
  for given in paths:
    let p = canonical(given) # as the map's layers name them
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

proc unitCombo(id: string; shown, headers: SurveyUnit; chosen: bool; marks: var Marks;
    name: string): tuple[picked, byHand: bool; unit: SurveyUnit] =
  ## A dropdown of the units, `shown` now (`chosen`: by the user), with "as
  ## the headers say" (`headers`) first, which takes a choice back; what the
  ## user picked, if anything.
  igSetNextItemWidth(igGetFontSize() * 16)
  let preview = $shown & (if chosen: "  (yours)" else: "")
  if igBeginCombo(id.cstring, preview.cstring, 0):
    if igSelectable_Bool(("As the headers say: " & $headers).cstring, not chosen, 0,
        ImVec2_c(x: 0, y: 0)):
      result = (true, false, headers)
    marks.mark(name & " headers")
    for v in SurveyUnit:
      if igSelectable_Bool(($v).cstring, chosen and v == shown, 0, ImVec2_c(x: 0, y: 0)):
        result = (true, true, v)
      marks.mark(name & " " & $v)
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
  # Read on the open job: nothing here reads the file (a network drive may hang).
  let text = s.crs.text
  ui.fileUnits = headerUnitOf(s.crs)
  ui.crsFormat = if s.crs.format == ctNone: "" else: $s.crs.format
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
  igTextUnformatted("a record's traces by", nil)
  igSameLine(0, -1)
  if enumCombo("##tracematch", opts.traceMatch, igGetFontSize() * 6): result = true
  tip("A shot is checked against the X record at its source station, a receiver gather " &
    "against the O records at its receiver station; never by a record number. Auto finds " &
    "a record's traces by their receiver stations, else their channel numbers")

proc drawJoin*(ui: var JoinUi; title: string; st: AppState; t: Theme;
    marks: var Marks): JoinOutput =
  ## The window, titled `title`, while it is open.
  if not ui.shown: return
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  # First over the left of the main window (the file list): the plot and the
  # map, which show what the import does, stay in sight.
  let cond = if ui.placeAgain: ImGui_Cond_Always.cint else: ImGui_Cond_FirstUseEver.cint
  ui.placeAgain = false
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + igGetFontSize(), y: vp.WorkPos.y +
    igGetFontSize() * 5), cond, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 34, y: min(igGetFontSize() * 40,
    vp.WorkSize.y - igGetFontSize() * 6)), cond)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("join")
    let underWay = st.joinUnderWay
    let busy = st.importing
    var opts = st.settings.join
    var changed = false
    var files: seq[JoinFile]
    # The file the survey is matched to: the one chosen, else the plot's,
    # else the first open; its index in `sessions`, -1 for none.
    let k = st.findPanel(MainPanel)
    let shown = if k >= 0: st.shownFile(k) else: -1
    var target = st.findSession(ui.session)
    if target < 0: target = shown
    if target < 0 and st.sessions.len > 0: target = 0
    if target >= 0: ui.learn(st, target)
    let key = if target >= 0: st.sessions[target].path else: ""
    # The window's content scrolls; Import, Close and the progress stay below
    # it, in sight. Tab goes through both (a flattened child).
    let footer = igGetFrameHeightWithSpacing() + igGetStyle().ItemSpacing.y
    discard igBeginChild_Str("##content", ImVec2_c(x: 0, y: -footer),
      ImGui_ChildFlags_NavFlattened.cint, 0)
    # -- the survey files
    igSeparatorText("Survey files")
    var heads: seq[SurveyHead] # what each chosen file's headers say, in order
    var ask: seq[JoinFile] # files whose headers are not read yet
    template headOf(f: JoinFile) =
      let h = st.surveyHead(f.path)
      if h >= 0: heads.add st.heads[h]
      else:
        heads.add SurveyHead(file: f)
        if f.path notin ui.asked:
          ui.asked.add f.path
          ask.add f
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
          let f = JoinFile(path: l.path, kind: (if l.kind == fkP1: jkP1 else: jkSps))
          files.add f
          if l.kind != fkP1 and l.gridUnit.known: # read with the file
            heads.add SurveyHead(file: f, done: true, head: headUnitOf(l.gridUnit))
          else: headOf(f)
    # A file added that is on the map now (Import loaded it) is listed with
    # the loaded ones, ticked: not twice.
    var a = 0
    while a < ui.added.len:
      if st.survey.findFile(ui.added[a].path) >= 0:
        let off = ui.unticked.find(ui.added[a].path)
        if off >= 0: ui.unticked.delete(off)
        ui.added.delete(a)
      else: inc a
    var drop = -1
    for a in 0 ..< ui.added.len:
      igPushID_Int(cint(10_000 + a))
      if igSmallButton(IconRemove.cstring): drop = a
      tip("Leave it out")
      igSameLine(0, -1)
      igTextUnformatted((ui.added[a].path.extractFilename & "  (" & $ui.added[a].kind &
        ")").cstring, nil)
      marks.mark("join.added " & ui.added[a].path.extractFilename)
      tip(ui.added[a].path)
      if ui.added[a].kind == jkCsv:
        igSameLine(0, -1)
        var role = ui.added[a].role
        if enumCombo("##role", role, igGetFontSize() * 13): ui.added[a].role = role
        tip("Which stations its rows are: as its kind column says (S or R), or all " &
          "sources, or all receivers")
      igPopID()
      files.add ui.added[a]
      headOf(ui.added[a])
    if drop >= 0:
      let gone = ui.asked.find(ui.added[drop].path)
      if gone >= 0: ui.asked.delete(gone) # (asked again when added again: one that failed)
      ui.added.delete(drop)
    if ask.len > 0: result.commands.add Command(kind: ckSurveyUnits, unitsOf: ask)
    let said = surveyUnitsSaid(heads)
    if loaded == 0 and ui.added.len == 0:
      dim("Choose the survey's files: its S, R, X and O files (SPS), SEG P1 files or a CSV " &
        "table of stations.", t)
    if igButton((IconOpenFile & "  Add files...").cstring, ImVec2_c(x: 0, y: 0)):
      result.addFiles = true
    marks.marked("join.add")
    tip("SPS (S, R, X, O), SEG P1 files, or a CSV table of stations: line, point, x, y " &
      "(and index, elevation, kind) columns")
    igAlignTextToFramePadding()
    igTextUnformatted("Their coordinates are in", nil)
    igSameLine(0, -1)
    var paths: seq[string] = @[] # the survey: its hand choice is of these files
    for f in files: paths.add f.path
    var surveyUnit = said.unit
    let surveyChosen = st.unitChoices.chosenFor(paths, surveyUnit)
    let pick = unitCombo("##surveyunits", surveyUnit, said.unit, surveyChosen, marks,
      "join.survey units")
    if pick.picked and paths.len > 0:
      result.commands.add Command(kind: ckChooseUnit, unitChoice: UnitChoice(survey: paths,
        unit: pick.unit, byHand: pick.byHand))
      surveyUnit = pick.unit
    tip(if surveyChosen: "As you chose, for these files. The headers say " & (if said.unit ==
          suNotGiven: "nothing of it" else: $said.unit) & ": \"As the headers say\" takes " &
          "your choice back. Nothing is converted: the map and the status bar label the " &
          "coordinates with it."
        elif said.unit != suNotGiven: "What the survey files' headers say. Change it when " &
          "they are wrong; nothing is converted: the map and the status bar label the " &
          "coordinates with it."
        else: "No survey file chosen says. Choose what its coordinates are in: the map " &
          "and the status bar label them with it; nothing is converted.")
    for w in said.words: dim(w, t)
    if said.words.len > 0: marks.marked("join.survey said")
    if surveyChosen and surveyUnit != said.unit and said.unit != suNotGiven:
      dim("You chose " & $surveyUnit & " for these files; their headers say " & $said.unit &
        ".", t)
      marks.marked("join.survey yours")
    var reading = 0
    for h in heads:
      if not h.done: inc reading
      elif h.problem.len > 0:
        wrapped(h.file.path.extractFilename & ": " & h.problem & ".", t.roles[rlWarning])
    if reading > 0:
      dim("Reading what " & (if reading == 1: "a survey file's headers say"
        else: $reading & " survey files' headers say") & " of the unit... Import need " &
        "not wait: it takes the units from the headers as it reads the files.", t)
      marks.marked("join.survey reading")
    if said.disagree.len > 0:
      wrapped(said.disagree, t.roles[rlWarning])
      marks.marked("join.survey disagree")
    for w in said.warnings:
      wrapped(w, t.roles[rlWarning])
      marks.marked("join.survey warning")
    # A unit nobody chose is the headers': the import works it out from the
    # files it reads, never from what this window had read so far.
    var units = JoinUnits(survey: surveyUnit, file: suNotGiven,
      surveyFromHeaders: not (surveyChosen or pick.picked and pick.byHand),
      fileFromHeaders: true)
    ui.drawnNote = ""
    # -- the seismic file
    igSeparatorText("Seismic file")
    if target < 0:
      dim("No seismic file is open: Import puts the survey on the map; open a file and " &
        "import again to match its traces.", t)
    else:
      template s: untyped = st.sessions[target]
      dim("The survey's stations are matched to this file's traces:", t)
      igSetNextItemWidth(-1)
      if igBeginCombo("##file", s.name.cstring, 0):
        for j in 0 ..< st.sessions.len:
          let name = st.sessions[j].name & (if j == shown: "  (in the plot)" else: "")
          igPushID_Int(cint(j))
          if igSelectable_Bool(name.cstring, j == target, 0, ImVec2_c(x: 0, y: 0)):
            ui.session = st.sessions[j].id
          marks.mark("join.file " & st.sessions[j].name)
          igPopID()
        igEndCombo()
      marks.marked("join.file")
      tip(s.path)
      let joinedAt = st.joinedOf(s.id)
      if joinedAt >= 0:
        dim("A survey was imported for it already (" & $st.joins[joinedAt].files.len &
          " files): importing again starts from its keys as they are now.", t)
      let fu = st.unitChoices.fileUnit(key, ui.fileUnits, surveyUnit)
      igAlignTextToFramePadding()
      igTextUnformatted("Its headers' coordinates are in", nil)
      igSameLine(0, -1)
      var fileUnit = fu.unit
      let filePick = unitCombo("##fileunits", fileUnit, fileUnitOf(ui.fileUnits,
        surveyUnit).unit, fu.byHand, marks, "join.file units")
      var fileByHand = fu.byHand
      if filePick.picked:
        result.commands.add Command(kind: ckChooseUnit, unitChoice: UnitChoice(file: key,
          unit: filePick.unit, byHand: filePick.byHand))
        (fileUnit, fileByHand) = (filePick.unit, filePick.byHand)
      units.file = fileUnit
      units.fileFromHeaders = not fileByHand
      ui.drawnNote = fu.note
      tip("What the file's headers say: " & $ui.fileUnits & (if fu.note.len > 0: ". " &
        fu.note else: ".") & " Change it when it is wrong; nothing is converted.")
      if fu.note.len > 0:
        dim(fu.note, t)
        marks.marked("join.file note")
      if fu.conflict.len > 0:
        wrapped(fu.conflict & (if opts.coordinates == hcFill: " Or choose \"" & $hcReplace &
          "\" (Options) to have the survey's coordinates everywhere." else: ""),
          t.roles[rlWarning])
        marks.marked("join.file conflict")
      if ui.crs.len > 1:
        igTextUnformatted(("Its coordinate reference system, as the file gives it (" &
          ui.crsFormat & "):").cstring, nil)
        discard igInputTextMultiline("##crs", cast[cstring](addr ui.crs[0]), csize_t(ui.crs.len),
          ImVec2_c(x: -1, y: igGetTextLineHeight() * 4), ImGui_InputTextFlags_ReadOnly.cint,
          nil, nil)
        marks.marked("join.crs")
      else:
        dim("The file gives no coordinate reference system: the survey files' headers say " &
          "what the coordinates are (above).", t)
    # -- options
    if igCollapsingHeader_TreeNodeFlags("Options", 0):
      marks.marked("join.options")
      if ui.drawOptions(opts, t, marks): changed = true
    else:
      marks.marked("join.options")
    # -- what the last import did
    let r = st.joinReport
    let id = if target >= 0: st.sessions[target].id else: NoSession
    if r.serial > 0 and r.session == id:
      igSeparatorText("Imported")
      if r.serial != ui.reported: # a new one: shown
        igSetScrollHereY(0)
        ui.reported = r.serial
      let colour = case r.outcome
        of joJoined, joMapOnly: t.roles[rlText]
        of joNothing: t.roles[rlWarning]
        of joFailed: t.roles[rlError]
        else: t.roles[rlTextDim]
      for w in r.words: wrapped(w, colour)
      marks.marked("join.report")
      let j = st.joinedOf(id)
      if j >= 0:
        for n in st.joins[j].survey.notes: dim(n, t)
      if r.outcome == joJoined and r.unmatched > 0 and j >= 0:
        if igButton(("Select unmatched traces (" & $r.unmatched & ")").cstring,
            ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
          result.commands.add Command(kind: ckSelectUnmatched, unmatchedOf: id)
        marks.marked("join.unmatched")
        tip("Select the traces the survey has no source or receiver station for, in the " &
          "plot and on the map")
    ui.drawn = units
    igEndChild()
    # -- import
    igSeparator()
    let can = not busy and files.len > 0
    igBeginDisabled(not can)
    if igButton((IconSurvey & "  Import").cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
        can:
      result.commands.add Command(kind: ckJoin, joinFile: (if target >= 0:
        st.sessions[target].id else: NoSession), joinFiles: files, joinOptions: opts,
        joinUnits: units)
    igEndDisabled()
    marks.marked("join.run")
    tip(if busy: "An import is under way" elif files.len == 0: "Choose the survey's files first"
        elif target < 0: "Put the survey on the map (no seismic file is open to match it to)"
        else: "Put the survey on the map and match it to " & st.sessions[target].name &
          "'s traces, in memory: the file is not changed")
    igSameLine(0, -1)
    if igButton("Close", ImVec2_c(x: 0, y: 0)): ui.shown = false
    marks.marked("join.close")
    tip("Close this window (the survey already imported stays)")
    igSameLine(0, -1)
    igBeginDisabled(not st.surveyInEffect)
    if igButton((IconTrash & "  " & ClearSurveyWords).cstring, ImVec2_c(x: 0, y: 0)) and
        ui.focus.acts and st.surveyInEffect:
      result.clearSurvey = true
    igEndDisabled()
    marks.marked("join.clear")
    tip(if st.surveyInEffect: ClearSurveyHelp else: NoSurveyHelp)
    if busy:
      igSameLine(0, -1)
      let info = st.jobs.info(underWay.job)
      var fraction = -float32(igGetTime())
      var text = if underWay.job == NoJob: "putting the survey on the map" else: $underWay.step
      if info.isSome:
        let p = info.get.progress
        if p.total > 0: fraction = float32(p.done) / float32(p.total)
        if p.phase.len > 0: text = p.phase
      igProgressBar(fraction, ImVec2_c(x: igGetFontSize() * 12, y: 0), text.cstring)
      marks.marked("join.progress")
      # Once the keys are being changed the join runs to its end (a second or
      # so a million traces): no Cancel then.
      if underWay.job != NoJob and (info.isNone or info.get.spec.cancellable):
        igSameLine(0, -1)
        if igSmallButton((IconStop & " Cancel").cstring):
          result.commands.add Command(kind: ckCancelJob, job: underWay.job)
        marks.marked("join.cancel")
        tip("Ask the import to stop")
    if changed:
      var s = st.settings
      s.join = opts
      result.commands.add Command(kind: ckSettings, settings: s)
    ui.focus.settle()
  igEnd()
  if not open: ui.shown = false
