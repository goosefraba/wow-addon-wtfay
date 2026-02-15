# Changelog

## v0.4.2

### New Features
- **Multi-Source Tracking** — Players now show all sources they've been seen in (e.g. "Group, Dungeon") instead of only the most recent one
- **Source filter** matches any source a player has ever been seen in
- **Stats panel** counts players in all their source categories
- **Edit Note: Enter to Save** — Press Enter to save notes instead of clicking the button
- **Edit Note: Escape to Cancel** — Press Escape to close the note editor

### Bug Fixes
- Fixed duplicate dungeon encounters from wipes/corpse runs — same instance now only logs one encounter per player
- Fixed non-instanced encounters (group) logging duplicates within 30 minutes
- Fixed alert popup firing when group members leave (now only triggers on genuine new arrivals)
- Improved alert anti-spam: session-based tracking prevents re-alerting for temporarily unscannable players

## v0.4.1

### Bug Fixes
- Fixed known-player alert firing when members leave the party or raid (now only triggers when someone joins)
- Fixed export panel showing blank text — the pipe separator conflicted with WoW's escape characters (switched to tab-separated V2 format)

## v0.4.0

### New Features
- **Known Player Alerts** — Get notified in chat when known players join your group or raid
- **Alert Popup Panel** — Visual popup at the top of your screen showing known players with ratings and notes
- **Blacklist Warning** — Blacklisted players trigger a prominent red alert with urgent sound
- **Alert Sound** — Configurable sound notification with 7 sound choices (Quest Complete, Ready Check, Raid Warning, Map Ping, Auction Open, PvP Enter Queue, Loot Coin)
- **Sound Picker** — Dropdown selector with preview button in both Settings panels
- **Skip Guild Members** — Option to suppress alerts for guild members
- **Alert Popup Toggle** — Choose between chat-only alerts or chat + popup panel

### Bug Fixes
- Fixed alert popup re-triggering on level-ups and zone changes (only alerts when group composition actually changes)
- Fixed anti-spam fingerprint not clearing on group disband

## v0.3.0

### New Features
- **Database Stats** — Popup showing total players, average rating, rating/source breakdowns, total encounters
- **Backup & Restore** — Automatic backup before Replace All imports, with `/wtfay restore` to undo (keeps up to 3 backups)
- **Color-Coded Rows** — Player rows subtly tinted by rating (red, orange, grey, green, gold)
- **Minimap Button** — Draggable icon on the minimap for quick access (left-click opens panel, right-click opens settings)
- **Help Panel** — In-app scrollable guide with tips, commands, and macro recommendations
- **Import/Export** — Share your database with friends via copy-paste (merge or replace modes)
- **Version Display** — Version shown in settings, login message, and help panel
- **Blizzard Settings Integration** — Settings available in Interface > AddOns > WTFAY

### Initial Features (from earlier development)
- Player database with auto-tracking of party, dungeon, and raid members
- Rating system (-3 to +5) with color-coded indicators
- Personal notes on any player
- Encounter history with zone names
- Search and filter by name, rating, source, class
- Sortable columns (name, level, class, source, last seen, rating)
- Tooltip integration showing ratings and notes on hover
- Right-click context menu (whisper, invite, rate, edit notes, remove)
- Slash commands for all operations (`/wtfay help` for full list)
