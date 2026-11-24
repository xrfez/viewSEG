# Leap seconds

SEG-D records a time as GPS time. viewSEG shows it as UTC. The difference is a whole number of seconds, the leap seconds, and it changes when a leap second is introduced.

**Tools > Leap seconds...** shows the table in use: each date a new offset starts, and GPS minus UTC from that date. The table shipped with viewSEG is complete through 30 June 2026. A time after the date the table was last checked through is still read, with the last offset, and the window says the table was not checked that far.

**Apply** adds a leap second. It takes effect at 00:00:00 UTC on the first of a month, after the last entry. **+1** puts GPS one second further ahead of UTC; **−1** puts it one second less. The date the table is known complete through does not change. **Set checked-to** sets that date, when it is a real date. **Remove last** drops a leap second added here, not one the program ships with. **Reload** reads the file again. **Reset** puts back the table shipped with the program.

The table is kept in `leapseconds.nif`, beside `settings.nif`, and written when you add, remove, set the checked date, reload or reset. With no settings folder, the change is kept for this run only and the window says it was not saved. A file that cannot be read is left as it is, and viewSEG says so. Open files are read again, so a time already on screen moves by the seconds you added.
