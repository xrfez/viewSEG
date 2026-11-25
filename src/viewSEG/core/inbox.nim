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

import std/[locks, times]
import parseSEG
import analysis, compare, edits, filelist, filememory, firstbreaks, geometryqc, identity, join,
  jobs, layouts, log, mapkinds, nif, noisearea, panels, project, references, session, shotfiles,
  sigtypes, spectra, stationmoves, survey, tiles, vendorfieldlist, vendormaps

type
  MsgKind* = enum
    mkOpened         ## an open job's file
    mkLog            ## a message for the log
    mkLayout         ## what a panel's traces span, from its reader
    mkOrder          ## the traces at a panel's positions, in the order shown, from its reader
    mkTile           ## samples a panel asked for, from its reader
    mkRead           ## a document the disk thread read
    mkListed         ## files a folder scan found
    mkWatched        ## what a look at the listed folder found changed
    mkKinds          ## the kinds of recording a job read from the trace headers of listed files
    mkPaired         ## the partner a search found for a signature file (`core/sweeppairs`)
    mkSurvey         ## a survey layer: a survey file read, or an open file's positions
    mkChecked        ## an open file's records checked against a relation file
    mkJoining        ## survey files read for a join, and what joining them does
    mkJoined         ## a join done
    mkMoves          ## station moves applied to an open file's keys
    mkLeap           ## an open file's keys read again after the leap-second table changed
    mkUnread         ## a panel's file cannot be read now (its drive went away, or fails), from its reader
    mkInspected
      ## what the Headers window shows of a record and of traces, from its reader
    mkSpreads        ## relation records made for the map's planned spreads (`core/spread`)
    mkDerived        ## the O records derived from a relation file's X records, for the records' check
    mkShots          ## a listed file's shots, for the map (`core/shots`)
    mkRecordQc
      ## what the map's filters find in the record shown (`core/recordqc`)
    mkFirstBreaks
      ## a record's first breaks, picked and modelled, for the overlay (`core/firstbreakjobs`)
    mkTraceRead
      ## one trace's keys and header fields, read on a job (`readTraceHeaders`)
    mkOwnPosition
      ## the receiver position one trace's own header gives, read from the file on disk
    mkIdentified
      ## an opened file's quick identity and what is remembered about it (`core/memoryjobs`)
    mkHashed         ## an opened file's identity with the hash of every byte
    mkMemoryList     ## every file the store remembers, for the File memory window
    mkMemoryLooked
      ## whether the files remembered in one folder are where they were seen
    mkMemoryMerged
      ## a document of what is remembered that another program (a second
      ## viewSEG) changed since this run read or wrote it: written merged
    mkEditsList ## a file's list of edits, as the text of the file it is exported to
    mkEditsRead ## a file's list of edits the user imports, read
    mkSpectrum ## a spectrum window's spectrum, from the spectrum reader
    mkAnalysis ## an analysis window's numbers, from the analysis reader (New plot)
    mkSurveyHead ## what a survey file's headers say of its unit, for the import's window
    mkProject ## what a project's job found (`core/projectjobs`)
    mkEarlier ## what is remembered about earlier outputs of a file's name (`earlierOutputs`)
    mkReferences ## a reference archive read or changed (`core/references`)
    mkCompare ## a trace copied into a compare slot (`core/comparejobs`)
    mkComparePicture ## the compare window's picture, computed on a job
    mkVendor ## the vendor header maps a load read (`core/vendorjobs`)
    mkVendorFields ## the vendor fields an open file has (`core/vendorfieldjobs`)
    mkTreated ## which document of the store keeps what the user forced for a file (`treatWork`)

  UnreadCause* = enum
    ## Why a panel's file is not read now (`mkUnread`): to the user, a drive
    ## that fails and a file cut short are different things.
    ucFailed = "failed" ## its drive went away or fails (an I/O error)
    ucCutShort = "cut short" ## it is shorter than when it was opened
    ucStopped = "stopped" ## the user stopped waiting for its drive

  ReadPurpose* = enum
    ## What a document is read for.
    rpImportSettings ## settings to take in (Tools > Import settings)
    rpLoadLayout     ## a layout to show (Window: a preset, Load)
    rpImportLayout   ## a layout to show and keep among the user's (Window > Import layout)
    rpLayouts        ## the layouts there are: the user's and the presets, listed (`layouts`)
    rpLeapFile       ## the leap-second table, read again (Tools > Leap seconds)

  Msg* = object
    ## One message for the UI thread.
    job*: JobId                       ## the job that sent it; `NoJob` for none
    case kind*: MsgKind
    of mkOpened: session*: Session
    of mkLog: entry*: LogEntry
    of mkLayout:
      panel*: PanelId
      sourceGen*: uint64              ## the panel's `sourceGen` it answers
      layout*: PanelLayout
      known*: set[HeaderField]        ## the header fields the traces have values for
      widest*: array[HeaderField, int]
        ## per field, its longest value as the header shows it, in characters
      components*: seq[uint8]
        ## distinct components before the component filter, in button order
      componentCounts*: seq[int]      ## traces of each, before that filter
      componentSensors*: seq[uint8]
        ## sensor type of each, when its traces agree; 0 when they do not,
        ## or the headers do not say (a SEG-Y trace)
      componentsCleared*: bool
        ## every component present was off, so none is: the panel's filter
        ## is emptied and the traces are shown
    of mkOrder:
      orderPanel*: PanelId
      orderGen*: uint64 ## the panel's newer of `sourceGen` and `orderGen` it answers
      positions*: seq[int] ## per position: the trace's index in its file
    of mkTile: tile*: Tile
    of mkRead:
      purpose*: ReadPurpose
      readPath*: string
      content*: string
      readError*: string ## why it could not be read; "" when it was
      doc*: seq[NifNode] ## `content` as NIF, read on the disk thread
      docError*: string ## why `content` is not NIF; "" when it is (or was not read)
      layouts*: seq[SavedLayout] ## `rpLayouts`: what `listLayouts` found
    of mkListed:
      listGen*: uint64 ## the file list's `gen` it answers
      listed*: seq[FileEntry] ## seismic files, in natural order
      others*: int ## files found that are not seismic
      unreadable*: int ## files that could not be read
      listVisited*: int ## a scan that goes through subfolders: the files it has looked at so far
      listCapped*: bool ## the tree had more files than `MaxTreeFiles`: the scan stopped there
      subfolders*: int ## the folders listed hold this many folders (the last message)
      listDone*: bool ## the scan's last message
      listFolder*: string ## the folder listed, once known; "" for files chosen one by one
      listChosen*: string ## the one file named, when only a file was named; "" otherwise
      listProject*: string
        ## the folder named is a project's (it holds a `project.nif`): it is
        ## opened as one, not listed; "" otherwise
      listLooked*: seq[WatchedFile]
        ## with `listDone`: every file the scan looked at, seismic or not, as it
        ## found it: what the folder's watch starts from
    of mkPaired:
      pairFor*: string ## the signature file the search was for
      pairPath*: string ## its partner; "" when none was found
      pairInfo*: SweepInfo ## the partner's list facts
      pairSelf*: SweepInfo ## the file's own
      pairWords*: string ## why none was: the reason, in words
      pairCandidates*: seq[string] ## several fit: the files to choose from
      pairLooked*: int ## files of the other kind looked at
    of mkWatched:
      watchGen*: uint64 ## the file list's `gen` it is for
      watched*: seq[WatchedFile] ## the files that changed, appeared or went, or stopped changing
      watchProblem*: string ## why the folder cannot be looked at now; "" when it can
      problemChanged*: bool ## `watchProblem` is news (it began, or ended)
    of mkKinds:
      kindsGen*: uint64 ## the file list's `gen` it is for
      kindsVendors*: int ## the vendor maps' load (`vendorGen`) it was read with
      kinds*: seq[KindAnswer]
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
      relations*: ref SurveyGeometry
        ## their relation records, kept apart from `geometry`
        ## (`SharedRelations`): the map layer's of the relation file, posted
        ## with it just before; nil when they are in `geometry`, or are a
        ## loaded layer's (`reusedAt`)
      reusedAt*: int
        ## the survey file (an index in the import's files) whose loaded
        ## layer's relation records the join uses; -1 for none
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
      joinedBases*: seq[ReceiverBase]
        ## receiver fields the join's moves replaced, for a later restore
      joinedMoves*: int
        ## traces whose receiver fields the moves changed
    of mkMoves:
      movedSession*: SessionId
        ## the open file the moves were applied to
      movedCount*: int
        ## traces whose receiver fields changed
      movedRevision*: int
        ## the file's `keysRevision` after the moves
      movedBases*: seq[ReceiverBase]
        ## receiver fields the moves replaced, for a later restore
    of mkLeap:
      leapSession*: SessionId
        ## the open file whose times were read again
      leapChanged*: bool
        ## a stored key changed
      leapRevision*: int
        ## the file's `keysRevision` after the read
    of mkUnread:
      unreadPanel*: PanelId
      unreadGen*: uint64 ## the panel's `sourceGen` it is about
      cause*: UnreadCause
      why*: string ## in plain words
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
    of mkDerived:
      derived*: ref SurveyGeometry ## moved, never shared; nil when none could be made
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
      qcRecord*: int64
        ## the relation record it was checked against; -1 for none
      qcRecords*: seq[int64]
        ## all of them (a receiver's O records)
      qcByPlace*: bool
        ## that record found with the station at the record's place
      qcOnStations*: bool
        ## the traces were matched to the record's stations, so which of them the
        ## template lists is known
      qcNoise*: NoiseSummary
        ## what the noisy-trace test found (not `ready` when it did not run)
      qcGeometry*: GeometrySummary
        ## what the geometry check found
      qcBreaks*: FirstBreaks
        ## the record's first breaks, when the job found them itself (`qcPicked`)
      qcPicked*: bool
    of mkFirstBreaks:
      breaks*: FirstBreaks ## moved, never shared
    of mkTraceRead:
      readKeys*: TraceKeys
        ## the trace's keys, as the index holds them
      headerRows*: seq[HeaderRow]
      readVendor*: VendorShown ## what the vendor maps decode of its header blocks
                                 ## the fields of its headers (parseSEG's), in file order
    of mkOwnPosition:
      ownSession*: SessionId ## the open file
      ownIndex*: int ## the trace in that file (from 0)
      ownKeys*: TraceKeys ## the trace's keys as its headers give them
      ownWhy*: string ## why the header was not read; "" when it was
    of mkIdentified:
      identPath*: string ## the file
      identity*: FileIdentity ## its quick identity
      identModified*: Time ## its modification time when it was read
      candidates*: seq[FileRecord] ## the store's documents of that quick identity
      taken*: seq[string] ## every document name of that quick identity
      memoryProblems*: seq[string] ## documents that could not be read, in plain words
      pending*: FileRecord
        ## the file's pending document (`pendingName`): edits made while its
        ## identity was not known; `pending.doc` "" for none
      pendingFits*: bool
        ## `pending` was made on the file as it is (its size and time): its
        ## edits are the file's
    of mkHashed:
      hashedPath*: string ## the file
      hashed*: FileIdentity ## its identity, `fullKnown`
    of mkMemoryList:
      records*: seq[FileRecord] ## every document of the store, the newest opened first
      listProblems*: seq[string] ## documents that could not be read
    of mkMemoryMerged:
      mergedDoc*: string ## the document's name in the store
      mergedEdits*: EditLists ## what it holds now: both programs' edits
      mergedSent*: EditLists ## what this run had asked to write
      mergedRemoved*: bool ## this run had asked to remove it
    of mkMemoryLooked:
      lookedFolder*: string ## the folder looked in
      looked*: seq[tuple[doc: string; gone, unreached: bool]]
        ## each document of a file last seen there, and where it stands
    of mkEditsList:
      listText*: string ## the text to write
      listDest*: string ## the file to write it to
      listName*: string ## the seismic file's name
    of mkEditsRead:
      importedList*: string ## the list's file
      importedEdits*: EditLists ## its edits; none when it could not be read
      importProblems*: seq[string] ## what in it could not be used, in plain words
      importFailure*: string ## why nothing of it could be used; "" when it could
      importIdentity*: FileIdentity ## the identity of the file it was made on (NIF)
      importHasIdentity*: bool ## it names one
      importOutside*: int ## its traces past the file's last, left out
    of mkSpectrum:
      spectrum*: Spectrum ## moved, never shared
    of mkAnalysis:
      analysis*: AnalysisResult ## moved, never shared
    of mkSurveyHead:
      surveyHead*: SurveyHead
    of mkProject:
      news*: ProjectNews ## moved, never shared
    of mkVendor:
      vendorLoad*: VendorLoad ## moved, never shared
      vendorGen*: int ## the load's number: a newer load makes it stale
    of mkVendorFields:
      vendorFields*: VendorFieldList ## moved, never shared
    of mkTreated:
      treatPath*: string ## the file
      treatDoc*: string ## the name of its document in the store (made when there is none)
      treatIdentity*: FileIdentity ## its identity: the hash of every byte too when it was needed
      treatModified*: Time ## its modification time then
      treatHash*: bool
        ## several documents may be the file's, or the one it has knows the hash of every byte:
        ## that hash is needed to tell (nothing else is filled)
      treatFailure*: string ## why the choice could not be kept for the file; "" when it could
    of mkEarlier:
      earlierPath*: string ## the file
      earlierOf*: FileIdentity ## its identity, which none of them is
      earlier*: seq[FileRecord] ## the documents of earlier outputs of its name
      earlierProblems*: seq[string]
    of mkReferences:
      refNews*: ReferenceNews ## moved, never shared
    of mkCompare:
      compareNews*: CompareNews ## moved, never shared
    of mkComparePicture:
      comparePicture*: ComparePicture ## moved, never shared
      comparePicGen*: uint64 ## the ask it answers; a newer one drops it

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
