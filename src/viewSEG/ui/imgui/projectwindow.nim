## The project's windows (docs/project.md): "New project" (Project > New
## project...: a name, a place, the data folders, and what the session takes
## along) and "Project" (Project > Project...: the project open, its data
## folders found or missing with Locate..., its survey and whether each file
## is as it was copied in, with Update from the original when one changed,
## and Close project). Both float, as "File memory" does; the Project window
## comes forward by itself when an original changed, since the change is
## never taken unasked.

import std/[algorithm, os, strutils, times]
import imguin/cimgui
import ../../core/[components, join, sensors, state, stationmoves]
import ../../view/theme
import chrome, clearsurvey, focus, icons, stationmovemenu, style

type
  ProjectAsk* = enum
    ## A folder dialog the window asks for (the frontend shows it).
    paNone, paPlace, paData, paLocate

  ProjectUi* = object
    ## The windows' own state between frames.
    shown*: bool              ## the Project window
    making*: bool             ## the New project window
    bringUp: bool
    placeAgain: bool
    name: array[128, char]
    place*: string            ## where the project folder is made (its parent)
    data*: seq[string]        ## its data folders
    useSurvey*: bool = true
    bringMemory*: bool = true
    takePresets*: bool = true
    locating*: string         ## the missing folder a Locate... is for
    wasOffered: bool          ## the project offered an update at the frame before
    earlierSeen: int          ## earlier outputs of the file shown, at the frame before
    editing: uint8            ## the component whose sensitivity is being typed (0: none)
    draft: float64            ## ... as typed so far
    unitPicked: array[256, int8]
      ## per component, the unit chosen for a row not made yet, as an index into the
      ## units offered it (0 until the user chooses)
    focus: FocusClicks ## the New project window's
    focusProject: FocusClicks ## the Project window's

  ProjectOutput* = object
    commands*: seq[Command]
    ask*: ProjectAsk   ## a folder dialog to show
    askAt*: string     ## where it starts
    clearSurvey*: bool ## Clear survey was clicked: ask for its confirmation

proc open*(ui: var ProjectUi) =
  ## Shows the Project window, in front.
  ui.shown = true
  ui.bringUp = true

proc startNew*(ui: var ProjectUi; place, folder: string) =
  ## Shows the New project window with a place and data folder to start from.
  ui.making = true
  ui.bringUp = true
  ui.place = place
  ui.data = if folder.len > 0: @[folder] else: @[]
  let name = if folder.len > 0: folder.extractFilename else: ""
  for i in 0 ..< ui.name.len: ui.name[i] = '\0'
  for i, c in name:
    if i < ui.name.high: ui.name[i] = c

proc addData*(ui: var ProjectUi; folder: string) =
  if folder notin ui.data: ui.data.add folder

proc placeAgain*(ui: var ProjectUi) = ui.placeAgain = true

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc button(label, mark, help: string; enabled: bool; marks: var Marks): bool =
  igBeginDisabled(not enabled)
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  igEndDisabled()
  marks.mark(mark)
  tip(help)

proc place(ui: var ProjectUi; title: string; w, h: float32) =
  let vp = igGetMainViewport()
  let cond = if ui.placeAgain: ImGui_Cond_Always.cint else: ImGui_Cond_FirstUseEver.cint
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2, y: vp.WorkPos.y +
    vp.WorkSize.y / 2), cond, ImVec2_c(x: 0.5, y: 0.5))
  igSetNextWindowSize(ImVec2_c(x: min(igGetFontSize() * w, vp.WorkSize.x - 40),
    y: min(igGetFontSize() * h, vp.WorkSize.y - 40)), cond)

proc dim(t: Theme; text: string) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("%s", text.cstring)
  igPopStyleColor(1)

