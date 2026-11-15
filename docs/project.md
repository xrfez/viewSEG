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
Morgantown 2026/            the project folder: this is what is opened
  project.nif               the project document (NIF text)
  layout.nif                the windows as they were arranged in the project
  files/                    what is remembered about each data file, one document per file
  survey/
    files/                  copies of the survey files imported (SPS, SEG P1, CSV tables)
    survey.bin              the survey as imported: what parseSEG read from the copies
  cache/                    what can be made again; safe to delete
  owner.nif                 who has the project open (a note; the lock is below)
  .lock                     the lock between programs, held while the project is open
```

- **A folder that holds a `project.nif` is a project**, wherever a folder is named to
  the program: File > Open project..., File > Recent projects, the command line
  (`viewSEG <project folder>` or `viewSEG <project folder>/project.nif`), a drop on the
  window, a folder listed in Files. Such a folder is opened as the project, never listed;
  any other folder is a data folder, whatever it holds. (Double-clicking a project in the
  desktop's file manager needs a file association, which needs an extension of its own,
  such as `.viewseg`: a later step.)
- **`project.nif`** says what the project is: its name, its data folders, its survey files
  with their originals, the import's options and units, what `survey.bin` holds, the
  project's filters and display presets (`core/projectnif`).
- **`files/`** is the store of what is remembered about files (`core/filememory`), in the
  same documents as `<config>/files/`. While a project is open it is the store's home, so
  every edit made goes there and nothing changes in the program's own store.
- **`survey/files/`** holds copies of the survey files imported, so a project handed over
  carries its survey. Each copy keeps its original's path and identity (below).
- **`survey/survey.bin`** is what parseSEG read from the copies, in a compact binary form
  (below). Opening the project reads it instead of the survey files.
- **`cache/`** holds only what the program can make again from the data.
- **Data folders are never written to**: not the project, not a cache, not a lock. A
  project is refused a place inside one of its own data folders.

### The project document

```
(.nif27)
(.vendor "viewSEG")
(project
 (version 1)
 (name "Morgantown 2026")
 (created "2026-11-15T21:40:00Z")
 (data (folder (path "../field/day1") (absolute "/mnt/field/day1")))
 (survey
  (file (kind sps) (copy "survey/files/morgantown.sps")
   (path "../survey/morgantown.sps") (absolute "/mnt/survey/morgantown.sps")
   (size 4812733) (modified 1763200961 120000000) (quick "9a0c51f3e2d4b6a7"))
  (join (trailingDigits false) (multiComponent false) (coordinates fill) (recordMatch auto)
   (traceMatch auto) (lineNames (line "CLT4960" 4960)))
  (units (survey usFeet) (file usFeet) (surveyFromHeaders false) (fileFromHeaders true))
  (notes "H20 Description of grid units: US survey feet")
  (imported "2026-11-15T21:42:10Z")
  (store (format 1) (bytes 31457280) (hash "51f3a0c4e2d4b6a7") (sources 1200)
   (receivers 3954) (relations 1200)))
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

**When an original changes.** At open, the program looks at each survey file's original
(on a job: a share may not answer): its size, modification time and quick hash (the size
and an XXH64 hash of its first and last 64 KiB). One that changed (an S file that grew
with the day's shots) is said in the log, and the Project window comes forward with
**Update from the original**: never updated without asking. Until then the project uses
its copy. The update copies the changed originals in again, writes `survey.bin` again and
puts the new survey on the map; the files open are matched to it again. An original that
is gone is no problem: the copy stands for it, and the Project window says the original
was not found.

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

**Every file opened in a project is matched to its survey.** The import is the one step
the user takes; after it, each seismic file opened is matched to the project's survey with
the project's options and units, as the Import survey window would do it, without the
window and without reading a survey file (`projectjobs.planWork`, then the import's own
join step). The log says "Matched ... to the project's survey". A file opened before the
survey is ready is matched once it is.

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

**File > New project...** opens its window: a name, the place the project's folder is made
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

**File > Open project...** (a folder dialog), **File > Recent projects**, the command line
and a drop: what is pending of the session is written, the files open and the survey on
the map are closed, and the project's opened: its document read, its lock taken, its
data folders and survey originals looked at, its first data folder found listed, its
survey made from `survey.bin`, its windows arranged as it left them. Everything is read on
jobs; the window stays at frame rate. **File > Close project** writes what is pending,
closes its files and survey in the same way and goes back to working without a project,
with the user's own windows, presets and filters. There is no Save: a project is written
as it changes.

**The window says which project is open:** the title (`viewSEG - Morgantown 2026`, with
`(read-only)` when it is) and the **Project window** (File > Project...): its name and
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
data folders and originals are a job on the interactive lane (`openProjectWork`, a few
stats and one small read); copying the survey in, writing `survey.bin` and making the
survey from it are jobs on the background lane (`keepSurveyWork`, `updateSurveyWork`,
`restoreWork`: `survey.bin` can be large, so its job writes it, not the disk thread,
which must stay free for the settings and the log). The disk thread writes the project
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
