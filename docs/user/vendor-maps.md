# Vendor header maps

The SEG-D and SEG-Y standards leave some header blocks to the maker of the recording system:
SEG-D extended and external headers and user blocks, SEG-Y extended textual stanzas and
unassigned header bytes. Without a description of such a block viewSEG shows its bytes. A
**vendor header map** is that description: a text file ending in `.nif` that names the
fields of a block, where each begins and how to read it. With a map that applies to the
file, the Headers window shows the fields by name, with their values.

## Where to put a map

viewSEG loads every `*.nif` file of these `vendormaps` folders, in this order of preference:

1. **The project's**: the `vendormaps` folder of the project open. New project makes it; a
   project made earlier gets it when it is opened writable (a project open read-only is left
   alone). Use it for maps that belong to one job: they travel with the project.
2. **Yours**: `vendormaps` in your viewSEG settings folder (`viewSEG --paths` prints where
   that is). Make the folder if it is not there.
3. **Beside the program**: `vendormaps` next to the viewSEG executable. A release comes with
   one; viewSEG makes it at start when the program's folder can be written to, and says
   nothing when it cannot.
4. **The environment's**: each folder named in `PARSESEG_VENDOR_PATH`.

`viewSEG --paths` lists the folders that exist, and `State`'s `vendorMaps` (agent control)
says what each gave.

Each folder viewSEG makes holds `README.txt` and `WRITING-A-MAP.md`, the guide to the format of
a map. A file already there is never replaced.

## Reload

Opening or closing a project loads the maps again, and so does **File > Reload vendor maps**:
a map dropped in while viewSEG runs is used without a restart, and the files already open
show the new decode (the Vendor tab of the Headers window, File headers). Reading the folders
happens in the background; the window does not wait for it.

## What the window shows

The **Vendor** tab of File headers lists each decoded block under the name of the map that
decoded it, its fields by name with their values, units and labels. A block no map applies
to stays as its bytes in the tab it had. The file's own bytes are never changed.

The **Trace** tab, Header, shows a **Vendor** group above the header table for each trace it is
about (the selected trace, or the one under the pointer): the vendor blocks of that trace's own
headers (a SEG-D trace header extension, a SEG-Y proprietary trace header) that a map decodes,
each under the map's name, fields by name with value, unit and label. A field whose value is the
map's "absent" sentinel is not listed; when no map applies there is no group. Only the traces
the tab is about are read, once, in the background; the trace table does not show vendor fields.

## A project's vendor map

A job is usually recorded with one vendor's system, but a map can only say which files it is for
by format, revision, manufacturer code, serial number and text: two maps for one manufacturer
cannot be told apart by the files. **Project > Vendor map** says which one the project uses:

- **Automatic** (the default; also every project made before this choice existed, and every file
  outside a project): every map loaded is offered, as described below.
- **A map, by name**: only that map is offered to decoding for the project's files. It is never
  forced onto a file it does not match: for a file whose format, revision, manufacturer or
  serial number is not the map's, no vendor field is shown and Messages says once, in a
  sentence, that the project's map does not apply to that file. A map that is not among
  those loaded (a map dropped out of the folders) is one warning in Messages, naming it;
  nothing is decoded and the choice stays in the project, so it works again when the map is back.
- **None**: no vendor decoding.

The choice is saved in the project (a read-only project keeps it for the run only), and the
Vendor tab and the Trace tab's Vendor group say which rule is in force when it is not
Automatic. Outside a project the entry is disabled: every map loaded is offered.

## Which map is used

A map says which files it is for (format, revision, manufacturer code, serial number, text
of the textual header). When several apply to the same block, the one that says the most about
the file is used; of two that say the same, the one of the folder first in the list above. Of
two maps with the same name the first folder's is the only one loaded, so a project can
replace a map of the program's by keeping a copy of the same name.

## Messages

Each load says one line in Messages: "3 vendor header maps loaded: 2 from the project, 1
beside the program". When no map is found anywhere that is said once, as information.

A map that does not load gets one line naming its file and the reason, in parseSEG's words
("line 12: unknown encoding"); the other maps load all the same. "Loaded, with a note" means
the map works but parseSEG saw something worth a look, such as two fields that overlap. Check a
map before dropping it in with `parseSEG vendormap check map.nif`.
