# config

This folder makes viewSEG **portable**: while it exists next to the program and can be
written to, viewSEG keeps everything it writes inside the program's own folder:

- here, in `config/`: settings, window layouts, presets and recently opened folders;
- `config/vendormaps/`: your own vendor header maps (see `vendormaps/README.md`);
- `logs/`: one log file per session;
- `cache/`: file indexes that make reopening large files fast (safe to delete).

Copy the whole folder to move viewSEG, with its settings, to another computer or a USB
drive.

If you delete this folder, or the program's folder is read-only (for example under
`Program Files`), viewSEG uses your per-user folders instead:

| | Linux | Windows | macOS |
|---|---|---|---|
| settings | `~/.config/viewSEG` | `%APPDATA%\viewSEG` | `~/Library/Application Support/viewSEG` |
| logs | `~/.local/state/viewSEG/logs` | `%LOCALAPPDATA%\viewSEG\logs` | `~/Library/Logs/viewSEG` |
| cache | `~/.cache/viewSEG` | `%LOCALAPPDATA%\viewSEG\cache` | `~/Library/Caches/viewSEG` |

`viewSEG --paths` prints the folders in use.