proc drawNew(ui: var ProjectUi; title: string; st: AppState; t: Theme; marks: var Marks;
    res: var ProjectOutput) =
  if ui.bringUp and not ui.shown:
    igSetWindowFocus_Str(title.cstring)
  let vp = igGetMainViewport()
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2, y: vp.WorkPos.y +
    vp.WorkSize.y / 2), ImGui_Cond_Appearing.cint, ImVec2_c(x: 0.5, y: 0.5))
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 36, y: 0),
    ImVec2_c(x: igGetFontSize() * 60, y: vp.WorkSize.y - 40), nil, nil)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint or
      ImGui_WindowFlags_AlwaysAutoResize.cint):
    ui.focus.watch()
    marks.markWindow("newproject")
    t.dim("A folder of its own for this job: what you do to its files, its survey (imported " &
      "once, never again), its filters, presets and windows. Copy the folder to hand the job " &
      "over. Data folders are never written to.")
    igTextUnformatted("Name", nil)
    igSameLine(igGetFontSize() * 7, -1)
    igSetNextItemWidth(-1)
    discard igInputText("##projectname", cast[cstring](addr ui.name[0]), csize_t(ui.name.len),
      0, nil, nil)
    marks.mark("newproject.name")
    tip("The project's name: its folder is made under this name")
    let name = ($cast[cstring](addr ui.name[0])).strip
    igTextUnformatted("Made in", nil)
    igSameLine(igGetFontSize() * 7, -1)
    igTextUnformatted((if ui.place.len > 0: ui.place else: "(choose a place)").cstring, nil)
    igSameLine(0, -1)
    if button("Choose...##place", "newproject.place", "The folder the project's folder is " &
        "made in", true, marks):
      res.ask = paPlace
      res.askAt = ui.place
    igSeparatorText("Data folders")
    var gone = -1
    for i, d in ui.data:
      igPushID_Int(cint(i))
      igTextUnformatted((IconFolder & "  " & d).cstring, nil)
      igSameLine(0, -1)
      if igSmallButton("Remove"): gone = i
      igPopID()
    if gone >= 0: ui.data.delete(gone)
    if ui.data.len == 0: igTextDisabled("None yet: add the folders the job's records are in.")
    if button(IconOpenFolder & "  Add a data folder...", "newproject.adddata",
        "A folder of the job's seismic files (several can be added)", true, marks):
      res.ask = paData
      res.askAt = if ui.data.len > 0: ui.data[^1] else: ""
    igSeparatorText("Take along")
    var layers = 0
    for l in st.survey.layers:
      if l.origin == loSurveyFile: inc layers
    igBeginDisabled(layers == 0)
    discard igCheckbox("Use the survey loaded now", addr ui.useSurvey)
    igEndDisabled()
    marks.mark("newproject.survey")
    tip(if layers > 0: "Its " & $layers & " survey files are copied into the project and kept " &
          "there, with the import's options and units" else: "No survey file is on the map")
    discard igCheckbox("Bring what is remembered about the files in these folders",
      addr ui.bringMemory)
    marks.mark("newproject.memory")
    tip("Their kills and polarity reversals are copied into the project (viewSEG keeps its own " &
      "copy too)")
    discard igCheckbox("Take my display presets", addr ui.takePresets)
    marks.mark("newproject.presets")
    tip("Copy the display presets kept on this computer into the project")
    let why = if name.len == 0: "a name is needed" else: projectNameProblem(name)
    let dir = if ui.place.len > 0 and name.len > 0: ui.place / name else: ""
    var inside = ""
    for d in ui.data:
      if dir.len > 0 and dir.isInside(d): inside = d
    if why.len > 0 and name.len > 0:
      igTextColored(vec4(t.roles[rlWarning]), "%s", ("The name cannot be used: " & why).cstring)
    elif inside.len > 0:
      igTextColored(vec4(t.roles[rlWarning]), "%s", ("It would be inside the data folder " &
        inside & ", which is never written to.").cstring)
    elif dir.len > 0: t.dim("The project's folder: " & dir)
    igSpacing()
    if button("Make the project", "newproject.make", "Make the folder and open the project; " &
        "the files open stay open", why.len == 0 and dir.len > 0 and inside.len == 0, marks) and
        ui.focus.acts:
      res.commands.add Command(kind: ckNewProject, projectPath: dir, projectName: name,
        dataFolders: ui.data, useSurvey: ui.useSurvey and layers > 0,
        bringMemory: ui.bringMemory, takePresets: ui.takePresets)
      ui.making = false
    igSameLine(0, -1)
    if button("Cancel##newproject", "newproject.cancel", "Make nothing", true, marks):
      ui.making = false
    ui.focus.settle()
  igEnd()
  if not open: ui.making = false

