## The job that lists the vendor fields an open file has (`vendorFieldsWork`).
##
## `vendorFieldNames` works from the file's index in memory, but it is a
## parseSEG call on a file, so it is made on a job and its answer goes back
## through the inbox (`mkVendorFields`), as the kinds of recording do: the
## display-line menu asks the state, never the file.

import parseSEG
import inbox, jobs, session, vendorfieldlist

proc vendorFieldsWork*(file: ptr SeismicFile; session: SessionId; vendorGen: int;
    reg: VendorRegistry; to: Poster): JobWork =
  ## The work of a job that lists the vendor fields `reg` can decode for
  ## `file` (open as `session`, which stays open until the job ends) and
  ## posts them as one `mkVendorFields` message for the maps' load
  ## `vendorGen`. A file the maps do not apply to (SEG-2, or no map) has none.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "listing the vendor fields"
    var list = VendorFieldList(session: session, vendors: vendorGen)
    {.cast(gcsafe).}:
      try:
        list.entries = vendorFieldEntries(reg.vendorFieldNames(file[]))
      except ValueError: discard # SEG-2, or a file closed meanwhile: no vendor fields
    ctx.checkCancelled()
    to.post Msg(job: ctx.id, kind: mkVendorFields, vendorFields: move list)
