## The job that reads the `{vendor:NAME}` values of the shown file for the name pattern editor's
## example, so that the example shows the name the output run would write (`vendorValuesOf`).
## The answer is for one key (file, killed traces, fields, vendor maps' load); an answer for
## another key is stale and is not used.

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

func vendorPreviewKey*(path: string; dropKilled: bool; fields: openArray[string];
    stamp: int): string =
  ## What an answer is for: the file, whether killed traces are dropped, the field names, and
  ## the vendor maps' load (`vendorStamp`).
  path & "\0" & $dropKilled & "\0" & $stamp & "\0" & fields.join("\0")

func vendorPreviewSpec*(name, path: string): JobSpec =
  ## The job that reads vendor values of open file `path`: background, reading it.
  JobSpec(title: "Read the vendor fields of " & name, lane: jlBackground, reads: @[path])

proc vendorPreviewWork*(file: ptr SeismicFile; facts: SignatureFacts; edits: FileEdits;
    dropKilled: bool; fields: seq[string]; vendors: VendorRegistry; key: string;
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

func vendorAnswer*(sink: VendorPreview; key: string): Option[seq[VendorFieldValue]] =
  ## The values the job read, when it has ended and was asked for `key`; none otherwise
  ## (not yet, or a stale answer).
  if sink != nil and sink.ready and sink.key == key: some(sink.values)
  else: none(seq[VendorFieldValue])
