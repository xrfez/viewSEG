## Words for Tools > Leap seconds. The sentences a change logs live in
## `core/leapfile`, which this imports so the window and the log say the
## same thing.

import ../core/leapfile

export dateText, addedSentence

const
  WindowTitle* = "Leap seconds###leap"
  NotSaved* = "Not saved: there is no settings folder."
  Intro* = "GPS time runs ahead of UTC by a whole number of seconds that grows by one " &
    "at each leap second. Recordings stamped in GPS time are converted with this table."
  AddHelp* = "A leap second takes effect at 00:00:00 UTC on the first of a month, " &
    "after the last entry. +1 puts GPS one second further ahead of UTC; -1, one second less."

proc pathLine*(path: string): string =
  ## Where the table is saved, or that it is not.
  if path.len == 0: NotSaved else: path
