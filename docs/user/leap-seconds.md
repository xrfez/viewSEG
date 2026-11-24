# Leap seconds

SEG-D records a time as GPS time. viewSEG shows it as UTC. The difference is a whole number of seconds, the leap seconds, and it changes when a leap second is introduced.

**Tools > Leap seconds...** shows the table in use: each date a new offset starts, and GPS minus UTC from that date. Above the table, the date the table is known complete through. The table shipped with viewSEG is complete through 30 June 2026. A time after that date is still read, with the last offset.

**Apply** adds a leap second. It takes effect at 00:00:00 UTC on the first of a month, after the last entry. **+1** puts GPS one second further ahead of UTC; **−1** puts it one second less. When the new leap is later than the date the table is known complete through, that date becomes the new leap's date. **Remove last** drops a leap second added here, not one the program ships with. **Reload** reads the file again. **Reset** puts back the table shipped with the program. Changes are saved at once. Edit > Undo does not undo them: use Remove last or Reset.

The table is kept in `leapseconds.nif`, beside `settings.nif`, and written when you add, remove or reset, and when a reload is used. With no settings folder, or when the file cannot be saved, the change is kept for this run only and viewSEG says so. A file that cannot be read, or that is read and not used, is left as it is, and viewSEG says so; the shipped table is then in use. Open files are read again, so a time already on screen moves by the seconds you added.
