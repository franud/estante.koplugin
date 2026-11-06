# Estante

A home screen for [KOReader](https://github.com/koreader/koreader) that works like a reading desk. Built for a Kobo Clara HD (1072×1448, 300 dpi), and it should work on any e-ink device.

- **Now reading**: a large cover with progress, time left (from your reading statistics), pages read today, and your reading streak.
- **Shelves**: All · Reading · Unread · Finished, plus one shelf per folder in your books directory.
- **Cover wall**: paged rather than scrolled. Books without a cover get a typographic spine tile.
- **Dock**: Files, Search, Z-library, Wallabag, Web (when [Ventana](https://github.com/franud/ventana.koplugin) is installed) and Menu.
- **Sleep screen**: ASCII art (`estante/art/`, format described in `FORMAT.md`).

It opens on top of the file manager and comes back when you close a book. The reader itself is left alone.

## Install
Copy this folder to `koreader/plugins/estante.koplugin/` and restart KOReader. The coverbrowser and statistics plugins should be enabled.
