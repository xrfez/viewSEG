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
import parseSEG
import filelist, join, jobs, layouts, log, mapkinds, nif, panels, session, shotfiles, survey,
  tiles

type
  MsgKind* = enum
    mkOpened  ## an open job's file
    mkLog     ## a message for the log
    mkLayout  ## what a panel's traces span, from its reader
    mkOrder   ## the traces at a panel's positions, in the order shown, from its reader
    mkTile    ## samples a panel asked for, from its reader
    mkRead    ## a document the disk thread read
    mkListed  ## files a folder scan found
    mkWatched ## what a look at the listed folder found changed
    mkSurvey  ## a survey layer: a survey file read, or an open file's positions
    mkChecked ## an open file's records checked against a relation file
    mkJoining ## survey files read for a join, and what joining them does
    mkJoined  ## a join done
    mkUnread  ## a panel's file cannot be read now (its drive went away, or fails), from its reader
    mkInspected
      ## what the Headers window shows of a record and of traces, from its reader
    mkSpreads ## relation records made for the map's planned spreads (`core/spread`)
    mkShots   ## a listed file's shots, for the map (`core/shots`)
    mkRecordQc
      ## what the map's filters find in the record shown (`core/recordqc`)
    mkTraceRead ## one trace's keys and header fields, read on a job (`readTraceHeaders`)

  UnreadCause* = enum
    ## Why a panel's file is not read now (`mkUnread`): to the user, a drive
    ## that fails and a file cut short are different things.
    ucFailed = "failed"      ## its drive went away or fails (an I/O error)
    ucCutShort = "cut short" ## it is shorter than when it was opened
    ucStopped = "stopped"    ## the user stopped waiting for its drive

  ReadPurpose* = enum
    ## What a document is read for.
    rpImportSettings ## settings to take in (File > Import > Settings)
    rpLoadLayout     ## a layout to show (Window: a preset, Load)
    rpImportLayout   ## a layout to show and keep among the user's (File > Import > Layout)
    rpLayouts        ## the layouts there are: the user's and the presets, listed (`layouts`)

  Msg* = object
    ## One message for the UI thread.
    job*: JobId                  ## the job that sent it; `NoJob` for none
    case kind*: MsgKind
    of mkOpened: session*: Session
    of mkLog: entry*: LogEntry
    of mkLayout:
      panel*: PanelId
      sourceGen*: uint64         ## the panel's `sourceGen` it answers
      layout*: PanelLayout
      known*: set[HeaderField]   ## the header fields the traces have values for
    of mkOrder:
      orderPanel*: PanelId
      orderGen*: uint64          ## the panel's newer of `sourceGen` and `orderGen` it answers
      positions*: seq[int]       ## per position: the trace's index in its file
    of mkTile: tile*: Tile
    of mkRead:
      purpose*: ReadPurpose
      readPath*: string
      content*: string
      readError*: string         ## why it could not be read; "" when it was
      doc*: seq[NifNode]         ## `content` as NIF, read on the disk thread
      docError*: string          ## why `content` is not NIF; "" when it is (or was not read)
      layouts*: seq[SavedLayout] ## `rpLayouts`: what `listLayouts` found
    of mkListed:
      listGen*: uint64           ## the file list's `gen` it answers
      listed*: seq[FileEntry]    ## seismic files, in natural order
      others*: int               ## files found that are not seismic
      unreadable*: int           ## files that could not be read
      listDone*: bool            ## the scan's last message
      listFolder*: string        ## the folder listed, once known; "" for files chosen one by one
      listChosen*: string        ## the one file named, when only a file was named; "" otherwise
      listLooked*: seq[WatchedFile]
        ## with `listDone`: every file the scan looked at, seismic or not, as it
        ## found it: what the folder's watch starts from
    of mkWatched:
      watchGen*: uint64 ## the file list's `gen` it is for
      watched*: seq[WatchedFile] ## the files that changed, appeared or went, or stopped changing
      watchProblem*: string ## why the folder cannot be looked at now; "" when it can
      problemChanged*: bool ## `watchProblem` is news (it began, or ended)
    of mkSurvey:
      layer*: SurveyLayer ## moved, never shared
    of mkChecked:
      checkedSession*: SessionId
        ## the open file whose records were checked
      against*: string
        ## the relation file's name
      againstLayer*: SurveyLayerId
        ## its layer
      keysRevision*: int
        ## the file's keys the check was made with
      planned*, plannedMissing*: seq[int]
        ## per gather: the stations planned, and those with no trace; -1 where not planned
      unlisted*, duplicates*: seq[int]
        ## per gather: its traces at stations the plan does not list, and its
        ## stations given more than once; -1 where not planned
    of mkJoining:
      planSession*: SessionId
        ## the open file to join
      geometry*: ref SurveyGeometry
        ## the survey files read; moved, never shared
      plan*: JoinPlan
        ## what joining them does
      joinSurvey*: JoinSurvey
        ## what they gave
    of mkJoined:
      joinedSession*: SessionId
        ## the open file joined
      stats*: JoinStats
        ## parseSEG's own count of what the join did
      changed*: int
        ## traces whose keys changed
      joinedRevision*: int
        ## the file's `keysRevision` after the join
      heldAtJoin*: int
        ## holds on the file when the join ran: none, as no reader may run
    of mkUnread:
      unreadPanel*: PanelId
      unreadGen*: uint64 ## the panel's `sourceGen` it is about
      cause*: UnreadCause
      why*: string       ## in plain words
    of mkInspected:
      inspected*: Inspected ## moved, never shared
    of mkSpreads:
      spreads*: ref SurveyGeometry
        ## the relation records made (X generated from the template, O from
        ## X); moved, never shared; nil when none could be made
      spreadWords*: seq[string]
        ## what was made, or why nothing was, in plain words
      differing*: seq[tuple[record: int64; source: StationKey]]
        ## the X records whose receivers are not those of their template
      compared*: int
        ## the X records compared with their template
    of mkShots:
      shotsGen*: uint64
        ## the file list's `gen` the file was listed by
      shots*: FileShots
        ## its records' shots; moved, never shared
    of mkRecordQc:
      qcSession*: SessionId
        ## the open file the record is of
      qcGather*: int
        ## its gather
      qcKeys*: int
        ## the file's `keysRevision` it was read with
      qcHits*: array[MapFilter, FilterHits]
        ## what each filter of `TraceFilters` found
    of mkTraceRead:
      traceKeys*: TraceKeys      ## the trace's keys, as the index holds them
      headerRows*: seq[HeaderRow] ## the fields of its headers (parseSEG's), in file order

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
