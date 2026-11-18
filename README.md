# WTFAY - Who The F* Are You?

A World of Warcraft addon for **WoW Forever**, **TBC Anniversary**, and **Midnight / retail** that helps you track, rate, and remember every player you encounter.

Never forget who you grouped with — rate players, leave notes, and build your own personal player database.

## Features

- **Player Database** — Automatically stores name, class, race, level, realm, and source (raid/dungeon/group/manual)
- **Rating System** — Rate players from -3 (blacklist) to +5 (legend) with color-coded indicators
- **Notes** — Leave personal notes on any player to remember details
- **Linked Characters** — Mark characters as the same player: they share one rating, a blacklist carries across, and tooltips, lists and alerts show who you're really dealing with
- **Encounter History** — Tracks every time you group with someone, including dungeon/raid zone names, the role they played, and who else was in the group
- **Group History** — The Groups tab lists every group you've been in: when, how long, where you went, who was there, plus a note of your own
- **Rate Your Group** — A card when a group ends, to rate everyone in it in a few clicks (can be turned off)
- **Tags & Nicknames** — Tag players ("Good tank", "Run again", or up to 20 tags of your own) and give them a private nickname
- **Auto-Tracking** — Automatically adds party, dungeon, and raid members to your database (battlegrounds and arenas are skipped)
- **Search & Filters** — Filter by name, nickname, tag, rating range, source type, class, last seen (7 / 30 days), or your last group
- **Sortable Columns** — Click column headers to sort by name, level, class, source, last seen, or rating
- **Color-Coded Rows** — Player rows are subtly tinted based on rating for quick visual scanning
- **Import / Export** — Share your database with friends via copy-paste text, with a preview of what an import will change
- **Backup & Restore** — Automatic backup before import replacements, with `/wtfay restore` to undo
- **Database Stats** — Overview of total players, average rating, breakdowns by rating and source
- **Minimap Button** — Quick access icon on the minimap (draggable, toggleable)
- **Tooltip Integration** — See player ratings, roles, notes and tags when hovering over players in-game (notes, tags and nicknames can be hidden for streaming)
- **Context Menu** — Right-click players in the list to whisper, invite, rate, edit notes, tag, or remove
- **Unit Menu Entry** — Right-click a player anywhere in the game: the WTFAY entry shows the rating you gave them (and whose alt they are), or offers to rate someone new
- **Blizzard Settings Integration** — Settings available in Interface > AddOns > WTFAY
- **Embedded Settings** — Configure General, Alerts, and Display options in the main window
- **Native Window Style** — Use the game's window styling on modern clients, or switch to the dark style
- **Help Panel** — In-app guide with tips and macro recommendations

## Installation

1. Download the latest release zip file
2. Extract the `WTFAY` folder into your WoW AddOns directory:
   ```
   World of Warcraft/_forever_/Interface/AddOns/WTFAY/
   ```
   Use your client's folder instead, such as `_anniversary_` for TBC or `_retail_` for Midnight.
3. Restart WoW or type `/reload` if already in-game
4. The database starts empty: players are added as you group with them, or with `/wtfay target` and `/wtfay add Name`

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
| `/wtfay rate Foo Bar 3`, `/wtfay note Foo Bar text` | The same with a WoW Forever name, using the full name (a comma after it is optional) |
| `/wtfay link Alt, Main` | Mark two characters as the same player |
| `/wtfay unlink Name` | Take a character back out of its group |
| `/wtfay main Name` | Make this the group's main character |
| `/wtfay groups` | Open the Groups tab |
| `/wtfay recap` | Rate everyone from your last group |
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

### Linked Characters

The game can't tell you who plays which alts, so you say so yourself: right-click a player and choose **Link to Another Character...**, or use **Link...** in the detail panel, or `/wtfay link Alt, Main`.

Linked characters count as one player:

