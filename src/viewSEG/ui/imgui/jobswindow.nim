## The "Jobs" window: what runs, what waits and what has finished
## (`view/joblist`). A running job shows its progress bar, what it is doing,
## the time left and Cancel; a queued job can be moved up or down its lane
## (the foreground lane, for what the user waits on, or the background one)
## or removed; a finished job says how it ended and how long it took, and
## can be cleared from the list. The status bar's job field, the toolbar
## and View > Jobs bring the window forward.

import std/monotimes
import imguin/cimgui
import ../../core/[geometry, state]
import ../../view/[joblist, theme]
import chrome, icons, style

type
  JobsOutput* = object
    commands*: seq[Command]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc small(label, mark, help: string; enabled: bool; marks: var Marks): bool =
  ## A small button, greyed out when it cannot act.
  igBeginDisabled(not enabled)
  result = igSmallButton(label.cstring)
  igEndDisabled()
  marks.mark(mark)
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(help.cstring, nil)
    igEndTooltip()

proc laneTag(lane: JobLane; t: Theme) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(("[" & laneName(lane) & "]").cstring, nil)
  igPopStyleColor(1)
  tip(if lane == jlInteractive: "Work you are waiting on: it runs at once, beside the " &
        "background work"
      elif lane == jlPeeks: "A file's first bytes read for what its headers say: beside " &
        "the other work, so a drive that does not answer holds nothing else"
      elif lane == jlOriginals: "A project's survey originals looked at, a lane of their own: " &
        "no file's hash waits for them"
      elif lane == jlHashes: "A file read whole to confirm what it holds: beside the other " &
        "background work, which never waits for it"
      else: "Long work that runs in the background while you go on")

proc drawJobs*(title: string; st: AppState; t: Theme; marks: var Marks): JobsOutput =
  ## The window, docked or floating like any other, titled `title`.
  if igBegin(title.cstring, nil, 0):
    marks.markWindow("jobs")
    let rows = jobRows(st.jobs.list, st.jobs.queues, getMonoTime())
    let style = igGetStyle()
    igSeparatorText("Running")
    if rows.running.len == 0: igTextDisabled("Nothing is running.")
    for r in rows.running:
      igPushID_Int(cint(int(r.id)))
      laneTag(r.lane, t)
      igSameLine(0, -1)
      igTextUnformatted(r.title.cstring, nil)
      marks.mark("jobs.running " & r.title)
      tip(if r.detail.len > 0: r.detail else: "This job is running")
      let width = max(igGetFontSize() * 6, igGetContentRegionAvail().x -
        igCalcTextSize("Cancel", nil, false, -1).x - 6 * style.FramePadding.x)
      let fraction = if r.fraction >= 0: r.fraction else: -float32(igGetTime())
      igProgressBar(fraction, ImVec2_c(x: width, y: 0), r.progress.cstring)
      tip(r.detail)
      igSameLine(0, -1)
      if small(IconStop & " Cancel", "jobs.cancel " & r.title, "Ask it to stop",
          r.canCancel, marks):
        result.commands.add Command(kind: ckCancelJob, job: r.id)
      igPopID()
    igSeparatorText("Waiting")
    if rows.queued.len == 0: igTextDisabled("Nothing is waiting.")
    for r in rows.queued:
      igPushID_Int(cint(int(r.id)))
      if small(IconArrowUp, "jobs.up " & r.title, "Run it sooner", r.canRaise, marks):
        result.commands.add Command(kind: ckReorderJob, reordered: r.id, position: r.position - 1)
      igSameLine(0, 2)
      if small(IconArrowDown, "jobs.down " & r.title, "Run it later", r.canLower, marks):
        result.commands.add Command(kind: ckReorderJob, reordered: r.id, position: r.position + 1)
      igSameLine(0, 2)
      if small(IconTrash, "jobs.remove " & r.title, "Take it off the list: it will not run",
          r.canRemove, marks):
        result.commands.add Command(kind: ckRemoveJob, job: r.id)
      igSameLine(0, -1)
      laneTag(r.lane, t)
      igSameLine(0, -1)
      igTextUnformatted(r.title.cstring, nil)
      marks.mark("jobs.queued " & r.title)
      igSameLine(0, -1)
      igTextDisabled("%s", r.detail.cstring)
      igPopID()
    igSeparatorText("Finished")
    if rows.finished.len == 0: igTextDisabled("Nothing has finished yet.")
    else:
      if small(IconClearAll & " Clear the list", "jobs.clear", "Take every finished job " &
          "off the list (the messages stay in Messages)", true, marks):
        for r in rows.finished:
          result.commands.add Command(kind: ckRemoveJob, job: r.id)
    let icon: array[JobState, string] = [IconInfo, IconInfo, IconCheck, IconError, IconStop]
    let colour: array[JobState, Rgba] = [t.roles[rlTextDim], t.roles[rlTextDim],
      t.roles[rlInfo], t.roles[rlError], t.roles[rlTextDim]]
    let clipper = ImGuiListClipper_ImGuiListClipper()
    ImGuiListClipper_Begin(clipper, cint(rows.finished.len), -1)
    while ImGuiListClipper_Step(clipper):
      for i in clipper.DisplayStart ..< clipper.DisplayEnd:
        let r = rows.finished[i]
        igPushID_Int(cint(int(r.id)))
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour[r.state]))
        igTextUnformatted(icon[r.state].cstring, nil)
        igPopStyleColor(1)
        igSameLine(0, -1)
        igTextUnformatted(r.title.cstring, nil)
        marks.mark("jobs.finished " & r.title)
        tip(r.detail)
        igSameLine(0, -1)
        igTextDisabled("%s", r.detail.cstring)
        igPopID()
    ImGuiListClipper_End(clipper)
    ImGuiListClipper_destroy(clipper)
  igEnd()