func stateWords(s: PlaceState): string =
  case s
  of psLooking: "looking..."
  of psFound: "found"
  of psMissing: "missing"
  of psNotAnswering: "not answering"

func originalWords(s: OriginalState): string =
  case s
  of osLooking: "looking..."
  of osAsCopied: "as copied in"
  of osChanged: "changed since it was copied in"
  of osNotFound: "original not found: the copy is used"

proc lastOpened(c: FileRecord): string =
  if c.opened == Time(): "" else: " (last opened " & c.opened.utc.format("yyyy-MM-dd HH:mm") &
    " UTC)"

proc drawShownFile(ui: var ProjectUi; st: AppState; t: Theme; marks: var Marks;
    res: var ProjectOutput) =
  ## The file the plot shows: whether its edits are being checked, and the
  ## earlier outputs of its name, whose edits are not its own.
  let shown = st.shownFile(st.findPanel(MainPanel))
  if shown < 0: return
  let s = st.sessions[shown]
  if st.editsChecking(s.path):
    igTextColored(vec4(t.roles[rlWarning]), "%s", (IconWarning & "  The edits of " & s.name &
      " are being checked: brought back on its size, first and last bytes and time, they " &
      "are taken back if its whole content differs.").cstring)
  let earlier = st.earlierOf(s.path)
  if earlier.len == 0: return
  igSeparatorText(("Edits kept apart for " & s.name).cstring)
  t.dim("Edits made on other contents under the same name, or before the file's content was " &
    "compared, are not applied to it. They are kept, to apply or to forget.")
  for i, c in earlier:
    igPushID_Int(cint(4000 + i))
    let made = (if c.opened == Time(): "an earlier day" else:
      c.opened.local.format("yyyy-MM-dd HH:mm"))
    let on = if c.name.len > 0: c.name else: s.name
    if c.unconfirmed:
      igTextUnformatted(("Edits you made on " & on & " on " & made & " before the file's " &
        "content was compared: " & keptWords(c.edits)).cstring, nil)
    else: igTextUnformatted(("Edits: " & keptWords(c.edits) & lastOpened(c)).cstring, nil)
    marks.mark("project.earlier." & $i)
    let fits = c.traces > 0 and c.traces == s.len
    let (given, takenOff) = st.replaceCounts(s.path, c.edits)
    if button("Apply them to this file", "project.earlier.apply." & $i,
        (if fits and c.unconfirmed: "This file's edits become these: " & $given & " given, " &
          $takenOff & " taken off. One step: Edit > Undo takes it back"
        elif fits: "Apply the earlier output's edits to " & s.name & " by trace number, as " &
          "one step: Edit > Undo takes it back"
        elif c.traces == 0: "Not offered: how many traces the earlier output had is not " &
          "known, so its trace numbers may not be these"
        else: "Not offered: the earlier output had " & $c.traces & " traces, this file has " &
          $s.len & ", so its trace numbers are not these"), fits and not st.project.readOnly,
        marks) and ui.focusProject.acts:
      res.commands.add Command(kind: ckImportEdits, panel: MainPanel,
        listPath: st.store.docPath(c.doc), replaceEdits: c.unconfirmed)
    igSameLine(0, -1)
    if button("Forget them", "project.earlier.forget." & $i,
        (if st.project.readOnly: "Not offered: the project is open read-only (" &
          st.project.whyReadOnly & ")"
        else: "Remove what is remembered about the earlier output (said in Messages)"),
        not st.project.readOnly, marks) and ui.focusProject.acts:
      res.commands.add Command(kind: ckForgetFiles, forget: @[c.doc])
    igPopID()

