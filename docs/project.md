# Projects: design

> **A draft for the user to confirm.** The choices still open are listed under
> [Open choices](#open-choices) at the end, each with the default this page describes.
> Nothing here is built yet.

A project is the home of one job's work. The user imports the survey into it once, and
the survey is never imported again: not when the program starts again, not for the next
file, and not on another machine the project is handed to. Kills, polarity, filters,
joins, picks, QC results and notes for that job go there too, so the whole job can be
copied or handed over as one folder.

A project is optional. Without one, the program works as it does today: what is
remembered about each file lives in the program's own folder (`<config>/files/`, keyed
by the file's content), and a survey is imported for the session.

## What a project is on disk

One folder, named by the user, that holds everything. Copying the folder copies the
project; nothing about it lives anywhere else (the user's recent projects aside).

```
Morgantown 2026/                  the project folder
  Morgantown 2026.viewseg         the project document (NIF text): open this one
  files/                          what is remembered about each data file, one document per file
  survey/
    survey.bin                    the survey as imported: stations, relations, line names
  cache/                          what can be made again (scans, positions); safe to delete
  owner.nif                       who has the project open (a note; the lock is below)
  .lock                           the lock between programs, held while the project is open
```

- **The project document** (`<name>.viewseg`) is NIF text, like the settings, written by
  the program and readable (and, with care, editable) by a person. It says what the
  project is: its name, its data folders, its survey files with their options and units,
  what the survey import made, the project's presets.
- **`files/`** is the store of what is remembered about files, in the same documents as
  `<config>/files/` (one per file identity: the trace edits; later flags, notes, the join
  used, the filters). While a project is open it is the store's home (`Store.home`), so
  every edit made goes there and nothing changes in the program's own store.
- **`survey/survey.bin`** is the survey as the import read it, in a compact binary form
  (below). It is what makes the survey "never redone": opening the project reads it
  instead of the survey files, and it stands in for them when they are gone (a project
  handed over without them).
- **`cache/`** holds only what the program can make again from the data. Deleting it
  loses nothing but time.
- Data folders are never written to: not the project, not a cache, not a lock. A project
  is refused a place inside one of its own data folders (field media is often
  read-only, and a copy of the media should be the field's bytes only).

### The project document

```
(.nif27)
(.vendor "viewSEG")
(project
 (version 1)
 (name "Morgantown 2026")
 (created "2026-11-15T21:40:00Z")
 (data
  (folder (path "../field/day1") (absolute "/mnt/field/day1"))
  (folder (path "../field/day2") (absolute "/mnt/field/day2")))
 (survey
  (file (path "../survey/morgantown.sps") (absolute "/mnt/survey/morgantown.sps")
   (kind SPS) (size 4812733) (modified 1763200961 120000000) (quick "9a0c51f3e2d4b6a7"))
  (file (path "../survey/morgantown.rps") ...)
  (file (path "../survey/morgantown.xps") ...)
  (options (trailingDigits false) (multiComponent false) (coordinates fill)
   (recordMatch auto) (traceMatch auto) (lineNames (line "CLT4960" 4960)))
  (units (survey usFeet) (byHand true))
  (crs "NAD83 / Pennsylvania South (ftUS)")
  (imported "2026-11-15T21:42:10Z")
  (made (file "survey/survey.bin") (format 1) (bytes 31457280) (hash "51f3...")
   (sources 1200) (receivers 3954) (relations 1200)))
 (fileUnits (file (path "../field/day1/shot12.sgd") (unit usFeet)))
 (displayPresets
  (preset "Section" (mode density) (colourMap viridis) (gain none) ...)))
```

- **Versioned.** `version` is the document's format. A reader skips what it does not
  know and writes it back as it was (`later`, as the file documents do), so a later
  version can add fields beside these. A document of a newer *version* than the program
  knows is opened read-only, and the program says it was made by a newer viewSEG.
- **Relative paths, with the absolute one beside.** Every path is kept twice: relative to
  the project folder (`path`) and as it was when last found (`absolute`). A path is
  looked for relative first, then absolute; so a project copied together with its data
  (the usual hand-over: one drive with the project and the field folders) finds them
  where they now are, and a project copied alone still finds data that did not move.
  Where no relative path exists (another drive on Windows), only the absolute one is
  kept.
- **Re-pointing what is missing.** A data folder or survey file found at neither place is
  shown as missing in the Project window, with **Locate...** (a folder or file dialog).
  When one is located, the others that were under the same old folder are looked for
  under the same new one, and the user is told which were found that way. Both paths are
  then written anew. Before saying a folder is missing, the program also looks for a
  folder of the same name beside the project folder, the common hand-over layout.
  A data file's own edits never depend on its path (they are kept by its identity), so
  re-pointing a folder loses nothing.
- **Robust to a crash mid-write.** The document is written by the disk thread
  (`core/diskio`) as the settings are: a second after a change and at the quit, to a
  temporary file that is flushed and then renamed over it, so a crash leaves the old
  document or the new one. The same holds for every file the project writes. `survey.bin`
  is written beside its final name and renamed only when whole; the document names it
  with its size and hash, so a `survey.bin` that does not match is never used.
- **A document that cannot be read** is never moved aside or written over (it is the
  user's job): the project opens read-only, with what could be read, and the log says
  which lines could not be read.

### The survey as imported (`survey.bin`)

The survey files can be large (an R file of 200 000 stations, an S file of two million,
relation files of tens of millions of records), and reading them is the slow part of an
import. The import reads each file once, with parseSEG, and keeps what it read in
`survey.bin`. Every later use reads that instead of the text:

- the map's survey layers (made from the stored stations, on a worker, as today);
- the geometry the joins and the record checks use (`SurveyGeometry`, made from the
  stored stations and relations through parseSEG's `addSource`, `addReceiver` and
  `addSps`);
- the planned spreads of the template box.

Today the same survey files are read three times in a session (as map layers, again for
the join, again for the spreads); with a project they are read once in the project's
life.

What is kept is what the files say, not what the options made of it: line names that
are not numbers are kept as text, so changing the import's line names or trailing
digits needs no new read. The format:

- a fixed header (a magic, the format number, the parseSEG version that read the files,
  the number and place of each section), little-endian throughout;
- sections: the survey files read (as in the document, to check them against it), the
  line names, the stations (role, line, point, index, easting, northing, elevation, the
  file they came from: about 50 bytes each), the relation records (X and O: about 80
  bytes each), the P1 shotpoints, the CSV table rows, the header records (H) as text,
  the problems found (counts and the first few lines);
- a footer with an XXH64 hash of everything before it.

Loading goes in steps so the map is not kept waiting for the relations: the stations
first (the map shows the survey, and files whose headers name their stations can be
joined), then the relations (joins by record and channel, the record checks, the
spreads). Each step is a job on the background lane, with progress in the Jobs window
and a cancel.

**When a survey file changes.** At open, the program looks at each survey file (on a
job: a share may not answer): its size, modification time and quick hash (the size and
an XXH64 hash of its first and last 64 KiB, as a data file's identity). One that changed
(an S file that grew with the day's shots) is read again in the background, with the
project's options and units, no window asked; until the new survey is made the map and
the joins use the one kept, and the log says what changed ("morgantown.sps changed on
disk: read again, 2 000 112 sources, 112 more"). One that is gone is not a problem: the
survey kept stands for it, and the Project window says the file is not found. A
`survey.bin` made by another parseSEG version is read again from the files when they are
there, else used as it is.

## What a project holds

| | In v1 | Later |
|---|---|---|
| Data folders (relative, re-pointable) | yes | several drives, a folder followed as files arrive |
| The survey: its files, options, units, CRS text | yes | several surveys (preplot and as shot), datum and projection as values |
| The survey as imported (`survey.bin`), invalidated by size, time, hash | yes | |
| Every file opened is joined with the project's survey, no window asked | yes | |
| Each file's join: what it matched (the plan's counts and words) | yes | |
| Kills, reversals, "reverse all" (the store's home) | yes | |
| The units chosen by hand for a seismic file | yes | |
| Display presets | yes | |
| Filters: the plot's filters in the project, named filter presets | | yes |
| Flags, notes (per project, per file, per trace) | | yes |
| First-break picks, QC and scan results, the folder scan's statistics | | yes |
| The positions of every data file, for a map of the whole project | | yes (below) |
| A layout kept with the project | | if asked for |
| The file and record shown last, the map's view | | yes |

**Every file opened in a project is joined with its survey.** The import is the one step
the user takes; after it, each seismic file opened, stepped to or prepared in the
background is matched to the project's survey with the project's options and units, as
the Import survey window would do it, without the window. What the join did is kept in
the file's document (the counts and the words the import's report shows) and said in
the Headers window's Summary. A file whose join changes nothing is left as it is. A
file opened before the survey is loaded is joined once it is.

**Many files, one survey (a folder or several files as one survey).** A project's data
folders are its seismic data. A background scan of their headers (no samples) keeps each
file's sources and receivers in `cache/`, by identity, so the map can show what was
recorded across the whole project without opening every file, and the Files window can
step from the last record of one folder to the first of the next. This is the step after
v1; v1 keeps today's one folder listed at a time.

## What stays per user

The settings stay the user's, whichever project is open: the theme, the windows, the
plot's defaults, scales and calibrations, the status bar, the sort presets, the Headers
and spectrum windows' toggles, the map's own options, the tray, and the import's options
as set last (the defaults of a new import). So do the recent files and folders, the
layouts, and the program's own store of file memory (used without a project). New in the
settings:

- `recentProjects`: the projects opened last, newest first, each with its name and its
  data folders as last seen (so a data folder can offer its project; below);
- `projectsHome`: where New project puts a project by default (`~/viewSEG projects/`,
  on Windows `Documents\viewSEG projects\`);
- `reopenProject`: whether the program starts with the project that was open at the
  quit (on by default).

A settings file from before has none of these and takes their defaults, without a
message.

## Opening, making and closing a project

**File > New project...** asks for a name, a place (`projectsHome` by default) and the
data folders (the folder listed now, by default), with three choices that take the
session's work along:

- *Use the survey loaded now* (when survey files are on the map): its files, the
  import's options and the units chosen, imported into the project at once;
- *Bring what is remembered about the files in these folders*: the program's store's
  documents whose file was last seen in those folders are **copied** into the project's
  `files/` (with a count: "38 files with edits"). The program's own store keeps them;
  the File memory window can forget them there later;
- *Take my display presets*: copied into the project.

The session then becomes the project's: the files open stay open, and their edits are
those of the project's store from then on (the ones brought along are the same).

**File > Open project...** (a `.viewseg` file), **File > Recent projects**, the command
line (`viewSEG "Morgantown 2026.viewseg"`), a drop of the file on the window: what is
pending of the session is written, the files open and the survey on the map are closed,
and the project's are opened: its document read, its data folders looked at, the first
one listed, its survey loaded from `survey.bin`. Everything is read on jobs; the window
stays at frame rate, and a project on a share that does not answer says so and can be
closed. **File > Close project** writes what is pending, closes the files and the survey
in the same way and goes back to working without a project. **File > Save project
as...** copies the project folder to another place (the data is not copied) and opens
the copy. There is no Save: a project is written as it changes, as the settings are.

**A data folder offers its project.** When a folder is listed (opened, dropped, picked
from the recent ones) and no project of it is open, the program looks for one: in
`recentProjects`, a project whose data folders hold this one; in the folder itself, a
`.viewseg` file (only listed, never written). It never opens one by itself: the Files
window shows a line, "This folder is in the project Morgantown 2026: Open project / Not
now".

**The window says which project is open:** the title (`viewSEG - Morgantown 2026`, with
`(read-only)` when it is), the start screen (recent projects above the recent folders),
and the **Project window** (View > Project): its name and place, who else has it open,
the data folders (found, missing with Locate..., not answering), the survey (its files
and whether each is as imported, changed or not found; units; the CRS text; stations
and relations; the state of `survey.bin`: loaded, loading, being made; **Import survey
into the project...**, **Read the survey files again**, **Forget the survey**), and the
project's presets.

**Moving to a project later.** Work done without a project is not lost by making one:
the second choice above brings the file memory along, and the first the survey.

## Two programs, one project

The first program to open a project holds its lock (`.lock`, through `fs.lockFile`, for
as long as it has the project open; the system lets it go when the program ends however
it ends) and writes `owner.nif` beside it (the computer, the user, the process, since
when). A second program that opens the project finds the lock taken and opens it
**read-only**: everything is shown and usable, its edits are for the session only, the
title says so, and the log names who has it open (from `owner.nif`). It can **Open
again for editing** once the other program has closed it. An `owner.nif` whose lock is
free is out of date and ignored.

Two programs never write the project at once, so the project needs no merging; the
file documents keep their own merge (`merged(base, ours, theirs)`) for the store without
a project.

## Threads and files

All of it runs off the UI thread. Reading the document, looking at the data folders and
survey files, and taking the lock are a job on the interactive lane; loading
`survey.bin`, reading changed survey files again and writing a new `survey.bin` are jobs
on the background lane (`survey.bin` can be large, so it is written by its job, not by
the disk thread, which must stay free for the settings and the log). The disk thread
writes the project document and the file documents. A project on a drive that does not
answer holds only its own jobs (`StallAfter`), and the quit does not wait for it beyond
the disk thread's deadline, as for the settings.

New modules, so the rest of the program changes little: `core/project` (the types and
the rules: paths, re-pointing, what a project holds), `core/projectnif` (the document),
`core/surveystore` (`survey.bin`: written, checked, read in steps), `core/projectjobs`
(the jobs above), `ui/imgui/projectwindow` (the Project and New project windows).
`core/state` gains a `project` (the project open, or none), the commands, and two hooks:
the store's home follows the project, and an opened file is joined when the project has
a survey.

## Agent control

- **`state` part `project`:** whether one is open, its path and name, `readOnly` and who
  holds it, its data folders (each `found`, `missing`, `looking` or `notAnswering`), its
  survey (the files with their state: `asImported`, `changed`, `notFound`, `reading`; the
  options and units; stations and relations; `survey.bin`'s state and size), the files
  it remembers, its presets, and whether the document is written (`saved`, `pending`).
- **Commands:** `new project` (`path`, `name`, `dataFolders`, `useSurvey`, `bringMemory`,
  `takePresets`), `open project` (`path`, `readOnly`), `close project`, `project folder`
  (`add`, `remove`, `locate` with `from` and `to`), and `join geometry` gains `intoProject`
  (true by default when a project is open). `wait` covers the project's jobs.
- **What an agent's commands keep:** as for everything else (`keeps`), an agent's
  changes are for the session. An agent can open, close and make projects (making one
  writes a new folder only), but its trace edits and its survey imports are not written
  into the project. A test that needs them written drives the program as the user does.

## Open choices

Each with the default this page describes.

1. **The extension: `.viewseg`.** Plain and unambiguous; `.vsp` (proposed earlier) is
   already Visual Studio's (performance sessions) and others'. Other choices: `.vsgp`,
   `.segproj`.
2. **A project is one folder** holding the document and everything else, so copying the
   folder copies the project. (The other choice: a document anywhere, with a folder
   beside it of the same name.)
3. **Where new projects go by default:** `~/viewSEG projects/` (Windows:
   `Documents\viewSEG projects\`), a place a user sees and can copy from, rather than
   inside the program's configuration folder keyed by the data folder.
4. **A project is never put inside one of its data folders** (refused, saying why).
5. **Opening or closing a project closes the files and the survey of the session**
   (a clean switch); New project keeps them and takes them along.
6. **The program starts with the project that was open at the quit.**
7. **Every file opened in a project is joined with the project's survey**, without the
   window; the import is done once.
8. **A survey file that changed is read again by itself** in the background with the
   project's options (said in the log); one that is gone is replaced by the survey kept.
9. **The survey files are not copied into the project** (the survey as imported stands
   for them). The other choice: an option at import to keep a copy of them in
   `survey/`, for a hand-over that can be imported again with other options.
10. **One survey per project** in v1, to which files can be added (a day's SPS), and
    several surveys (preplot, as shot) later.
11. **Edits made on a file outside the project's data folders** go into the project too
    (the project is the store's home while it is open); the Project window offers to add
    the file's folder.
12. **Display presets:** the project has its own list, which the presets menu shows
    while the project is open; New project can copy the user's into it. (The other
    choice: the user's list stays the only one, and a project only carries copies to
    hand over.)
13. **A second program opens a project read-only** (a lock and a note naming who holds
    it), rather than both writing it with merging.
14. **An agent's survey imports and trace edits are not written into a project**, as
    today they are not kept with a file.
15. **What v1 holds:** new, open, recent, close and save-as; the lock; relative paths and
    re-pointing; the survey imported into the project and restored from `survey.bin`
    without reading the survey files; every file opened joined with it; kills,
    reversals and "reverse all"; the units chosen by hand; display presets; the state
    part and commands for agent control; tests. Later: filters in the project, flags,
    notes, picks, QC and scan results, the whole project's positions on the map and
    stepping across folders, layouts, several surveys.
