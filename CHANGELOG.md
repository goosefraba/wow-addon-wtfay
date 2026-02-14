# Changelog

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