proc drawMoves(ui: var ProjectUi; st: AppState; t: Theme; marks: var Marks;
    res: var ProjectOutput) =
  ## The station moves: one row each with Remove, or how to make one.
  igSeparatorText("Station moves")
  marks.mark("project.moves")
  let moves = st.project.doc.stationMoves
  if moves.len == 0:
    t.dim("No receiver station is moved. Right-click a trace in the Seismic window and choose " &
      "a move under Map.")
  else:
    t.dim((if st.inProject: "Moves are kept in the project" else:
      "No project is open: these moves hold for this run only") & ". They change a station's " &
      "position on the map, in the checks and in written output; they never change the survey " &
      "files or the recordings.")
    let unit = st.stationMoveUnit.abbreviation
    for i, m in moves:
      igPushID_Int(cint(i))
      let at = if m.fromTime.isSome: "from " & utcWords(m.fromTime.get) else: "every trace"
      let line = "Receiver " & stationWords(m.station) & ", " & at & ": X " &
        formatFloat(m.x, ffDecimal, 2) & ", Y " & formatFloat(m.y, ffDecimal, 2) &
        (if unit.len > 0: " " & unit else: "") &
        (if m.elev.isSome: ", elevation " & formatFloat(m.elev.get, ffDecimal, 2) else: "") &
        (if m.note.len > 0: " (" & m.note & ")" else: "")
      if igSmallButton("Remove"):
        res.commands.add forgetCommand(m)
      marks.mark("project.move.remove." & $i)
      tip("Take this move away: the station's position from the survey or the headers holds again")
      igSameLine(0, -1)
      igTextWrapped("%s", line.cstring)
      marks.mark("project.move." & $i)
      igPopID()

proc presentComponents(st: AppState): seq[uint8] =
  ## The components of the files shown (the main plot's buttons) and of the sensors typed, in
  ## order, each once.
  let k = st.findPanel(MainPanel)
  if k >= 0:
    for c in st.panels[k].componentCodes:
      if c > 0 and c notin result: result.add c
  for r in st.project.doc.sensors:
    if r.component notin result: result.add r.component
  result.sort

proc drawSensors(ui: var ProjectUi; st: AppState; t: Theme; marks: var Marks;
    res: var ProjectOutput) =
  ## The sensors: one row per component present in the open files or already typed, its
  ## sensitivity as wired and its unit, and what is converted.
  igSeparatorText("Sensors")
  marks.mark("project.sensors")
  let imperial = st.settings.units == usImperial
  t.dim((if st.inProject: "Sensors are kept in the project" else:
    "No project is open: these sensors hold for this run only") & ". They turn the status " &
    "bar's raw amplitude into physical units, with the counts-to-volts factor the file itself " &
    "gives.")
  t.dim("Type the sensitivity as wired: a data sheet's figure is usually the open-circuit " &
    "sensitivity, and a damping shunt lowers it, so use the figure for your shunt.")
  t.dim("Only the flat band is converted: below the sensor's natural frequency the true " &
    "motion is larger than shown.")
  igTextUnformatted("Raw amplitude in:", nil)
  for a in AmplitudeIn:
    igSameLine(0, 8)
    if igRadioButton_Bool(($a).capitalizeAscii.cstring, st.settings.amplitudeIn == a) and
        st.settings.amplitudeIn != a:
      res.commands.add Command(kind: ckSettings, settings: st.settings.withAmplitudeIn(a))
    marks.mark("project.amplitude." & $a)
  tip("What the status bar's raw amplitude shows: the sample as the file has it (counts), " &
    "volts at the recorder's input, or ground motion or pressure through the sensors below. " &
    "Choosing volts or physical units adds the raw amplitude to the status bar.")
  let comps = st.presentComponents
  if comps.len == 0:
    t.dim("Open a seismic file to list its components here.")
  for c in comps:
    igPushID_Int(cint(c))
    let have = st.project.doc.sensors.get(c)
    let units = unitsFor(kindOf(c), imperial)
    var unit = units[0]
    if have.isSome: unit = have.get.unit
    elif ui.unitPicked[c] in 0'i8 ..< int8(units.len): unit = units[ui.unitPicked[c]]
    igTextUnformatted(componentName(c).cstring, nil)
    igSameLine(max(igGetFontSize() * 13, 0), -1)
    var v = if ui.editing == c: ui.draft elif have.isSome: have.get.value else: 0.0
    igSetNextItemWidth(igGetFontSize() * 7)
    if igInputDouble("##value", addr v, 0, 0, "%.6g".cstring, 0): (ui.editing, ui.draft) = (c, v)
    let typed = igIsItemDeactivatedAfterEdit()
    if igIsItemActive(): (ui.editing, ui.draft) = (c, v)
    elif ui.editing == c: ui.editing = 0
    marks.mark("project.sensor.value." & $c)
    tip("The sensitivity as wired, in the unit beside it, as typed: it is kept as typed and " &
      "never shown in another unit. Press Enter, or click elsewhere, to keep it.")
    igSameLine(0, 6)
    igSetNextItemWidth(igGetFontSize() * 8)
    var picked = unit
    if igBeginCombo("##unit", ($unit).cstring, 0):
      for u in units:
        if igSelectable_Bool(($u).cstring, u == unit, 0, ImVec2_c(x: 0, y: 0)): picked = u
      igEndCombo()
    marks.mark("project.sensor.unit." & $c)
    tip("Changing the unit keeps the number as typed; it is not converted.")
    if picked != unit:
      ui.unitPicked[c] = int8(units.find(picked))
      if have.isSome:
        res.commands.add Command(kind: ckSensor, sensorComponent: int(c),
          sensorValue: have.get.value, sensorUnit: $picked)
    elif typed:
      res.commands.add Command(kind: ckSensor, sensorComponent: int(c), sensorValue: v,
        sensorUnit: $unit)
    if have.isSome:
      igSameLine(0, 6)
      if igSmallButton("Remove"):
        res.commands.add Command(kind: ckSensor, sensorComponent: int(c), sensorForget: true)
      marks.mark("project.sensor.remove." & $c)
      tip("Take this sensor away: this component's raw amplitude then has no sensor to convert with")
    igPopID()

