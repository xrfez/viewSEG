# Leap seconds

SEG-D records a time as GPS time. viewSEG shows it as UTC. The difference is a whole number of seconds, the leap seconds, and it changes when a leap second is introduced.

**Tools > Leap seconds...** opens the **Leap seconds** window. Under a short explanation and the
path of the file the table is saved in (or "Not saved: there is no settings folder."), it shows
the table in use, newest first, in two columns: **Date**, each date a new offset starts, and
**GPS minus UTC**, the offset from that date. Above the table, "Known complete through" gives the
date the table is known to be complete through. The table shipped with viewSEG is complete
through 30 June 2026. A time after that date is still read, with the last offset.

**Add a leap second** has **Year** (1972 to 2099) and **Month**, which start at 2027 and 1, and
a choice of **+1** or **-1**. A leap second takes effect at 00:00:00 UTC on the first of that
month, and it must come after the last entry. **+1** puts GPS one second further ahead of UTC;
**-1** puts it one second less. A line under the fields says that, or, in a warning colour, why
the leap cannot be added; **Apply** is dim while it cannot. When the new leap is later than the
date the table is known complete through, that date becomes the new leap's date.

**Remove last** drops a leap second added here, not one the program ships with, and is dim
otherwise. **Reload** reads the file again; it is dim when there is no settings folder.
**Reset** puts back the table shipped with the program. Changes are saved at once. Edit > Undo
does not undo them: use Remove last or Reset.

The table is kept in `leapseconds.nif`, beside `settings.nif`, and written when you add, remove or reset, and when a reload is used. With no settings folder, or when the file cannot be saved, the change is kept for this run only and viewSEG says so. A file that cannot be read, or that is read and not used, is left as it is, and viewSEG says so; the shipped table is then in use. Open files are read again, so a time already on screen moves by the seconds you added.
