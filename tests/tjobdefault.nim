## A job id field left unset names no job: job ids start at 0, so a `JobId`
## field without a default would name the first job, and cancelling "none"
## would cancel it. Every exported type with a job id field starts at `NoJob`;
## the fields of private types are kept the same way by hand.
##
## Seen to fail: with `FileList.job` without its `= NoJob`, `fieldsStartAtNoJob`
## reported "FileList.job names job 0".

import std/typetraits
import viewSEG/core/[filelist, inbox, jobs, state]
import viewSEG/view/[joblist, jobstatus]

proc check(what: string; id: JobId) =
  doAssert id == NoJob, what & " names " & $id

template checkFields(T: typedesc[object]) =
  ## Every `JobId` field of the plain (not variant) object type `T`.
  block:
    let x = default(T)
    for name, field in x.fieldPairs:
      when field is JobId:
        check($T & "." & name, field)

proc fieldsStartAtNoJob() =
  checkFields JobInfo
  checkFields FileList
  checkFields Waiting
  checkFields JobStatus
  checkFields JobRow
  # a message has a variant part: its common field by name
  check "Msg.job", default(Msg).job
  check "Msg.job", Msg(kind: mkLog).job

proc main*() =
  fieldsStartAtNoJob()

when isMainModule:
  main()