proc drawProject(ui: var ProjectUi; title: string; st: AppState; t: Theme; marks: var Marks;
    res: var ProjectOutput) =
  let p = st.project
  ui.place(title, 44, 28)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focusProject.watch()
    marks.markWindow("project")
    ui.drawShownFile(st, t, marks, res)
    if not st.inProject:
      let opening = st.projectOpening
      igTextDisabled((if opening.len > 0: "Opening " & opening & "..." else:
        "No project is open. Project > New project... makes one; Project > Open project... opens " &
        "one.").cstring)
      ui.drawMoves(st, t, marks, res)
      ui.drawSensors(st, t, marks, res)
    else:
      igTextUnformatted((IconFolder & "  " & p.doc.name).cstring, nil)
      t.dim(p.dir)
      if p.readOnly:
        igTextColored(vec4(t.roles[rlWarning]), "%s", ("Read-only: " & p.whyReadOnly &
          ". Nothing you do is written into it.").cstring)
      if p.offer:
        igSeparator()
        igTextColored(vec4(t.roles[rlWarning]), "%s", (IconWarning & "  A survey file changed " &
          "since it was copied into the project. The project uses its copy until you " &
          "update it.").cstring)
        if button(IconSync & "  Update from the original", "project.update",
            "Copy the originals that changed into the project again, and read them (in the " &
            "background; not while the survey is being copied in)", p.survey != srKeeping,
            marks) and ui.focusProject.acts:
          res.commands.add Command(kind: ckUpdateSurvey)
        igSameLine(0, -1)
        igTextDisabled("or leave it: the copy stays")
      igSeparatorText("Data folders")
      for i, d in p.doc.data:
        igPushID_Int(cint(i))
        let look = if i < p.folders.len: p.folders[i] else: PlaceLook()
        let where = if look.path.len > 0: look.path elif d.absolute.len > 0: d.absolute
                    else: d.path
        if look.state == psMissing:
          igTextColored(vec4(t.roles[rlWarning]), "%s", (IconWarning & "  " & d.displayName &
            ": missing (last at " & where & ")").cstring)
          igSameLine(0, -1)
          if button("Locate...", "project.locate." & $i, "Say where this folder is now; the " &
              "folders that were beside it are looked for beside it there", not p.readOnly,
              marks):
            ui.locating = if d.absolute.len > 0: d.absolute else: d.path
            res.ask = paLocate
            res.askAt = p.dir.parentDir
        else:
          igTextUnformatted((IconFolder & "  " & where & "  (" & stateWords(look.state) &
            ")").cstring, nil)
          marks.mark("project.folder." & $i)
          igSameLine(0, -1)
          if igSmallButton("List"):
            res.commands.add Command(kind: ckBrowse, paths: @[look.path], showFirst: true)
          tip("List this folder in Files and show its first seismic file")
        igPopID()
      if button(IconOpenFolder & "  Add a data folder...", "project.adddata",
          "Another folder of the job's seismic files", not p.readOnly, marks):
        res.ask = paData
        res.askAt = p.dir.parentDir
      igSeparatorText("Survey")
      if not p.doc.hasSurvey:
        igTextDisabled("None imported: Project > Import survey imports it into the " &
          "project, once.")
      else:
        let state = case p.survey
          of srNone: "not loaded"
          of srLoading: "loading from the project..."
          of srLoaded: "on the map; every file opened is matched to it"
          of srKeeping: "being copied into the project..."
          of srFailed: "could not be made: " & p.surveyNote
        igTextUnformatted(($p.doc.store.sources & " sources, " & $p.doc.store.receivers &
          " receivers, " & (if p.doc.store.splitKnown: $p.doc.store.relations &
            " X records, " & $p.doc.store.receiverRelations & " O records: "
          else: $p.doc.store.relations & " relation records: ") & state).cstring, nil)
        marks.mark("project.survey")
        if p.restoreMs > 0:
          t.dim("Made from the project's copy in " & formatFloat(p.restoreMs, ffDecimal, 0) &
            " ms, without reading a survey file.")
        for i, c in p.doc.survey:
          let o = if i < p.originals.len: p.originals[i] else: OriginalLook()
          let line = c.copy.extractFilename & ": " & originalWords(o.state)
          if o.state == osChanged: igTextColored(vec4(t.roles[rlWarning]), "%s", line.cstring)
          else: igTextUnformatted(line.cstring, nil)
          tip("Copied from " & c.original.absolute)
        if button(IconTrash & "  " & ClearSurveyWords, "project.survey.clear",
            (if p.readOnly: "Not offered: the project is open read-only (" & p.whyReadOnly & ")"
            else: ClearSurveyHelp), not p.readOnly, marks) and ui.focusProject.acts:
          res.clearSurvey = true
      ui.drawMoves(st, t, marks, res)
      ui.drawSensors(st, t, marks, res)
      igSeparator()
      if button(IconClose & "  Close project", "project.close", "Write what is pending, close " &
          "its files and survey and go back to working without a project", true, marks):
        res.commands.add Command(kind: ckCloseProject)
    ui.focusProject.settle()
  igEnd()
  if not open: ui.shown = false

proc drawProjectWindows*(ui: var ProjectUi; projectTitle, newTitle: string; st: AppState;
    t: Theme; marks: var Marks): ProjectOutput =
  ## The windows that are open. The Project window comes forward once when
  ## the project offers an update from its survey's originals.
  result = ProjectOutput()
  let offered = st.inProject and st.project.offer
  if offered and not ui.wasOffered: ui.open()
  ui.wasOffered = offered
  let shown = st.shownFile(st.findPanel(MainPanel))
  let earlier = if shown >= 0: st.earlierOf(st.sessions[shown].path).len else: 0
  if earlier > ui.earlierSeen: ui.open() # an earlier output said: shown where it can be acted on
  ui.earlierSeen = earlier
  if ui.making: ui.drawNew(newTitle, st, t, marks, result)
  if ui.shown:
    if ui.bringUp: igSetWindowFocus_Str(projectTitle.cstring)
    ui.drawProject(projectTitle, st, t, marks, result)
  ui.bringUp = false
  ui.placeAgain = false
