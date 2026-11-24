# Projects

A project is the home of one job's work. The user imports the survey into it once, and
the survey is never imported again: not when the program starts again, not for the next
file, and not on another machine the project is handed to. Kills, polarity, the plot's
filters, display presets and the windows' arrangement for that job go there too (later
picks, flags, QC results and notes), so the whole job can be copied or handed over as one
folder.

A project is optional. Without one, the program works as it always has: what is
remembered about each file lives in the program's own folder (`<config>/files/`, keyed
by the file's content), a survey is imported for the session, and the windows, presets
and filters are the user's own.

The choices made with the user are listed under [Decisions](#decisions) at the end.

## What a project is on disk

One folder, named by the user, that holds everything. Copying the folder copies the
project; nothing about it lives anywhere else (the user's recent projects aside).

```
Land 2026/                  the project folder: this is what is opened
  project.nif               the project document (NIF text)
  layout.nif                the windows as they were arranged in the project
  files/                    what is remembered about each data file, one document per file
  survey/
    files/                  copies of the survey files imported (SPS, SEG P1, CSV tables)
    survey.bin              the survey as imported: what parseSEG read from the copies
  cache/                    what can be made again; safe to delete
  vendormaps/               the project's vendor header maps (*.nif), with a note and the guide to writing one
  shotlogs/                 copies of shot logs imported; the document keeps the name and the map
  owner.nif                 who has the project open (a note; the lock is below)
  .lock                     the lock between programs, held while the project is open
```

- **A folder that holds a `project.nif` is a project**, wherever a folder is named to
  the program: Project > Open project..., Project > Recent projects, the command line
  (`viewSEG <project folder>` or `viewSEG <project folder>/project.nif`), a drop on the
  window, a folder listed in Files. Such a folder is opened as the project, never listed;
  any other folder is a data folder, whatever it holds. (Double-clicking a project in the
  desktop's file manager needs a file association, which needs an extension of its own,
  such as `.viewseg`: a later step.)
- **`project.nif`** says what the project is: its name, its data folders, its survey files
  with their originals, the import's options and units, what `survey.bin` holds, the
  project's filters and display presets (`core/projectnif`). A station moved during a
  deployment is a `stationMoves` entry there: a new receiver position from a time on,
  not written into the seismic file or the survey file. While a file is open that
  position replaces the header's and the survey's for a trace recorded at or after
  `fromTime`, and the offset and midpoint are computed again. Removing the move puts
  the header or survey position back. They are applied even when the project's survey
  cannot be restored. A move matches a trace as the join matches a station: the
  same index, else index 0 for any index, else a trace with index 0 takes index 1.
  A document without the tag has none. File > Output writes that position, and a
  survey join's, into the output headers on every path, unless **Keep the file's
  own positions** is ticked: then the file's own header positions are written.
  The result counts only traces whose positions were stored. A file the batch
  opens itself is not joined or moved, and the result says the batch wrote the
  file's own positions.
- **`files/`** is the store of what is remembered about files (`core/filememory`), in the
  same documents as `<config>/files/`. While a project is open it is the store's home, so
  every edit made goes there and nothing changes in the program's own store.
- **`survey/files/`** holds copies of the survey files imported, so a project handed over
  carries its survey. Each copy keeps its original's path and identity (below).
- **`shotlogs/`** holds copies of shot logs imported into the project. The document
  names each one (`shotLogs`: a short name, the copy's file name, and the column map).
  The map writes `decimalComma` when a comma is the decimal point; a document
  without it reads as not. The text is the copy, never a node of `project.nif`,
  and the file it was imported from is not changed. A document without the node
  has none. A field inside a log that this version does not know is kept and
  written back. A role that is not one,
  a map with more columns than this version keeps, or a file name that is not a
  plain name in `shotlogs/` is said and left out. A name Windows keeps for a device
  (`CON`, `PRN`, `AUX`, `NUL`, `COM1` to `COM9`, `LPT1` to `LPT9`, any extension)
  or one that ends in a dot or a space is not a plain name. The document also keeps
  the column map used last (`lastShotMap`: a `map` written and read as a stored log's
  map, and `headerName` entries beside it, one per column). An import with no map
  given uses it when the column count is the same and, when there is a header, the
  header names are the same after trimming and ignoring capitals. Removing a log does
  not remove the node. A document without the node has none. A role that is not one,
  more columns or header names than a stored map keeps, or a header name longer than
  a shot log's name, is said and the node is left out. A field inside it that this
  version does not know is kept and written back. A project open read-only uses the
  map and does not write it.
- **`survey/survey.bin`** is what parseSEG read from the copies, in a compact binary form
  (below). Opening the project reads it instead of the survey files.
- **`cache/`** holds only what the program can make again from the data.
- The project document also holds the job's vibrator QC profile (`vibProfile`), when one
  was taken from a Vibrator window: the six limits, the statistics window, the harmonics,
   the accelerometer set, the force scale, a typed 100 % force, the unit it was
   typed in and the accelerometer set that a pound-counts force was typed on,
   a drive level, the reference's archive id and the top typed for that
  reference. A document without it has
  no profile, so a project made earlier opens unchanged. A field inside it that this
  version does not know is kept and written back. The job's vibrator weights
  (`vibWeights`) are stored once, in kilograms: the hold-down, the baseplate mass and
  the reaction mass. A weight not set is left out; a document without the tree has
  none. They are the job's, not a file header's.
- The project document also holds which vendor map decodes the project's files (`vendorMap`:
  a map's name, empty for none; absent for Automatic): Project > Vendor map
  (docs/user/vendor-maps.md). A document without it reads as Automatic, so projects made earlier
  open unchanged, and a program that does not know it keeps it as it is.
- **`vendormaps/`** holds vendor header maps for this job, preferred to the user's and the
  program's (docs/user/vendor-maps.md). It is made with the project, and added when a project
  without it is opened writable; a read-only project is left alone.
- **Data folders are never written to**: not the project, not a cache, not a lock. A
  project is refused a place inside one of its own data folders.

### The project document

```
(.nif27)
(.vendor "viewSEG")
(project
 (version 1)
 (name "Land 2026")
 (created "2026-11-15T21:40:00Z")
 (data (folder (path "../field/day1") (absolute "/mnt/field/day1")))
 (survey
  (file (kind sps) (copy "survey/files/land.s")
   (path "../samples/land/land.s") (absolute "/data/samples/land/land.s")
   (size 776) (modified 1763200961 120000000) (quick "9a0c51f3e2d4b6a7"))
  (join (trailingDigits false) (multiComponent false) (coordinates fill) (recordMatch auto)
   (traceMatch auto) (lineNames (line "CLT4960" 4960)))
  (units (survey usFeet) (file usFeet) (surveyFromHeaders false) (fileFromHeaders true))
  (notes "H20 Description of grid units: US survey feet")
  (imported "2026-11-15T21:42:10Z")
  (store (format 1) (bytes 4096) (hash "51f3a0c4e2d4b6a7") (sources 6)
   (receivers 96) (relations 6)))
 (processing (dc none) (band bandPass) (f1 4.0) (f2 8.0) (f3 60.0) (f4 80.0) (aux false))
 (displayPresets (preset "Section" (mode density) ...)))
```

- **Versioned.** `version` is the document's format. A reader skips what it does not
  know and writes it back as it was, so a later version can add fields beside these. A
  document of a newer version than the program knows is opened read-only, and the
  program says so.
- **Relative paths, with the absolute one beside.** Every path is kept twice: relative to
  the project folder (`path`) and as it was when last found (`absolute`). It is looked for
  relative first, then absolute, then as a folder of the same name beside the project
  folder: a project copied together with its data finds them where they now are, and a
  project copied alone still finds data that did not move. Where no relative path exists
  (another drive on Windows), only the absolute one is kept.
- **Re-pointing what is missing.** A data folder found at none of its places is shown as
  missing in the Project window, with **Locate...**. When one is located, the other missing
  folders that were beside it are looked for beside it at its new place. A data file's own
  edits never depend on its path (they are kept by its identity), so re-pointing a folder
  loses nothing.
- **Robust to a crash mid-write.** The document, the project's layout and the file
  documents are written by the disk thread (`core/diskio`) as the settings are: a second
  after a change and at the quit, to a temporary file that is flushed and then renamed
  over it. Copies of survey files and `survey.bin` are written beside their final names
  and renamed only when whole; `survey.bin` ends with its own hash, so one that does not
  match is never used.
- **A document that cannot be read** is never moved aside or written over: the project is
  not opened, and the log says why.

### The survey as imported (`survey.bin`)

The survey files can be large (an R file of 200 000 stations, an S file of two million,
relation files of tens of millions of records), and reading them is the slow part of an
import. When the user imports a survey with a project open, the import runs as always;
then, on the background lane, its files are copied into `survey/files/` and read once
more into `survey.bin` (`core/surveystore`). Every later use reads `survey.bin`, never the
text:

- the map's survey layers (one per SPS or P1 file, made on a worker as when a survey file
  is loaded);
- the geometry the joins use (`SurveyGeometry`, made from the stored records through
  parseSEG's `addSps`, `addP1` and the viewer's `addCsv`, with the project's options);
- the joins of every file opened.

What is kept is what the files say, not what the options made of them: line and point
fields as text beside their numbers, so the line names and trailing digits can change
without a new read. The format (1): a 16-byte magic and the format number, then blocks
(a kind, a count and a size before each payload): a file's block (its copy, its kinds, its
size and time), its SPS header records, its point records and relation records in parts
of at most 65 536, a P1 logical file's shotpoints, a CSV table's text; an end block, then
an XXH64 hash of every byte before it. The whole file's hash is checked before anything
in it is used.

**A `survey.bin` that cannot be used** (damaged, cut short, of a newer format) is not the
end of the survey while its copies are in the project: in a writable project it is made
again from them, with a message. It is written to a temporary file that is flushed and
synced to the disk before it is renamed, so a full disk or a power loss never leaves a
cut-short `survey.bin` in place.

**While the survey is being copied in.** The import's files (their originals), options
and units are written to `project.nif` at once, as `(importing ...)`, and Messages says
the survey "is being copied into the project", not that it is. Close project, or a quit,
while the copy runs stops it and keeps what was written; the next open copies the
originals again and makes the survey, with a message. The entry records each original's
size, modified time and first-and-last-64-KiB hash when the copy begins; the resume takes
only a file of that identity at the recorded path (never one found beside the project or by
its name), and only when that path is inside the project folder or one of its data folders
(the paths resolved, links followed): a project handed over may name any path, and no other
file is copied into the project without the user's say. A file already in `survey/files`
that is one of the project's copies, of its recorded identity, is taken as it is. Anything
else (an original changed or gone, an entry without an identity, a path elsewhere) is
not copied: Messages says the import was interrupted and its files are not as they were,
the survey is to be imported again (for a path elsewhere, Messages says it is not in the
project or its data folders), and the entry is cleared. The copies are written to
temporary files and put in place only once `survey.bin` is written, so a failed or
abandoned copy leaves none. The `(importing ...)` entry goes
when the copy is whole (or when it failed: the user then imports the survey again).

**When an original changes.** After the open, the program looks at each survey file's original
(on a job of its own: a share may not answer): its size, modification time and quick hash (the size
and an XXH64 hash of its first and last 64 KiB). One that changed (an S file that grew
with the day's shots) is said in the log, and the Project window comes forward with
**Update from the original**: never updated without asking. Until then the project uses
its copy. The update copies the changed originals in again, writes `survey.bin` again and
puts the new survey on the map; the files open are matched to it again. The original's identity is taken after the copy and must be the one before it: an original written meanwhile is copied once more, and then refused with a message. The copies are written to temporary files and put over the old ones only after `survey.bin` is written from them, so a refused or cancelled Update leaves the copies, `project.nif` and `survey.bin` as they were. They are put over the old ones with each old copy set aside first: when one cannot be moved in, the ones put in place are removed and the old ones come back, never a mixture. Update is not offered while the survey is being copied in. An original that
is gone is no problem: the copy stands for it, and the Project window says the original
was not found.

## What identifies a file

A project never goes by a file's name. Files are often output, found wrong, and output
again under the same name; what was done to the first output must not land on the
second.

- **A data file is known by its content.** Its size and a hash of its first and last
  64 KiB are read when it opens (a few milliseconds); a hash of every byte follows in
  the background. Its kills and reversals are kept under that identity (`files/`), so a
  file renamed or moved keeps them, and another file under the same name does not get
  them. The path is kept only as a hint of where the file was last seen. (The project's
  filters and presets are the project's, not a file's.)
- **Brought back at once, then checked.** When the size, the ends and the modification
  time are those the edits were made on, the edits are shown at once, and the plot's
  title says "(edits being checked)" until the hash of every byte agrees. If it does not
  (the same size and ends, one trace in the middle re-processed), they are taken off
  again and Messages says so. With another modification time, they wait for that hash
  and are never shown on another file.
- **Edits made during the check are the user's own, kept apart.** The brought-back
  document is not written until the hash agrees. What the user does meanwhile goes into
  a record of its own (the quick identity, the modification time, the trace count and
  the date; no hash of every byte), holding the whole state as the user has it, so an edit
  taken off a brought-back one is kept too. When the hash agrees, it joins the document.
  When it differs, the brought-back edits are taken off and the user's own stay as this
  file's record; Messages says both.
- **A record never confirmed is never applied by itself.** A quit (or a close) during the
  check leaves the brought-back document as it was and that record of the user's own
  edits, marked unconfirmed. No later hash can say whether they were made on this file or
  on the other one of the same size, ends and time, so at the next open of a file of that
  quick identity nothing of them is applied: the normal path runs, and Messages says once
  that the edits were not yet confirmed as this file's. The Project window lists them with
  the earlier outputs ("Edits you made on 2026-11-14 10:32 before the file's content was
  compared"), with **Apply them to this file** (the file's edits become that state, in
  one step Edit > Undo takes back; offered only when the trace counts match) and
  **Forget them**. It does so without a project too, for the program's own store.
- **Paths of one content are linked only when confirmed.** Two open paths of one size, ends
  and modification time are not linked at once while edits brought back for either are
  being checked: each waits for its own hash of every byte.
- **An earlier output is said, kept and listed.** When the file at a path is not the
  one the edits there were made on, Messages says it once ("line7.sgy is not the file
  your edits were made on (output again since 2026-11-14 10:32: other contents): its
  12 killed, 3 reversed are not applied."), and the Project window lists the earlier
  output's edits under the file, with **Apply them to this file** (one step: Edit > Undo
  takes it back; offered only when the two have the same number of traces, and the
  button says why when they do not) and **Forget them**. Nothing is moved onto the new
  file by itself. Once applied, the earlier output is neither said nor listed again: its edits are the file's own.
- **Survey originals too.** An original is "changed" only when its content is: its
  size or the hash of its first and last 64 KiB differ, or, when those agree but its
  time moved, the hash of every byte differs from its copy's. A file touched or copied
  with its content as it was is as copied.

## What a project holds

| | v1 | Later |
|---|---|---|
| Data folders (relative, re-pointable) | yes | a folder followed as files arrive |
| The survey: copies of its files, their originals, the options, units, header notes | yes | several surveys (preplot and as shot) |
| The survey as imported (`survey.bin`); the originals checked, Update from the original | yes | |
| Every file opened is matched to the project's survey, no window, no survey file read | yes | |
| Kills, reversals, "reverse all" (the store's home) | yes | |
| The plot's filters | yes | named filter presets |
| Display presets | yes | |
| The windows' arrangement | yes | |
| Flags, notes (per project, per file, per trace) | | yes |
| First-break picks, QC and scan results, the folder scan's statistics | | yes |
| The positions of every data file, for a map of the whole project; stepping across folders | | yes |
| A data folder listed offers the project it belongs to; Save project as (a copy elsewhere) | | yes |
| Notes and filters of one file (beside its kills) | | yes |

**Every file opened in a project is matched to its survey.** The import is the one step
the user takes; after it, each seismic file opened is matched to the project's survey with
the project's options and units, as the Import survey window would do it, without the
window and without reading a survey file (`projectjobs.planWork`, then the import's own
join step). The log says "Matched ... to the project's survey". A file opened before the
survey is ready is matched once it is.

**Clear survey** (Project > Clear survey, the Import survey window, this window's Survey part) removes the
project's survey: its document entries, and on a background job its `survey/` folder (the
copies and `survey.bin`). The originals the copies were made from are never touched. A
project open read-only is not cleared.

**Many files, one survey.** A project's data folders are its seismic data. The step after
v1: a background scan of their headers (no samples) keeps each file's sources and
receivers in `cache/`, by identity, so the map shows what was recorded across the whole
project without opening every file, and Files steps from the last record of one folder to
the first of the next.

## What stays per user

The settings stay the user's, whichever project is open: the theme, the main window's
place, the plot's defaults (but the filters, which are the project's while it is open),
scales and calibrations, the status bar, the sort presets, the Headers and spectrum
windows' toggles, the map's own options, the tray, the import's options as set last. So do
the recent files and folders, the named layouts, and the program's own store. New in the
settings: `recentProjects` (newest first), `lastProject` (the project open at the quit)
and `reopenProject` (on: the program starts with that project). A settings file from
before has none of these and takes their defaults, without a message.

While a project is open, a change of the display presets or of the plot's filters made in
a window is kept in the project, not in the settings, and the windows' arrangement is
saved in the project's `layout.nif`. Closing the project brings the user's own presets,
filters and windows back.

## Opening, making and closing a project

**Project > New project...** opens its window: a name, the place the project's folder is made
in (`~/viewSEG projects`, on Windows `Documents\viewSEG projects`, by default; Choose...),
the data folders (the folder Files lists, by default; Add a data folder...), and what the
session takes along:

- *Use the survey loaded now* (when survey files are on the map): copied into the project
  with the import's options and units;
- *Bring what is remembered about the files in these folders*: the program's store's
  documents whose file was last seen in those folders are copied into the project's
  `files/` (the program's own store keeps them);
- *Take my display presets*: copied into the project.

The plot's filters are taken along too. The session then becomes the project's: the files
open stay open.

**Project > Open project...** (a folder dialog), **Project > Recent projects**, the command line
and a drop: what is pending of the session is written, the files open and the survey on
the map are closed, and the project's opened: its document read, its lock taken, its
data folders and survey originals looked at, its first data folder found listed, its
survey made from `survey.bin`, its windows arranged as it left them. Everything is read on
jobs; the window stays at frame rate. **Project > Close project** writes what is pending,
closes its files and survey in the same way and goes back to working without a project,
with the user's own windows, presets and filters. There is no Save: a project is written
as it changes.

**The window says which project is open:** the title (`viewSEG - Land 2026`, with
`(read-only)` when it is), the right end of the toolbar (the project's icon and its name,
the same `(read-only)` when it is, or "No project"; a long name is shortened in the
middle; a click opens the Project menu's items; the tooltip is the folder and, in one
line, how many survey files and data folders the project holds) and the **Project window**
(Project > Project...): its name and
place, why it is read-only, its data folders (found, missing with Locate..., each with
List), Add a data folder..., the survey (its counts; on the map, loading, being copied;
each file as copied in, changed, or its original not found; how long it took to make from
the project), Update from the original when an original changed, and Close project.

## Two programs, one project

The first program to open a project holds its lock (`.lock`, through `fs.lockFile`, for as
long as it has the project open; the system lets it go when the program ends however it
ends) and writes `owner.nif` beside it (the computer, the user, the process, since when).
A second program that opens the project finds the lock taken and opens it **read-only**:
everything is shown and usable, nothing it does is written into the project (its edits are
for the session), the title says so and the Project window names who has it open. Two
programs never write the project at once, so the project needs no merging.

## Threads and files

Reading the document, taking the lock, reading the project's layout and looking at the
data folders are a job on the interactive lane (`openProjectWork`, a few stats and one
small read). The survey originals are never looked at on the open path: once the project
is open they are looked at in a job of their own on a lane of its own (`originalsWork`,
with progress and a cancel), so an original on a share that does not answer, or one
touched and large, holds up nothing: not the open, and not the hash of any data file
("edits being checked"). An original found changed by a read of every byte is not read
again until its time moves: the time it was found changed at is kept in `project.nif`. When one's time moved but every byte is its copy's,
the new time is recorded in `project.nif`, so the next open does not read it again; copying the survey in, writing `survey.bin` and making the
survey from it are jobs on the background lane (`keepSurveyWork`, `updateSurveyWork`,
`restoreWork`: `survey.bin` can be large, so its job writes it, not the disk thread,
which must stay free for the settings and the log). These three are exclusive on the project's survey folder, so two never run at once, and each names its temporary files for its own job; copying and hashing a file have places for a cancel. The disk thread writes the project
document, its layout and the file documents. A project on a drive that does not answer
holds only its own jobs.

The modules: `core/project` (the types and rules: parts, paths, re-pointing),
`core/projectnif` (the document, the owner note), `core/surveystore` (`survey.bin`),
`core/projectjobs` (the jobs above), `ui/imgui/projectwindow` (the Project and New
project windows). `core/state` holds the project open (`AppState.project`), its commands,
and the hooks: the store's home, the layout's file, the presets' and filters' home, and
each opened file queued to be matched (`followProject`).

## Agent control

- **`state` part `project`:** `open`; the project's path and name, `readOnly` and why,
  its data folders (each `found`, `missing`, `looking` or `notAnswering`, and where it was
  found), its survey (the copies with their originals' state: `asCopied`, `changed`,
  `notFound`; the state: `none`, `loading`, `loaded`, `keeping`, `failed`; the options and
  units; sources, receivers, relations, `survey.bin`'s size; `restoreMs`, `updateOffered`),
  and whether it holds its own presets and filters.
- **Commands:** `new project` (`projectPath`: the folder to make; `projectName`,
  `dataFolders`, `useSurvey`, `bringMemory`, `takePresets`), `open project` (`projectPath`:
  the folder or its project.nif), `close project`. `wait` covers the project's jobs.
- **What an agent's commands keep:** as for everything else, an agent's changes are for
  the session. It may make (a new folder only), open and close projects; its trace edits,
  presets, filters and survey imports are not written into a project, and `project folder`
  and `update survey`, which write into the project, are the user's alone.

## Decisions

Each choice the draft left open, with the user's answer (2026-11-15).

1. **The project is its folder**, and its document is `project.nif` inside it (the user:
   "is .nif not the way to go on this? .viewseg will work if not."). A unique extension
   is needed only for a file association, later.
2. **A project is one folder** holding everything. Confirmed.
3. **New projects go under `~/viewSEG projects/`** by default. Confirmed.
4. **A project is never put inside one of its data folders.** Confirmed.
5. **Opening or closing a project closes the session's files and survey;** New project
   keeps them. Confirmed.
6. **The program starts with the project that was open at the quit.** Confirmed.
7. **Every file opened in a project is matched to its survey**, without the window.
   Confirmed.
8. **A survey original that changed is said and offered (Update from the original),
   never taken unasked;** one that is gone is replaced by the copy. Changed by the user:
   the draft read a changed file again by itself.
9. **The survey files are copied into the project.** Changed by the user: the draft kept
   only `survey.bin`.
10. **One survey per project** in v1. Confirmed.
11. **Edits on a file outside the project's data folders go into the project too.**
    Confirmed.
12. **The project has its own display presets.** Confirmed.
13. **A second program opens a project read-only.** Confirmed.
14. **An agent's survey imports and trace edits are not written into a project.**
    Confirmed.
15. **v1 holds** the defaults of the draft and, added by the user, **the plot's filters
    and the windows' arrangement**: a project restores its own windows; without one the
    user's layout is as always, and closing the project brings it back.
16. **A file is known by its content, never its name** (the user: "It is common for
    files to be output then an issue discovered and re-output. we wouldnt want to save
    anything for files like that. the discriminator for a file needs to be more than just
    its name."): [What identifies a file](#what-identifies-a-file).