- **One rating.** Rating any of them rates them all. When you link, a blacklist always wins; otherwise the stronger opinion does.
- **Visible everywhere.** Lists, tooltips, group alerts and the detail panel show "alt of Felcaster" or "Also plays...", and each character's notes appear on the others.
- **One history.** The detail panel merges encounters from all of them, and searching for the main also finds the alts.
- **Reversible.** Each character keeps its own rating and notes underneath, so Unlink puts things back. If you re-rated the group while linked, the last character left keeps that rating.

Links are included in exports.

### Groups

Every time you group with people, WTFAY keeps one record of that group: when it started, how long it lasted, the zones and instances you went through, and everyone who was in it. Questing across several zones and then running a dungeon together is one group. A `/reload`, or regrouping with someone from it within 30 minutes, continues the same one.

- **Groups tab** — newest first. Left-click a group to rate its players; right-click to add a note, show its players in the Database tab, or forget it.
- **Last Group** — the pill next to My Group shows everyone from your latest group, including players still in your Inbox.
- **Encounter history** — hover a line in a player's history to see who else was there and the role they played.
- **Rate Your Group Afterwards** (Settings > General, on by default) — when a group ends, a card lists everyone in it with a row of rating buttons. It waits until you're out of combat, and says how to turn it off.

Battlegrounds and arenas are never recorded, so random PvP teams don't flood your Inbox.

### Tags & Nicknames

The rating window (the game's right-click menu, or any **Rate** button) does it all in one go: the rating, every tag as a button, and a note. Ratings and tags save as you click; the note saves when you press Enter or close the window. **More...** leads to the nickname and your own tags.

Right-click a player and choose **Tags & Nickname...** (or **Tags...** in the detail panel). Tick any of the built-in tags (Good tank, Good healer, Good DPS, Helpful, Quest buddy, Run again, Knows the fights, AFK, Ninja looter, Rude) or add up to 20 of your own; right-click one of your own to rename or delete it. Tags show in the list, the detail panel and tooltips, and the **All Tags** filter cycles through the ones in use. A nickname shows next to the player's name, and search finds it.

Tags, nicknames and notes are private. Turn off **Show Private Notes** (Settings > Display) to keep them off tooltips while streaming; the rating still shows.

## Sharing Your Database

1. Click **Export** to generate a text dump of your database
2. Copy the text (Ctrl+A, Ctrl+C) and send it to a friend
3. Your friend clicks **Import** and pastes the text. A preview underneath shows how many players are new, how many they already know (and how many of those are rated differently), and any lines that couldn't be read. Then they choose:
   - **Merge** — adds new players and updates existing ones (higher rating wins, notes are added, tags combine)
   - **Replace All** — click twice; wipes their database and imports yours (a backup is created automatically)
4. Use `/wtfay restore` to undo a Replace All if needed

Exports include notes, links, tags and nicknames. Group records stay on your own computer.

## Settings

Access via the **Settings** tab in the main window, `/wtfay settings`, or **Interface > AddOns > WTFAY**. Settings stay inside the main window, with scrollable General, Alerts, and Display sections. Changes apply immediately.

- **Debug Logging** — Show verbose debug messages (off by default)
- **Auto-Track Party Members** — Automatically track players you group with (on by default)
- **Rate Your Group Afterwards** — Show the rating card when a group ends (on by default)
- **Show Private Notes** — Include notes, tags and nicknames on player tooltips (on by default)
- **Minimap Button** — Show/hide the minimap icon

Typing a note and closing the editor any way other than **Cancel** (Escape, opening another popup) keeps what you typed as a draft; it comes back the next time you edit that player's note.

## Compatibility

- **WoW Forever**: Interface 16001 (`_forever_`)
- **TBC Anniversary**: Interface 20506 (`_anniversary_`)
- **Midnight / retail**: Interface 120100 (`_retail_`)
- **SavedVariables**: `WTFAYDB` (persists across sessions)

## Author

Developed by **goosefraba**

## License

Copyright (C) 2026 goosefraba (Bernhard Keprt)

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full license text.
