## A project never writes into a data folder (docs/project.md), checked
## without a window:
##
## - a project is made only in an empty folder: one holding a file is
##   refused, the file left as it was and no project document written;
## - a project folder reached through a link from a data folder is refused
##   inside the job, which compares the folders' resolved paths (the UI
##   thread compares them as given);
## - a data folder located at a place inside the project is refused as a
##   data folder is added at one (the same check).
##
## Seen to fail: with `isEmptyFolder` not checked, "a folder holding a file
## is refused" (a project was made there); with `realPath` left out of the
## job's check, "a link to the project is refused" (the project was made
## inside its own data folder); with the check left out of `faLocate`, "a
## data folder located inside the project is refused" (the folder moved in).
import std/[os, strutils]
import viewSEG/core/[project, state]
import utils/[faultyfs, fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

withFixtures fx:
  let config = fx.dir / "config"
  block notEmpty:
    let job = fx.dir / "Holding"
    createDir job
    writeFile(job / "keep.txt", "not a project's")
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.said("is not empty")), "the refusal is not said"
    discard st.settle(st.jobs.active.len == 0)
    doAssert not st.inProject and not fileExists(job / ProjectFileName), "a project was made"
    doAssert readFile(job / "keep.txt") == "not a project's", "the folder's file changed"
    st.shutdown()
  block linkToProject:
    let job = fx.dir / "Linked"
    createDir job
    let link = fx.dir / "link"
    createSymlink(job, link)
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[link])
    doAssert st.settle(st.said("inside its data folder")), "the link is not refused"
    discard st.settle(st.jobs.active.len == 0)
    doAssert not fileExists(job / ProjectFileName), "a project was made in its data folder"
    st.shutdown()
  block locateInside:
    let job = fx.dir / "Located"
    let field = fx.dir / "field"
    createDir field
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject)
    let was = st.project.doc.data[0].absolute
    st.apply Command(kind: ckProjectFolder, folderAction: faLocate, folderWas: was,
      folderPath: job / "moved")
    doAssert st.settle(st.said("cannot hold")), "the refusal is not said"
    doAssert st.project.doc.data[0].absolute == was, "the data folder was moved inside"
    st.shutdown()
  block fileManagerFiles:
    # a folder holding only what a file manager leaves (.DS_Store, desktop.ini,
    # Thumbs.db) is empty: a project is made there, and those files stay
    let job = fx.dir / "Managed"
    createDir job
    for name in [".DS_Store", "desktop.ini", "Thumbs.db"]: writeFile(job / name, "x")
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject), "a folder with only those files is refused"
    doAssert fileExists(job / "Thumbs.db") and fileExists(job / ProjectFileName)
    st.shutdown()
  block failedMakeTakesBack:
    # a make that fails part-way removes what it made (folders and the
    # document) and nothing it did not: the folder as it was, and a retry
    # in it works
    install()
    let job = fx.dir / "Retried"
    createDir job
    writeFile(job / "Thumbs.db", "not a project's")
    fault(job / CacheFolder, fkFail)
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.said("Cannot make the project")), "the failure is not said"
    discard st.settle(st.jobs.active.len == 0)
    doAssert not st.inProject
    doAssert fileExists(job / "Thumbs.db") and readFile(job / "Thumbs.db") == "not a project's"
    doAssert not dirExists(job / "survey") and not dirExists(job / ProjectStoreFolder) and
      not fileExists(job / ProjectFileName), "what the failed make made is still there"
    fault(job / CacheFolder, fkNone)
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject), "a retry in the same folder fails"
    st.shutdown()
echo "tprojectdatafolder: done"
