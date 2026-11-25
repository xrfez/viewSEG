## The job that reads the `{vendor:NAME}` values of the shown file for the name pattern editor's
## example, so that the example shows the name the output run would write (`vendorValuesOf`).
## The answer is for one key (file session, killed traces, fields, vendor maps' load); an
## answer for another key is stale and is not used. `vendorPreviewStep` is the decision the
## window takes each frame: ask, use the values, or show the sample.

import std/[options, strutils]
import parseSEG
import edits, jobs, outputnames, outputnamevalues, sigtypes, vendormaps

const PreviewTraceLimit* = 200_000
  ## traces of the shown file the example reads vendor values over; a longer file is not read

type VendorPreview* = ref object
  ## Filled by the job; read once it has ended.
  key*: string
  values*: seq[VendorFieldValue]
  ready*: bool

func vendorPreviewKey*(path: string; session: int; dropKilled: bool;
    revision: int; fields: openArray[string]; stamp: int): string =
  ## What an answer is for: the file's path and loaded session (a file reloaded under the same
  ## path is another file), whether killed traces are dropped and, when they are, the file's
  ## edits `revision` (killing traces changes what the run writes), the field names, and the
  ## vendor maps' load (`vendorStamp`).
  path & "\0" & $session & "\0" & $dropKilled & "\0" & (
      if dropKilled: $revision else: "") &
    "\0" & $stamp & "\0" & fields.join("\0")

func vendorPreviewSpec*(name, path: string): JobSpec =
  ## The job that reads vendor values of open file `path`: background, reading it.
  JobSpec(title: "Read the vendor fields of " & name, lane: jlBackground,
      reads: @[path])

proc vendorPreviewWork*(file: ptr SeismicFile; facts: SignatureFacts;
    edits: FileEdits; dropKilled: bool; fields: seq[string];
        vendors: VendorRegistry; key: string;
    sink: VendorPreview): JobWork =
  ## Reads `fields` of `file` (which stays open until the job ends) as the output run does,
  ## on a job thread. `sink` is set when it finishes; a cancel leaves it unset, and so
  ## does a file of more than `PreviewTraceLimit` traces (the example keeps its sample values).
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      if file[].len <= PreviewTraceLimit:
        let got = vendorValuesOf(file[], facts, edits, dropKilled, fields, vendors)
        ctx.checkCancelled()
        sink.values = got
        sink.key = key
        sink.ready = true

func vendorAnswer*(sink: VendorPreview; key: string): Option[seq[
    VendorFieldValue]] =
  ## The values the job read, when it has ended and was asked for `key`; none otherwise
  ## (not yet, or a stale answer).
  if sink != nil and sink.ready and sink.key == key: some(sink.values)
  else: none(seq[VendorFieldValue])

type
  VendorPreviewState* = object
    ## What the window keeps between frames about the example's vendor values.
    job*: JobId = NoJob            ## the job reading them, or `NoJob`
    sink*: VendorPreview           ## what it fills
    asked*: string                 ## the key it was asked for
    shownKey*: string              ## the key `values` are for
    values*: seq[VendorFieldValue] ## read from the shown file; empty before an answer

  VendorStep* = enum
    vsSample ## show the sample values (nothing to read, or the answer is on its way)
    vsUse    ## use `values`
    vsSubmit ## ask for the key: submit a job filling `sink`, then call `started`

proc started*(s: var VendorPreviewState; id: JobId) =
  ## Records the job submitted after `vsSubmit`.
  s.job = id

proc vendorPreviewStep*(s: var VendorPreviewState; jobs: Jobs;
    key: string): VendorStep =
  ## The decision of one frame. `key` is `vendorPreviewKey` of the shown file, or "" when
  ## there is nothing to read (no field, no file open). A job that is not queued or running
  ## is read whatever its state, so a pruned job still gives its answer. A job that was
  ## pruned without an answer is asked again; a cancelled one (the user stopped it in the Jobs
  ## window) and a failed one are not, for the same key (it would run again on every frame):
  ## the sample is shown. A file reloaded or closed changes the key, so it is asked again. An answer for another key is not used.
  if s.job != NoJob:
    let info = jobs.info(s.job)
    if info.isSome and info.get.state in {jsQueued, jsRunning}: return vsSample
    let got = vendorAnswer(s.sink, s.asked)
    if got.isSome:
      s.values = got.get
      s.shownKey = s.asked
    elif info.isNone:
      s.asked = ""
    s.job = NoJob
  if key.len == 0: return vsSample
  if key == s.shownKey: return vsUse
  if key != s.asked:
    s.asked = key
    s.sink = VendorPreview()
    return vsSubmit
  vsSample
