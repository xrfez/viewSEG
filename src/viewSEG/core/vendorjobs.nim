## The job that loads the vendor header maps (`core/vendormaps`) off the UI
## thread: the folders may be on a drive that does not answer. It posts
## `mkVendor`.

import inbox, jobs, vendormaps

proc vendorWork*(folders: seq[VendorFolder]; gen: int; to: Poster): JobWork =
  ## The work of a job that loads the maps of `folders` and posts them as load
  ## number `gen`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var load = VendorLoad()
    {.cast(gcsafe).}:
      ctx.setPhase "reading the vendor header maps"
      load = loadVendorFolders(folders)
    discard ctx.progress(1, 1)
    to.post Msg(job: ctx.id, kind: mkVendor, vendorLoad: load, vendorGen: gen)
