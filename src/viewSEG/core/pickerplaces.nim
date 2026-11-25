## Where each file or folder picker was last used, so that it opens there the next
## time. Pure rules on a table of (picker name, folder); the toolkit's side
## (`ui/imgui/shell`) names each dialog with a stable string and asks for its start.

import std/os

const MaxPickerPlaces* = 64 ## the table keeps at most this many pickers

type
  PickerPlace* = object
    name*: string   ## the picker's stable name (never an enum's ordinal)
    folder*: string ## the folder it was last used in

func folderOf*(places: openArray[PickerPlace]; name: string): string =
  ## The folder stored for the picker `name`; "" for none.
  for p in places:
    if p.name == name: return p.folder

proc remember*(places: var seq[PickerPlace]; name, folder: string) =
  ## Stores `folder` as where the picker `name` was last used. An empty name or
  ## folder remembers nothing.
  if name.len > 0 and folder.len > 0:
    var found = false
    for p in places.mitems:
      if p.name == name:
        p.folder = folder
        found = true
    if not found and places.len < MaxPickerPlaces:
      places.add PickerPlace(name: name, folder: folder)

proc nearestFolder*(folder: string): string =
  ## `folder` when it exists, else its nearest parent that does; "" when none does.
  result = folder
  while result.len > 0 and not dirExists(result):
    let up = result.parentDir
    result = if up == result: "" else: up

proc startAt*(places: openArray[PickerPlace]; name, location: string;
    explicit, save: bool): string =
  ## Where the picker `name` starts. In this order: `location` when the caller means
  ## it (`explicit`: a folder or file the user is editing) and its folder exists; else
  ## the folder last used with this picker, when it, or a parent of it, exists (a save
  ## picker keeps the file name `location` proposes, in that folder); else `location`.
  let proposed = location.len > 0 and (dirExists(location) or dirExists(location.parentDir))
  if explicit and proposed: location
  else:
    let folder = nearestFolder(places.folderOf(name))
    if folder.len == 0: location
    else:
      let leaf = if save and not dirExists(location): location.extractFilename else: ""
      if leaf.len > 0: folder / leaf else: folder & DirSep
