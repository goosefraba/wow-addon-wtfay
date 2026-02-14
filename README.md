# WTFAY - Who The F* Are You?

A World of Warcraft addon for **TBC Classic / Anniversary Edition** (Interface 20505) that helps you track, rate, and remember every player you encounter.

Never forget who you grouped with — rate players, leave notes, and build your own personal player database.

## Features

- **Player Database** — Automatically stores name, class, race, level, realm, and source (raid/dungeon/group/manual)
- **Rating System** — Rate players from -3 (blacklist) to +5 (legend) with color-coded indicators
- **Notes** — Leave personal notes on any player to remember details
- **Encounter History** — Tracks every time you group with someone, including dungeon/raid zone names
- **Auto-Tracking** — Automatically adds party, dungeon, and raid members to your database
- **Search & Filters** — Filter by name, rating range, source type, and class
- **Sortable Columns** — Click column headers to sort by name, level, class, source, last seen, or rating
- **Color-Coded Rows** — Player rows are subtly tinted based on rating for quick visual scanning
- **Import / Export** — Share your database with friends via copy-paste text
- **Backup & Restore** — Automatic backup before import replacements, with `/wtfay restore` to undo
- **Database Stats** — Overview of total players, average rating, breakdowns by rating and source
- **Minimap Button** — Quick access icon on the minimap (draggable, toggleable)
- **Tooltip Integration** — See player ratings and notes when hovering over players in-game
- **Context Menu** — Right-click players in the list to whisper, invite, rate, edit notes, or remove
- **Blizzard Settings Integration** — Settings available in Interface > AddOns > WTFAY
- **Help Panel** — In-app guide with tips and macro recommendations

## Installation

1. Download the latest release zip file
2. Extract the `WTFAY` folder into your WoW AddOns directory:
   ```
   World of Warcraft/_anniversary_/Interface/AddOns/WTFAY/
   ```
3. Restart WoW or type `/reload` if already in-game
4. The addon will load with sample data so you can explore the UI right away

## Usage

### Slash Commands

| Command | Description |
|---|---|
| `/wtfay` | Toggle the main panel |
| `/wtfay target` | Add your current target |
| `/wtfay add Name` | Add a player manually |
| `/wtfay remove Name` | Remove a player |
| `/wtfay rate Name 3` | Rate a player (-3 to 5) |
| `/wtfay note Name text` | Set a note on a player |
| `/wtfay search term` | Search by name |
| `/wtfay export` | Export your database |
| `/wtfay import` | Import a database |
| `/wtfay restore` | Undo last Replace All |
| `/wtfay stats` | Show database statistics |
| `/wtfay settings` | Open settings |
| `/wtfay minimap` | Toggle minimap button |
| `/wtfay help` | Show help in chat |

### Recommended Macro

Create a macro for quick one-click adding of targeted players:

```
/run SlashCmdList["WTFAY"]("target")
```

Put this on your action bar — target a player and click to instantly add them with auto-detected class, race, and level.

### Rating Scale

| Rating | Meaning | Row Color |
|---|---|---|
| -3 | Blacklisted | Red |
| -2 to -1 | Negative | Orange |
| 0 | Neutral | Grey |
| 1 to 4 | Positive | Green |
| 5 | Legend | Gold |

## Sharing Your Database

1. Click **Export** to generate a text dump of your database
2. Copy the text (Ctrl+A, Ctrl+C) and send it to a friend
3. Your friend clicks **Import**, pastes the text, and chooses:
   - **Merge** — adds new players and updates existing ones (higher rating wins)
   - **Replace All** — wipes their database and imports yours (a backup is created automatically)
4. Use `/wtfay restore` to undo a Replace All if needed

## Settings

Access via the **Settings** button, `/wtfay settings`, or **Interface > AddOns > WTFAY**:

- **Debug Logging** — Show verbose debug messages (off by default)
- **Auto-Track Party Members** — Automatically track players you group with (on by default)
- **Minimap Button** — Show/hide the minimap icon

## Compatibility

- **Interface**: 20505 (TBC Classic / Anniversary Edition, Patch 2.5.5)
- **SavedVariables**: `WTFAYDB` (persists across sessions)

## Author

Developed by **goosefraba**

## License

Copyright (C) 2026 goosefraba (Bernhard Keprt)

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full license text.
