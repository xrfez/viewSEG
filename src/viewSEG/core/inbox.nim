## The main-thread inbox: how workers hand results to the UI thread.
##
## Workers `post` messages through a `Poster`; the UI thread takes them all
## once per frame with `drainInto`, which holds the lock only to swap two
## buffers, so it never waits for a worker. Whatever a message holds (a
## session, later a tile) is moved, never shared: the worker gives it up.
##
## `Inbox` is the UI thread's end; `Poster` is a copyable handle for workers.
## Both share one buffer, freed when the last of them goes, so a job that is
## still running when the program closes can post safely.

import std/locks
import filelist, jobs, log, panels, session, tiles

type
  MsgKind* = enum
    mkOpened ## an open job's file
    mkLog    ## a message for the log
    mkLayout ## what a panel's traces span, from its reader
    mkTile   ## samples a panel asked for, from its reader
    mkRead   ## a document the disk thread read
    mkListed ## files a folder scan found

  ReadPurpose* = enum
    ## What a document is read for.
    rpImportSettings ## settings to take in (File > Settings > Import)
    rpLoadLayout     ## a layout to show (View > Layout > Load)
    rpImportLayout   ## a layout to show and keep among the user's (View > Layout > Import)

  Msg* = object
    ## One message for the UI thread.
    job*: JobId                ## the job that sent it; `NoJob` for none
    case kind*: MsgKind
    of mkOpened: session*: Session
    of mkLog: entry*: LogEntry
    of mkLayout:
      panel*: PanelId
      sourceGen*: uint64       ## the panel's `sourceGen` it answers
      layout*: PanelLayout
      known*: set[HeaderField] ## the header fields the traces have values for
    of mkTile: tile*: Tile
    of mkRead:
      purpose*: ReadPurpose
      readPath*: string
      content*: string
      readError*: string       ## why it could not be read; "" when it was
    of mkListed:
      listGen*: uint64         ## the file list's `gen` it answers
      listed*: seq[FileEntry]  ## seismic files, in natural order
      others*: int             ## files found that are not seismic
      unreadable*: int         ## files that could not be read
      listDone*: bool          ## the scan's last message
      listFolder*: string      ## the folder listed, once known; "" for files chosen one by one
      listChosen*: string      ## the one file named, when only a file was named; "" otherwise

  InboxObj = object
    lock: Lock
    items: seq[Msg]
    refs: int ## the `Inbox` and every `Poster`; changed atomically

  Inbox* = object
    ## The UI thread's end. Move-only.
    p: ptr InboxObj

  Poster* = object
    ## A worker's end: copy it freely, post from any thread.
    p: ptr InboxObj

proc dropRef(p: ptr InboxObj) {.raises: [].} =
  if p != nil and atomicDec(p.refs) == 0:
    deinitLock p.lock
    `=destroy`(p[])
    deallocShared p

proc `=destroy`*(b: Inbox) =
  dropRef(b.p)

proc `=wasMoved`*(b: var Inbox) =
  b.p = nil

proc `=copy`*(dest: var Inbox; src: Inbox) {.error.}
proc `=dup`*(src: Inbox): Inbox {.error.}

proc `=destroy`*(p: Poster) =
  dropRef(p.p)

proc `=wasMoved`*(p: var Poster) =
  p.p = nil

proc `=dup`*(src: Poster): Poster =
  if src.p != nil: atomicInc src.p.refs
  result.p = src.p

proc `=copy`*(dest: var Poster; src: Poster) =
  if src.p != nil: atomicInc src.p.refs
  dropRef(dest.p)
  dest.p = src.p

proc initInbox*(): Inbox =
  ## An empty inbox.
  let p = cast[ptr InboxObj](allocShared0(sizeof(InboxObj)))
  initLock p.lock
  p.refs = 1
  Inbox(p: p)

proc poster*(b: Inbox): Poster =
  ## A handle workers post through.
  assert b.p != nil, "an Inbox made with initInbox"
  atomicInc b.p.refs
  result.p = b.p

proc post*(p: Poster; msg: sink Msg) {.raises: [].} =
  ## Hands `msg` to the UI thread. Any thread.
  assert p.p != nil, "a Poster made with poster(inbox)"
  withLock p.p.lock:
    p.p.items.add msg

proc drainInto*(b: Inbox; dest: var seq[Msg]) =
  ## Replaces `dest` with every message posted since the last call, oldest
  ## first.
  assert b.p != nil, "an Inbox made with initInbox"
  dest.setLen 0
  withLock b.p.lock:
    swap(dest, b.p.items)
