# Vendor header maps

Seismic files often carry header blocks whose layout is defined by the manufacturer of the
recording system rather than by the SEG standard: SEG-D extended and external headers, and
the proprietary bytes of SEG-Y trace headers. Without a description of that layout, viewSEG
can only show those bytes as raw numbers.

A **vendor header map** is that description: a small text file (`*.nif`) that names each
field in such a block, where it starts, how long it is and how to read it. With a matching
map, viewSEG shows the fields by name, like any standard header.

## Adding a map

1. Get or write a `.nif` map for your recording system.
2. Put it in your own maps folder:
   - **portable copy** (a `config/` folder next to the program): `config/vendormaps/`;
   - **installed copy** (no `config/` folder next to the program): `vendormaps/` inside your
     viewSEG settings folder (`viewSEG --paths` prints where that is).
3. Start viewSEG again.

## Where viewSEG looks

In this order, and only in folders that exist:

1. your own folder, `config/vendormaps/` (see above): **searched first**, so when one of your
   maps and a shipped map fit a file equally well, yours is used;
2. this folder, `vendormaps/`, next to the program: the maps that ship with this release;
3. every folder listed in the environment variable `PARSESEG_VENDOR_PATH` (separated by `:`
   on Linux and macOS, `;` on Windows).

Run `viewSEG --paths` to see the folders in use on your machine (the `vendormaps:` lines).

Leave this folder as it is: a new release replaces it. Keep your own maps in
`config/vendormaps/`.

---

*In the source repository, this folder holds viewSEG's own maps; `nim package` copies them,
with parseSEG's, into every release.*
