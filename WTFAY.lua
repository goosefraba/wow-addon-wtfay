----------------------------------------------------------------------
-- WTFAY - Who The F* Are You?   v0.9.0
-- Database, slash commands, browse UI, rating, notes
--
-- Multi-flavor: TBC Anniversary (20506), WoW Forever (16001) and Midnight
-- (120100+). Everything client-specific lives in Compat.lua and is reached
-- through ns.C - do NOT branch on game flavor in this file.
----------------------------------------------------------------------
local ADDON_NAME, ns = ...
local C = ns.C
local T = C.T   -- text colour tokens; never write a raw |cFF literal

local ADDON_VERSION = "0.9.0"
local ACCENT     = "00CCFF"
local PREFIX     = "|cFF" .. ACCENT .. "[WTFAY]|r "
local DEBUG      = false  -- overridden by db.settings.debug after ADDON_LOADED

local function P(msg) print(PREFIX .. msg) end
local function D(msg) if DEBUG then print(T.grey .. "[WTFAY-DBG]|r " .. tostring(msg)) end end

D(">>> File loading started")

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function ColorRating(r)
    if r < 0 then
        local pct = (r + 3) / 3
        local g = math.floor(pct * 255)
        return string.format("|cFFFF%02X00%+d|r", g, r)
    else
        local pct = r / 5
        local red = math.floor((1 - pct) * 255)
        return string.format("|cFF%02XFF00%+d|r", red, r)
    end
end

-- Filterable classes for the class-filter pill (also the color fallback
-- source for that list). Actual coloring goes through the compat layer,
-- which prefers Blizzard's RAID_CLASS_COLORS on every flavor.
local CLASS_COLORS = {
    WARRIOR     = "C79C6E", PALADIN   = "F58CBA", HUNTER    = "ABD473",
    ROGUE       = "FFF569", PRIEST    = "FFFFFF", SHAMAN    = "0070DE",
    MAGE        = "69CCF0", WARLOCK   = "9482C9", DRUID     = "FF7D0A",
}

local function ClassColor(class)
    return "|cFF" .. C.ClassColorHex(class)
end

local function Timestamp()
    return date("%Y-%m-%d %H:%M")
end

----------------------------------------------------------------------
-- Name / realm identity
--
-- All of this is flavor-dependent and lives in Compat.lua:
--   * Classic keys a player "Name-Realm". Realms are normalized (spaces and
--     dashes stripped) and input is split on the FIRST dash, so
--     "Bob-Azjol-Nerub" becomes Bob / AzjolNerub rather than Bob-Azjol / Nerub.
--   * Forever has NO realm suffix. Characters have surnames, so the whole
--     "Firstname Surname" string is the identity - never split it on a dash
--     and never strip its spaces.
-- Always build keys with MakeKey so the rule stays in exactly one place.
----------------------------------------------------------------------
local TitleCase      = C.TitleCase
local NormalizeRealm = C.NormalizeRealm
local MakeKey        = C.MakeKey
local SplitNameRealm = C.SplitInput
local UnitKey        = C.UnitKey

local SOURCE_INFO = {
    raid    = { color = "FF6699", label = "Raid" },
    dungeon = { color = "66BBFF", label = "Dungeon" },
    group   = { color = "99FF66", label = "Group" },
    manual  = { color = "FFCC44", label = "Manual" },
}
local SOURCE_ORDER = { "raid", "dungeon", "group", "manual" }

-- Derive all unique sources from a player's encounter history
-- Returns: sourceSet (table of booleans), displayStr (colored comma-separated)
local function GetPlayerSources(p)
    local set = {}
    if p.encounters and #p.encounters > 0 then
        for _, e in ipairs(p.encounters) do
            local src = e.source or "manual"
            set[src] = true
        end
    end
    -- Fallback: if no encounters, use the stored source
    if not next(set) then
        set[p.source or "manual"] = true
    end
    -- Build colored display string in consistent order
    local parts = {}
    for _, src in ipairs(SOURCE_ORDER) do
        if set[src] then
            local info = SOURCE_INFO[src]
            parts[#parts + 1] = "|cFF" .. info.color .. info.label .. "|r"
        end
    end
    return set, table.concat(parts, ", ")
end

D("helpers OK")

----------------------------------------------------------------------
-- Database
----------------------------------------------------------------------
local db

----------------------------------------------------------------------
-- People: several characters, one player
--
-- Each character keeps its own record; a character that's been linked also
-- carries p.personId, pointing at db.people[id]:
--     { main = key, members = { key, ... }, rating = n, rated = bool }
--
-- A person owns the RATING, so a blacklist follows the player onto their alts.
-- Always read it with People.Rating(p) and write it with People.SetRating(p, v).
-- The character's own p.rating is left alone while linked, which is what lets
-- Unlink undo a mistaken link: the character simply gets its own rating back.
-- Notes, encounters, level and class stay on the character.
--
-- WoW has no API that reveals another player's alts, so links only ever come
-- from the user.
----------------------------------------------------------------------
local People = {}
do
    -- A blacklist always wins, so linking can never lose one (plain "larger
    -- absolute value" would let +5 beat -3). Otherwise the stronger opinion
    -- wins, and a tie goes to the lower rating.
    local function CombineRatings(a, b)
        a, b = a or 0, b or 0
        if a <= -3 or b <= -3 then return math.min(a, b) end
        local absA, absB = math.abs(a), math.abs(b)
        if absA ~= absB then return absA > absB and a or b end
        return math.min(a, b)
    end
    People.CombineRatings = CombineRatings

    function People.Of(p)
        local id = p and p.personId
        return id and db and db.people and db.people[id] or nil
    end

    function People.Rating(p)
        local person = People.Of(p)
        if person then return person.rating or 0 end
        return p and p.rating or 0
    end

    function People.SetRating(p, value)
        local person = People.Of(p)
        if person then
            person.rating = value
            person.rated = true   -- a deliberate opinion of the person; see Settle
        else
            p.rating = value
        end
    end

    function People.IsMain(p)
        local person = People.Of(p)
        return person ~= nil and db.players[person.main] == p
    end

    -- The other characters of this player, main first. Returns records and,
    -- in parallel, their keys.
    function People.Others(p)
        local records, keys = {}, {}
        local person = People.Of(p)
        if not person then return records, keys end
        local main = db.players[person.main]
        if main and main ~= p then
            records[1], keys[1] = main, person.main
        end
        for _, k in ipairs(person.members) do
            local m = db.players[k]
            if m and m ~= p and m ~= main then
                records[#records + 1], keys[#keys + 1] = m, k
            end
        end
        return records, keys
    end

    -- Short label for lists: "alt of Felcaster" or "+2 alts". Nil if unlinked.
    function People.Tag(p)
        local others = People.Others(p)
        if #others == 0 then return nil end
        if People.IsMain(p) then
            return "+" .. #others .. (#others == 1 and " alt" or " alts")
        end
        return "alt of " .. others[1].name
    end

    -- Full sentence for tooltips, with class-coloured names. Nil if unlinked.
    function People.Line(p)
        local others = People.Others(p)
        if #others == 0 then return nil end
        local MAX_NAMES = 4
        local names = {}
        for i = 1, math.min(#others, MAX_NAMES) do
            names[i] = ClassColor(others[i].class) .. others[i].name .. "|r"
        end
        local more = (#others > MAX_NAMES) and (" +" .. (#others - MAX_NAMES) .. " more") or ""
        if People.IsMain(p) then
            return "Also plays " .. table.concat(names, ", ") .. more
        end
        local line = "Alt of " .. table.remove(names, 1)
        if #names > 0 then line = line .. ", also " .. table.concat(names, ", ") end
        return line .. more
    end

    -- Notes on this player's other characters: { { name =, note = }, ... }
    function People.OtherNotes(p)
        local out = {}
        for _, m in ipairs((People.Others(p))) do
            if m.note and m.note ~= "" then
                out[#out + 1] = { name = m.name, note = m.note }
            end
        end
        return out
    end

    -- One note for one-line displays: their own, else one from another
    -- character. Returns the note and, if borrowed, whose it was.
    function People.BestNote(p)
        if p.note and p.note ~= "" then return p.note, nil end
        local first = People.OtherNotes(p)[1]
        if first then return first.note, first.name end
        return nil, nil
    end

    -- Person ids with a member whose name contains text (already lower-case),
    -- so searching for a main also finds their alts.
    function People.NameHits(text)
        local hits = {}
        for id, person in pairs(db and db.people or {}) do
            for _, k in ipairs(person.members) do
                local m = db.players[k]
                if m and m.name and m.name:lower():find(text, 1, true) then
                    hits[id] = true
                    break
                end
            end
        end
        return hits
    end

    -- Encounters oldest first. Linked: merged across the person's characters,
    -- plus an entry -> owning record map. Unlinked: their own list and nil.
    function People.Encounters(p)
        if not p then return {}, nil end
        local person = People.Of(p)
        if not person then return p.encounters or {}, nil end
        local merged, owners = {}, {}
        for _, k in ipairs(person.members) do
            local m = db.players[k]
            for _, e in ipairs(m and m.encounters or {}) do
                merged[#merged + 1] = e
                owners[e] = m
            end
        end
        table.sort(merged, function(a, b)
            local ta, tb = a.time or "", b.time or ""
            if ta ~= tb then return ta < tb end
            local sa, sb = a._ts or 0, b._ts or 0
            if sa ~= sb then return sa < sb end
            return (owners[a].name or "") < (owners[b].name or "")
        end)
        return merged, owners
    end

    -- How many characters beyond the first each player accounts for, i.e.
    -- character count minus this equals the number of people.
    function People.ExtraCharacters()
        local extra = 0
        for _, person in pairs(db and db.people or {}) do
            extra = extra + math.max(0, #person.members - 1)
        end
        return extra
    end

    -- Resolve typed input to a key: exact match first, then a name (or, on
    -- Forever, a first name) that only one tracked character has.
    function People.Find(input)
        if not input or not db then return nil end
        local name, realm = SplitNameRealm(input)
        if not name or name == "" then return nil end
        local key = MakeKey(name, realm)
        if db.players[key] then return key end
        local wanted, found = input:trim():lower(), nil
        for k, p in pairs(db.players) do
            local n = (p.name or ""):lower()
            if n == wanted or n:sub(1, #wanted + 1) == wanted .. " " then
                if found then return nil end   -- ambiguous
                found = k
            end
        end
        return found
    end

    -- Keep a person consistent after its members changed. One member left means
    -- there's no group any more. That member keeps its own rating, unless the
    -- person was deliberately rated while linked: then that opinion carries on.
    local function Settle(id, person)
        if #person.members >= 2 then
            local mainOK = false
            for _, k in ipairs(person.members) do
                if k == person.main then mainOK = true end
            end
            if not mainOK then person.main = person.members[1] end
            return
        end
        local last = person.members[1] and db.players[person.members[1]]
        if last then
            last.personId = nil
            if person.rated then last.rating = person.rating end
        end
        db.people[id] = nil
    end

    -- Link a character (and anyone already linked to it) to a target. The
    -- target's person survives, so its main stays; a new person's main is the
    -- target. Returns true, or false and a reason.
    function People.Link(key, targetKey)
        local a, b = db.players[key], db.players[targetKey]
        if not a or not b then return false, "not found" end
        if key == targetKey or a == b then return false, "same character" end
        if a.personId and a.personId == b.personId then return false, "already linked" end

        local targetId = b.personId
        local person = People.Of(b)
        if not person then
            db.peopleSeq = (db.peopleSeq or 0) + 1
            targetId = "p" .. db.peopleSeq
            person = { main = targetKey, members = { targetKey }, rating = b.rating or 0 }
            db.people[targetId] = person
            b.personId = targetId
        end

        local incoming = People.Of(a)
        local incomingRating = People.Rating(a)
        local incomingKeys = incoming and incoming.members or { key }
        for _, k in ipairs(incomingKeys) do
            db.players[k].personId = targetId
            person.members[#person.members + 1] = k
        end
        if incoming then
            person.rated = person.rated or incoming.rated
            for id, candidate in pairs(db.people) do
                if candidate == incoming then db.people[id] = nil; break end
            end
        end
        person.rating = CombineRatings(person.rating, incomingRating)

        -- Knowing who they are is a decision about them, like rating them is,
        -- so linked characters leave the Inbox.
        for _, k in ipairs(person.members) do
            db.players[k].pending = nil
        end
        return true
    end

    -- Remove a character from its person. Used for Unlink, and before a
    -- character is deleted. Its own rating, kept all along, applies again.
    function People.Unlink(key)
        local p = db and db.players[key]
        local id = p and p.personId
        local person = id and db.people and db.people[id]
        if p then p.personId = nil end
        if not person then return false end
        for i, k in ipairs(person.members) do
            if k == key then table.remove(person.members, i); break end
        end
        Settle(id, person)
        return true
    end

    function People.SetMain(key)
        local person = People.Of(db and db.players[key])
        if not person then return false end
        person.main = key
        return true
    end

    -- Make links and records agree after anything that rewrites db.players
    -- wholesale (load, reset, import, restore).
    function People.Reconcile()
        if not db then return end
        if not db.people then db.people = {} end
        for id, person in pairs(db.people) do
            local kept = {}
            for _, k in ipairs(person.members or {}) do
                local m = db.players[k]
                if m and m.personId == id then kept[#kept + 1] = k end
            end
            person.members = kept
            Settle(id, person)
        end
        local listed = {}
        for _, person in pairs(db.people) do
            for _, k in ipairs(person.members) do listed[k] = true end
        end
        for k, m in pairs(db.players) do
            if m.personId and not listed[k] then m.personId = nil end
        end
    end

    -- Deep copy of the links, for the Replace All backup.
    function People.Snapshot()
        local copy = {}
        for id, person in pairs(db and db.people or {}) do
            local members = {}
            for i, k in ipairs(person.members) do members[i] = k end
            copy[id] = { main = person.main, members = members, rating = person.rating, rated = person.rated }
        end
        return copy
    end

    -- Replaced by the UI once the list and detail panel exist.
    function People.Changed() end

    -- Link and tell the user, including the rating they now share.
    function People.LinkAndReport(key, targetKey)
        local ok, why = People.Link(key, targetKey)
        local a, b = db.players[key], db.players[targetKey]
        if not ok then
            if why == "already linked" then
                P(a.name .. " and " .. b.name .. " are already the same player.")
            elseif why == "same character" then
                P("A character can't be linked to itself.")
            end
            return false
        end
        P(ClassColor(a.class) .. a.name .. "|r is now linked to " .. ClassColor(b.class) .. b.name
          .. "|r (same player, rated " .. ColorRating(People.Rating(a)) .. ").")
        People.Changed()
        return true
    end

    function People.UnlinkAndReport(key)
        local p = db.players[key]
        if not People.Of(p) then
            P(p.name .. " isn't linked to anyone.")
            return false
        end
        People.Unlink(key)
        P(ClassColor(p.class) .. p.name .. "|r is no longer linked (rated " .. ColorRating(People.Rating(p)) .. ").")
        People.Changed()
        return true
    end
end

----------------------------------------------------------------------
-- Tags and nicknames
--
-- p.tags = { ["Run again"] = true, ... } and p.nick live on the character,
-- like notes, so Unlink leaves each character its own. Displays and the tag
-- filter use the whole player's: a linked character shows its alts' tags.
-- Tag names come from Tags.PRESETS plus db.customTags (up to MAX_CUSTOM).
-- Tags, nicknames and notes are private: the tooltip shows them only while
-- db.settings.tooltipNotes is on.
----------------------------------------------------------------------
local Tags = {}
do
    Tags.PRESETS = {
        "Good tank", "Good healer", "Good DPS", "Helpful", "Quest buddy",
        "Run again", "Knows the fights", "AFK", "Ninja looter", "Rude",
    }
    Tags.MAX_CUSTOM = 20
    Tags.MAX_LEN = 24

    function Tags.All()
        local out = {}
        for _, t in ipairs(Tags.PRESETS) do out[#out + 1] = t end
        for _, t in ipairs(db and db.customTags or {}) do out[#out + 1] = t end
        return out
    end

    function Tags.IsCustom(name)
        for _, t in ipairs(db and db.customTags or {}) do
            if t == name then return true end
        end
        return false
    end

    -- Existing tag with this name, ignoring case.
    local function Existing(name)
        local lower = name:lower()
        for _, t in ipairs(Tags.All()) do
            if t:lower() == lower then return t end
        end
        return nil
    end

    -- Sorted list and set of the player's tags, across linked characters.
    function Tags.Of(p)
        local set = {}
        for t in pairs(p and p.tags or {}) do set[t] = true end
        if p then
            for _, m in ipairs((People.Others(p))) do
                for t in pairs(m.tags or {}) do set[t] = true end
            end
        end
        local list = {}
        for t in pairs(set) do list[#list + 1] = t end
        table.sort(list)
        return list, set
    end

    -- "Run again, Good tank", or nil.
    function Tags.Text(p)
        local list = Tags.Of(p)
        if #list == 0 then return nil end
        return table.concat(list, ", ")
    end

    -- Set or clear one tag on this character. Tagging someone is a decision
    -- about them, like rating them, so they leave the Inbox.
    function Tags.Set(p, name, on)
        p.tags = p.tags or {}
        p.tags[name] = on and true or nil
        if not next(p.tags) then p.tags = nil end
        if on then p.pending = nil end
    end

    Tags.Find = Existing

    -- No pipes (WoW escapes), tabs (export separator) or commas (they
    -- separate tags in an export).
    local function Clean(name)
        name = (name or ""):gsub("[|\t\r\n,]", ""):trim()
        return name
    end

    -- Returns the new tag, or nil and a reason.
    function Tags.AddCustom(name)
        name = Clean(name)
        if name == "" then return nil, "empty" end
        if #name > Tags.MAX_LEN then return nil, "too long (" .. Tags.MAX_LEN .. " letters at most)" end
        if Existing(name) then return nil, "already exists" end
        db.customTags = db.customTags or {}
        if #db.customTags >= Tags.MAX_CUSTOM then return nil, "you already have " .. Tags.MAX_CUSTOM .. " custom tags" end
        db.customTags[#db.customTags + 1] = name
        return name
    end

    -- Rename a custom tag everywhere it's used. Returns true, or nil and a reason.
    function Tags.Rename(old, new)
        new = Clean(new)
        if not Tags.IsCustom(old) then return nil, "only your own tags can be renamed" end
        if new == "" then return nil, "empty" end
        if #new > Tags.MAX_LEN then return nil, "too long (" .. Tags.MAX_LEN .. " letters at most)" end
        local clash = Existing(new)
        if clash and clash ~= old then return nil, "already exists" end
        for i, t in ipairs(db.customTags) do
            if t == old then db.customTags[i] = new end
        end
        for _, p in pairs(db.players) do
            if p.tags and p.tags[old] then
                p.tags[old] = nil
                p.tags[new] = true
            end
        end
        return true
    end

    -- Delete a custom tag and take it off everyone. Returns how many lost it.
    function Tags.Remove(name)
        for i, t in ipairs(db.customTags or {}) do
            if t == name then table.remove(db.customTags, i); break end
        end
        local n = 0
        for _, p in pairs(db.players) do
            if p.tags and p.tags[name] then
                Tags.Set(p, name, false)
                n = n + 1
            end
        end
        return n
    end

    -- Their nickname: this character's, else one from a linked character.
    -- Returns the nickname and, if borrowed, whose it was.
    function Tags.Nick(p)
        if not p then return nil end
        if p.nick and p.nick ~= "" then return p.nick, nil end
        for _, m in ipairs((People.Others(p))) do
            if m.nick and m.nick ~= "" then return m.nick, m.name end
        end
        return nil
    end

    function Tags.SetNick(p, nick)
        nick = Clean(nick)
        p.nick = (nick ~= "") and nick:sub(1, 32) or nil
        if p.nick then p.pending = nil end
    end
end

----------------------------------------------------------------------
-- Groups ("outings"): one record per time you were grouped
--
-- db.outings[id] = { start, till, time, kind, zones = { ... },
--                    members = { key, ... }, note }
-- An outing spans everything you did with one group: questing across zones,
-- then the dungeon. Each encounter logged during it carries e.outing = id, so
-- a player's history can say who else was there. Battlegrounds and arenas are
-- never recorded (see ScanGroupMembers).
----------------------------------------------------------------------
local Outings = {}
do
    local KIND_RANK = { group = 1, dungeon = 2, raid = 3 }
    local MAX_OUTINGS = 300
    local RESUME_SECONDS = 1800   -- matches LogEncounter's 30 minutes

    Outings.currentId = nil   -- runtime only: the outing the current group belongs to

    function Outings.Get(id)
        return id and db and db.outings and db.outings[id] or nil
    end

    -- Ids, newest first.
    function Outings.Sorted()
        local ids = {}
        for id in pairs(db and db.outings or {}) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b)
            local sa, sb = db.outings[a].start or 0, db.outings[b].start or 0
            if sa ~= sb then return sa > sb end
            return a > b
        end)
        return ids
    end

    function Outings.Latest()
        return Outings.Sorted()[1]
    end

    local function Prune()
        local ids = Outings.Sorted()
        for i = MAX_OUTINGS + 1, #ids do db.outings[ids[i]] = nil end
    end

    -- Called by every group scan with the set of keys in the group. Continues
    -- the current outing; after a /reload, or regrouping within 30 minutes
    -- with someone from the last one, resumes that; otherwise starts a new one.
    -- Returns the outing id.
    function Outings.Touch(keys, source, zone)
        if not db then return nil end
        db.outings = db.outings or {}
        local now = time()
        local o = Outings.Get(Outings.currentId)
        if not o then
            local last = Outings.Get(db.lastOuting)
            local resume = false
            if last and last.till and (now - last.till) < RESUME_SECONDS then
                for _, k in ipairs(last.members) do
                    if keys[k] then resume = true; break end
                end
            end
            if resume then
                o, Outings.currentId = last, db.lastOuting
            else
                db.outingSeq = (db.outingSeq or 0) + 1
                local id = "g" .. db.outingSeq
                o = { start = now, till = now, time = Timestamp(), kind = "group", zones = {}, members = {} }
                db.outings[id] = o
                db.lastOuting, Outings.currentId = id, id
                Prune()
            end
        end
        o.till = now
        if (KIND_RANK[source] or 0) > (KIND_RANK[o.kind] or 0) then o.kind = source end
        if zone and zone ~= "" then
            local known = false
            for _, z in ipairs(o.zones) do
                if z == zone then known = true; break end
            end
            if not known then o.zones[#o.zones + 1] = zone end
        end
        local listed, fresh = {}, {}
        for _, k in ipairs(o.members) do listed[k] = true end
        for k in pairs(keys) do
            if not listed[k] then fresh[#fresh + 1] = k end
        end
        table.sort(fresh)
        for _, k in ipairs(fresh) do o.members[#o.members + 1] = k end
        return Outings.currentId
    end

    -- You left the group. Returns the outing that ended and its id, unless
    -- nobody was in it (then it's dropped).
    function Outings.Close()
        local id = Outings.currentId
        Outings.currentId = nil
        local o = Outings.Get(id)
        if not o then return nil end
        if #o.members == 0 then db.outings[id] = nil; return nil end
        return o, id
    end

    function Outings.Forget(id)
        if db and db.outings then db.outings[id] = nil end
        if db and db.lastOuting == id then db.lastOuting = nil end
        if Outings.currentId == id then Outings.currentId = nil end
    end

    -- "1h 12m", "25m", or "<1m".
    function Outings.FormatDuration(seconds)
        local mins = math.floor((seconds or 0) / 60)
        if mins < 1 then return "<1m" end
        if mins >= 60 then return string.format("%dh %02dm", math.floor(mins / 60), mins % 60) end
        return mins .. "m"
    end

    function Outings.Duration(o)
        return Outings.FormatDuration((o.till or o.start or 0) - (o.start or 0))
    end

    -- "Hillsbrad Foothills > City of Dalaran", at most `max` places.
    function Outings.Where(o, max)
        max = max or 3
        local zones = o.zones or {}
        if #zones == 0 then return "" end
        local shown = {}
        for i = 1, math.min(#zones, max) do shown[i] = zones[i] end
        local text = table.concat(shown, " > ")
        if #zones > max then text = text .. " +" .. (#zones - max) end
        return text
    end

    -- Records of the members still in the database, minus `exceptKey` and
    -- that player's linked characters. Returns records and keys in parallel.
    function Outings.Members(o, exceptKey)
        local records, keys = {}, {}
        local except = exceptKey and db.players[exceptKey]
        local exceptPerson = except and except.personId
        for _, k in ipairs(o and o.members or {}) do
            local m = db.players[k]
            if m and k ~= exceptKey and not (exceptPerson and m.personId == exceptPerson) then
                records[#records + 1], keys[#keys + 1] = m, k
            end
        end
        return records, keys
    end

    -- "with Bob, Ann +2", class-coloured, or "" when they were alone with you.
    function Outings.WithText(o, exceptKey, maxNames)
        local others = Outings.Members(o, exceptKey)
        if #others == 0 then return "" end
        maxNames = maxNames or 3
        local names = {}
        for i = 1, math.min(#others, maxNames) do
            names[i] = ClassColor(others[i].class) .. others[i].name .. "|r"
        end
        local more = (#others > maxNames) and (" +" .. (#others - maxNames)) or ""
        return table.concat(names, ", ") .. more
    end
end

-- How often the game reported each role for this player: "Tank x2, Healer",
-- across their linked characters, or nil when it never did.
local ROLE_LABELS = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
function People.RoleSummary(p)
    local counts = {}
    for _, e in ipairs((People.Encounters(p))) do
        if e.role and ROLE_LABELS[e.role] then counts[e.role] = (counts[e.role] or 0) + 1 end
    end
    local parts = {}
    for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
        local n = counts[role]
        if n then parts[#parts + 1] = ROLE_LABELS[role] .. (n > 1 and (" x" .. n) or "") end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Alert sound choices (name, soundID for normal, soundID for blacklisted)
local ALERT_SOUNDS = {
    { name = "Quest Complete",  normal = 1516,  blacklist = 8959 },
    { name = "Ready Check",     normal = 8960,  blacklist = 8959 },
    { name = "Raid Warning",    normal = 8959,  blacklist = 8959 },
    { name = "Map Ping",        normal = 3175,  blacklist = 8959 },
    { name = "Auction Open",    normal = 5274,  blacklist = 8959 },
    { name = "PvP Enter Queue", normal = 8458,  blacklist = 8959 },
    { name = "Loot Coin",       normal = 120,   blacklist = 8959 },
}

-- Default settings
local SETTINGS_DEFAULTS = {
    debug            = false,
    autoTrack        = true,
    knownAlerts      = true,   -- Master toggle for known player alerts
    alertOnJoin      = true,   -- Alert when a known player joins the group
    alertOnLeave     = true,   -- Alert when a known player leaves the group
    alertOnMeJoin    = true,   -- Alert when I join a group with known players
    alertPopup       = false,  -- Also show a popup panel (not just chat)
    alertSound       = true,   -- Play a sound when the alert popup appears
    alertSoundChoice = 1,      -- Index into ALERT_SOUNDS (default: Quest Complete)
    alertSkipGuild   = true,   -- Skip guild members from known player alerts
    tooltipEnabled   = true,   -- Show WTFAY info on player tooltips
    tooltipHint      = false,  -- Show "/wtfay target to track" on unknown players
    tooltipGuild     = true,   -- Show the guild name in the tooltip when known
    whoEnrich        = true,   -- Fill in missing class/level/guild via /who lookups
    unitMenu         = true,   -- Add a WTFAY entry to right-click unit menus
    tooltipNotes     = true,   -- Show notes, tags and nicknames on player tooltips
    groupRecap       = true,   -- After a group ends, show a card to rate who was in it
    skin             = "auto", -- "auto" (native on Mainline), "native" or "dark"
}

-- Play the user's chosen alert sound (isBlacklist = true for blacklisted warning)
local function PlayAlertSound(isBlacklist)
    if not db or not db.settings or not db.settings.alertSound then return end
    local idx = db.settings.alertSoundChoice or 1
    local choice = ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]
    if isBlacklist then
        PlaySound(choice.blacklist)
    else
        PlaySound(choice.normal)
    end
end

local function InitDB()
    if not WTFAYDB then WTFAYDB = {} end
    db = WTFAYDB
    if not db.players then db.players = {} end
    if not db.frame then db.frame = {} end
    if not db.people then db.people = {} end
    if not db.outings then db.outings = {} end

    -- Initialize settings with defaults (preserves existing values)
    if not db.settings then db.settings = {} end
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end

    -- Migration: rekey players stored before realm normalization existed, so
    -- "Bob-Azjol Nerub" / "Bob-Azjol-Nerub" both become "Bob-AzjolNerub".
    local DB_VERSION = 3
    local fromVersion = db.dbVersion or 1
    if fromVersion < 2 then
        local function Richness(x)
            return (((x.rating or 0) ~= 0) and 2 or 0) + (((x.note or "") ~= "") and 1 or 0)
        end
        local rekeyed, moved = {}, 0
        for oldKey, p in pairs(db.players) do
            -- Recover name/realm from the old key if the record is incomplete,
            -- and store back exactly what the new key is built from.
            local nm = p.name
            if not nm or nm == "" then nm = oldKey:match("^([^%-]+)") or oldKey end
            local rlm = NormalizeRealm(p.realm)
            if rlm == "" then rlm = NormalizeRealm(oldKey:match("^[^%-]+%-(.+)$")) end
            if rlm == "" then rlm = C.MyRealm() end
            -- Only invent a placeholder realm on flavors that have realms;
            -- on Forever the empty string is the correct value.
            if rlm == "" and C.UsesRealms then rlm = "Unknown" end
            p.name, p.realm = nm, rlm

            local newKey = MakeKey(nm, rlm)
            if newKey ~= oldKey then moved = moved + 1 end
            local existing = rekeyed[newKey]
            -- Two old keys can collapse onto one; keep the richer record.
            if existing and Richness(existing) >= Richness(p) then
                rekeyed[newKey] = existing
            else
                rekeyed[newKey] = p
            end
        end
        db.players = rekeyed
        if moved > 0 then D("DB migration: rekeyed " .. moved .. " player(s)") end
    end

    -- Migration: up to v0.8.1 every zone you crossed while grouped logged a
    -- new encounter, so one evening of questing together left a dozen lines.
    -- Collapse them the way LogEncounter now records them: a grouped entry
    -- within an hour of the previous one is the same outing, unless it's a
    -- different instance (a dungeon run keeps its own line). The hour is
    -- looser than the live 30 minutes because skipped scans left gaps.
    if fromVersion < 3 then
        local function Instanced(e)
            return e.instance or (e.instance == nil and e.zone ~= nil)
        end
        local function Grouped(e) return not e.remote and e.source ~= "manual" end
        local dropped = 0
        for _, p in pairs(db.players) do
            local enc = p.encounters
            if type(enc) == "table" and #enc > 1 then
                local kept, prev = {}, nil
                for _, e in ipairs(enc) do
                    local last = kept[#kept]
                    if last and prev and Grouped(e) and Grouped(last)
                       and e._ts and prev._ts and (e._ts - prev._ts) < 3600
                       and (not Instanced(e) or (Instanced(last) and last.zone == e.zone)) then
                        last.till = math.max(last.till or last._ts or 0, e._ts)
                        if last.lvl == nil then last.lvl = e.lvl end
                        dropped = dropped + 1
                    else
                        kept[#kept + 1] = e
                    end
                    prev = e
                end
                p.encounters = kept
            end
        end
        if dropped > 0 then
            P("Tidied encounter history: merged " .. dropped .. " duplicate entr"
              .. (dropped == 1 and "y" or "ies") .. " from zoning while grouped.")
        end
    end
    db.dbVersion = DB_VERSION

    People.Reconcile()
end

-- Log an encounter for a player (appends to encounters list)
-- zone is optional: e.g. "Karazhan", "Shattered Halls"
local LogEncounter
do
    -- Logged by auto-tracking while grouped (not a manual add or add-by-name).
    local function IsGroupEncounter(e)
        return not e.remote and e.source ~= "manual"
    end
    -- Where the player is right now: zone, subzone, and whether it's an instance.
    local function CurrentLocation()
        local inInstance = IsInInstance and IsInInstance()
        local zone
        if inInstance and GetInstanceInfo then zone = GetInstanceInfo() end
        if not zone or zone == "" then zone = GetRealZoneText and GetRealZoneText() or "" end
        local sub = GetSubZoneText and GetSubZoneText() or ""
        if sub == zone then sub = "" end
        return zone, sub, inInstance and true or false
    end

    -- A level, or nil when unknown: 0 / -1 ("??") or a Midnight-era secret value.
    local function SafeLevel(v)
        if v == nil or C.IsSecret(v) then return nil end
        v = tonumber(v)
        if not v or v <= 0 then return nil end
        return v
    end

    -- Log an encounter for a player (appended; displayed newest-first).
    --   zone       instance name the caller already knows (else read here)
    --   theirLevel their level right now, when there was a unit to read it from
    --   remote     true when they were added by name and weren't actually with
    --              you, so where you happened to be says nothing about them
    --   continuing true when they were already in the group at the last scan
    --   role       "TANK" / "HEALER" / "DAMAGER" as the game reported it, or nil
    LogEncounter = function(key, source, zone, theirLevel, remote, continuing, role)
        local p = db and db.players[key]
        if not p then return end
        if not p.encounters then p.encounters = {} end
        local enc = p.encounters

        local now = time()
        local effectiveSource = source or p.source or "manual"
        local grouped = not remote and effectiveSource ~= "manual"
        local where, sub, instanced = nil, nil, false
        if not remote then
            local z, sz, inst = CurrentLocation()
            where = (zone and zone ~= "") and zone or z
            sub, instanced = sz, inst
        end
        if where == "" then where = nil end
        if sub == "" then sub = nil end

        -- Dedup:
        --   Grouped (auto-tracking): one encounter per time you're together.
        --   While still grouped -- `continuing`, or seen within the last 30
        --   minutes (`till`, which covers reloads) -- wandering through zones
        --   just extends the last entry. Only entering a different instance
        --   starts a new one, so a dungeon run shows up as its own line.
        --   Manual / by-name: skip the same source within 30 minutes in the
        --   same zone, and the same instance (wipes, corpse runs, reloads).
        --   Entries from before locations were recorded only carried a zone when
        --   instanced, so on an old entry (no `instance` field) a zone still
        --   means "instance" -- which is why new entries always set the field.
        --   A different group (outing) is always a new entry, so "who else was
        --   there" stays true for every line.
        local outing = grouped and Outings.currentId or nil
        if #enc > 0 then
            local last = enc[#enc]
            local lastInstanced = last.instance or (last.instance == nil and last.zone ~= nil)
            local lastSeen = last.till or last._ts
            local sameOuting = not (last.outing and outing) or last.outing == outing
            if grouped and IsGroupEncounter(last) and sameOuting
               and (continuing or (lastSeen and (now - lastSeen) < 1800)) then
                if not instanced or (lastInstanced and last.zone == where) then
                    last.till = now
                    -- keep the level they had when you met; fill it in if unknown
                    if last.lvl == nil then last.lvl = SafeLevel(theirLevel) end
                    if outing and not last.outing then last.outing = outing end
                    if role then last.role = role end
                    return
                end
            elseif not grouped and last.source == effectiveSource then
                if instanced then
                    if lastInstanced and last.zone == where then return end
                elseif not lastInstanced and last._ts and (now - last._ts) < 1800
                       and (last.zone == nil or last.zone == where) then
                    return
                end
            end
        end

        enc[#enc + 1] = {
            time     = Timestamp(),
            source   = effectiveSource,
            _ts      = now,
            zone     = where,
            subzone  = sub,
            instance = instanced,
            remote   = remote and true or nil,
            lvl      = SafeLevel(theirLevel),
            myLvl    = SafeLevel(UnitLevel and UnitLevel("player")),
            outing   = outing,
            role     = role,
        }
    end
end

-- Where you first met someone, from the first encounter you were actually with
-- them (not an add-by-name): "Met in Elwynn Forest at level 12 (you 11)".
-- Plain text without colour codes, or nil when no encounter has a location.
local function MetLineFor(p)
    -- Across all of this player's characters, so it's the first time you met
    -- the person, whichever character they were on.
    local enc, owners = People.Encounters(p)
    for _, e in ipairs(enc) do
        if e.zone and not e.remote then
            local text = "Met in " .. e.zone
            local owner = owners and owners[e]
            if owner and owner ~= p then text = text .. " as " .. owner.name end
            if e.lvl then text = text .. " at level " .. e.lvl end
            if e.myLvl then
                text = text .. (e.lvl and (" (you " .. e.myLvl .. ")") or (" (you were " .. e.myLvl .. ")"))
            end
            return text
        end
    end
    return nil
end

D("database code OK")

----------------------------------------------------------------------
-- Sorted player list
----------------------------------------------------------------------
local sortedKeys = {}

-- Sort state: field = "name"|"rating"|"class"|"level"|"source"|"seen"
-- direction = "asc" | "desc"
local sortField     = "seen"
local sortDirection  = "desc"
local groupFilterActive = false
-- The newer filters share one table (file-scope locals are capped at 200):
--   tag    tag name, or nil for all
--   days   only players seen in the last N days, or nil
--   outing an outing id: only who was in that group, Inbox players included
local listFilters = { tag = nil, days = nil, outing = nil }

-- Forward declaration: defined with the list further down, but the filter
-- widgets above it already need to call it.
local RefreshList

-- Returns a set of name-realm keys for all current group/raid members
local function GetCurrentGroupKeys()
    local keys = {}
    if not IsInGroup() and not IsInRaid() then return keys end
    local myName = C.UnitIdentity("player") or ""

    local prefix, n
    if IsInRaid() then
        prefix = "raid"
        n = GetNumRaidMembers and GetNumRaidMembers() or GetNumGroupMembers() or 0
    else
        prefix = "party"
        n = GetNumPartyMembers and GetNumPartyMembers() or (GetNumGroupMembers and GetNumGroupMembers() or 0)
    end

    -- Must go through UnitKey so these match the normalized db.players keys.
    for i = 1, n do
        local key, name = UnitKey(prefix .. i)
        if key and name ~= myName then keys[key] = true end
    end
    return keys
end

local function RebuildSorted(filterText, ratingMin, ratingMax, sourceFilter, classFilter)
    wipe(sortedKeys)
    filterText = (filterText or ""):lower()
    local classLower = classFilter and classFilter:lower() or nil
    local groupKeys = groupFilterActive and GetCurrentGroupKeys() or nil
    -- Searching for a main also finds their alts.
    local personHits = (filterText ~= "") and People.NameHits(filterText) or nil
    -- One past group: its members, including any still in the Inbox, since
    -- reviewing who you just played with is the point.
    local outingKeys
    local outing = Outings.Get(listFilters.outing)
    if outing then
        outingKeys = {}
        for _, k in ipairs(outing.members) do outingKeys[k] = true end
    end
    -- "seen" is a sortable "YYYY-MM-DD HH:MM" string, so compare strings.
    local seenCutoff = listFilters.days and date("%Y-%m-%d %H:%M", time() - listFilters.days * 86400) or nil
    for key, p in pairs(db.players) do
        local match = true
        -- Skip pending (inbox) players, unless showing one group
        if p.pending and not outingKeys then match = false end
        if match and outingKeys and not outingKeys[key] then match = false end
        -- Group filter: only show current group/raid members
        if match and groupKeys and not groupKeys[key] then match = false end
        if match and seenCutoff and (p.seen or "") < seenCutoff then match = false end
        if match and listFilters.tag then
            local _, tagSet = Tags.Of(p)
            if not tagSet[listFilters.tag] then match = false end
        end
        -- Text search: name, nickname, alts' names, or a tag
        if match and filterText ~= "" and not p.name:lower():find(filterText, 1, true)
           and not (p.personId and personHits[p.personId]) then
            local nick = Tags.Nick(p)
            local tagText = Tags.Text(p)
            if not (nick and nick:lower():find(filterText, 1, true))
               and not (tagText and tagText:lower():find(filterText, 1, true)) then
                match = false
            end
        end
        -- Rating range filter
        local r = People.Rating(p)
        if ratingMin and r < ratingMin then match = false end
        if ratingMax and r > ratingMax then match = false end
        -- Source filter (checks all encounter sources, not just most recent)
        if sourceFilter then
            local srcSet = GetPlayerSources(p)
            if not srcSet[sourceFilter] then match = false end
        end
        -- Class filter
        if classLower and (p.class or ""):lower() ~= classLower then
            match = false
        end
        if match then sortedKeys[#sortedKeys + 1] = key end
    end

    local asc = (sortDirection == "asc")
    table.sort(sortedKeys, function(a, b)
        local pa, pb = db.players[a], db.players[b]
        if not pa or not pb then return a < b end

        local va, vb
        if sortField == "name" then
            va, vb = (pa.name or ""):lower(), (pb.name or ""):lower()
        elseif sortField == "rating" then
            va, vb = People.Rating(pa), People.Rating(pb)
        elseif sortField == "class" then
            va, vb = (pa.class or ""):lower(), (pb.class or ""):lower()
        elseif sortField == "level" then
            va, vb = pa.level or 0, pb.level or 0
        elseif sortField == "source" then
            va, vb = (pa.source or ""):lower(), (pb.source or ""):lower()
        elseif sortField == "seen" then
            va, vb = pa.seen or "", pb.seen or ""
        else
            va, vb = (pa.name or ""):lower(), (pb.name or ""):lower()
        end

        -- For equal values, tie-break on name ascending
        if va == vb then
            local na, nb = (pa.name or ""):lower(), (pb.name or ""):lower()
            return na < nb
        end

        if asc then return va < vb else return va > vb end
    end)
end

D("sorted list code OK")

----------------------------------------------------------------------
-- Main frame — no template, pure API
----------------------------------------------------------------------
-- MIN_W has to fit the fixed columns (360px) plus a readable Name column.
-- MAX_W was 800, which the resizable list comfortably outgrows.
local MIN_W, MIN_H = 640, 320
local MAX_W, MAX_H = 1200, 700

D("creating main frame...")
-- On Mainline this is a ButtonFrameTemplate, so the native skin can show the
-- client's own window chrome; the dark skin hides that art again.
local f = C.CreateWindow("WTFAYFrame", UIParent)
D("main frame created (template: " .. tostring(f.wtfayIsTemplate and true or false) .. ")")

f:SetSize(MIN_W, MIN_H)
f:SetPoint("CENTER")
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetFrameStrata("DIALOG")
f:SetClampedToScreen(true)

-- Backdrop via Mixin or direct method
if BackdropTemplateMixin then
    D("BackdropTemplateMixin exists, mixing in")
    Mixin(f, BackdropTemplateMixin)
    f:OnBackdropLoaded()
elseif f.SetBackdrop then
    D("SetBackdrop exists directly")
else
    D("WARNING: No backdrop support found!")
end

-- Chrome is applied by C.SkinWindow once the title and close button exist.
D("backdrop deferred to SkinWindow")

f:Hide()

-- Resizable
if f.SetResizable then
    D("SetResizable exists")
    f:SetResizable(true)
    if f.SetMinResize then
        f:SetMinResize(MIN_W, MIN_H)
        f:SetMaxResize(MAX_W, MAX_H)
    elseif f.SetResizeBounds then
        f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    end
else
    D("WARNING: SetResizable does not exist")
end

-- Drag to move
f:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if db and db.frame then
        db.frame.point    = point
        db.frame.relPoint = relPoint
        db.frame.x        = x
        db.frame.y        = y
    end
end)

D("main frame configured OK")

-- Resize handle
local sizer = CreateFrame("Frame", nil, f)
sizer:SetSize(16, 16)
sizer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
sizer:EnableMouse(true)
sizer:SetScript("OnMouseDown", function()
    f:StartSizing("BOTTOMRIGHT")
end)
sizer:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    if db and db.frame then
        db.frame.width  = f:GetWidth()
        db.frame.height = f:GetHeight()
    end
end)

local grip = sizer:CreateTexture(nil, "OVERLAY")
grip:SetSize(16, 16)
grip:SetPoint("CENTER")
grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
sizer:SetScript("OnEnter", function() grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight") end)
sizer:SetScript("OnLeave", function() grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up") end)

D("resize handle OK")

-- Title
local titleBar = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
titleBar:SetPoint("TOP", f, "TOP", 0, -14)
titleBar:SetText("|cFF" .. ACCENT .. "WTFAY|r - Who The F* Are You?")

-- Close button
local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
C.SkinWindow(f, { title = titleBar, close = closeBtn, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })

D("title + close OK")

----------------------------------------------------------------------
-- Pill button factory — flat dark button with an active state, used for
-- segmented toggles (main tabs, source filter, group filter). Active state
-- uses WTFAY's cyan accent so it matches the rest of the addon. Auto-sizes
-- to its label; callers may override with SetWidth() / FitLabel().
----------------------------------------------------------------------
local PILL_BG_INACTIVE  = { 0.14, 0.13, 0.11, 0.85 }  -- warm, sits on gold trim
local PILL_BG_ACTIVE    = { 0.10, 0.45, 0.62, 0.95 }  -- WTFAY cyan
local PILL_BG_HOVER     = { 0.22, 0.20, 0.15, 0.95 }
local PILL_TXT_INACTIVE = { 0.70, 0.66, 0.55 }
local PILL_TXT_ACTIVE   = { 0.85, 0.97, 1.00 }
local PILL_TXT_HOVER    = { 1.00, 0.82, 0.00 }  -- Blizzard UI gold on hover
-- 1px physical-pixel edges (C.Hairline) instead of the tooltip edgeFile, which
-- blurs at any UI scale but 1.0.
local PILL_EDGE = {
    inactive = { 0.42, 0.36, 0.24, 0.90 },  -- warm, matches the gold trim
    active   = { 0.30, 0.75, 0.95, 1.00 },  -- WTFAY cyan
    hover    = { 1.00, 0.82, 0.00, 0.90 },  -- Blizzard UI gold
}

local function MakePill(parent, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(20)
    b:EnableMouse(true)
    b:RegisterForClicks("LeftButtonUp")

    if BackdropTemplateMixin then
        Mixin(b, BackdropTemplateMixin)
        b:OnBackdropLoaded()
    end
    if b.SetBackdrop then
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        b:SetBackdropColor(unpack(PILL_BG_INACTIVE))
    end

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(label or "")
    fs:SetTextColor(unpack(PILL_TXT_INACTIVE))
    b.text = fs
    b:SetWidth(math.max(40, fs:GetStringWidth() + 20))

    function b:SetActive(active)
        self._active = active and true or false
        if not self.SetBackdropColor then return end
        if active then
            self:SetBackdropColor(unpack(PILL_BG_ACTIVE))
            self.text:SetTextColor(unpack(PILL_TXT_ACTIVE))
            C.Hairline(self, unpack(PILL_EDGE.active))
        else
            self:SetBackdropColor(unpack(PILL_BG_INACTIVE))
            self.text:SetTextColor(unpack(PILL_TXT_INACTIVE))
            C.Hairline(self, unpack(PILL_EDGE.inactive))
        end
    end
    function b:IsActive() return self._active end

    -- Resize to fit the current label (call after the text changes)
    function b:FitLabel(minW)
        self:SetWidth(math.max(minW or 40, self.text:GetStringWidth() + 20))
    end

    b:SetScript("OnEnter", function(self)
        if not self._active and self.SetBackdropColor then
            self:SetBackdropColor(unpack(PILL_BG_HOVER))
            self.text:SetTextColor(unpack(PILL_TXT_HOVER))
            C.Hairline(self, unpack(PILL_EDGE.hover))
        end
    end)
    b:SetScript("OnLeave", function(self)
        if not self._active and self.SetBackdropColor then
            self:SetBackdropColor(unpack(PILL_BG_INACTIVE))
            self.text:SetTextColor(unpack(PILL_TXT_INACTIVE))
            C.Hairline(self, unpack(PILL_EDGE.inactive))
        end
    end)

    b:SetActive(false)
    return b
end

D("pill factory OK")

----------------------------------------------------------------------
-- Main window tabs: Database / Inbox / Settings
----------------------------------------------------------------------
local mainTabButtons = {}
local nativeMainTabs   -- native bottom tabs (Mainline only); built after the pills
local NATIVE_TAB_INDEX = { Database = 1, Inbox = 2, Groups = 3, Settings = 4 }
local settingsPanel = { spec = {} }
local dbElements = {}  -- database-specific UI elements to show/hide
local inboxContent     -- forward declare
local RefreshInbox     -- forward declare

local function GetInboxCount()
    if not db or not db.players then return 0 end
    local n = 0
    for _, p in pairs(db.players) do
        if p.pending then n = n + 1 end
    end
    return n
end

local function UpdateInboxTabLabel()
    local btn = mainTabButtons["Inbox"]
    if btn then
        local count = GetInboxCount()
        if count > 0 then
            btn.text:SetText("Inbox (" .. T.warn .. count .. "|r)")
        else
            btn.text:SetText("Inbox")
        end
        btn:FitLabel(60)
        if nativeMainTabs and nativeMainTabs[2] then
            C.SetNativeTabText(nativeMainTabs[2], btn.text:GetText())
        end
    end
end

local activeMainTab = "Database"
local function ShowMainTab(name)
    if name == "Settings" and activeMainTab ~= "Settings" then
        settingsPanel.returnTab = activeMainTab
    end
    activeMainTab = name
    for tname, btn in pairs(mainTabButtons) do
        btn:SetActive(tname == name)
    end
    if nativeMainTabs then C.SelectNativeTab(f, NATIVE_TAB_INDEX[name]) end
    -- Show/hide database elements
    local showDb = (name == "Database")
    for _, el in ipairs(dbElements) do
        if showDb then el:Show() else el:Hide() end
    end
    -- Show/hide inbox
    if inboxContent then
        if name == "Inbox" then
            inboxContent:Show()
            if RefreshInbox then RefreshInbox() end
        else
            inboxContent:Hide()
        end
    end
    if Outings.tabFrame then
        Outings.tabFrame:SetShown(name == "Groups")
        if name == "Groups" and Outings.RefreshTab then Outings.RefreshTab() end
    end
    if settingsPanel.frame then settingsPanel.frame:SetShown(name == "Settings") end
    for _, btn in ipairs(settingsPanel.mainButtons or {}) do
        btn:SetShown(name ~= "Settings")
    end
end

do
    local MAIN_TAB_NAMES = { "Database", "Inbox", "Groups", "Settings" }
    local prev
    for _, tname in ipairs(MAIN_TAB_NAMES) do
        local btn = MakePill(f, tname)
        btn:FitLabel(70)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        else
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
        end
        btn:SetScript("OnClick", function() ShowMainTab(tname) end)
        mainTabButtons[tname] = btn
        prev = btn
    end

    -- Native bottom tabs, hanging off the frame like Character / Reputation.
    if C.Mainline then
        nativeMainTabs = C.CreateNativeTabs(f, MAIN_TAB_NAMES, function(i)
            ShowMainTab(MAIN_TAB_NAMES[i])
        end)
    end
end

D("main tabs OK")

----------------------------------------------------------------------
-- Search bar
----------------------------------------------------------------------
D("creating search box...")
local searchBox = CreateFrame("EditBox", "WTFAYSearchBox", f, C.SearchBoxTemplate)
D("search box created")
searchBox:SetSize(120, 22)
searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -56)
searchBox:SetAutoFocus(false)
searchBox:SetFontObject(ChatFontNormal)
searchBox:SetMaxLetters(40)

-- The native search box carries its own magnifier + placeholder, so the
-- external "Search:" label is redundant there.
local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -4, 0)
searchLabel:SetText(T.light .. "Search:|r")
if C.HasSearchBox then
    searchLabel:Hide()
    searchBox:SetSize(150, 22)
    if searchBox.Instructions then searchBox.Instructions:SetText("Search players") end
end

D("search bar OK")

----------------------------------------------------------------------
-- Rating filter button (cycles through presets)
----------------------------------------------------------------------
-- Each entry: { label, minRating (nil=any), maxRating (nil=any) }
local ratingFilterPresets = {
    { label = "All Ratings",        min = nil, max = nil },
    { label = "Negative (<0)",      min = -3,  max = -1 },
    { label = "Blacklist (-3)",     min = -3,  max = -3 },
    { label = "Neutral (0)",        min = 0,   max = 0  },
    { label = "Positive (1+)",      min = 1,   max = nil },
    { label = "Good (2+)",          min = 2,   max = nil },
    { label = "Great (3+)",         min = 3,   max = nil },
    { label = "Excellent (4+)",     min = 4,   max = nil },
    { label = "Legend (5)",         min = 5,   max = 5  },
}
local currentRatingFilterIdx = 1

local ratingFilterBtn = CreateFrame("Button", nil, f)
ratingFilterBtn:SetSize(105, 22)
ratingFilterBtn:SetPoint("LEFT", searchBox, "RIGHT", 4, 0)
ratingFilterBtn:SetNormalFontObject(GameFontNormalSmall)
ratingFilterBtn:SetHighlightFontObject(GameFontHighlightSmall)
ratingFilterBtn:SetText(T.gold .. ratingFilterPresets[1].label .. "|r")

local ratingFilterBg = ratingFilterBtn:CreateTexture(nil, "BACKGROUND")
ratingFilterBg:SetAllPoints()
if ratingFilterBg.SetColorTexture then
    ratingFilterBg:SetColorTexture(0.10, 0.10, 0.12, 0.85)
else
    ratingFilterBg:SetTexture(0.10, 0.10, 0.12, 0.85)
end

ratingFilterBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Rating Filter", 1, 0.82, 0)
    GameTooltip:AddLine("Left-click to cycle forward", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click to cycle back", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
ratingFilterBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

D("rating filter button OK")

----------------------------------------------------------------------
-- Source filter button (cycles through presets)
----------------------------------------------------------------------
local sourceFilterPresets = {
    { label = "All",         value = nil   },
    { label = "Raid",        value = "raid"    },
    { label = "Dungeon",     value = "dungeon" },
    { label = "Group",       value = "group"   },
    { label = "Manual",      value = "manual"  },
}
local currentSourceFilterIdx = 1

-- Source filter — segmented pill row (one pill per source), on the second
-- filter row. Click a pill to select; OnClick handlers are wired later, once
-- RefreshList exists. UpdateSourcePills() reflects the current selection.
local sourcePills = {}
local function UpdateSourcePills()
    for i, b in ipairs(sourcePills) do
        b:SetActive(i == currentSourceFilterIdx)
    end
end

do
    local prev
    for i, preset in ipairs(sourceFilterPresets) do
        local b = MakePill(f, preset.label)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -84)
        end
        sourcePills[i] = b
        prev = b
    end
    UpdateSourcePills()
end

D("source filter pills OK")

----------------------------------------------------------------------
-- Class filter button (cycles through classes)
----------------------------------------------------------------------
local classFilterPresets = {
    { label = "All Classes",  value = nil,       color = "AADDFF" },
    { label = "Warrior",      value = "Warrior",  color = CLASS_COLORS.WARRIOR  },
    { label = "Paladin",      value = "Paladin",  color = CLASS_COLORS.PALADIN  },
    { label = "Hunter",       value = "Hunter",   color = CLASS_COLORS.HUNTER   },
    { label = "Rogue",        value = "Rogue",    color = CLASS_COLORS.ROGUE    },
    { label = "Priest",       value = "Priest",   color = CLASS_COLORS.PRIEST   },
    { label = "Shaman",       value = "Shaman",   color = CLASS_COLORS.SHAMAN   },
    { label = "Mage",         value = "Mage",     color = CLASS_COLORS.MAGE     },
    { label = "Warlock",      value = "Warlock",  color = CLASS_COLORS.WARLOCK  },
    { label = "Druid",        value = "Druid",    color = CLASS_COLORS.DRUID    },
}
local currentClassFilterIdx = 1

local classFilterBtn = CreateFrame("Button", nil, f)
classFilterBtn:SetSize(80, 22)
classFilterBtn:SetPoint("LEFT", ratingFilterBtn, "RIGHT", 4, 0)
classFilterBtn:SetNormalFontObject(GameFontNormalSmall)
classFilterBtn:SetHighlightFontObject(GameFontHighlightSmall)
classFilterBtn:SetText("|cFF" .. classFilterPresets[1].color .. classFilterPresets[1].label .. "|r")

local classFilterBg = classFilterBtn:CreateTexture(nil, "BACKGROUND")
classFilterBg:SetAllPoints()
if classFilterBg.SetColorTexture then
    classFilterBg:SetColorTexture(0.10, 0.10, 0.12, 0.85)
else
    classFilterBg:SetTexture(0.10, 0.10, 0.12, 0.85)
end

classFilterBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Class Filter", 0.67, 0.87, 1)
    GameTooltip:AddLine("Left-click to cycle forward", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click to cycle back", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
classFilterBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

D("class filter button OK")

----------------------------------------------------------------------
-- Group filter — single toggle pill (right-aligned on the second filter row)
----------------------------------------------------------------------
local groupFilterPill = MakePill(f, "My Group")
groupFilterPill:FitLabel(70)
groupFilterPill:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -84)

-- HookScript so the pill's built-in hover styling still fires alongside the tooltip
groupFilterPill:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Group Filter", 0.67, 0.87, 1)
    GameTooltip:AddLine("Show only players in your current group/raid", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
groupFilterPill:HookScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------
-- Tag, recency and last-group filters (widgets live in listFilters too)
----------------------------------------------------------------------
do
    -- A cycling button like the rating / class filters. Left-click forward,
    -- right-click back; `options()` is re-read on each click.
    local function CycleButton(width, options, apply, tipTitle, tipText)
        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(width, 22)
        btn:SetNormalFontObject(GameFontNormalSmall)
        btn:SetHighlightFontObject(GameFontHighlightSmall)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if bg.SetColorTexture then bg:SetColorTexture(0.10, 0.10, 0.12, 0.85) else bg:SetTexture(0.10, 0.10, 0.12, 0.85) end
        btn.idx = 1
        function btn:Show1()
            local opts = options()
            if btn.idx > #opts then btn.idx = 1 end
            btn:SetText(opts[btn.idx].label)
            apply(opts[btn.idx].value)
        end
        btn:SetScript("OnClick", function(self, mouse)
            local opts = options()
            self.idx = self.idx + ((mouse == "RightButton") and -1 or 1)
            if self.idx < 1 then self.idx = #opts end
            if self.idx > #opts then self.idx = 1 end
            self:Show1()
            if RefreshList then RefreshList() end
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(tipTitle, 0.67, 0.87, 1)
            GameTooltip:AddLine(tipText, 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Left-click to cycle forward, right-click back", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return btn
    end

    -- Tags that someone actually has, so the cycle doesn't stop on empty ones.
    local function TagOptions()
        local opts = { { label = T.manual .. "All Tags|r", value = nil } }
        local used = {}
        for _, p in pairs(db and db.players or {}) do
            for t in pairs(p.tags or {}) do used[t] = true end
        end
        for _, t in ipairs(Tags.All()) do
            if used[t] then opts[#opts + 1] = { label = T.manual .. t .. "|r", value = t } end
        end
        return opts
    end
    listFilters.tagBtn = CycleButton(86, TagOptions, function(v) listFilters.tag = v end,
        "Tag Filter", "Show only players with one of your tags.")
    listFilters.tagBtn:SetPoint("LEFT", classFilterBtn, "RIGHT", 4, 0)
    listFilters.tagBtn:Show1()

    local DAY_OPTIONS = {
        { label = T.light .. "Any Time|r",     value = nil },
        { label = T.light .. "Last 7 Days|r",  value = 7 },
        { label = T.light .. "Last 30 Days|r", value = 30 },
    }
    listFilters.daysBtn = CycleButton(84, function() return DAY_OPTIONS end, function(v) listFilters.days = v end,
        "Last Seen", "Show only players you've seen recently.")
    listFilters.daysBtn:SetPoint("LEFT", sourcePills[#sourcePills], "RIGHT", 10, 0)
    listFilters.daysBtn:Show1()

    -- Everyone from your latest group (or one picked in the Groups tab).
    local pill = MakePill(f, "Last Group")
    pill:FitLabel(70)
    pill:SetPoint("RIGHT", groupFilterPill, "LEFT", -6, 0)
    pill:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Last Group", 0.67, 0.87, 1)
        GameTooltip:AddLine("Show everyone from your most recent group, Inbox players included. Pick an older group in the Groups tab.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    pill:HookScript("OnLeave", function() GameTooltip:Hide() end)
    listFilters.groupPill = pill

    -- Show one group's members (nil turns the filter off).
    function listFilters.ShowOuting(id)
        listFilters.outing = id
        local o = Outings.Get(id)
        if o and id ~= Outings.Latest() then
            pill.text:SetText("Group " .. ((o.time or ""):gsub("^%d+%-", ""):gsub(" .*$", "")))
        else
            pill.text:SetText("Last Group")
        end
        pill:FitLabel(70)
        pill:SetActive(o ~= nil)
        if RefreshList then RefreshList() end
    end
    pill:SetScript("OnClick", function()
        if listFilters.outing then
            listFilters.ShowOuting(nil)
        else
            local latest = Outings.Latest()
            if not latest then P("No groups recorded yet - they're saved as you group with people.") return end
            listFilters.ShowOuting(latest)
        end
    end)
end

D("group filter pill OK")

----------------------------------------------------------------------
-- Player count label
----------------------------------------------------------------------
local countLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
countLabel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -60)
countLabel:SetJustifyH("RIGHT")

D("count label OK")

----------------------------------------------------------------------
-- Column headers (clickable to sort)
----------------------------------------------------------------------
local HEADER_HEIGHT = 20
local headerBar = CreateFrame("Frame", nil, f)
headerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -108)
headerBar:SetPoint("RIGHT", f, "RIGHT", -30, 0)
headerBar:SetHeight(HEADER_HEIGHT)

-- Background for header
local headerBg = headerBar:CreateTexture(nil, "BACKGROUND")
headerBg:SetAllPoints()
if headerBg.SetColorTexture then
    headerBg:SetColorTexture(0.15, 0.15, 0.18, 0.9)
else
    headerBg:SetTexture(0.15, 0.15, 0.18, 0.9)
end

-- RefreshList is forward-declared next to the sort state (the header clicks
-- and filter widgets call it before it's defined).

----------------------------------------------------------------------
-- Column layout
--
-- Every column except Name is a fixed-width box anchored from the RIGHT,
-- so widening the window grows Name instead of leaving a dead gap before
-- Rating. Headers and rows both derive their geometry from these tables,
-- which is what stops them drifting apart (the old fixed left offsets had
-- "Lv" and "Class" pointing at nothing, and only 70px between Source and
-- Last Seen, so multi-source values collided with the date).
----------------------------------------------------------------------
local COL_GAP   = 8
-- Total fixed width is 360px (incl. gaps); MIN_W below is chosen so the
-- flexible Name column still gets ~226px at the smallest window size.
local COL_W     = { rating = 50, seen = 72, source = 84, class = 88, level = 26 }
local COL_ORDER = { "rating", "seen", "source", "class", "level" }
local COL_RIGHT = {}
do
    local x = -8
    for _, k in ipairs(COL_ORDER) do
        COL_RIGHT[k] = x
        x = x - COL_W[k] - COL_GAP
    end
    COL_RIGHT.nameRight = x                                   -- Name stops here
    COL_RIGHT.noteRight = COL_RIGHT.rating - COL_W.rating - COL_GAP
end

-- Anchor a font string into a right-hand column on the given line.
local function AnchorCol(fs, parent, field, y)
    fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", COL_RIGHT[field], y)
    fs:SetWidth(COL_W[field])
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
end

-- Header column definitions: { field, label, point }
local HEADER_COLS = {
    { field = "name",   label = "Name",    point = "LEFT"  },
    { field = "level",  label = "Lv",      point = "LEFT"  },
    { field = "class",  label = "Class",   point = "LEFT"  },
    { field = "source", label = "Source",  point = "LEFT"  },
    { field = "seen",   label = "Last Seen", point = "LEFT" },
    { field = "rating", label = "Rating",  point = "RIGHT" },
}

local headerButtons = {}

local function UpdateHeaderArrows()
    for _, hb in ipairs(headerButtons) do
        if hb.field == sortField then
            local arrow = (sortDirection == "asc") and " " .. T.accent .. "^|r" or " " .. T.accent .. "v|r"
            hb.label:SetText(T.gold .. hb.labelText .. arrow .. "|r")
        else
            hb.label:SetText(T.grey .. hb.labelText .. "|r")
        end
    end
end

for i, col in ipairs(HEADER_COLS) do
    local btn = CreateFrame("Button", nil, headerBar)
    btn:SetHeight(HEADER_HEIGHT)

    if col.field == "name" then
        -- Flexible column: absorbs the extra width when the window grows.
        btn:SetPoint("LEFT", headerBar, "LEFT", 8, 0)
        btn:SetPoint("RIGHT", headerBar, "RIGHT", COL_RIGHT.nameRight, 0)
    else
        btn:SetPoint("RIGHT", headerBar, "RIGHT", COL_RIGHT[col.field], 0)
        btn:SetWidth(COL_W[col.field])
    end

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if col.point == "RIGHT" then
        lbl:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        lbl:SetJustifyH("RIGHT")
    else
        lbl:SetPoint("LEFT", btn, "LEFT", 0, 0)
        lbl:SetJustifyH("LEFT")
    end

    -- Hover highlight
    btn:SetScript("OnEnter", function(self)
        if self.field ~= sortField then
            self.label:SetText(T.light .. self.labelText .. "|r")
        end
    end)
    btn:SetScript("OnLeave", function(self)
        UpdateHeaderArrows()
    end)

    btn:SetScript("OnClick", function(self)
        if sortField == self.field then
            sortDirection = (sortDirection == "asc") and "desc" or "asc"
        else
            sortField = self.field
            -- Default direction: name/class/source asc, rating/level/seen desc
            if self.field == "rating" or self.field == "level" or self.field == "seen" then
                sortDirection = "desc"
            else
                sortDirection = "asc"
            end
        end
        -- Persist sort prefs
        if db then
            db.sortField = sortField
            db.sortDirection = sortDirection
        end
        UpdateHeaderArrows()
        if RefreshList then RefreshList() end
    end)

    btn.field = col.field
    btn.labelText = col.label
    btn.label = lbl
    headerButtons[#headerButtons + 1] = btn
end

UpdateHeaderArrows()

D("column headers OK")

----------------------------------------------------------------------
-- Scroll frame
----------------------------------------------------------------------
local ROW_HEIGHT = 44
local scrollParent = CreateFrame("Frame", nil, f)
scrollParent:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, -2)
scrollParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 42)
scrollParent:EnableMouse(false)

D("creating scroll frame...")
local scrollFrame = CreateFrame("ScrollFrame", "WTFAYScrollFrame", f, "FauxScrollFrameTemplate")
D("scroll frame created")
scrollFrame:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, 0)
scrollFrame:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", 0, 0)
scrollFrame:EnableMouse(false)

local content = CreateFrame("Frame", nil, f)
content:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, 0)
content:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", 0, 0)
content:EnableMouse(false)

-- Recessed frame behind the list so it reads as a native WoW list area.
-- Deliberately kept at the parent frame level so rows draw on top of it.
local listInset = C.CreateInset(f)
listInset:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", -4, 4)
listInset:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", 4, -4)
listInset:EnableMouse(false)
if listInset.SetFrameLevel then listInset:SetFrameLevel(f:GetFrameLevel()) end

D("scroll frame OK")

----------------------------------------------------------------------
-- Row pool
----------------------------------------------------------------------
local rows = {}
-- Forward declaration so CreateRow closures can see it
local ShowDetailPanel

----------------------------------------------------------------------
-- Row widgets
--
-- Shared by both scroll backends, so position/anchoring is deliberately
-- NOT set here: the FauxScrollFrame path anchors rows absolutely, while
-- ScrollBox positions and recycles them itself. Everything below must be
-- safe to run once per pooled frame.
----------------------------------------------------------------------
local function BuildRowWidgets(row)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    if BackdropTemplateMixin and not row.SetBackdrop then
        Mixin(row, BackdropTemplateMixin)
        if row.OnBackdropLoaded then row:OnBackdropLoaded() end
    end

    if row.SetBackdrop then
        row:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            insets = { left = 0, right = 0, top = 0, bottom = 1 },
        })
        row:SetBackdropColor(unpack(C.Theme.rowA))
    end

    -- Base color for restoring after hover; overwritten per row on populate.
    row.baseR, row.baseG, row.baseB, row.baseA = unpack(C.Theme.rowA)

    row:SetScript("OnEnter", function(self)
        if self.SetBackdropColor then
            self:SetBackdropColor(
                math.min(self.baseR + 0.12, 1),
                math.min(self.baseG + 0.15, 1),
                math.min(self.baseB + 0.20, 1),
                0.9
            )
        end
    end)
    row:SetScript("OnLeave", function(self)
        if self.SetBackdropColor then
            self:SetBackdropColor(self.baseR, self.baseG, self.baseB, self.baseA)
        end
    end)

    -- Line 1: one cell per header column.
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -5)
    row.nameText:SetPoint("TOPRIGHT", row, "TOPRIGHT", COL_RIGHT.nameRight, -5)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AnchorCol(row.levelText, row, "level", -6)

    row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AnchorCol(row.classText, row, "class", -6)

    row.sourceText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AnchorCol(row.sourceText, row, "source", -6)

    row.seenText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AnchorCol(row.seenText, row, "seen", -6)

    -- Rating spans both lines, right-aligned.
    row.ratingText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.ratingText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.ratingText:SetJustifyH("RIGHT")

    -- Line 2: the note, spanning everything left of the rating column.
    row.noteText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.noteText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -25)
    row.noteText:SetPoint("TOPRIGHT", row, "TOPRIGHT", COL_RIGHT.noteRight, -25)
    row.noteText:SetJustifyH("LEFT")
    row.noteText:SetWordWrap(false)

    row.playerKey = nil

    -- Left-click = detail, Right-click = context menu
    row:SetScript("OnClick", function(self, button)
        D("row clicked: " .. tostring(self.playerKey) .. " button=" .. tostring(button))
        if button == "RightButton" then
            RowMenu(self)
        elseif button == "LeftButton" then
            ShowDetailPanel(self.playerKey)
        end
    end)

    row.wtfayBuilt = true
end

-- Fill a row from a player key. dataIdx drives the even/odd striping.
local function PopulateRow(row, key, dataIdx)
    local p = key and db and db.players and db.players[key]
    if not p then
        row.playerKey = nil
        row:Hide()
        return
    end

    local cc = ClassColor(p.class)
    local personTag = People.Tag(p)
    local nick = Tags.Nick(p)
    row.nameText:SetText(cc .. p.name .. "|r"
        .. (nick and ("  " .. T.soft .. "\"" .. nick .. "\"|r") or "")
        .. (personTag and ("  " .. T.dim .. "(" .. personTag .. ")|r") or "")
        .. (p.pending and ("  " .. T.warn .. "(Inbox)|r") or ""))
    row.levelText:SetText(T.soft .. (p.level or "?") .. "|r")
    local raceStr = (p.race and p.race ~= "") and (T.grey .. p.race .. "|r ") or ""
    row.classText:SetText(raceStr .. cc .. (p.class or "") .. "|r")
    row.ratingText:SetText(C.RatingIcon(People.Rating(p)) .. ColorRating(People.Rating(p)))

    -- Line 2: tags first (short and scannable), then the note.
    local bestNote, noteOwner = People.BestNote(p)
    local tagText = Tags.Text(p)
    local tagStr = tagText and (T.manual .. "[" .. tagText:gsub(", ", "] [") .. "]|r  ") or ""
    if bestNote then
        row.noteText:SetText(tagStr .. (noteOwner and (T.dim .. noteOwner .. ": |r") or "") .. T.text .. bestNote .. "|r")
    elseif tagStr ~= "" then
        row.noteText:SetText(tagStr)
    else
        row.noteText:SetText(T.faint .. "(no note)|r")
    end

    local _, srcDisplay = GetPlayerSources(p)
    row.sourceText:SetText(srcDisplay)
    -- Year dropped in the list to keep the column narrow; the detail
    -- panel and encounter history still show the full timestamp.
    row.seenText:SetText(T.faint .. ((p.seen or ""):gsub("^%d+%-", "")) .. "|r")

    row.playerKey = key

    -- Subtle row tint based on rating
    local r = People.Rating(p)
    local baseEven = ((dataIdx or 1) % 2 == 0)
    local br, bg, bb, ba
    if r <= -3 then
        -- Blacklist: dark red tint
        br, bg, bb, ba = baseEven and 0.22 or 0.18, 0.04, 0.04, 0.85
    elseif r < 0 then
        -- Negative: subtle warm/orange tint
        br, bg, bb, ba = baseEven and 0.18 or 0.14, 0.08, 0.04, 0.82
    elseif r == 0 then
        -- Neutral: default grey
        br, bg, bb, ba = baseEven and 0.12 or 0.08, baseEven and 0.12 or 0.08, baseEven and 0.15 or 0.10, 0.8
    elseif r >= 5 then
        -- Legend: subtle gold tint
        br, bg, bb, ba = baseEven and 0.18 or 0.14, baseEven and 0.16 or 0.12, 0.04, 0.82
    else
        -- Positive: subtle green tint
        br, bg, bb, ba = 0.04, baseEven and 0.16 or 0.12, 0.06, 0.82
    end
    row.baseR, row.baseG, row.baseB, row.baseA = br, bg, bb, ba
    if row.SetBackdropColor then
        row:SetBackdropColor(br, bg, bb, ba)
    end

    row:Show()
end

-- FauxScrollFrame path: rows are pooled by index and anchored absolutely.
local function CreateRow(index)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    BuildRowWidgets(row)
    row:SetFrameLevel(content:GetFrameLevel() + 5)
    rows[index] = row
    return row
end

D("row pool code OK")

----------------------------------------------------------------------
-- ScrollBox list (Mainline only)
--
-- Modern clients get a real WowScrollBoxList + MinimalScrollBar: native
-- scrollbar art, built-in wheel handling and frame recycling. TBC has none
-- of that, so it stays on the FauxScrollFrame path above.
--
-- The whole setup is pcall'd. If any part of the API differs from what we
-- expect we keep Faux rather than shipping a silently empty list — that
-- failure mode is the whole reason this migration waited for a live client.
----------------------------------------------------------------------
local USE_SCROLLBOX = false
local scrollBox, scrollBar

if C.Mainline and ScrollUtil and CreateScrollBoxListLinearView and CreateDataProvider
   and C.HasTemplate("WowScrollBoxList") and C.HasTemplate("MinimalScrollBar") then
    local ok, err = pcall(function()
        scrollBox = CreateFrame("Frame", nil, f, "WowScrollBoxList")
        scrollBox:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, 0)
        scrollBox:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", -16, 0)

        scrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
        scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
        scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

        local view = CreateScrollBoxListLinearView()
        view:SetElementExtent(ROW_HEIGHT)
        view:SetElementInitializer("Button", function(row, elementData)
            if not row.wtfayBuilt then BuildRowWidgets(row) end
            PopulateRow(row, elementData.key, elementData.idx)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    end)

    if ok then
        USE_SCROLLBOX = true
        -- Hide the Faux widgets. The template's scrollbar is a NAMED child and
        -- has been seen surviving a parent Hide(), so kill it explicitly too --
        -- otherwise it sits alongside the MinimalScrollBar as a second bar.
        scrollFrame:Hide()
        content:Hide()
        local fauxName = scrollFrame:GetName()
        if fauxName then
            for _, suffix in ipairs({ "ScrollBar", "ScrollBarScrollUpButton",
                                      "ScrollBarScrollDownButton", "ScrollChildFrame" }) do
                local child = _G[fauxName .. suffix]
                if child and child.Hide then child:Hide() end
            end
        end
        D("ScrollBox list active")
    else
        D("ScrollBox init failed, falling back to FauxScrollFrame: " .. tostring(err))
        if scrollBox then scrollBox:Hide() end
        if scrollBar then scrollBar:Hide() end
        scrollBox, scrollBar = nil, nil
    end
end

----------------------------------------------------------------------
-- Right-click context menu (forward declared for CreateRow)
----------------------------------------------------------------------
-- Shared variable for popup data passing (must be declared before RowMenu)
local popupActiveKey = nil
-- Forward declarations (defined later in the file)
-- NOTE: ShowDetailPanel is declared earlier (before CreateRow)
local ShowRatingPicker
local AddTargetPlayer

D("setting up context menu...")
D("flavor: " .. C.flavorName .. " (interface " .. tostring(C.uiVersion) .. ")")

function RowMenu(self)
    local key = self.playerKey
    D("RowMenu called for key=" .. tostring(key))
    if not key or not db or not db.players[key] then
        D("RowMenu: early return - key/db/player missing")
        return
    end
    local p = db.players[key]

    -- Whisper target: realm-qualify only for cross-realm, and only on flavors
    -- that have realms at all (Forever names carry no realm suffix).
    -- Compare against the NORMALIZED realm - GetRealmName() returns the display
    -- form ("Azjol-Nerub") and would never match the stored "AzjolNerub".
    local whisperTarget = p.name
    if C.UsesRealms and p.realm and p.realm ~= "" and p.realm ~= C.MyRealm() then
        whisperTarget = p.name .. "-" .. p.realm
    end

    local menuTag = People.Tag(p)
    local entries = {
        { text = ClassColor(p.class) .. p.name .. "|r" .. (menuTag and ("  " .. T.dim .. "(" .. menuTag .. ")|r") or ""), isTitle = true },
        { text = "Whisper", func = function()
            ChatFrame_OpenChat("/w " .. whisperTarget .. " ")
        end },
        { text = "Invite", func = function()
            C.InviteByName(whisperTarget)
            P("Invited " .. ClassColor(p.class) .. p.name .. "|r")
        end },
        { text = "Set Rating", func = function()
            ShowRatingPicker(key)
        end },
        { text = "Edit Note", func = function()
            popupActiveKey = key
            StaticPopup_Show("WTFAY_EDIT_NOTE", p.name)
        end },
        { text = "Tags & Nickname...", func = function()
            if Tags.ShowPicker then Tags.ShowPicker(key) end
        end },
        { text = T.off .. "Remove|r", func = function()
            popupActiveKey = key
            StaticPopup_Show("WTFAY_CONFIRM_REMOVE", p.name)
        end },
        { text = "Cancel" },
    }

    -- Just above Remove (position 7 of the list above).
    local at = 7
    table.insert(entries, at, { text = "Link to Another Character...", func = function()
        People.ShowPicker(key)
    end })
    if People.Of(p) then
        at = at + 1
        if not People.IsMain(p) then
            table.insert(entries, at, { text = "Make Main Character", func = function()
                People.SetMain(key)
                P(ClassColor(p.class) .. p.name .. "|r is now the main character.")
                People.Changed()
            end })
            at = at + 1
        end
        table.insert(entries, at, { text = "Unlink", func = function()
            People.UnlinkAndReport(key)
        end })
    end

    local shown = C.ShowContextMenu(self, entries)

    if not shown then
        D("RowMenu: no menu system available, falling back to rating picker")
        ShowRatingPicker(key)
    end
end

D("context menu OK")

----------------------------------------------------------------------
-- Refresh list
----------------------------------------------------------------------
RefreshList = function()
    if not db then D("RefreshList: db is nil!"); return end

    local filterText = searchBox:GetText() or ""
    local rf = ratingFilterPresets[currentRatingFilterIdx]
    local sf = sourceFilterPresets[currentSourceFilterIdx]
    local cf = classFilterPresets[currentClassFilterIdx]
    RebuildSorted(filterText, rf.min, rf.max, sf.value, cf.value)

    local total = #sortedKeys
    countLabel:SetText(T.muted .. total .. " player" .. (total == 1 and "" or "s") .. "|r")

    local parentH = scrollParent:GetHeight()
    local parentW = scrollParent:GetWidth()
    if parentH < 1 then parentH = MIN_H - 110 end
    local visibleRows = math.floor(parentH / ROW_HEIGHT)
    if visibleRows < 1 then visibleRows = 1 end

    D("RefreshList: total=" .. total .. " parentH=" .. string.format("%.0f", parentH)
      .. " parentW=" .. string.format("%.0f", parentW)
      .. " visibleRows=" .. visibleRows
      .. " contentW=" .. string.format("%.0f", content:GetWidth()))

    -- ScrollBox owns layout, recycling and scrolling; we just hand it data.
    if USE_SCROLLBOX and scrollBox then
        local list = {}
        for i = 1, total do
            list[i] = { key = sortedKeys[i], idx = i }
        end
        scrollBox:SetDataProvider(CreateDataProvider(list))
        UpdateInboxTabLabel()
        return
    end

    FauxScrollFrame_Update(scrollFrame, total, visibleRows, ROW_HEIGHT)

    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    for i = 1, visibleRows do
        local row = rows[i] or CreateRow(i)
        local dataIdx = offset + i
        if dataIdx <= total then
            PopulateRow(row, sortedKeys[dataIdx], dataIdx)
        else
            row:Hide()
        end
    end

    for i = visibleRows + 1, #rows do
        rows[i]:Hide()
    end

    UpdateInboxTabLabel()
end

-- Mouse wheel scrolling. FauxScrollFrame drives itself through its
-- named scrollbar, which also gives us clamping for free. Shift
-- scrolls a page at a time.
scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local step = IsShiftKeyDown() and 5 or 1
    local name = self:GetName()
    local bar = name and _G[name .. "ScrollBar"]
    if bar and bar.SetValue and bar.GetValue then
        bar:SetValue(bar:GetValue() - delta * ROW_HEIGHT * step)
    else
        local cur = FauxScrollFrame_GetOffset(self) or 0
        local new = cur - delta * step
        if new < 0 then new = 0 end
        self:SetVerticalScroll(new * ROW_HEIGHT)
    end
end)

scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshList)
end)

C.HookSearchBoxChanged(searchBox, function() RefreshList() end)

ratingFilterBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        currentRatingFilterIdx = currentRatingFilterIdx - 1
        if currentRatingFilterIdx < 1 then currentRatingFilterIdx = #ratingFilterPresets end
    else
        currentRatingFilterIdx = currentRatingFilterIdx + 1
        if currentRatingFilterIdx > #ratingFilterPresets then currentRatingFilterIdx = 1 end
    end
    self:SetText(T.gold .. ratingFilterPresets[currentRatingFilterIdx].label .. "|r")
    RefreshList()
end)
ratingFilterBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- Wire source pill clicks now that RefreshList exists
for i, b in ipairs(sourcePills) do
    b:SetScript("OnClick", function()
        currentSourceFilterIdx = i
        UpdateSourcePills()
        RefreshList()
    end)
end

classFilterBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        currentClassFilterIdx = currentClassFilterIdx - 1
        if currentClassFilterIdx < 1 then currentClassFilterIdx = #classFilterPresets end
    else
        currentClassFilterIdx = currentClassFilterIdx + 1
        if currentClassFilterIdx > #classFilterPresets then currentClassFilterIdx = 1 end
    end
    local preset = classFilterPresets[currentClassFilterIdx]
    self:SetText("|cFF" .. preset.color .. preset.label .. "|r")
    RefreshList()
end)
classFilterBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

groupFilterPill:SetScript("OnClick", function(self)
    groupFilterActive = not groupFilterActive
    self:SetActive(groupFilterActive)
    RefreshList()
end)

f:SetScript("OnSizeChanged", function()
    RefreshList()
end)

f:SetScript("OnShow", function()
    D("OnShow: scrollParent height=" .. tostring(scrollParent:GetHeight())
      .. " width=" .. tostring(scrollParent:GetWidth())
      .. " content height=" .. tostring(content:GetHeight())
      .. " width=" .. tostring(content:GetWidth()))
    -- Activate current tab and refresh
    ShowMainTab(activeMainTab)
    -- Delay refresh slightly to let layout settle
    C_Timer.After(0.05, function()
        D("OnShow delayed refresh: scrollParent height=" .. tostring(scrollParent:GetHeight()))
        if activeMainTab == "Database" then
            RefreshList()
        elseif activeMainTab == "Inbox" and RefreshInbox then
            RefreshInbox()
        elseif activeMainTab == "Groups" and Outings.RefreshTab then
            Outings.RefreshTab()
        end
    end)
end)

D("refresh list code OK")

-- Register database-specific UI elements for tab switching
-- Only what the Database tab really shows. ShowMainTab re-Show()s every entry
-- on each switch, so a widget hidden on purpose must not be listed: the Faux
-- scroll frame used to be re-shown under the ScrollBox (a second scrollbar),
-- the ScrollBox itself was missing (so it stayed up behind the Inbox), and the
-- redundant "Search:" label kept reappearing beside the native search box.
dbElements = { searchBox, ratingFilterBtn, classFilterBtn, groupFilterPill, countLabel, headerBar, scrollParent, listInset,
    listFilters.tagBtn, listFilters.daysBtn, listFilters.groupPill }
if not C.HasSearchBox then dbElements[#dbElements + 1] = searchLabel end
if USE_SCROLLBOX and scrollBox then
    dbElements[#dbElements + 1] = scrollBox
    dbElements[#dbElements + 1] = scrollBar
else
    dbElements[#dbElements + 1] = scrollFrame
    dbElements[#dbElements + 1] = content
end
for _, b in ipairs(sourcePills) do
    dbElements[#dbElements + 1] = b
end

----------------------------------------------------------------------
-- Inbox tab content
----------------------------------------------------------------------
do
    inboxContent = CreateFrame("Frame", nil, f)
    inboxContent:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
    inboxContent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 42)
    inboxContent:Hide()

    local inboxTitle = inboxContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    inboxTitle:SetPoint("TOPLEFT", inboxContent, "TOPLEFT", 4, -4)
    inboxTitle:SetText(T.muted .. "Players to review — rate or dismiss:|r")

    -- Purge All button
    local purgeBtn = CreateFrame("Button", nil, inboxContent, C.ButtonTemplate)
    purgeBtn:SetSize(70, 20)
    purgeBtn:SetPoint("TOPRIGHT", inboxContent, "TOPRIGHT", 0, -2)
    purgeBtn:SetText("Purge All")
    -- Two clicks within 3s instead of a modal popup. The popup's OnAccept
    -- still holds the purge logic, so there is one implementation of it.
    C.ArmConfirm(purgeBtn, function()
        local dlg = StaticPopupDialogs["WTFAY_PURGE_INBOX"]
        if dlg and dlg.OnAccept then dlg.OnAccept() end
    end)

    StaticPopupDialogs["WTFAY_PURGE_INBOX"] = {
        text = "Remove all players from the inbox?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            if not db or not db.players then return end
            local count = 0
            for key, p in pairs(db.players) do
                if p.pending then
                    People.Unlink(key)
                    db.players[key] = nil
                    count = count + 1
                end
            end
            P("Inbox purged: " .. count .. " player" .. (count == 1 and "" or "s") .. " removed.")
            if RefreshInbox then RefreshInbox() end
            UpdateInboxTabLabel()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    local INBOX_ROW_HEIGHT = 36
    local inboxScrollParent = CreateFrame("Frame", nil, inboxContent)
    inboxScrollParent:SetPoint("TOPLEFT", inboxContent, "TOPLEFT", 0, -24)
    inboxScrollParent:SetPoint("BOTTOMRIGHT", inboxContent, "BOTTOMRIGHT", -18, 0)

    local inboxScrollFrame = CreateFrame("ScrollFrame", "WTFAYInboxScrollFrame", inboxContent, "FauxScrollFrameTemplate")
    inboxScrollFrame:SetPoint("TOPLEFT", inboxScrollParent, "TOPLEFT", 0, 0)
    inboxScrollFrame:SetPoint("BOTTOMRIGHT", inboxScrollParent, "BOTTOMRIGHT", 0, 0)

    local inboxContentFrame = CreateFrame("Frame", nil, inboxContent)
    inboxContentFrame:SetPoint("TOPLEFT", inboxScrollParent, "TOPLEFT", 0, 0)
    inboxContentFrame:SetPoint("BOTTOMRIGHT", inboxScrollParent, "BOTTOMRIGHT", 0, 0)

    local inboxInset = C.CreateInset(inboxContent)
    inboxInset:SetPoint("TOPLEFT", inboxScrollParent, "TOPLEFT", -4, 4)
    inboxInset:SetPoint("BOTTOMRIGHT", inboxScrollParent, "BOTTOMRIGHT", 4, -4)
    inboxInset:EnableMouse(false)
    if inboxInset.SetFrameLevel then inboxInset:SetFrameLevel(inboxContent:GetFrameLevel()) end

    local inboxRows = {}
    local inboxSortedKeys = {}

    local function RebuildInboxSorted()
        wipe(inboxSortedKeys)
        if not db or not db.players then return end
        for key, p in pairs(db.players) do
            if p.pending then
                inboxSortedKeys[#inboxSortedKeys + 1] = key
            end
        end
        -- Sort by last seen, newest first
        table.sort(inboxSortedKeys, function(a, b)
            local pa, pb = db.players[a], db.players[b]
            if not pa or not pb then return a < b end
            return (pa.seen or "") > (pb.seen or "")
        end)
    end

    local function CreateInboxRow(index)
        local row = CreateFrame("Button", nil, inboxContentFrame)
        row:SetHeight(INBOX_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", inboxContentFrame, "TOPLEFT", 0, -((index - 1) * INBOX_ROW_HEIGHT))
        row:SetPoint("RIGHT", inboxContentFrame, "RIGHT", 0, 0)
        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        if BackdropTemplateMixin then Mixin(row, BackdropTemplateMixin); row:OnBackdropLoaded() end
        if row.SetBackdrop then
            row:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = nil, tile = true, tileSize = 16,
            })
            row:SetBackdropColor(0.1, 0.1, 0.13, 0.8)
        end

        -- Store base color for hover restore; updated per-row in RefreshInbox
        row.baseR, row.baseG, row.baseB, row.baseA = 0.1, 0.1, 0.13, 0.8

        -- Hover highlight (matches database rows)
        row:SetScript("OnEnter", function(self)
            if self.SetBackdropColor then
                self:SetBackdropColor(
                    math.min(self.baseR + 0.12, 1),
                    math.min(self.baseG + 0.15, 1),
                    math.min(self.baseB + 0.20, 1),
                    0.9
                )
            end
        end)
        row:SetScript("OnLeave", function(self)
            if self.SetBackdropColor then
                self:SetBackdropColor(self.baseR, self.baseG, self.baseB, self.baseA)
            end
        end)

        -- Left-click = detail panel, Right-click = context menu (same as database rows)
        row:SetScript("OnClick", function(self, button)
            if not self.playerKey then return end
            if button == "RightButton" then
                RowMenu(self)
            elseif button == "LeftButton" then
                ShowDetailPanel(self.playerKey)
            end
        end)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)

        row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.infoText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -1)
        row.infoText:SetText("")

        -- Dismiss button
        row.dismissBtn = CreateFrame("Button", nil, row, C.ButtonTemplate)
        row.dismissBtn:SetSize(54, 20)
        row.dismissBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.dismissBtn:SetText("Dismiss")
        row.dismissBtn:SetScript("OnClick", function()
            if row.playerKey and db and db.players then
                db.players[row.playerKey] = nil
                if RefreshInbox then RefreshInbox() end
                UpdateInboxTabLabel()
            end
        end)

        -- Rate button
        row.rateBtn = CreateFrame("Button", nil, row, C.ButtonTemplate)
        row.rateBtn:SetSize(42, 20)
        row.rateBtn:SetPoint("RIGHT", row.dismissBtn, "LEFT", -4, 0)
        -- Clip the info line against the buttons, so a long zone truncates
        -- instead of running underneath them.
        row.infoText:SetPoint("RIGHT", row.rateBtn, "LEFT", -8, 0)
        row.infoText:SetJustifyH("LEFT")
        row.infoText:SetWordWrap(false)
        row.rateBtn:SetText("Rate")
        row.rateBtn:SetScript("OnClick", function()
            if row.playerKey and ShowRatingPicker then
                ShowRatingPicker(row.playerKey)
            end
        end)

        return row
    end

    RefreshInbox = function()
        if not db then return end
        RebuildInboxSorted()

        local parentH = inboxScrollParent:GetHeight()
        if parentH < 1 then parentH = 200 end
        local visibleRows = math.floor(parentH / INBOX_ROW_HEIGHT)
        if visibleRows < 1 then visibleRows = 1 end

        local total = #inboxSortedKeys
        FauxScrollFrame_Update(inboxScrollFrame, total, visibleRows, INBOX_ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(inboxScrollFrame)

        for i = 1, visibleRows do
            local row = inboxRows[i]
            if not row then
                row = CreateInboxRow(i)
                inboxRows[i] = row
            end
            local dataIdx = offset + i
            if dataIdx <= total then
                local key = inboxSortedKeys[dataIdx]
                local p = db.players[key]
                if p then
                    local cc = ClassColor(p.class)
                    row.nameText:SetText(cc .. (p.name or "?") .. "|r")
                    local parts = {}
                    if p.level and p.level > 0 then parts[#parts + 1] = "Lv" .. p.level end
                    if p.race and p.race ~= "" then parts[#parts + 1] = p.race end
                    if p.class and p.class ~= "" then parts[#parts + 1] = p.class end
                    local _, srcDisplay = GetPlayerSources(p)
                    if srcDisplay ~= "" then parts[#parts + 1] = srcDisplay end
                    local lastEnc = p.encounters and p.encounters[#p.encounters]
                    if lastEnc and lastEnc.zone and lastEnc.zone ~= "" then
                        parts[#parts + 1] = T.brass .. lastEnc.zone .. "|r"
                    end
                    if p.seen then parts[#parts + 1] = T.faint .. p.seen .. "|r" end
                    row.infoText:SetText(T.muted .. table.concat(parts, "  ") .. "|r")
                    row.playerKey = key
                    -- Alternate row colors + store base for hover restore
                    if row.SetBackdropColor then
                        if i % 2 == 0 then
                            row.baseR, row.baseG, row.baseB, row.baseA = 0.12, 0.12, 0.15, 0.8
                        else
                            row.baseR, row.baseG, row.baseB, row.baseA = 0.08, 0.08, 0.10, 0.8
                        end
                        row:SetBackdropColor(row.baseR, row.baseG, row.baseB, row.baseA)
                    end
                    row:Show()
                else
                    row:Hide()
                end
            else
                row:Hide()
            end
        end

        for i = visibleRows + 1, #inboxRows do
            inboxRows[i]:Hide()
        end

        UpdateInboxTabLabel()
    end

    -- Mouse wheel scrolling. FauxScrollFrame drives itself through its
    -- named scrollbar, which also gives us clamping for free. Shift
    -- scrolls a page at a time.
    inboxScrollFrame:EnableMouseWheel(true)
    inboxScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local step = IsShiftKeyDown() and 5 or 1
        local name = self:GetName()
        local bar = name and _G[name .. "ScrollBar"]
        if bar and bar.SetValue and bar.GetValue then
            bar:SetValue(bar:GetValue() - delta * INBOX_ROW_HEIGHT * step)
        else
            local cur = FauxScrollFrame_GetOffset(self) or 0
            local new = cur - delta * step
            if new < 0 then new = 0 end
            self:SetVerticalScroll(new * INBOX_ROW_HEIGHT)
        end
    end)

    inboxScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, INBOX_ROW_HEIGHT, RefreshInbox)
    end)
end

D("inbox tab OK")

----------------------------------------------------------------------
-- Groups tab: every group you've been in, newest first
--
-- Left-click a group to rate who was in it (the recap card), right-click
-- for its note, the list of its players, or Forget.
----------------------------------------------------------------------
do
    local gc = CreateFrame("Frame", nil, f)
    gc:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
    gc:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 42)
    gc:Hide()
    Outings.tabFrame = gc

    local title = gc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", gc, "TOPLEFT", 4, -4)
    title:SetText(T.muted .. "Groups you've been in - click one to rate who was there:|r")

    local countText = gc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("TOPRIGHT", gc, "TOPRIGHT", -4, -6)

    local ROW_H = 36
    local listParent = CreateFrame("Frame", nil, gc)
    listParent:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, -24)
    listParent:SetPoint("BOTTOMRIGHT", gc, "BOTTOMRIGHT", -18, 0)

    local scroll = CreateFrame("ScrollFrame", "WTFAYGroupsScrollFrame", gc, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", 0, 0)

    local holder = CreateFrame("Frame", nil, gc)
    holder:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, 0)
    holder:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", 0, 0)

    local inset = C.CreateInset(gc)
    inset:SetPoint("TOPLEFT", listParent, "TOPLEFT", -4, 4)
    inset:SetPoint("BOTTOMRIGHT", listParent, "BOTTOMRIGHT", 4, -4)
    inset:EnableMouse(false)
    if inset.SetFrameLevel then inset:SetFrameLevel(gc:GetFrameLevel()) end

    local empty = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    empty:SetPoint("TOPLEFT", holder, "TOPLEFT", 10, -12)
    empty:SetPoint("RIGHT", holder, "RIGHT", -10, 0)
    empty:SetJustifyH("LEFT")
    empty:SetText(T.dim .. "No groups yet. WTFAY saves one each time you group with people "
        .. "(Auto-Track in Settings must be on). Battlegrounds and arenas aren't recorded.|r")

    local groupRows, ids = {}, {}

    StaticPopupDialogs["WTFAY_EDIT_GROUP_NOTE"] = {
        text = "Note for this group:",
        button1 = "Save",
        button2 = "Cancel",
        hasEditBox = true,
        editBoxWidth = 280,
        OnShow = function(self)
            local eb = self.editBox or _G[self:GetName() .. "EditBox"]
            local o = Outings.Get(Outings.editingId)
            if eb then
                eb:SetText(o and o.note or "")
                eb:SetFocus()
                eb:HighlightText()
            end
        end,
        OnAccept = function(self)
            local eb = self.editBox or _G[self:GetName() .. "EditBox"]
            local o = Outings.Get(Outings.editingId)
            if not (o and eb) then return end
            local text = (eb:GetText() or ""):trim()
            o.note = (text ~= "") and text or nil
            if Outings.RefreshTab then Outings.RefreshTab() end
            if Outings.RefreshRecap then Outings.RefreshRecap() end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            local accept = StaticPopupDialogs["WTFAY_EDIT_GROUP_NOTE"].OnAccept
            accept(parent)
            parent:Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    StaticPopupDialogs["WTFAY_FORGET_GROUP"] = {
        text = "Forget this group?\nIts players, ratings and notes stay; only the group record goes.",
        button1 = "Forget",
        button2 = "Cancel",
        OnAccept = function()
            local id = Outings.editingId
            if not Outings.Get(id) then return end
            Outings.Forget(id)
            if listFilters.outing == id then listFilters.ShowOuting(nil) end
            P("Group forgotten.")
            if Outings.RefreshTab then Outings.RefreshTab() end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    local function GroupMenu(row)
        local id = row.outingId
        local o = Outings.Get(id)
        if not o then return end
        C.ShowContextMenu(row, {
            { text = "Group of " .. (o.time or "?"), isTitle = true },
            { text = "Rate the Players...", func = function() Outings.ShowRecap(id) end },
            { text = "Show Players in Database", func = function()
                listFilters.ShowOuting(id)
                ShowMainTab("Database")
            end },
            { text = "Edit Group Note", func = function()
                Outings.editingId = id
                StaticPopup_Show("WTFAY_EDIT_GROUP_NOTE")
            end },
            { text = T.off .. "Forget This Group|r", func = function()
                Outings.editingId = id
                StaticPopup_Show("WTFAY_FORGET_GROUP")
            end },
            { text = "Cancel" },
        })
    end

    local function CreateGroupRow(i)
        local row = CreateFrame("Button", nil, holder)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -((i - 1) * ROW_H))
        row:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if BackdropTemplateMixin then Mixin(row, BackdropTemplateMixin); row:OnBackdropLoaded() end
        if row.SetBackdrop then
            row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", insets = { left = 0, right = 0, top = 0, bottom = 1 } })
        end
        row.baseR, row.baseG, row.baseB, row.baseA = 0.08, 0.08, 0.10, 0.8
        row:SetScript("OnEnter", function(self)
            if self.SetBackdropColor then self:SetBackdropColor(self.baseR + 0.12, self.baseG + 0.15, self.baseB + 0.20, 0.9) end
            local o = Outings.Get(self.outingId)
            if not o then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(SOURCE_INFO[o.kind] and SOURCE_INFO[o.kind].label or "Group", 1, 0.82, 0)
            GameTooltip:AddLine((o.time or "?") .. "  -  " .. Outings.Duration(o), 0.8, 0.8, 0.8)
            if #(o.zones or {}) > 0 then GameTooltip:AddLine(table.concat(o.zones, ", "), 0.87, 0.67, 0.27, true) end
            local members = Outings.Members(o)
            for _, m in ipairs(members) do
                GameTooltip:AddLine(ClassColor(m.class) .. m.name .. "|r  " .. ColorRating(People.Rating(m))
                    .. (m.pending and (" " .. T.warn .. "(Inbox)|r") or ""))
            end
            if o.note then GameTooltip:AddLine(o.note, 1, 1, 1, true) end
            GameTooltip:AddLine("Left-click to rate the players, right-click for more", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            if self.SetBackdropColor then self:SetBackdropColor(self.baseR, self.baseG, self.baseB, self.baseA) end
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self, mouse)
            if not self.outingId then return end
            if mouse == "RightButton" then GroupMenu(self) else Outings.ShowRecap(self.outingId) end
        end)

        row.line1 = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
        row.line1:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.line1:SetJustifyH("LEFT")
        row.line1:SetWordWrap(false)
        row.line2 = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.line2:SetPoint("TOPLEFT", row.line1, "BOTTOMLEFT", 0, -2)
        row.line2:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.line2:SetJustifyH("LEFT")
        row.line2:SetWordWrap(false)
        groupRows[i] = row
        return row
    end

    function Outings.RefreshTab()
        if not db then return end
        ids = Outings.Sorted()
        local total = #ids
        countText:SetText(T.muted .. total .. " group" .. (total == 1 and "" or "s") .. "|r")
        empty:SetShown(total == 0)

        local h = listParent:GetHeight()
        if not h or h < 1 then h = 200 end
        local visible = math.max(1, math.floor(h / ROW_H))
        FauxScrollFrame_Update(scroll, total, visible, ROW_H)
        local offset = FauxScrollFrame_GetOffset(scroll)

        for i = 1, visible do
            local row = groupRows[i] or CreateGroupRow(i)
            local id = ids[offset + i]
            local o = Outings.Get(id)
            if o then
                local info = SOURCE_INFO[o.kind] or SOURCE_INFO.group
                local when = (o.time or "?"):gsub("^%d+%-", "")
                local where = Outings.Where(o, 3)
                row.line1:SetText(T.light .. when .. "|r  |cFF" .. info.color .. info.label .. "|r  "
                    .. T.dim .. Outings.Duration(o) .. "|r" .. (where ~= "" and ("  " .. T.brass .. where .. "|r") or ""))
                local members = Outings.Members(o)
                local with = Outings.WithText(o, nil, 5)
                row.line2:SetText(T.muted .. #members .. " player" .. (#members == 1 and "" or "s") .. "|r"
                    .. (with ~= "" and ("  " .. with) or "")
                    .. (o.note and ("  " .. T.dim .. "- " .. o.note .. "|r") or ""))
                row.outingId = id
                local even = ((offset + i) % 2 == 0)
                row.baseR, row.baseG, row.baseB = even and 0.12 or 0.08, even and 0.12 or 0.08, even and 0.15 or 0.10
                if row.SetBackdropColor then row:SetBackdropColor(row.baseR, row.baseG, row.baseB, row.baseA) end
                row:Show()
            else
                row.outingId = nil
                row:Hide()
            end
        end
        for i = visible + 1, #groupRows do groupRows[i]:Hide() end
    end

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local name = self:GetName()
        local bar = name and _G[name .. "ScrollBar"]
        if bar and bar.SetValue and bar.GetValue then
            bar:SetValue(bar:GetValue() - delta * ROW_H * (IsShiftKeyDown() and 5 or 1))
        end
    end)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, Outings.RefreshTab)
    end)
end

D("groups tab OK")

-- Forward declaration for minimap button (created after settings, referenced by settings toggles)
local minimapBtn

----------------------------------------------------------------------
-- Settings tab (also records the spec used by the game's AddOns menu)
----------------------------------------------------------------------

do
    local sp = CreateFrame("Frame", "WTFAYSettingsPanel", f)
    sp:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
    sp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    sp:Hide()
    settingsPanel.frame = sp

    -- Title
    local spTitle = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    spTitle:SetPoint("TOPLEFT", sp, "TOPLEFT", 4, -4)
    spTitle:SetText(T.gold .. "Settings|r")

    local hint = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -4, -8)
    hint:SetText(T.dim .. "Changes apply immediately.|r")

    ----------------------------------------------------------------
    -- Tab bar
    ----------------------------------------------------------------
    local TAB_NAMES = { "General", "Alerts", "Display" }
    local tabButtons = {}
    local tabContents = {}
    local tabScrolls = {}
    local tabHeights = { General = 280, Alerts = 360, Display = 330 }
    local activeTab = "General"

    local tabWidth = 80
    local tabBarY = -30
    local startX = 4

    for i, name in ipairs(TAB_NAMES) do
        local btn = CreateFrame("Button", nil, sp)
        btn:SetSize(tabWidth, 20)
        btn:SetPoint("TOPLEFT", sp, "TOPLEFT", startX + (i - 1) * tabWidth, tabBarY)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
        label:SetText(name)
        btn.label = label

        local underline = btn:CreateTexture(nil, "ARTWORK")
        underline:SetHeight(2)
        underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, 0)
        underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 0)
        underline:SetColorTexture(0.9, 0.7, 0.2, 1)
        underline:Hide()
        btn.underline = underline

        btn:SetScript("OnClick", function()
            activeTab = name
            for _, n in ipairs(TAB_NAMES) do
                if tabScrolls[n] then
                    tabScrolls[n]:SetShown(n == name)
                end
                if tabButtons[n] then
                    if n == name then
                        tabButtons[n].label:SetTextColor(1, 0.82, 0.1)
                        tabButtons[n].underline:Show()
                    else
                        tabButtons[n].label:SetTextColor(0.6, 0.6, 0.6)
                        tabButtons[n].underline:Hide()
                    end
                    -- Native skin: the client's Options_Tab art instead of the underline.
                    C.SkinTab(tabButtons[n], n == name)
                end
            end
        end)

        tabButtons[name] = btn
    end

    -- Each section scrolls so every option stays reachable at minimum window height.
    for _, name in ipairs(TAB_NAMES) do
        local scroll = CreateFrame("ScrollFrame", "WTFAYSettings" .. name .. "Scroll", sp, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, tabBarY - 28)
        scroll:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", -24, 36)
        scroll:Hide()
        local cf = CreateFrame("Frame", nil, scroll)
        cf:SetSize(400, tabHeights[name])
        scroll:SetScrollChild(cf)
        scroll:SetScript("OnSizeChanged", function(self, width)
            if width and width > 0 then cf:SetWidth(width) end
            -- Resizing a tall window after scrolling must not leave an empty section.
            local maxOffset = math.max(0, cf:GetHeight() - self:GetHeight())
            self:SetVerticalScroll(math.min(self:GetVerticalScroll(), maxOffset))
        end)
        scroll:HookScript("OnShow", function(self)
            local resize = self:GetScript("OnSizeChanged")
            resize(self, self:GetWidth())
        end)
        tabContents[name] = cf
        tabScrolls[name] = scroll
    end

    -- Show default tab
    local function ShowTab(name)
        tabButtons[name]:GetScript("OnClick")()
    end

    ----------------------------------------------------------------
    -- Helper: create a toggle row (checkbox + label + description)
    ----------------------------------------------------------------
    local function CreateToggle(parent, yOffset, label, description, getter, setter, default)
        local row = C.CreateCheckbox(parent)
        row:SetSize(24, 24)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)


        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", row, "RIGHT", 4, 0)
        lbl:SetText(label)

        local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
        desc:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText(T.dim .. description .. "|r")
        desc:SetWordWrap(true)

        C.BindToggle(row, label, description, setter, default)

        row.Refresh = function()
            row:SetChecked(getter())
        end

        -- Recorded too, so the game's AddOns menu rebuilds exactly these
        -- settings in the same sections (see the options panel below).
        local section = "General"
        for name, frame in pairs(tabContents) do
            if frame == parent then section = name end
        end
        settingsPanel.spec[#settingsPanel.spec + 1] = {
            kind = "toggle", section = section, label = label, description = description,
            getter = getter, setter = setter, default = default,
        }

        return row
    end

    ----------------------------------------------------------------
    -- Shared pickers
    --
    -- Both settings panels build these through the same functions, so the
    -- game's AddOns menu can't drift from /wtfay settings. Each returns a
    -- refresh function, or nil when it doesn't apply on this client.
    ----------------------------------------------------------------
    local function RecordCustom(section, height, build)
        settingsPanel.spec[#settingsPanel.spec + 1] = {
            kind = "custom", section = section, height = height, build = build,
        }
    end

    function settingsPanel.BuildSoundPicker(parent, y)
        local soundLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        soundLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
        soundLabel:SetText(T.soft .. "Sound:|r")

        -- UIDropDownMenu_* is gone on Mainline; the compat layer swaps in a
        -- MenuUtil-backed button there and keeps the classic dropdown on TBC.
        local dd
        dd = C.CreateDropdown(parent, 130, function()
            local entries = {}
            for i, snd in ipairs(ALERT_SOUNDS) do
                entries[#entries + 1] = {
                    text    = snd.name,
                    checked = (db and db.settings and db.settings.alertSoundChoice == i),
                    func    = function()
                        if db and db.settings then db.settings.alertSoundChoice = i end
                        dd:SetLabel(snd.name)
                        PlaySound(snd.normal)
                    end,
                }
            end
            return entries
        end)
        dd:SetPoint("LEFT", soundLabel, "RIGHT", -8, -2)

        local previewBtn = CreateFrame("Button", nil, parent, C.ButtonTemplate)
        previewBtn:SetSize(40, 22)
        previewBtn:SetPoint("LEFT", dd, "RIGHT", -4, 2)
        previewBtn:SetText("Test")
        previewBtn:SetScript("OnClick", function()
            local idx = db and db.settings and db.settings.alertSoundChoice or 1
            local choice = ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]
            PlaySound(choice.normal)
        end)
        previewBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Preview sound")
            GameTooltip:Show()
        end)
        previewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        return function()
            local idx = db and db.settings and db.settings.alertSoundChoice or 1
            dd:SetLabel((ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]).name)
        end
    end

    local SKIN_LABELS = { native = "Native (game UI)", dark = "Dark (classic WTFAY)" }
    local function CurrentSkinKey()
        local k = db and db.settings and db.settings.skin
        if k ~= "native" and k ~= "dark" then k = C.DefaultSkin() end
        return k
    end

    -- Window style: Mainline only, since Classic has no native look to pick.
    function settingsPanel.BuildSkinPicker(parent, y)
        if not C.CanChooseSkin() then return nil end
        local skinLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        skinLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        skinLabel:SetText("Window Style")
        local dd
        dd = C.CreateDropdown(parent, 150, function()
            local entries = {}
            for _, key in ipairs({ "native", "dark" }) do
                entries[#entries + 1] = {
                    text    = SKIN_LABELS[key],
                    checked = (CurrentSkinKey() == key),
                    func    = function()
                        if db and db.settings then db.settings.skin = key end
                        C.SetSkin(key)
                        dd:SetLabel(SKIN_LABELS[key])
                        P("Window style: " .. T.on .. SKIN_LABELS[key] .. "|r")
                    end,
                }
            end
            return entries
        end)
        dd:SetPoint("LEFT", skinLabel, "RIGHT", 8, 0)
        return function() dd:SetLabel(SKIN_LABELS[CurrentSkinKey()]) end
    end

    ----------------------------------------------------------------
    -- Tab: General
    ----------------------------------------------------------------
    local gc = tabContents["General"]

    local debugToggle = CreateToggle(gc, -10,
        "Debug Logging",
        "Show verbose debug messages in chat. Useful for troubleshooting.",
        function() return DEBUG end,
        function(val)
            DEBUG = val
            if db and db.settings then db.settings.debug = val end
            P("Debug mode: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.debug
    )

    local autoTrackToggle = CreateToggle(gc, -60,
        "Auto-Track Party Members",
        "Automatically add or update players when you join a party, raid, or dungeon.",
        function() return db and db.settings and db.settings.autoTrack or false end,
        function(val)
            if db and db.settings then db.settings.autoTrack = val end
            P("Auto-tracking: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.autoTrack
    )

    local whoEnrichToggle = CreateToggle(gc, -110,
        "Fill In Details via /who",
        "Look up class, level, guild, and zone for players added by name. Throttled to one lookup every few seconds.",
        function() return db and db.settings and db.settings.whoEnrich or false end,
        function(val)
            if db and db.settings then db.settings.whoEnrich = val end
            P("/who enrichment: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.whoEnrich
    )

    local unitMenuToggle = CreateToggle(gc, -170,
        "Right-Click Menu Entry",
        "Add \"WTFAY: Rate / Note\" to the right-click menu on unit frames, chat names, and the friends list.",
        function() return db and db.settings and db.settings.unitMenu or false end,
        function(val)
            if db and db.settings then db.settings.unitMenu = val end
            P("Unit menu entry: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.unitMenu
    )

    local groupRecapToggle = CreateToggle(gc, -220,
        "Rate Your Group Afterwards",
        "When you leave a group, show a card with everyone who was in it, to rate them while you still remember. Waits until you're out of combat.",
        function() return db and db.settings and db.settings.groupRecap and true or false end,
        function(val)
            if db and db.settings then db.settings.groupRecap = val end
            P("Group rating card: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.groupRecap
    )

    ----------------------------------------------------------------
    -- Tab: Alerts
    ----------------------------------------------------------------
    local ac = tabContents["Alerts"]

    local knownAlertsToggle = CreateToggle(ac, -10,
        "Known Player Alerts",
        "Master toggle for all known player notifications.",
        function() return db and db.settings and db.settings.knownAlerts or false end,
        function(val)
            if db and db.settings then db.settings.knownAlerts = val end
            P("Known player alerts: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.knownAlerts
    )

    local alertJoinToggle = CreateToggle(ac, -48,
        "  Player Joins",
        "Alert when a known player joins your group.",
        function() return db and db.settings and db.settings.alertOnJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnJoin = val end
            P("Alert on join: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertOnJoin
    )

    local alertLeaveToggle = CreateToggle(ac, -86,
        "  Player Leaves",
        "Alert when a known player leaves your group.",
        function() return db and db.settings and db.settings.alertOnLeave or false end,
        function(val)
            if db and db.settings then db.settings.alertOnLeave = val end
            P("Alert on leave: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertOnLeave
    )

    local alertMeJoinToggle = CreateToggle(ac, -124,
        "  I Join a Group",
        "Alert when you join a group with known players already in it.",
        function() return db and db.settings and db.settings.alertOnMeJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnMeJoin = val end
            P("Alert on me join: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertOnMeJoin
    )

    local alertPopupToggle = CreateToggle(ac, -174,
        "Alert Popup Panel",
        "Also show a popup panel with known players (not just chat).",
        function() return db and db.settings and db.settings.alertPopup or false end,
        function(val)
            if db and db.settings then db.settings.alertPopup = val end
            P("Alert popup: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertPopup
    )

    local alertSoundToggle = CreateToggle(ac, -224,
        "Alert Sound",
        "Play a sound when the known player alert appears.",
        function() return db and db.settings and db.settings.alertSound or false end,
        function(val)
            if db and db.settings then db.settings.alertSound = val end
            P("Alert sound: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertSound
    )

    -- Sound picker (shared builder, also used by the game's AddOns menu)
    local soundRefresh = settingsPanel.BuildSoundPicker(ac, -268)
    RecordCustom("Alerts", 44, settingsPanel.BuildSoundPicker)

    local skipGuildToggle = CreateToggle(ac, -304,
        "Skip Guild Members in Alerts",
        "Don't show alerts for players in your guild.",
        function() return db and db.settings and db.settings.alertSkipGuild or false end,
        function(val)
            if db and db.settings then db.settings.alertSkipGuild = val end
            P("Skip guild in alerts: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.alertSkipGuild
    )

    ----------------------------------------------------------------
    -- Tab: Display
    ----------------------------------------------------------------
    local dc = tabContents["Display"]

    local minimapToggle = CreateToggle(dc, -10,
        "Minimap Button",
        "Show the WTFAY icon on your minimap.",
        function() return not (db and db.minimapHidden) end,
        function(val)
            if db then db.minimapHidden = not val end
            if val then minimapBtn:Show() else minimapBtn:Hide() end
            P("Minimap button: " .. (val and T.on .. "shown|r" or T.off .. "hidden|r"))
        end, true
    )

    local tooltipToggle = CreateToggle(dc, -60,
        "Show Info on Tooltips",
        "Add rating, note, and last-seen info to the tooltip of players you've tracked.",
        function() return db and db.settings and db.settings.tooltipEnabled or false end,
        function(val)
            if db and db.settings then db.settings.tooltipEnabled = val end
            P("Tooltip info: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.tooltipEnabled
    )

    local tooltipGuildToggle = CreateToggle(dc, -110,
        "  Include Guild",
        "Also show the player's guild on the tooltip when it's known.",
        function() return db and db.settings and db.settings.tooltipGuild or false end,
        function(val)
            if db and db.settings then db.settings.tooltipGuild = val end
            P("Tooltip guild: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.tooltipGuild
    )

    local tooltipHintToggle = CreateToggle(dc, -160,
        "  Hint on Unknown Players",
        "Show a \"/wtfay target to track\" reminder on players you haven't tracked yet.",
        function() return db and db.settings and db.settings.tooltipHint or false end,
        function(val)
            if db and db.settings then db.settings.tooltipHint = val end
            P("Tooltip hint: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.tooltipHint
    )

    local tooltipNotesToggle = CreateToggle(dc, -210,
        "  Show Private Notes",
        "Include your notes, tags and nicknames on the tooltip. Turn off when streaming or sharing your screen; the rating still shows.",
        function() return db and db.settings and db.settings.tooltipNotes or false end,
        function(val)
            if db and db.settings then db.settings.tooltipNotes = val end
            P("Private notes on tooltips: " .. (val and T.on .. "ON|r" or T.off .. "OFF|r"))
        end, SETTINGS_DEFAULTS.tooltipNotes
    )

    -- Window style (shared builder; Mainline only)
    local skinRefresh = settingsPanel.BuildSkinPicker(dc, -266)
    if skinRefresh then RecordCustom("Display", 40, settingsPanel.BuildSkinPicker) end

    ----------------------------------------------------------------
    -- Settings footer replaces the database actions while this tab is open.
    ----------------------------------------------------------------
    local aboutLabel = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aboutLabel:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", -4, 8)
    aboutLabel:SetText(T.dim .. "v" .. ADDON_VERSION .. "  -  Developed by |r|cFF" .. ACCENT .. "goosefraba|r")

    local doneBtn = CreateFrame("Button", nil, sp, C.ButtonTemplate)
    doneBtn:SetSize(100, 22)
    doneBtn:SetPoint("BOTTOMLEFT", sp, "BOTTOMLEFT", 0, 2)
    doneBtn:SetText("Back")
    doneBtn:SetScript("OnClick", function()
        ShowMainTab(settingsPanel.returnTab or "Database")
    end)

    -- Refresh all toggles when shown
    sp:SetScript("OnShow", function()
        debugToggle.Refresh()
        autoTrackToggle.Refresh()
        knownAlertsToggle.Refresh()
        alertJoinToggle.Refresh()
        alertLeaveToggle.Refresh()
        alertMeJoinToggle.Refresh()
        alertPopupToggle.Refresh()
        alertSoundToggle.Refresh()
        skipGuildToggle.Refresh()
        minimapToggle.Refresh()
        whoEnrichToggle.Refresh()
        unitMenuToggle.Refresh()
        groupRecapToggle.Refresh()
        tooltipToggle.Refresh()
        tooltipGuildToggle.Refresh()
        tooltipHintToggle.Refresh()
        tooltipNotesToggle.Refresh()
        if skinRefresh then skinRefresh() end
        if soundRefresh then soundRefresh() end
        ShowTab(activeTab)
    end)

    -- Public interface
    settingsPanel.Toggle = function()
        if f:IsShown() and activeMainTab == "Settings" then
            ShowMainTab(settingsPanel.returnTab or "Database")
        else
            ShowMainTab("Settings")
            f:Show()
        end
    end

    -- Initialize default tab
    ShowTab("General")
end

D("settings panel OK")

----------------------------------------------------------------------
-- Main window layout per skin
--
-- In the native skin Database/Inbox/Settings become bottom tabs, which frees the pill
-- row under the title bar, so everything below moves up into it. The original
-- anchors are captured once and re-applied with an offset, never accumulated,
-- so switching skins back and forth is exact.
----------------------------------------------------------------------
do  -- block-scoped: these helpers spend no file-scope locals (Lua 5.1 caps a scope at 200)
local MAIN_TOP_SHIFT = 22
local mainLayoutBase   -- widget -> its original points

local function ApplyMainLayout()
    local widgets = { searchBox, sourcePills[1], groupFilterPill, countLabel, headerBar, inboxContent, Outings.tabFrame, settingsPanel.frame }
    if not mainLayoutBase then
        mainLayoutBase = {}
        for _, w in ipairs(widgets) do
            if w then
                local pts = {}
                for i = 1, w:GetNumPoints() do pts[i] = { w:GetPoint(i) } end
                mainLayoutBase[w] = pts
            end
        end
    end

    local useNative = (nativeMainTabs ~= nil) and C.IsNativeWindow(f)
    local shift = useNative and MAIN_TOP_SHIFT or 0

    for _, btn in pairs(mainTabButtons) do btn:SetShown(not useNative) end
    if nativeMainTabs then
        for _, tab in ipairs(nativeMainTabs) do tab:SetShown(useNative) end
    end

    for w, pts in pairs(mainLayoutBase) do
        w:ClearAllPoints()
        for _, pt in ipairs(pts) do
            local point, rel, relPoint, x, y = pt[1], pt[2], pt[3], pt[4], pt[5]
            -- The search box no longer needs room for its "Search:" label once
            -- the native search field (magnifier + placeholder) replaces it.
            if w == searchBox and C.HasSearchBox and rel == f then x = 16 end
            if rel == f and type(relPoint) == "string" and relPoint:find("^TOP") then
                y = (y or 0) + shift
            end
            w:SetPoint(point, rel, relPoint, x, y)
        end
    end
end

C.OnSkinChanged(ApplyMainLayout)
ApplyMainLayout()
end


----------------------------------------------------------------------
-- Blizzard Interface Options panel (AddOns tab)
----------------------------------------------------------------------
do
    local optPanel = CreateFrame("Frame", "WTFAYOptionsPanel", UIParent)
    optPanel.name = "WTFAY"

    -- Title
    local optTitle = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    optTitle:SetPoint("TOPLEFT", 16, -16)
    optTitle:SetText("|cFF" .. ACCENT .. "WTFAY|r - Who The F* Are You?  " .. T.dim .. "v" .. ADDON_VERSION .. "|r")

    -- Subtitle
    local optSub = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -8)
    optSub:SetText("Track, rate, and remember every player you group with.")

    -- Helper: checkbox for Blizzard panel
    local function BlizCheckbox(parent, yOffset, label, description, getter, setter, default)
        local cb = C.CreateCheckbox(parent)
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)


        local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1)
        lbl:SetText(label)

        local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
        desc:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText(description)
        desc:SetWordWrap(true)

        C.BindToggle(cb, label, description, setter, default)

        cb.Refresh = function()
            cb:SetChecked(getter())
        end

        return cb
    end

    -- Open the player browser straight from the game's AddOns menu.
    local optOpenBtn = CreateFrame("Button", nil, optPanel, C.ButtonTemplate)
    optOpenBtn:SetSize(130, 22)
    optOpenBtn:SetPoint("TOPRIGHT", optPanel, "TOPRIGHT", -16, -16)
    optOpenBtn:SetText("Open WTFAY")
    optOpenBtn:SetScript("OnClick", function() f:Show() end)

    ----------------------------------------------------------------
    -- Every setting, generated from settingsPanel.spec
    --
    -- This page used to be hand-written alongside /wtfay settings and had
    -- quietly fallen behind it (no tooltip, /who, menu-entry or window-style
    -- options). It now replays whatever the Settings tab recorded, in
    -- the same sections and order, so the two can't drift again.
    ----------------------------------------------------------------
    local optScroll = CreateFrame("ScrollFrame", "WTFAYOptionsScroll", optPanel, "UIPanelScrollFrameTemplate")
    optScroll:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 4, -64)
    optScroll:SetPoint("BOTTOMRIGHT", optPanel, "BOTTOMRIGHT", -30, 40)

    local optBody = CreateFrame("Frame", nil, optScroll)
    optBody:SetSize(560, 10)
    optScroll:SetScrollChild(optBody)
    -- Descriptions wrap against the body's width, which only exists once the
    -- game has sized its Settings canvas.
    optScroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then optBody:SetWidth(w) end
    end)

    local SECTION_TITLES = { General = "General", Alerts = "Known Player Alerts", Display = "Display" }
    local optRefreshers = {}
    local y, lastSection = -4, nil
    for _, e in ipairs(settingsPanel.spec) do
        if e.section ~= lastSection then
            if lastSection then y = y - 12 end
            local h = optBody:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
            h:SetPoint("TOPLEFT", optBody, "TOPLEFT", 12, y)
            h:SetText(SECTION_TITLES[e.section] or e.section)
            local rule = optBody:CreateTexture(nil, "ARTWORK")
            rule:SetColorTexture(unpack(C.Theme.sep))
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
            rule:SetPoint("RIGHT", optBody, "RIGHT", -16, 0)
            y = y - 32
            lastSection = e.section
        end
        if e.kind == "toggle" then
            local cb = BlizCheckbox(optBody, y, e.label, e.description, e.getter, e.setter, e.default)
            optRefreshers[#optRefreshers + 1] = cb.Refresh
            -- Indented sub-options ("  Player Joins") sit closer together.
            y = y - (((e.label or ""):find("^%s")) and 40 or 48)
        elseif e.kind == "custom" then
            local refresh = e.build(optBody, y)
            if refresh then optRefreshers[#optRefreshers + 1] = refresh end
            y = y - (e.height or 40)
        end
    end
    optBody:SetHeight(-y + 16)

    -- About / credit
    local optAbout = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optAbout:SetPoint("BOTTOMLEFT", optPanel, "BOTTOMLEFT", 16, 22)
    optAbout:SetText(T.dim .. "v" .. ADDON_VERSION .. "  -  Developed by |r|cFF" .. ACCENT .. "goosefraba|r")

    local optInfo = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optInfo:SetPoint("BOTTOMLEFT", optPanel, "BOTTOMLEFT", 16, 8)
    optInfo:SetText(T.dim .. "The same settings as /wtfay settings. Hover an option for details; right-click to reset it.|r")

    optPanel:SetScript("OnShow", function()
        for _, refresh in ipairs(optRefreshers) do refresh() end
    end)

    -- Store reference; registration happens in PLAYER_LOGIN to ensure Blizzard UI is fully ready
    settingsPanel.blizPanel = optPanel
    ns.optionsPanel = optPanel      -- compat layer needs it for the legacy open path

    settingsPanel.RegisterBliz = function()
        -- Settings.* on Mainline, InterfaceOptions_AddCategory on Classic.
        local ok, err = C.RegisterOptions(optPanel, optPanel.name)
        D("RegisterOptions: ok=" .. tostring(ok) .. " err=" .. tostring(err))
        if not ok then
            D("Not visible in the game options; the Settings tab still works.")
        end
    end

    settingsPanel.OpenBliz = function()
        if not C.OpenOptions() then
            -- Nothing to open (or the API refused) - fall back to our own panel.
            settingsPanel.Toggle()
        end
    end
end

D("blizzard options panel OK")

----------------------------------------------------------------------
-- Minimap Button
----------------------------------------------------------------------
minimapBtn = CreateFrame("Button", "WTFAYMinimapButton", Minimap)
minimapBtn:SetSize(33, 33)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(8)
minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapBtn:SetMovable(true)
minimapBtn:EnableMouse(true)
minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapBtn:RegisterForDrag("LeftButton")

-- Icon overlay
local mmOverlay = minimapBtn:CreateTexture(nil, "OVERLAY")
mmOverlay:SetSize(53, 53)
mmOverlay:SetPoint("TOPLEFT")
mmOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

-- Icon background
local mmBg = minimapBtn:CreateTexture(nil, "BACKGROUND")
mmBg:SetSize(24, 24)
mmBg:SetPoint("CENTER", minimapBtn, "CENTER", 0, 1)
mmBg:SetTexture("Interface\\Icons\\INV_Misc_Note_01")  -- note/scroll icon

-- Position helper: convert angle (degrees) to position on minimap
local function MinimapBtn_SetAngle(angle)
    local rad = math.rad(angle)
    local x = math.cos(rad) * 80
    local y = math.sin(rad) * 80
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Default angle
local minimapAngle = 220
MinimapBtn_SetAngle(minimapAngle)

-- Drag to reposition around minimap
minimapBtn:SetScript("OnDragStart", function(self)
    self.isDragging = true
    self:SetScript("OnUpdate", function(self)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
        MinimapBtn_SetAngle(minimapAngle)
    end)
end)
minimapBtn:SetScript("OnDragStop", function(self)
    self.isDragging = false
    self:SetScript("OnUpdate", nil)
    if db then db.minimapAngle = minimapAngle end
end)

-- Left-click: toggle WTFAY. Right-click: toggle settings.
minimapBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        -- Open the Settings tab in the main window.
        if settingsPanel and settingsPanel.Toggle then
            settingsPanel.Toggle()
        elseif settingsPanel and settingsPanel.OpenBliz then
            settingsPanel.OpenBliz()
        end
    else
        if f:IsShown() then f:Hide() else f:Show() end
    end
end)

-- Tooltip
minimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cFF" .. ACCENT .. "WTFAY|r")
    GameTooltip:AddLine("Left-click to toggle panel", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click for settings", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag to reposition", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)
minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

D("minimap button OK")

-- Forward declarations so bottom-bar buttons can reference them
local importExportPanel
local statsPanel
local helpPanel

----------------------------------------------------------------------
-- Bottom bar
----------------------------------------------------------------------
local addBtn = CreateFrame("Button", nil, f, C.ButtonTemplate)
addBtn:SetSize(100, 22)
addBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
addBtn:SetText("Add Target")
addBtn:SetScript("OnClick", function()
    AddTargetPlayer()
end)

local exportBtn = CreateFrame("Button", nil, f, C.ButtonTemplate)
exportBtn:SetSize(60, 22)
exportBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
exportBtn:SetText("Export")
exportBtn:SetScript("OnClick", function()
    if importExportPanel.ShowExport then importExportPanel.ShowExport() end
end)

local importBtn = CreateFrame("Button", nil, f, C.ButtonTemplate)
importBtn:SetSize(60, 22)
importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 4, 0)
importBtn:SetText("Import")
importBtn:SetScript("OnClick", function()
    if importExportPanel.ShowImport then importExportPanel.ShowImport() end
end)

local statsBtn = CreateFrame("Button", nil, f, C.ButtonTemplate)
statsBtn:SetSize(50, 22)
statsBtn:SetPoint("LEFT", importBtn, "RIGHT", 4, 0)
statsBtn:SetText("Stats")
statsBtn:SetScript("OnClick", function()
    if statsPanel and statsPanel.Toggle then statsPanel.Toggle() end
end)

local helpBtn = CreateFrame("Button", nil, f, C.ButtonTemplate)
helpBtn:SetSize(50, 22)
helpBtn:SetPoint("LEFT", statsBtn, "RIGHT", 4, 0)
helpBtn:SetText("Help")
helpBtn:SetScript("OnClick", function()
    if helpPanel and helpPanel.Toggle then helpPanel.Toggle() end
end)

settingsPanel.mainButtons = { addBtn, exportBtn, importBtn, statsBtn, helpBtn }

D("bottom bar OK")

----------------------------------------------------------------------
-- Import / Export
----------------------------------------------------------------------
importExportPanel = {}

do
    -- Serialize one player to a line: key\tname\trealm\tclass\trace\tlevel\trating\tnote\tsource\tseen
    -- NOTE: pipe "|" was used as separator in V1 but WoW interprets | as an
    -- escape character (|H = hyperlink, |T = texture, |c = colour, etc.),
    -- which caused the EditBox to render export text as invisible/blank.
    -- V2 uses tab as separator instead.
    local SEP = "\t"
    local FIELD_ESC_PIPE = "@@PIPE@@"  -- escape literal pipes in notes
    local FIELD_ESC_TAB  = "@@TAB@@"   -- escape literal tabs (shouldn't appear, but be safe)

    local function EscField(s)
        s = (s or ""):gsub("|", FIELD_ESC_PIPE)
        return (s:gsub("\t", FIELD_ESC_TAB))
    end
    local function UnescField(s)
        s = (s or ""):gsub(FIELD_ESC_TAB, "\t")
        return (s:gsub(FIELD_ESC_PIPE, "|"))
    end

    local function ExportDB()
        if not db or not db.players then return "" end
        local lines = {}
        lines[1] = "WTFAY_EXPORT_V2"  -- header for version detection
        for key, p in pairs(db.players) do
            if not p.pending then
                local parts = {
                    EscField(key),
                    EscField(p.name),
                    EscField(p.realm),
                    EscField(p.class),
                    EscField(p.race or ""),
                    tostring(p.level or 0),
                    tostring(People.Rating(p)),
                    EscField(p.note or ""),
                    EscField(p.source or "manual"),
                    EscField(p.seen or ""),
                }
                -- Linked characters add two fields; the importer has always
                -- accepted lines longer than 10 fields, so older versions
                -- simply ignore them.
                local person = People.Of(p)
                local ownTags = {}
                for t in pairs(p.tags or {}) do ownTags[#ownTags + 1] = t end
                table.sort(ownTags)
                local extra = (p.nick and p.nick ~= "") or #ownTags > 0
                if person then
                    parts[#parts + 1] = p.personId
                    parts[#parts + 1] = (person.main == key) and "1" or "0"
                elseif extra then
                    parts[#parts + 1] = ""   -- no link
                    parts[#parts + 1] = ""
                end
                -- Nickname and tags (comma-separated) as fields 13 and 14.
                if extra then
                    parts[#parts + 1] = EscField(p.nick or "")
                    parts[#parts + 1] = EscField(table.concat(ownTags, ","))
                end
                lines[#lines + 1] = table.concat(parts, SEP)
            end
        end
        return table.concat(lines, "\n")
    end

    -- Read an export into records without touching the database. Returns the
    -- records and how many non-empty lines weren't understood.
    local function ParseExport(text)
        local records, skipped = {}, 0
        if not text or text == "" then return records, skipped end
        local lines = { strsplit("\n", text) }

        -- Check header and detect format version
        local startLine = 1
        local lineSep = SEP  -- default to current (tab)
        if lines[1] and lines[1]:find("^WTFAY_EXPORT_V2") then
            startLine = 2
            lineSep = "\t"
        elseif lines[1] and lines[1]:find("^WTFAY_EXPORT_V1") then
            startLine = 2
            lineSep = "|"
        end

        for i = startLine, #lines do
            -- Not trim(): a tab is a field separator, and a line can end in an
            -- empty field.
            local line = (lines[i] or ""):gsub("^[ \r\n]+", ""):gsub("[ \r\n]+$", "")
            if line ~= "" then
                local parts = { strsplit(lineSep, line) }
                -- Need at least: key, name, realm, class, race, level, rating, note, source, seen
                local r
                if #parts >= 10 then
                    r = {
                        key    = UnescField(parts[1]),
                        name   = UnescField(parts[2]),
                        realm  = UnescField(parts[3]),
                        class  = UnescField(parts[4]),
                        race   = UnescField(parts[5]),
                        level  = tonumber(parts[6]) or 0,
                        rating = math.max(-3, math.min(5, tonumber(parts[7]) or 0)),
                        note   = UnescField(parts[8]),
                        source = UnescField(parts[9]),
                        seen   = UnescField(parts[10]),
                    }
                    if r.key == "" or r.name == "" then r = nil end
                end
                if r then
                    -- Recompute rather than trusting the file's key, so an
                    -- export from an older build (or from a realm whose
                    -- name contains a dash or space) lands on the same
                    -- normalized key the rest of the addon uses.
                    if r.realm ~= "" then
                        r.realm = NormalizeRealm(r.realm)
                        r.key   = MakeKey(r.name, r.realm)
                    end
                    -- Exports up to v0.8.1 end every line in a stray "0"
                    -- at field 11, so only a line with field 12 has a link.
                    if parts[12] and parts[11] ~= "" then
                        r.linkId, r.isMain = parts[11], (parts[12] == "1")
                    end
                    if parts[13] and parts[13] ~= "" then r.nick = UnescField(parts[13]) end
                    if parts[14] and parts[14] ~= "" then
                        r.tags = {}
                        for t in UnescField(parts[14]):gmatch("[^,]+") do r.tags[#r.tags + 1] = t end
                    end
                    records[#records + 1] = r
                else
                    skipped = skipped + 1
                end
            end
        end
        return records, skipped
    end

    -- What a Merge would do, counted without changing anything.
    local function PreviewImport(text)
        local records, skipped = ParseExport(text)
        local s = { total = #records, new = 0, known = 0, rating = 0, notes = 0, links = 0, skipped = skipped }
        local groups = {}
        for _, r in ipairs(records) do
            local existing = db.players[r.key]
            if existing then
                s.known = s.known + 1
                if r.rating ~= People.Rating(existing) then s.rating = s.rating + 1 end
                if r.note ~= "" and r.note ~= (existing.note or "") then s.notes = s.notes + 1 end
            else
                s.new = s.new + 1
            end
            if r.linkId then groups[r.linkId] = true end
        end
        for _ in pairs(groups) do s.links = s.links + 1 end
        return s
    end
    importExportPanel.Preview = PreviewImport

    local function ImportDB(text)
        local records = ParseExport(text)
        local added, updated = 0, 0
        local fileGroups = {}   -- link id in the file -> { keys = {...}, main = key }
        for _, r in ipairs(records) do
            local key = r.key
            if db.players[key] then
                -- Merge: keep higher absolute rating, append note if different
                local existing = db.players[key]
                if math.abs(r.rating) > math.abs(People.Rating(existing)) then
                    People.SetRating(existing, r.rating)
                end
                if r.note ~= "" and r.note ~= existing.note then
                    if (existing.note or "") == "" then
                        existing.note = r.note
                    else
                        existing.note = existing.note .. " | " .. r.note
                    end
                end
                -- Update level if imported is higher
                if r.level > (existing.level or 0) then
                    existing.level = r.level
                end
                -- Update class/race if we had Unknown
                if (existing.class or "Unknown") == "Unknown" and r.class ~= "Unknown" then
                    existing.class = r.class
                end
                if (existing.race or "") == "" and r.race ~= "" then
                    existing.race = r.race
                end
                updated = updated + 1
            else
                db.players[key] = {
                    name       = r.name,
                    realm      = r.realm,
                    class      = r.class,
                    race       = r.race,
                    level      = r.level,
                    rating     = r.rating,
                    note       = r.note,
                    source     = r.source,
                    seen       = r.seen,
                    encounters = {},
                }
                added = added + 1
            end
            -- Nickname only if you haven't given them one; tags add up. A tag
            -- you don't have becomes one of your own, while there's room.
            local p = db.players[key]
            if r.nick and not (p.nick and p.nick ~= "") then Tags.SetNick(p, r.nick) end
            for _, t in ipairs(r.tags or {}) do
                local tag = Tags.Find(t) or Tags.AddCustom(t)
                if tag then
                    p.tags = p.tags or {}
                    p.tags[tag] = true
                end
            end
            -- The file's link id only groups its lines; local ids
            -- are assigned by People.Link, so they can't collide.
            if r.linkId then
                local group = fileGroups[r.linkId]
                if not group then
                    group = { keys = {} }
                    fileGroups[r.linkId] = group
                end
                group.keys[#group.keys + 1] = key
                if r.isMain then group.main = key end
            end
        end
        for _, group in pairs(fileGroups) do
            local main = group.main or group.keys[1]
            for _, k in ipairs(group.keys) do
                if k ~= main then People.Link(k, main) end
            end
        end
        People.Reconcile()
        return added, updated
    end

    -- Export panel: scrollable editbox with select-all
    local expFrame = C.CreateWindow("WTFAYExportFrame", UIParent)
    expFrame:SetSize(500, 350)
    expFrame:SetPoint("CENTER")
    expFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    expFrame:SetMovable(true)
    expFrame:EnableMouse(true)
    expFrame:RegisterForDrag("LeftButton")
    expFrame:SetClampedToScreen(true)
    expFrame:SetScript("OnDragStart", function(s) s:StartMoving() end)
    expFrame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    expFrame:Hide()

    if BackdropTemplateMixin then Mixin(expFrame, BackdropTemplateMixin); expFrame:OnBackdropLoaded() end
    -- Chrome: C.SkinWindow below, once title and close button exist.

    do local nm = expFrame:GetName(); if nm then tinsert(UISpecialFrames, nm) end end

    local expClose = CreateFrame("Button", nil, expFrame, "UIPanelCloseButton")
    expClose:SetPoint("TOPRIGHT", -2, -2)

    local expTitle = expFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    expTitle:SetPoint("TOP", 0, -14)
    C.SkinWindow(expFrame, { title = expTitle, close = expClose, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })

    local expHint = expFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expHint:SetPoint("TOP", expTitle, "BOTTOM", 0, -4)

    -- ScrollFrame + EditBox for the text
    local expScroll = CreateFrame("ScrollFrame", "WTFAYExportScroll", expFrame, "UIPanelScrollFrameTemplate")
    expScroll:SetPoint("TOPLEFT", 14, -52)
    expScroll:SetPoint("BOTTOMRIGHT", -32, 72)   -- room for the import preview

    local expEditBox = CreateFrame("EditBox", "WTFAYExportEditBox", expScroll)
    expEditBox:SetMultiLine(true)
    expEditBox:SetAutoFocus(false)
    expEditBox:SetFontObject(ChatFontNormal)
    expEditBox:SetWidth(450)
    expEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); expFrame:Hide() end)
    expScroll:SetScrollChild(expEditBox)

    -- Bottom buttons: Close (default), Merge + Replace (import mode)
    local btnClose = CreateFrame("Button", nil, expFrame, C.ButtonTemplate)
    btnClose:SetSize(80, 22)
    btnClose:SetPoint("BOTTOM", 0, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() expFrame:Hide() end)

    local btnMerge = CreateFrame("Button", nil, expFrame, C.ButtonTemplate)
    btnMerge:SetSize(100, 22)
    btnMerge:SetPoint("BOTTOMLEFT", expFrame, "BOTTOMLEFT", 60, 12)
    btnMerge:SetText("Merge")
    btnMerge:Hide()

    local btnReplace = CreateFrame("Button", nil, expFrame, C.ButtonTemplate)
    btnReplace:SetSize(100, 22)
    btnReplace:SetPoint("LEFT", btnMerge, "RIGHT", 8, 0)
    btnReplace:SetText(T.dangerSoft .. "Replace All|r")
    btnReplace:Hide()

    local btnCancel = CreateFrame("Button", nil, expFrame, C.ButtonTemplate)
    btnCancel:SetSize(80, 22)
    btnCancel:SetPoint("LEFT", btnReplace, "RIGHT", 8, 0)
    btnCancel:SetText("Cancel")
    btnCancel:Hide()

    local function ResetButtons()
        btnClose:Show()
        btnMerge:Hide()
        btnReplace:Hide()
        btnCancel:Hide()
    end

    -- Public show functions
    importExportPanel.ShowExport = function()
        expTitle:SetText("|cFF" .. ACCENT .. "Export WTFAY Database|r")
        expHint:SetText(T.dim .. "Select all (Ctrl+A), copy (Ctrl+C), and share with a friend.|r")
        expEditBox:SetText(ExportDB())
        expEditBox:SetCursorPosition(0)
        ResetButtons()
        expFrame:Show()
        expEditBox:SetFocus()
        expEditBox:HighlightText()
    end

    -- Import mode: a live preview of what Merge would do, under the paste box.
    local importMode = false
    local expPreview = expFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expPreview:SetPoint("BOTTOMLEFT", expFrame, "BOTTOMLEFT", 16, 40)
    expPreview:SetPoint("RIGHT", expFrame, "RIGHT", -16, 0)
    expPreview:SetJustifyH("LEFT")
    expPreview:SetWordWrap(true)

    local function PreviewText(text)
        if not text or text:trim() == "" then return T.dim .. "Paste an export to see what it contains.|r" end
        local s = PreviewImport(text)
        if s.total == 0 then
            return T.warn .. "Nothing here looks like a WTFAY export.|r"
        end
        local known = {}
        if s.rating > 0 then known[#known + 1] = s.rating .. " rated differently (the stronger rating is kept)" end
        if s.notes > 0 then known[#known + 1] = s.notes .. " with a new note (added to yours)" end
        local line = T.white .. s.total .. " player" .. (s.total == 1 and "" or "s") .. "|r: "
            .. T.on .. s.new .. " new|r, " .. T.manual .. s.known .. " you already know|r"
            .. (#known > 0 and (" (" .. table.concat(known, ", ") .. ")") or "")
        if s.links > 0 then line = line .. ", " .. s.links .. " linked group" .. (s.links == 1 and "" or "s") end
        if s.skipped > 0 then line = line .. ".  " .. T.warn .. s.skipped .. " line" .. (s.skipped == 1 and "" or "s") .. " not understood|r" end
        local mine = 0
        for _ in pairs(db.players) do mine = mine + 1 end
        return line .. "\n" .. T.dim .. "Replace All backs up, then removes, your " .. mine .. " player"
            .. (mine == 1 and "" or "s") .. " (/wtfay restore undoes it).|r"
    end
    importExportPanel.PreviewText = PreviewText

    do
        local showExport = importExportPanel.ShowExport
        importExportPanel.ShowExport = function()
            importMode = false
            expPreview:SetText("")
            showExport()
        end
    end

    expEditBox:SetScript("OnTextChanged", function(self)
        if importMode then expPreview:SetText(PreviewText(self:GetText())) end
    end)

    local function CloseImport()
        importMode = false
        expPreview:SetText("")
        expFrame:Hide()
        ResetButtons()
    end
    expFrame:HookScript("OnHide", function() importMode = false; expPreview:SetText("") end)

    btnMerge:SetScript("OnClick", function()
        local text = expEditBox:GetText()
        if text == "" then P("Nothing to import."); CloseImport(); return end
        local added, updated = ImportDB(text)
        P("Merge complete: " .. T.on .. added .. " added|r, " .. T.manual .. updated .. " updated|r")
        RefreshList()
        CloseImport()
    end)

    -- Two clicks: Replace All wipes the database, even with a backup behind it.
    C.ArmConfirm(btnReplace, function()
        local text = expEditBox:GetText()
        if text == "" then P("Nothing to import."); CloseImport(); return end
        if PreviewImport(text).total == 0 then
            P(T.warn .. "Nothing in that text looks like a WTFAY export - your database is unchanged.|r")
            return
        end
        -- Backup current database before wiping
        if not db.backups then db.backups = {} end
        local backup = {}
        for k, p in pairs(db.players) do
            backup[k] = {}
            for field, val in pairs(p) do
                if field == "encounters" then
                    backup[k].encounters = {}
                    for idx, e in ipairs(val) do
                        local copy = {}
                        for ek, ev in pairs(e) do copy[ek] = ev end
                        backup[k].encounters[idx] = copy
                    end
                else
                    backup[k][field] = val
                end
            end
        end
        -- Keep only the 3 most recent backups
        table.insert(db.backups, 1, {
            time    = Timestamp(),
            count   = 0,  -- updated below
            players = backup,
            people  = People.Snapshot(),
        })
        local backupCount = 0
        for _ in pairs(backup) do backupCount = backupCount + 1 end
        db.backups[1].count = backupCount
        while #db.backups > 3 do
            table.remove(db.backups)
        end
        P("Backup created (" .. backupCount .. " players saved). Use " .. T.gold .. "/wtfay restore|r to undo.")
        -- Wipe existing data and import fresh
        wipe(db.players)
        wipe(db.people)
        local added, _ = ImportDB(text)
        P("Replace complete: " .. T.on .. added .. " players|r imported (old data wiped)")
        RefreshList()
        CloseImport()
    end, T.off .. "Click again|r")

    btnCancel:SetScript("OnClick", CloseImport)

    importExportPanel.ShowImport = function()
        expTitle:SetText("|cFF" .. ACCENT .. "Import WTFAY Database|r")
        expHint:SetText(T.dim .. "Paste exported data below. Merge adds new + updates existing. Replace overwrites everything.|r")
        importMode = true
        expEditBox:SetText("")
        expPreview:SetText(PreviewText(""))

        -- Show import buttons, hide close
        btnClose:Hide()
        btnMerge:Show()
        btnReplace:Show()
        btnCancel:Show()

        expFrame:Show()
        expEditBox:SetFocus()
    end
end

D("import/export OK")

----------------------------------------------------------------------
-- Database Stats Panel
----------------------------------------------------------------------
statsPanel = {}

do
    local sp = C.CreateWindow("WTFAYStatsPanel", UIParent)
    sp:SetSize(320, 380)
    sp:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    sp:SetFrameStrata("FULLSCREEN_DIALOG")
    sp:SetMovable(true)
    sp:EnableMouse(true)
    sp:RegisterForDrag("LeftButton")
    sp:SetClampedToScreen(true)
    sp:SetScript("OnDragStart", function(s) s:StartMoving() end)
    sp:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    sp:Hide()

    if BackdropTemplateMixin then
        Mixin(sp, BackdropTemplateMixin)
        sp:OnBackdropLoaded()
    end
    -- Chrome: C.SkinWindow below, once title and close button exist.

    -- Close on Escape
    do
        local nm = sp:GetName()
        if nm then tinsert(UISpecialFrames, nm) end
    end

    -- Close button
    local spClose = CreateFrame("Button", nil, sp, "UIPanelCloseButton")
    spClose:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -2, -2)

    -- Title
    local spTitle = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    spTitle:SetPoint("TOP", sp, "TOP", 0, -14)
    C.SkinWindow(sp, { title = spTitle, close = spClose, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    spTitle:SetText("|cFF" .. ACCENT .. "WTFAY Database Stats|r")

    -- Content area: we create font strings for each stat line
    local contentLines = {}
    local function AddLine(yOff)
        local fs = sp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", sp, "TOPLEFT", 18, yOff)
        fs:SetPoint("RIGHT", sp, "RIGHT", -18, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        contentLines[#contentLines + 1] = fs
        return fs
    end

    -- Pre-create stat lines
    local lineTotalPlayers   = AddLine(-44)
    local lineAvgRating      = AddLine(-64)
    local lineSep1           = AddLine(-82)
    local lineRatingHeader   = AddLine(-96)
    local lineBlacklist      = AddLine(-114)
    local lineNegative       = AddLine(-132)
    local lineNeutral        = AddLine(-150)
    local linePositive       = AddLine(-168)
    local lineLegend         = AddLine(-186)
    local lineSep2           = AddLine(-204)
    local lineSourceHeader   = AddLine(-218)
    local lineRaid           = AddLine(-236)
    local lineDungeon        = AddLine(-254)
    local lineGroup          = AddLine(-272)
    local lineManual         = AddLine(-290)
    local lineEncounters     = AddLine(-312)

    lineSep1:SetText(T.dark .. "———————————————————————|r")
    lineSep2:SetText(T.dark .. "———————————————————————|r")

    -- Helper: colored count bar
    local function StatLine(label, count, total, color)
        local pct = total > 0 and math.floor(count / total * 100) or 0
        return "|cFF" .. color .. label .. "|r  " .. T.white .. count .. "|r  " .. T.dim .. "(" .. pct .. "%)|r"
    end

    -- Refresh stats on show
    local function RefreshStats()
        if not db or not db.players then return end

        local totalPlayers = 0
        local ratingSum = 0
        local countBlacklist = 0  -- -3
        local countNegative = 0   -- -2 to -1
        local countNeutral = 0    -- 0
        local countPositive = 0   -- 1 to 4
        local countLegend = 0     -- 5
        local countRaid = 0
        local countDungeon = 0
        local countGroup = 0
        local countManual = 0
        local totalEncounters = 0
        local classCounts = {}

        for _, p in pairs(db.players) do
            if p.pending then -- skip inbox players from stats
            else
            totalPlayers = totalPlayers + 1
            local r = People.Rating(p)
            ratingSum = ratingSum + r

            if r == -3 then countBlacklist = countBlacklist + 1
            elseif r < 0 then countNegative = countNegative + 1
            elseif r == 0 then countNeutral = countNeutral + 1
            elseif r >= 5 then countLegend = countLegend + 1
            else countPositive = countPositive + 1
            end

            local srcSet = GetPlayerSources(p)
            if srcSet["raid"] then countRaid = countRaid + 1 end
            if srcSet["dungeon"] then countDungeon = countDungeon + 1 end
            if srcSet["group"] then countGroup = countGroup + 1 end
            if srcSet["manual"] then countManual = countManual + 1 end

            local cls = (p.class or "Unknown"):upper()
            classCounts[cls] = (classCounts[cls] or 0) + 1

            if p.encounters then
                totalEncounters = totalEncounters + #p.encounters
            end
            end -- close else (skip pending)
        end

        local avgRating = totalPlayers > 0 and (ratingSum / totalPlayers) or 0
        local avgStr = string.format("%.1f", avgRating)

        local extraChars = People.ExtraCharacters()
        lineTotalPlayers:SetText(T.white .. "Total Players:|r  |cFF" .. ACCENT .. totalPlayers .. "|r"
            .. (extraChars > 0 and ("  " .. T.dim .. "(" .. (totalPlayers - extraChars) .. " people)|r") or ""))
        lineAvgRating:SetText(T.white .. "Average Rating:|r  " .. C.RatingIcon(math.floor(avgRating + 0.5)) .. ColorRating(math.floor(avgRating + 0.5)) .. " " .. T.dim .. "(" .. avgStr .. ")|r")

        lineRatingHeader:SetText("|cFF" .. ACCENT .. "Rating Breakdown|r")
        lineBlacklist:SetText(StatLine("  Blacklist (-3)", countBlacklist, totalPlayers, "FF4444"))
        lineNegative:SetText(StatLine("  Negative (-2 to -1)", countNegative, totalPlayers, "FF8844"))
        lineNeutral:SetText(StatLine("  Neutral (0)", countNeutral, totalPlayers, "CCCCCC"))
        linePositive:SetText(StatLine("  Positive (1-4)", countPositive, totalPlayers, "44FF44"))
        lineLegend:SetText(StatLine("  Legend (5)", countLegend, totalPlayers, "FFD700"))

        lineSourceHeader:SetText("|cFF" .. ACCENT .. "Source Breakdown|r")
        lineRaid:SetText(StatLine("  Raid", countRaid, totalPlayers, "FF6699"))
        lineDungeon:SetText(StatLine("  Dungeon", countDungeon, totalPlayers, "66BBFF"))
        lineGroup:SetText(StatLine("  Group", countGroup, totalPlayers, "99FF66"))
        lineManual:SetText(StatLine("  Manual", countManual, totalPlayers, "FFCC44"))

        lineEncounters:SetText(T.white .. "Total Encounters:|r  |cFF" .. ACCENT .. totalEncounters .. "|r")
    end

    sp:SetScript("OnShow", RefreshStats)

    -- Done button
    local doneBtn = CreateFrame("Button", nil, sp, C.ButtonTemplate)
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", sp, "BOTTOM", 0, 12)
    doneBtn:SetText("Close")
    doneBtn:SetScript("OnClick", function() sp:Hide() end)

    -- Public interface
    statsPanel.Toggle = function()
        if sp:IsShown() then sp:Hide() else sp:Show() end
    end
    statsPanel.frame = sp
end

D("stats panel OK")

----------------------------------------------------------------------
-- Help Panel
----------------------------------------------------------------------
helpPanel = {}

do
    local hp = C.CreateWindow("WTFAYHelpPanel", UIParent)
    hp:SetSize(440, 480)
    hp:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    hp:SetFrameStrata("FULLSCREEN_DIALOG")
    hp:SetMovable(true)
    hp:EnableMouse(true)
    hp:RegisterForDrag("LeftButton")
    hp:SetClampedToScreen(true)
    hp:SetScript("OnDragStart", function(s) s:StartMoving() end)
    hp:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    hp:Hide()

    if BackdropTemplateMixin then
        Mixin(hp, BackdropTemplateMixin)
        hp:OnBackdropLoaded()
    end
    -- Chrome: C.SkinWindow below, once title and close button exist.

    -- Close on Escape
    do
        local nm = hp:GetName()
        if nm then tinsert(UISpecialFrames, nm) end
    end

    -- Close button
    local hpClose = CreateFrame("Button", nil, hp, "UIPanelCloseButton")
    hpClose:SetPoint("TOPRIGHT", hp, "TOPRIGHT", -2, -2)

    -- Title
    local hpTitle = hp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hpTitle:SetPoint("TOP", hp, "TOP", 0, -14)
    C.SkinWindow(hp, { title = hpTitle, close = hpClose, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    hpTitle:SetText("|cFF" .. ACCENT .. "WTFAY Help & Guide|r")

    -- Scrollable content area
    local hpScroll = CreateFrame("ScrollFrame", "WTFAYHelpScroll", hp, "UIPanelScrollFrameTemplate")
    hpScroll:SetPoint("TOPLEFT", hp, "TOPLEFT", 12, -38)
    hpScroll:SetPoint("BOTTOMRIGHT", hp, "BOTTOMRIGHT", -30, 44)

    local hpContent = CreateFrame("Frame", nil, hpScroll)
    hpContent:SetSize(390, 1)  -- height will grow with content
    hpScroll:SetScrollChild(hpContent)

    -- Build help text as a single large FontString with word wrap
    local hpText = hpContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hpText:SetPoint("TOPLEFT", hpContent, "TOPLEFT", 4, 0)
    hpText:SetWidth(380)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(true)
    hpText:SetSpacing(3)

    local helpLines = {
        "|cFF" .. ACCENT .. "Welcome to WTFAY!|r",
        "WTFAY helps you keep track of every player you group with in World of Warcraft.",
        "Rate them, leave notes, and never forget who you played with.",
        " ",
        "|cFF" .. ACCENT .. "--- Getting Started ---|r",
        "Open the main panel by typing " .. T.gold .. "/wtfay|r or clicking the minimap icon.",
        "You can also bind it to a key or use a macro!",
        " ",
        "|cFF" .. ACCENT .. "--- Adding Players ---|r",
        "The easiest way to add a player is to " .. T.white .. "target them|r and click the",
        T.gold .. "Add Target|r button, or type " .. T.gold .. "/wtfay target|r.",
        " ",
        T.warn .. "Pro Tip:|r Create a macro for quick access:",
        " ",
        T.on .. "/run SlashCmdList[\"WTFAY\"](\"target\")|r",
        " ",
        "Put this on your action bar and you can add any targeted player",
        "with a single click! Their name, class, race, and level are",
        "detected automatically.",
        " ",
        "You can also add players manually:",
        "  " .. T.gold .. "/wtfay add Playername|r",
        "  " .. T.gold .. "/wtfay add Playername-Realm|r",
        " ",
        "|cFF" .. ACCENT .. "--- Rating Players ---|r",
        "Rate players from " .. T.off .. "-3|r (blacklist) to " .. T.goldAlt .. "5|r (legend):",
        "  " .. T.off .. "-3|r = Blacklisted  " .. T.ember .. "-2/-1|r = Negative",
        "  " .. T.light .. " 0|r = Neutral       " .. T.on .. "1-4|r = Positive",
        "  " .. T.goldAlt .. " 5|r = Legend",
        " ",
        "Click a player row, then use the rating stars in the detail view.",
        "Or right-click a row and choose " .. T.gold .. "Set Rating|r.",
        "Or via command: " .. T.gold .. "/wtfay rate Playername 3|r",
        " ",
        "|cFF" .. ACCENT .. "--- Notes ---|r",
        "Add notes to remember specific details about a player.",
        "Right-click a row and choose " .. T.gold .. "Edit Note|r,",
        "or: " .. T.gold .. "/wtfay note Playername Great tank, marks targets|r",
        " ",
        "|cFF" .. ACCENT .. "--- Browsing & Filtering ---|r",
        "The main panel has several tools at the top:",
        "  " .. T.white .. "Search|r - Filter by player name",
        "  " .. T.white .. "Rating filter|r - Show only certain ratings (click to cycle)",
        "  " .. T.white .. "Source filter|r - Show Raid / Dungeon / Group / Manual",
        "  " .. T.white .. "Class filter|r - Show only a specific class",
        " ",
        "All filters support " .. T.gold .. "left-click|r (forward) and " .. T.gold .. "right-click|r (backward).",
        " ",
        "Click any " .. T.white .. "column header|r to sort. Click again to reverse.",
        " ",
        "|cFF" .. ACCENT .. "--- Auto-Tracking ---|r",
        "When enabled (Settings), WTFAY automatically adds players you",
        "group with in parties, dungeons, and raids. Dungeon and raid",
        "encounters include the zone name. Toggle in Settings or:",
        "  " .. T.gold .. "Interface > AddOns > WTFAY|r",
        " ",
        "|cFF" .. ACCENT .. "--- Import / Export ---|r",
        "Share your database with friends!",
        "  " .. T.gold .. "Export|r - Copies your data as text. Send it to a friend.",
        "  " .. T.gold .. "Import|r - Paste data from a friend.",
        "    " .. T.white .. "Merge|r keeps your existing data and adds new entries.",
        "    " .. T.white .. "Replace All|r wipes your data first (a backup is created).",
        "  " .. T.gold .. "/wtfay restore|r - Undo the last Replace All.",
        " ",
        "|cFF" .. ACCENT .. "--- Quick Reference ---|r",
        "  " .. T.gold .. "/wtfay|r - Toggle panel",
        "  " .. T.gold .. "/wtfay target|r - Add current target",
        "  " .. T.gold .. "/wtfay add Name|r - Add manually",
        "  " .. T.gold .. "/wtfay remove Name|r - Remove player",
        "  " .. T.gold .. "/wtfay rate Name 3|r - Rate player",
        "  " .. T.gold .. "/wtfay note Name text|r - Set note",
        "  " .. T.gold .. "/wtfay search term|r - Search",
        "  " .. T.gold .. "/wtfay export / import|r - Data sharing",
        "  " .. T.gold .. "/wtfay restore|r - Undo replace",
        "  " .. T.gold .. "/wtfay stats|r - Database stats",
        "  " .. T.gold .. "/wtfay settings|r - Settings",
        "  " .. T.gold .. "/wtfay minimap|r - Toggle minimap icon",
        "  " .. T.gold .. "/wtfay help|r - Chat help",
        " ",
        T.dim .. "v" .. ADDON_VERSION .. "  -  Developed by goosefraba|r",
    }

    hpText:SetText(table.concat(helpLines, "\n"))

    -- Resize content frame to fit the text
    hp:SetScript("OnShow", function()
        local textH = hpText:GetStringHeight() or 400
        hpContent:SetSize(390, textH + 10)
    end)

    -- Close button at bottom
    local hpDone = CreateFrame("Button", nil, hp, C.ButtonTemplate)
    hpDone:SetSize(80, 22)
    hpDone:SetPoint("BOTTOM", hp, "BOTTOM", 0, 12)
    hpDone:SetText("Close")
    hpDone:SetScript("OnClick", function() hp:Hide() end)

    -- Public interface
    helpPanel.Toggle = function()
        if hp:IsShown() then hp:Hide() else hp:Show() end
    end
    helpPanel.frame = hp
end

D("help panel OK")

----------------------------------------------------------------------
-- Static popups — popupActiveKey is declared earlier (before RowMenu)
-- so both RowMenu and the popups share the same upvalue
----------------------------------------------------------------------

StaticPopupDialogs["WTFAY_ADD_PLAYER"] = {
    text = "Enter player name (or Name-Realm):",
    button1 = "Add",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 220,
    OnAccept = function(self)
        local ok, err = pcall(function()
            local eb = self.editBox or _G[self:GetName() .. "EditBox"]
            local text = eb and eb:GetText() or ""
            if text.trim then text = text:trim() end
            D("WTFAY_ADD_PLAYER OnAccept: text='" .. text .. "'")
            if text ~= "" then
                SlashCmdList["WTFAY"]("add " .. text)
            end
        end)
        if not ok then D("ADD_PLAYER OnAccept ERROR: " .. tostring(err)) end
    end,
    OnShow = function(self)
        local eb = self.editBox or _G[self:GetName() .. "EditBox"]
        if eb then eb:SetFocus() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["WTFAY_EDIT_NOTE"] = {
    text = "Edit note for %s:",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 280,
    OnAccept = function(self)
        local ok, err = pcall(function()
            local key = popupActiveKey
            D("WTFAY_EDIT_NOTE OnAccept: key=" .. tostring(key))
            local eb = self.editBox or _G[self:GetName() .. "EditBox"]
            D("WTFAY_EDIT_NOTE editBox=" .. tostring(eb))
            if not key or not db or not db.players[key] then
                D("WTFAY_EDIT_NOTE: player not found")
                return
            end
            local note = ""
            if eb then
                note = eb:GetText() or ""
            end
            D("WTFAY_EDIT_NOTE note='" .. note .. "'")
            local dialog = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
            dialog.saved = true
            dialog.drafts[key] = nil
            db.players[key].note = note
            if note ~= "" and db.players[key].pending then
                db.players[key].pending = nil
                P("Note updated for " .. db.players[key].name .. " " .. T.on .. "(moved to database)|r")
            else
                P("Note updated for " .. db.players[key].name)
            end
            RefreshList()
            if RefreshInbox then RefreshInbox() end
            UpdateInboxTabLabel()
        end)
        if not ok then D("EDIT_NOTE OnAccept ERROR: " .. tostring(err)) end
    end,
    OnShow = function(self)
        local ok, err = pcall(function()
            local key = popupActiveKey
            D("WTFAY_EDIT_NOTE OnShow: key=" .. tostring(key))
            local eb = self.editBox or _G[self:GetName() .. "EditBox"]
            D("WTFAY_EDIT_NOTE OnShow editBox=" .. tostring(eb))
            local dialog = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
            dialog.saved, dialog.discarded = nil, nil
            dialog.editingKey = key
            dialog.original = key and db and db.players[key] and (db.players[key].note or "") or ""
            if eb then
                local draft = key and dialog.drafts[key]
                if draft then
                    eb:SetText(draft)
                    P("Restored your unsaved note for " .. db.players[key].name .. ". Cancel throws it away.")
                elseif key and db and db.players[key] then
                    eb:SetText(db.players[key].note or "")
                else
                    eb:SetText("")
                end
                eb:SetFocus()
                eb:HighlightText()
                local saveBtn = self.button1 or _G[self:GetName() .. "Button1"]
                eb:SetScript("OnEnterPressed", function()
                    if saveBtn then saveBtn:Click() end
                end)
                eb:SetScript("OnEscapePressed", function()
                    self:Hide()
                end)
            end
        end)
        if not ok then D("EDIT_NOTE OnShow ERROR: " .. tostring(err)) end
    end,
    -- Only the Cancel button discards. Escape, another popup taking this one's
    -- place, or closing the window keeps the text as a draft, which comes
    -- back the next time this player's note is opened.
    OnCancel = function(self, data, reason)
        if reason == "clicked" then
            local dialog = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
            dialog.discarded = true
            if dialog.editingKey then dialog.drafts[dialog.editingKey] = nil end
        end
    end,
    OnHide = function(self)
        local dialog = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
        local key = dialog.editingKey
        dialog.editingKey = nil
        if not key or dialog.saved or dialog.discarded then return end
        local eb = self.editBox or (self.GetName and _G[self:GetName() .. "EditBox"])
        local text = eb and eb:GetText() or ""
        if text ~= (dialog.original or "") and db and db.players[key] then
            dialog.drafts[key] = text
            P("Unsaved note for " .. db.players[key].name .. " kept - open Edit Note again to finish it.")
        end
    end,
    drafts = {},   -- key -> unsaved text, for this session
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    exclusive = true,
}

----------------------------------------------------------------------
-- Visual Rating Picker (replaces the old text-input popup)
----------------------------------------------------------------------
local ratingPicker = CreateFrame("Frame", "WTFAYRatingPicker", UIParent)

-- Rating labels for display
local RATING_LABELS = {
    [-3] = "Blacklist",
    [-2] = "Bad",
    [-1] = "Poor",
    [0]  = "Neutral",
    [1]  = "OK",
    [2]  = "Good",
    [3]  = "Great",
    [4]  = "Excellent",
    [5]  = "Legend",
}

-- Rate, tag and write a note in one place. Ratings and tags save as you
-- click, the note when you press Enter or close the window (Done, Escape,
-- Link..., More...), so it stays open until you're finished.
do
    local W = 360
    local BTN_SIZE, BTN_GAP = 32, 3
    local BTN_Y = -66                 -- centre line of the rating buttons
    local CHIP_TOP, CHIP_H, CHIP_GAP = -132, 20, 4
    -- Tags that are a warning, so they light up red instead of green.
    local NEGATIVE = { ["AFK"] = true, ["Ninja looter"] = true, ["Rude"] = true }

    local rp = ratingPicker
    rp:SetSize(W, 200)
    rp:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    rp:SetFrameStrata("FULLSCREEN_DIALOG")
    rp:SetMovable(true)
    rp:EnableMouse(true)
    rp:RegisterForDrag("LeftButton")
    rp:SetClampedToScreen(true)
    rp:SetScript("OnDragStart", function(s) s:StartMoving() end)
    rp:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    rp:Hide()
    if BackdropTemplateMixin then
        Mixin(rp, BackdropTemplateMixin)
        rp:OnBackdropLoaded()
    end
    C.SkinPanel(rp, { edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    rp:SetToplevel(true)
    tinsert(UISpecialFrames, rp:GetName())   -- Escape closes it

    local function Fill(tex, r, g, b, a)
        if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
    end

    local title = rp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", rp, "TOP", 0, -14)

    local bad = rp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bad:SetPoint("TOPLEFT", rp, "TOPLEFT", 18, -32)
    bad:SetText(T.off .. "Avoid|r")
    local good = rp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    good:SetPoint("TOPRIGHT", rp, "TOPRIGHT", -18, -32)
    good:SetText(T.on .. "Great|r")

    -- One line under the buttons: what a button means while you hover it,
    -- otherwise the rating they have now.
    local desc = rp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    desc:SetPoint("TOP", rp, "TOP", 0, BTN_Y - BTN_SIZE / 2 - 12)

    local tagsLabel = rp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tagsLabel:SetPoint("TOPLEFT", rp, "TOPLEFT", 18, CHIP_TOP + 18)
    tagsLabel:SetText(T.soft .. "Tags|r")

    local rateKey
    local buttons, chips = {}, {}

    local function Player() return rateKey and db and db.players[rateKey] end

    local function ShowNow()
        local p = Player()
        if not p then desc:SetText(""); return end
        local r = People.Rating(p)
        desc:SetText(T.dim .. "Now: |r" .. C.RatingIcon(r) .. ColorRating(r) .. "  " .. T.white .. (RATING_LABELS[r] or "") .. "|r")
    end

    local function Decided(p, wasPending)
        if wasPending and not p.pending then
            P(p.name .. " " .. T.on .. "moved to your database.|r")
        end
    end

    -- The note: this character's own (linked characters keep theirs).
    local noteLabel = rp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    noteLabel:SetText(T.soft .. "Note|r  " .. T.dim .. "(saved when you press Enter or close this window)|r")
    local noteBox = CreateFrame("EditBox", "WTFAYRatingPickerNote", rp, "InputBoxTemplate")
    noteBox:SetSize(W - 42, 20)
    noteBox:SetAutoFocus(false)
    noteBox:SetMaxLetters(255)

    local function SaveNote()
        local p = Player()
        if not p then return end
        local text = (noteBox:GetText() or ""):gsub("[\r\n]", " ")
        text = text:trim()
        if text == (p.note or "") then return end
        local wasPending = p.pending
        p.note = text
        if text ~= "" then p.pending = nil end
        local editor = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
        if editor and editor.drafts then editor.drafts[rateKey] = nil end
        P("Note " .. (text == "" and "cleared" or "saved") .. " for " .. p.name .. ".")
        Decided(p, wasPending)
        People.Changed()
    end
    noteBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        SaveNote()
    end)
    noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local totalW = 9 * BTN_SIZE + 8 * BTN_GAP
    local startX = (W - totalW) / 2
    for i = -3, 5 do
        local idx = i + 4
        local btn = CreateFrame("Button", nil, rp)
        btn:SetSize(BTN_SIZE, BTN_SIZE)
        -- Anchored by its centre, so the bigger "current" button grows evenly
        -- instead of spilling over its right-hand neighbour.
        btn:SetPoint("CENTER", rp, "TOPLEFT", startX + (idx - 1) * (BTN_SIZE + BTN_GAP) + BTN_SIZE / 2, BTN_Y)

        local r, g, b
        if i < 0 then
            local pct = (i + 3) / 3            -- 0 at -3, 1 at 0
            r, g, b = 1.0, pct * 0.6, 0
        else
            local pct = i / 5                  -- 0 at 0, 1 at 5
            r, g, b = 1.0 - pct * 0.7, 0.5 + pct * 0.5, 0
        end
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        Fill(bg, r, g, b, 0.85)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Fill(hl, 1, 1, 1, 0.3)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
        label:SetText(T.white .. (i > 0 and "+" or "") .. i .. "|r")

        btn.ratingValue = i
        btn.bgTex = bg
        btn:SetScript("OnEnter", function(self)
            desc:SetText(ColorRating(self.ratingValue) .. "  " .. T.white .. RATING_LABELS[self.ratingValue] .. "|r")
        end)
        btn:SetScript("OnLeave", ShowNow)
        btn:SetScript("OnClick", function(self)
            local ok, err = pcall(function()
                local p = Player()
                D("RatingPicker click: val=" .. self.ratingValue .. " key=" .. tostring(rateKey))
                if not p then return end
                local wasPending = p.pending
                People.SetRating(p, self.ratingValue)
                p.pending = nil
                P(p.name .. " rated " .. ColorRating(self.ratingValue))
                Decided(p, wasPending)
                People.Changed()   -- refreshes this window too
            end)
            if not ok then D("RatingPicker ERROR: " .. tostring(err)) end
        end)
        buttons[idx] = btn
    end

    local function Chip(i)
        if chips[i] then return chips[i] end
        local c = CreateFrame("Button", nil, rp)
        c:SetHeight(CHIP_H)
        c.bg = c:CreateTexture(nil, "BACKGROUND")
        c.bg:SetAllPoints()
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Fill(hl, 1, 1, 1, 0.15)
        c.label = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        c.label:SetPoint("CENTER", c, "CENTER", 0, 0)
        c:SetScript("OnClick", function(self)
            local p = Player()
            if not p then return end
            local wasPending = p.pending
            Tags.Set(p, self.tag, not self.own)
            Decided(p, wasPending)
            People.Changed()
        end)
        c:SetScript("OnEnter", function(self)
            if not self.altOnly and not Tags.IsCustom(self.tag) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tag, 1, 0.82, 0)
            if self.altOnly then
                GameTooltip:AddLine("Tagged on one of their linked characters. Click to tag this one too.", 1, 1, 1, true)
            end
            if Tags.IsCustom(self.tag) then
                GameTooltip:AddLine("Your own tag. Rename or delete it under More...", 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        chips[i] = c
        return c
    end

    -- Lay the tags out like words in a paragraph and size the window to fit.
    local function LayoutChips(p)
        local _, whole = Tags.Of(p)    -- including linked characters'
        local all = Tags.All()
        local x, y = 18, CHIP_TOP
        for i, tag in ipairs(all) do
            local c = Chip(i)
            local own = p.tags and p.tags[tag] and true or false
            c.tag, c.own, c.altOnly = tag, own, (not own and whole[tag]) and true or false
            if own then
                if NEGATIVE[tag] then Fill(c.bg, 0.6, 0.12, 0.08, 0.95) else Fill(c.bg, 0.16, 0.48, 0.16, 0.95) end
                c.label:SetText(T.white .. tag .. "|r")
            else
                Fill(c.bg, 0.12, 0.12, 0.12, 0.85)
                local color = c.altOnly and T.manual or (Tags.IsCustom(tag) and T.light or T.dim)
                c.label:SetText(color .. tag .. (c.altOnly and "*" or "") .. "|r")
            end
            local w = math.floor((c.label:GetStringWidth() or 40) + 14)
            if x > 18 and x + w > W - 18 then
                x, y = 18, y - CHIP_H - CHIP_GAP
            end
            c:SetWidth(w)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", rp, "TOPLEFT", x, y)
            c:Show()
            x = x + w + CHIP_GAP
        end
        for i = #all + 1, #chips do chips[i]:Hide() end
        -- The note goes under the tags; the buttons sit at the bottom.
        local noteTop = y - CHIP_H - 12
        noteLabel:ClearAllPoints()
        noteLabel:SetPoint("TOPLEFT", rp, "TOPLEFT", 18, noteTop)
        noteBox:ClearAllPoints()
        noteBox:SetPoint("TOPLEFT", rp, "TOPLEFT", 24, noteTop - 16)
        rp:SetHeight(-(noteTop - 16 - 20) + 12 + 22 + 14)
    end

    function rp.Refresh()
        local p = Player()
        if not p then rp:Hide(); return end
        local linkedCount = #People.Others(p)
        title:SetText("Rate " .. ClassColor(p.class) .. p.name .. "|r"
            .. (linkedCount > 0 and (T.dim .. " + " .. linkedCount .. " linked|r") or ""))
        local current = People.Rating(p)
        for _, btn in ipairs(buttons) do
            if btn.ratingValue == current then
                btn.bgTex:SetAlpha(1.0)
                btn:SetSize(BTN_SIZE + 6, BTN_SIZE + 6)
            else
                btn.bgTex:SetAlpha(0.6)
                btn:SetSize(BTN_SIZE, BTN_SIZE)
            end
        end
        ShowNow()
        LayoutChips(p)
    end

    local doneBtn = CreateFrame("Button", nil, rp, C.ButtonTemplate)
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", rp, "BOTTOM", 0, 12)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() rp:Hide() end)

    -- This window is what the game's right-click menu opens, so it's also the
    -- quickest route to "this is someone's alt" for a player you've just met.
    local linkBtn = CreateFrame("Button", nil, rp, C.ButtonTemplate)
    linkBtn:SetSize(70, 22)
    linkBtn:SetPoint("RIGHT", doneBtn, "LEFT", -6, 0)
    linkBtn:SetText("Link...")
    linkBtn:SetScript("OnClick", function()
        local key = rateKey
        rp:Hide()
        People.ShowPicker(key)
    end)

    -- Nickname, and adding / renaming / deleting your own tags.
    local moreBtn = CreateFrame("Button", nil, rp, C.ButtonTemplate)
    moreBtn:SetSize(70, 22)
    moreBtn:SetPoint("LEFT", doneBtn, "RIGHT", 6, 0)
    moreBtn:SetText("More...")
    moreBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Tags & Nickname", 1, 0.82, 0)
        GameTooltip:AddLine("Give them a nickname, or add, rename and delete tags of your own.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    moreBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    moreBtn:SetScript("OnClick", function()
        local key = rateKey
        rp:Hide()
        if Tags.ShowPicker then Tags.ShowPicker(key) end
    end)

    -- However it closes, the note is kept: Done, Escape, Link..., More...
    rp:SetScript("OnHide", function()
        noteBox:ClearFocus()
        SaveNote()
    end)

    ShowRatingPicker = function(key)
        local p = key and db and db.players[key]
        if not p then return end
        -- Opening it for someone else keeps what was typed for the last one.
        if rp:IsShown() and rateKey and rateKey ~= key then SaveNote() end
        popupActiveKey = key
        rateKey = key
        -- An unsaved draft from the note editor wins over the stored note.
        local editor = StaticPopupDialogs["WTFAY_EDIT_NOTE"]
        noteBox:SetText((editor and editor.drafts and editor.drafts[key]) or p.note or "")
        rp.Refresh()
        rp:Show()
    end
end

StaticPopupDialogs["WTFAY_CONFIRM_REMOVE"] = {
    text = "Remove " .. T.dangerSoft .. "%s|r from WTFAY?",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self)
        local ok, err = pcall(function()
            local key = popupActiveKey
            D("WTFAY_CONFIRM_REMOVE OnAccept: key=" .. tostring(key))
            if key and db and db.players[key] then
                local name = db.players[key].name
                People.Unlink(key)
                db.players[key] = nil
                P("Removed " .. name)
                RefreshList()
            end
        end)
        if not ok then D("CONFIRM_REMOVE OnAccept ERROR: " .. tostring(err)) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

D("popups OK")

----------------------------------------------------------------------
-- Player Detail Panel (left-click a row to open)
----------------------------------------------------------------------
local ENCOUNTERS_PER_PAGE = 25
local detailCurrentKey = nil
local detailPage = 1

local detail = C.CreateWindow("WTFAYDetailPanel", UIParent)
detail:SetSize(340, 400)   -- +20 for the "Met in ..." line
detail:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
detail:SetFrameStrata("FULLSCREEN_DIALOG")
detail:SetMovable(true)
detail:EnableMouse(true)
detail:RegisterForDrag("LeftButton")
detail:SetClampedToScreen(true)
detail:SetScript("OnDragStart", function(s) s:StartMoving() end)
detail:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
detail:Hide()

if BackdropTemplateMixin then
    Mixin(detail, BackdropTemplateMixin)
    detail:OnBackdropLoaded()
end
-- Chrome: C.SkinWindow below, once title and close button exist.

-- Close on Escape
do
    local nm = detail:GetName()
    if nm then tinsert(UISpecialFrames, nm) end
end

-- Close button
local detailClose = CreateFrame("Button", nil, detail, "UIPanelCloseButton")
detailClose:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -2, -2)

-- Player name title
local detailTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
detailTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 14, -14)
C.SkinWindow(detail, { title = detailTitle, close = detailClose, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })

-- Info line (race, class, level, realm)
local detailInfo = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
detailInfo:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -4)

-- Rating + note
local detailRating = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
detailRating:SetPoint("TOPLEFT", detailInfo, "BOTTOMLEFT", 0, -6)

local detailNote = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
detailNote:SetPoint("TOPLEFT", detailRating, "BOTTOMLEFT", 0, -4)
detailNote:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
detailNote:SetJustifyH("LEFT")
detailNote:SetWordWrap(true)

-- Encounter history header
local encHeader = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
-- Where you first met (zone, their level, yours). Sits between the note and
-- the history, so the history header now hangs off it.
local detailMet = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
detailMet:SetPoint("TOPLEFT", detailNote, "BOTTOMLEFT", 0, -6)
detailMet:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
detailMet:SetJustifyH("LEFT")
detailMet:SetWordWrap(false)

-- "Same player: Felcaster (main), Natureboi". Left-click a name to open that
-- character, right-click for its menu. Collapses to nothing when unlinked.
do
    local peopleRow = CreateFrame("Frame", nil, detail)
    peopleRow:SetPoint("TOPLEFT", detailMet, "BOTTOMLEFT", 0, -4)
    peopleRow:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    peopleRow:SetHeight(1)
    detail.peopleRow = peopleRow

    local label = peopleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", peopleRow, "LEFT", 0, 0)
    label:SetText(T.accent .. "Same player:|r")

    local more = peopleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    local buttons = {}
    local function NameButton(i)
        local b = buttons[i]
        if b then return b end
        b = CreateFrame("Button", nil, peopleRow)
        b:SetHeight(16)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetPoint("LEFT", b, "LEFT", 0, 0)
        b:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" then
                RowMenu(self)
            elseif self.playerKey then
                ShowDetailPanel(self.playerKey)
            end
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Left-click to open, right-click for options", 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buttons[i] = b
        return b
    end

    -- Returns true when the row is showing.
    function detail.RefreshPeopleRow(p)
        local others, keys = People.Others(p)
        for _, b in ipairs(buttons) do b:Hide() end
        more:SetText("")
        if #others == 0 then
            peopleRow:SetHeight(1)
            label:Hide()
            return false
        end
        peopleRow:SetHeight(18)
        label:Show()

        local AVAILABLE, used, shown = 312, label:GetStringWidth() + 6, 0
        local prev = label
        for i, other in ipairs(others) do
            local b = NameButton(i)
            local isMain = People.IsMain(other)
            b.playerKey = keys[i]
            b.text:SetText(ClassColor(other.class) .. other.name .. "|r" .. (isMain and (T.dim .. " (main)|r") or ""))
            local width = b.text:GetStringWidth() + 8
            if used + width > AVAILABLE and shown > 0 then break end
            b:SetWidth(width)
            b:ClearAllPoints()
            b:SetPoint("LEFT", prev, "RIGHT", 6, 0)
            b:Show()
            used, shown, prev = used + width, shown + 1, b
        end
        if shown < #others then
            more:ClearAllPoints()
            more:SetPoint("LEFT", prev, "RIGHT", 4, 0)
            more:SetText(T.dim .. "+" .. (#others - shown) .. "|r")
        end
        return true
    end
end

encHeader:SetPoint("TOPLEFT", detail.peopleRow, "BOTTOMLEFT", 0, -8)
encHeader:SetText("|cFF" .. ACCENT .. "Encounter History|r")

-- Encounter count
local encCount = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
encCount:SetPoint("LEFT", encHeader, "RIGHT", 8, 0)

-- Separator line
local encSep = detail:CreateTexture(nil, "ARTWORK")
encSep:SetHeight(1)
encSep:SetPoint("TOPLEFT", encHeader, "BOTTOMLEFT", 0, -4)
encSep:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
if encSep.SetColorTexture then
    encSep:SetColorTexture(unpack(C.Theme.sep))
else
    encSep:SetTexture(0.3, 0.3, 0.3, 0.8)
end

-- Encounter list: use font strings in a scrollable area
local ENC_ROW_HEIGHT = 18
local MAX_VISIBLE_ENC = 12
local encRows = {}

local encContainer = CreateFrame("Frame", nil, detail)
encContainer:SetPoint("TOPLEFT", encSep, "BOTTOMLEFT", 0, -4)
encContainer:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
encContainer:SetHeight(MAX_VISIBLE_ENC * ENC_ROW_HEIGHT)

do
    -- Full details of one encounter on hover; the row itself is kept short.
    local function ShowEncounterTooltip(row)
        local e = row.entry
        if not e then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        local where = e.zone or (e.remote and "Added by name" or "Unknown location")
        if e.subzone then where = where .. " - " .. e.subzone end
        GameTooltip:SetText(where, 1, 0.82, 0)
        GameTooltip:AddLine((e.time or "?") .. "  (" .. (e.source or "?") .. ")", 0.8, 0.8, 0.8)
        if row.owner then GameTooltip:AddLine("As " .. row.owner.name, 1, 1, 1) end
        if e.role and ROLE_LABELS[e.role] then GameTooltip:AddLine("Role: " .. ROLE_LABELS[e.role], 1, 1, 1) end
        -- One entry covers the whole time you stayed grouped (see LogEncounter).
        local mins = (e.till and e._ts) and math.floor((e.till - e._ts) / 60) or 0
        if mins >= 1 then
            GameTooltip:AddLine("Grouped for " .. Outings.FormatDuration(e.till - e._ts) .. ", until " .. date("%H:%M", e.till), 1, 1, 1)
        end
        -- Who else was in that group, and what you noted about the group.
        local o = Outings.Get(e.outing)
        if o then
            local with = Outings.WithText(o, row.ownerKey, 6)
            if with ~= "" then GameTooltip:AddLine("With " .. with, 1, 1, 1, true) end
            if o.note then GameTooltip:AddLine(T.dim .. "Group note: |r" .. o.note, 1, 1, 1, true) end
        end
        if e.lvl then GameTooltip:AddLine("They were level " .. e.lvl, 1, 1, 1) end
        if e.myLvl then GameTooltip:AddLine("You were level " .. e.myLvl, 1, 1, 1) end
        if e.remote then
            GameTooltip:AddLine("You weren't grouped, so no location was recorded.", 0.6, 0.6, 0.6, true)
        elseif not e.lvl and not e.myLvl then
            GameTooltip:AddLine("Logged before WTFAY recorded levels.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end

    for i = 1, MAX_VISIBLE_ENC do
        local row = CreateFrame("Frame", nil, encContainer)
        row:SetHeight(ENC_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", encContainer, "TOPLEFT", 0, -((i - 1) * ENC_ROW_HEIGHT))
        row:SetPoint("RIGHT", encContainer, "RIGHT", 0, 0)
        row:EnableMouse(true)

        -- Levels on the right; the description takes the rest and truncates.
        row.levels = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.levels:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.levels:SetJustifyH("RIGHT")

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.text:SetPoint("RIGHT", row.levels, "LEFT", -6, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)

        row:SetScript("OnEnter", ShowEncounterTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Hide()
        encRows[i] = row
    end
end

-- Page navigation
local pageInfo = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pageInfo:SetPoint("BOTTOM", detail, "BOTTOM", 0, 30)

local prevBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
prevBtn:SetSize(60, 20)
prevBtn:SetPoint("RIGHT", pageInfo, "LEFT", -8, 0)
prevBtn:SetText("Newer")
prevBtn:SetNormalFontObject(GameFontNormalSmall)

local nextBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
nextBtn:SetSize(60, 20)
nextBtn:SetPoint("LEFT", pageInfo, "RIGHT", 8, 0)
nextBtn:SetText("Older")
nextBtn:SetNormalFontObject(GameFontNormalSmall)

-- Action buttons at bottom
local detailRateBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
detailRateBtn:SetSize(56, 20)
detailRateBtn:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", 10, 8)
detailRateBtn:SetText("Rate")
detailRateBtn:SetNormalFontObject(GameFontNormalSmall)
detailRateBtn:SetScript("OnClick", function()
    if detailCurrentKey then ShowRatingPicker(detailCurrentKey) end
end)

local detailNoteBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
detailNoteBtn:SetSize(72, 20)
detailNoteBtn:SetPoint("LEFT", detailRateBtn, "RIGHT", 4, 0)
detailNoteBtn:SetText("Edit Note")
detailNoteBtn:SetNormalFontObject(GameFontNormalSmall)
detailNoteBtn:SetScript("OnClick", function()
    if detailCurrentKey and db and db.players[detailCurrentKey] then
        popupActiveKey = detailCurrentKey
        StaticPopup_Show("WTFAY_EDIT_NOTE", db.players[detailCurrentKey].name)
    end
end)

-- Tags and nickname, between the note and Remove.
do
    local detailTagsBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
    detailTagsBtn:SetSize(50, 20)
    detailTagsBtn:SetPoint("LEFT", detailNoteBtn, "RIGHT", 4, 0)
    detailTagsBtn:SetText("Tags...")
    detailTagsBtn:SetNormalFontObject(GameFontNormalSmall)
    detailTagsBtn:SetScript("OnClick", function()
        if detailCurrentKey and Tags.ShowPicker then Tags.ShowPicker(detailCurrentKey) end
    end)
    detail.tagsBtn = detailTagsBtn
end

local detailRemoveBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
detailRemoveBtn:SetSize(64, 20)
detailRemoveBtn:SetPoint("LEFT", detail.tagsBtn, "RIGHT", 4, 0)
detailRemoveBtn:SetText(T.off .. "Remove|r")
detailRemoveBtn:SetNormalFontObject(GameFontNormalSmall)
-- Two clicks within 3s; the row context menu keeps its popup, since a menu
-- closes on the first click and can't arm.
C.ArmConfirm(detailRemoveBtn, function()
    if detailCurrentKey and db and db.players[detailCurrentKey] then
        popupActiveKey = detailCurrentKey
        local dlg = StaticPopupDialogs["WTFAY_CONFIRM_REMOVE"]
        if dlg and dlg.OnAccept then dlg.OnAccept() end
    end
end)

-- Link to another character (or, once linked, unlink from the same window).
do
    local detailLinkBtn = CreateFrame("Button", nil, detail, C.ButtonTemplate)
    detailLinkBtn:SetSize(56, 20)
    detailLinkBtn:SetPoint("LEFT", detailRemoveBtn, "RIGHT", 4, 0)
    detailLinkBtn:SetText("Link...")
    detailLinkBtn:SetNormalFontObject(GameFontNormalSmall)
    detailLinkBtn:SetScript("OnClick", function()
        if detailCurrentKey then People.ShowPicker(detailCurrentKey) end
    end)
end

-- Refresh the detail panel for the current player and page
local function RefreshDetailPanel()
    local key = detailCurrentKey
    if not key or not db or not db.players[key] then
        detail:Hide()
        return
    end

    local p = db.players[key]
    local cc = ClassColor(p.class)

    local nick = Tags.Nick(p)
    detailTitle:SetText(cc .. p.name .. "|r" .. (nick and ("  " .. T.soft .. "\"" .. nick .. "\"|r") or ""))

    local raceStr = (p.race and p.race ~= "") and (p.race .. " ") or ""
    local guildStr = (p.guild and p.guild ~= "") and ("  " .. T.guild .. "<" .. p.guild .. ">|r") or ""
    local zoneStr  = (p.zone and p.zone ~= "") and ("  " .. T.faint .. "seen in " .. p.zone .. "|r") or ""
    detailInfo:SetText(T.soft .. "Lv " .. (p.level or "?") .. "  " .. raceStr .. "|r" .. cc .. (p.class or "Unknown") .. "|r  " .. T.dim .. (p.realm or "") .. "|r" .. guildStr .. zoneStr)

    local roles = People.RoleSummary(p)
    detailRating:SetText("Rating: " .. C.RatingIcon(People.Rating(p)) .. ColorRating(People.Rating(p)) .. "  " .. T.muted .. (RATING_LABELS[People.Rating(p)] or "") .. "|r"
        .. (roles and ("    " .. T.soft .. roles .. "|r") or ""))

    -- Tags, their own note, then what you wrote on their other characters.
    local noteLines = {}
    local tagText = Tags.Text(p)
    if tagText then noteLines[1] = T.manual .. "Tags: " .. tagText .. "|r" end
    if p.note and p.note ~= "" then noteLines[#noteLines + 1] = T.text .. p.note .. "|r" end
    for _, other in ipairs(People.OtherNotes(p)) do
        noteLines[#noteLines + 1] = T.dim .. other.name .. ": |r" .. T.text .. other.note .. "|r"
    end
    if #noteLines > 0 then
        detailNote:SetText(table.concat(noteLines, "\n"))
    else
        detailNote:SetText(T.faint .. "(no note)|r")
    end

    local linked = detail.RefreshPeopleRow(p)

    -- Encounters: display newest first, across all of this player's characters
    local enc, owners = People.Encounters(p)
    local totalEnc = #enc
    encCount:SetText(T.dim .. "(" .. totalEnc .. " total" .. (owners and ", all characters" or "") .. ")|r")

    -- Grow for the "Same player" row and for notes running past one line, so
    -- neither pushes the history into the buttons at the bottom.
    local noteHeight = detailNote:GetStringHeight() or 0
    detail:SetHeight(400 + (linked and 20 or 0) + math.max(0, noteHeight - 14))

    local met = MetLineFor(p)
    detailMet:SetText(met and (T.brass .. met .. "|r") or "")

    local totalPages = math.max(1, math.ceil(totalEnc / ENCOUNTERS_PER_PAGE))
    if detailPage > totalPages then detailPage = totalPages end
    if detailPage < 1 then detailPage = 1 end

    -- Page slice: newest first, so page 1 = last entries in the array
    local startIdx = totalEnc - (detailPage - 1) * ENCOUNTERS_PER_PAGE
    local endIdx   = math.max(1, startIdx - MAX_VISIBLE_ENC + 1)

    local srcColors = {
        raid    = "FF6699",
        dungeon = "66BBFF",
        group   = "99FF66",
        manual  = "FFCC44",
    }

    local visibleCount = 0
    for i = startIdx, endIdx, -1 do
        visibleCount = visibleCount + 1
        local e = enc[i]
        if e then
            local sc = srcColors[e.source or "manual"] or "CCCCCC"
            local num = totalEnc - i + 1  -- encounter number, newest = 1
            local row = encRows[visibleCount]
            -- Year dropped to make room for the place; the tooltip has the full stamp.
            local when = (e.time or "?"):gsub("^%d+%-", "")
            local zoneStr = (e.zone and e.zone ~= "") and ("  " .. T.brass .. e.zone .. "|r") or ""
            -- In a merged history, say when it was on another character.
            local owner = owners and owners[e]
            local ownerStr = (owner and owner ~= p) and (ClassColor(owner.class) .. owner.name .. "|r  ") or ""
            local roleStr = (e.role and ROLE_LABELS[e.role]) and (T.soft .. " " .. ROLE_LABELS[e.role] .. "|r") or ""
            row.text:SetText(T.faint .. "#" .. num .. "|r  " .. ownerStr .. T.light .. when .. "|r  |cFF" .. sc .. (e.source or "?") .. "|r" .. roleStr .. zoneStr)
            local lv = ""
            if e.lvl then lv = T.soft .. "Lv " .. e.lvl .. "|r" end
            if e.myLvl then lv = lv .. (lv ~= "" and "  " or "") .. T.dim .. "you " .. e.myLvl .. "|r" end
            row.levels:SetText(lv)
            row.entry = e
            row.owner = owner
            -- The key of whoever this line belongs to, so "With" leaves them out.
            row.ownerKey = key
            if owner and owner ~= p then
                for _, k in ipairs((People.Of(p) or {}).members or {}) do
                    if db.players[k] == owner then row.ownerKey = k end
                end
            end
            row:Show()
        end
    end

    -- Check if this page has more entries beyond what's visible
    local pageEntries = startIdx - math.max(1, startIdx - ENCOUNTERS_PER_PAGE + 1) + 1
    local hasMoreOnPage = pageEntries > MAX_VISIBLE_ENC

    -- Hide unused rows
    for i = visibleCount + 1, MAX_VISIBLE_ENC do
        encRows[i]:Hide()
    end

    -- Page info and buttons
    if totalPages > 1 or hasMoreOnPage then
        pageInfo:SetText(T.muted .. detailPage .. " / " .. totalPages .. "|r")
        pageInfo:Show()
        prevBtn:SetShown(detailPage > 1)
        nextBtn:SetShown(detailPage < totalPages)
    else
        pageInfo:Hide()
        prevBtn:Hide()
        nextBtn:Hide()
    end
end

prevBtn:SetScript("OnClick", function()
    detailPage = detailPage - 1
    RefreshDetailPanel()
end)

nextBtn:SetScript("OnClick", function()
    detailPage = detailPage + 1
    RefreshDetailPanel()
end)

ShowDetailPanel = function(key)
    if not key or not db or not db.players[key] then return end
    detailCurrentKey = key
    detailPage = 1
    -- Shown first: a wrapped note's height is only right once it's laid out.
    detail:Show()
    RefreshDetailPanel()
end

D("detail panel OK")

----------------------------------------------------------------------
-- People: refreshing, and the "Link to..." picker
----------------------------------------------------------------------
People.Changed = function()
    RefreshList()
    if RefreshInbox then RefreshInbox() end
    UpdateInboxTabLabel()
    if detail:IsShown() then RefreshDetailPanel() end
    if Outings.recapFrame and Outings.recapFrame:IsShown() then Outings.RefreshRecap() end
    if Outings.tabFrame and Outings.tabFrame:IsShown() and Outings.RefreshTab then Outings.RefreshTab() end
    if ratingPicker:IsShown() then ratingPicker.Refresh() end
end

do
    local PICK_ROWS, PICK_ROW_H = 8, 24
    local pickKey, pickOffset, pickMatches = nil, 0, {}

    local picker = CreateFrame("Frame", "WTFAYLinkPicker", UIParent)
    picker:SetSize(340, 100 + PICK_ROWS * PICK_ROW_H + 44)
    picker:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetMovable(true)
    picker:EnableMouse(true)
    picker:RegisterForDrag("LeftButton")
    picker:SetClampedToScreen(true)
    picker:SetScript("OnDragStart", function(s) s:StartMoving() end)
    picker:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    picker:Hide()
    C.SkinPanel(picker, { edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    picker:SetToplevel(true)
    tinsert(UISpecialFrames, picker:GetName())

    local close = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -2, -2)

    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", picker, "TOPLEFT", 16, -16)
    title:SetPoint("RIGHT", picker, "RIGHT", -30, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    local hint = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetText(T.dim .. "Pick another character played by the same person.|r")

    local search = CreateFrame("EditBox", "WTFAYLinkPickerSearch", picker, C.SearchBoxTemplate)
    search:SetSize(306, 22)
    search:SetPoint("TOPLEFT", picker, "TOPLEFT", 18, -58)
    search:SetAutoFocus(false)
    search:SetFontObject(ChatFontNormal)
    search:SetMaxLetters(40)
    if search.Instructions then search.Instructions:SetText("Search players") end

    local rows = {}
    local unlinkBtn

    local function Rebuild()
        wipe(pickMatches)
        local source = pickKey and db and db.players[pickKey]
        if not source then return end
        local text = (search:GetText() or ""):lower()
        for key, p in pairs(db.players) do
            local sameNow = (key == pickKey) or (source.personId and p.personId == source.personId)
            if not sameNow and (text == "" or (p.name or ""):lower():find(text, 1, true)) then
                pickMatches[#pickMatches + 1] = key
            end
        end
        table.sort(pickMatches, function(a, b)
            local pa, pb = db.players[a], db.players[b]
            local sa, sb = pa.seen or "", pb.seen or ""
            if sa ~= sb then return sa > sb end
            return (pa.name or "") < (pb.name or "")
        end)
    end

    local function Draw()
        local maxOffset = math.max(0, #pickMatches - PICK_ROWS)
        pickOffset = math.max(0, math.min(pickOffset, maxOffset))
        for i, row in ipairs(rows) do
            local key = pickMatches[pickOffset + i]
            local p = key and db.players[key]
            row.playerKey = key
            if p then
                local tag = People.Tag(p)
                row.nameText:SetText(ClassColor(p.class) .. p.name .. "|r"
                    .. (tag and ("  " .. T.dim .. "(" .. tag .. ")|r") or ""))
                row.infoText:SetText(ColorRating(People.Rating(p)))
                row:Show()
            else
                row:Hide()
            end
        end
    end

    local function Refresh()
        Rebuild()
        pickOffset = 0
        Draw()
    end

    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, picker)
        row:SetHeight(PICK_ROW_H)
        row:SetPoint("TOPLEFT", picker, "TOPLEFT", 14, -84 - (i - 1) * PICK_ROW_H)
        row:SetPoint("RIGHT", picker, "RIGHT", -14, 0)
        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp")

        local lit = row:CreateTexture(nil, "BACKGROUND")
        lit:SetAllPoints(row)
        lit:SetColorTexture(1, 1, 1, 0.08)
        lit:Hide()

        row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.infoText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.infoText:SetJustifyH("RIGHT")

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.nameText:SetPoint("RIGHT", row.infoText, "LEFT", -8, 0)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        row:SetScript("OnEnter", function() lit:Show() end)
        row:SetScript("OnLeave", function() lit:Hide() end)
        row:SetScript("OnClick", function(self)
            local source, target = pickKey, self.playerKey
            if source and target then
                picker:Hide()
                People.LinkAndReport(source, target)
            end
        end)
        rows[i] = row
    end

    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(_, delta)
        pickOffset = pickOffset - delta * (IsShiftKeyDown() and PICK_ROWS or 1)
        Draw()
    end)

    C.HookSearchBoxChanged(search, Refresh)

    unlinkBtn = CreateFrame("Button", nil, picker, C.ButtonTemplate)
    unlinkBtn:SetSize(190, 22)
    unlinkBtn:SetPoint("BOTTOM", picker, "BOTTOM", 0, 12)
    unlinkBtn:SetScript("OnClick", function()
        local key = pickKey
        picker:Hide()
        if key then People.UnlinkAndReport(key) end
    end)

    function People.ShowPicker(key)
        local p = key and db and db.players[key]
        if not p then return end
        pickKey = key
        title:SetText("Link " .. ClassColor(p.class) .. p.name .. "|r to:")
        unlinkBtn:SetShown(People.Of(p) ~= nil)
        unlinkBtn:SetText("Unlink " .. p.name)
        search:SetText("")
        Refresh()
        picker:Show()
        search:SetFocus()
    end
end

----------------------------------------------------------------------
-- Tags & nickname window
--
-- Tick tags for one character, type a nickname (saved as you type), add a
-- tag of your own, or right-click one of yours to rename or delete it. The
-- bottom row switches between those three jobs (add / rename / delete).
----------------------------------------------------------------------
do
    local COL_W, ROW_H, TOP = 150, 22, 92
    local pickKey
    local mode, modeTag = "add", nil

    local frame = CreateFrame("Frame", "WTFAYTagPicker", UIParent)
    frame:SetSize(340, 240)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(s) s:StartMoving() end)
    frame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    frame:Hide()
    C.SkinPanel(frame, { edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    frame:SetToplevel(true)
    tinsert(UISpecialFrames, frame:GetName())

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -16)
    title:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    local nickLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nickLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -46)
    nickLabel:SetText(T.soft .. "Nickname:|r")

    local nickBox = CreateFrame("EditBox", "WTFAYTagPickerNick", frame, "InputBoxTemplate")
    nickBox:SetSize(200, 20)
    nickBox:SetPoint("LEFT", nickLabel, "RIGHT", 12, 0)
    nickBox:SetAutoFocus(false)
    nickBox:SetMaxLetters(32)
    nickBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nickBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local tagsLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tagsLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -72)
    tagsLabel:SetText(T.soft .. "Tags:|r  " .. T.dim .. "(right-click one of yours to rename or delete it)|r")

    local modeLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeLabel:SetJustifyH("LEFT")
    local newBox = CreateFrame("EditBox", "WTFAYTagPickerNew", frame, "InputBoxTemplate")
    newBox:SetSize(150, 20)
    newBox:SetAutoFocus(false)
    newBox:SetMaxLetters(Tags.MAX_LEN)
    newBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local actionBtn = CreateFrame("Button", nil, frame, C.ButtonTemplate)
    actionBtn:SetSize(64, 20)
    local cancelBtn = CreateFrame("Button", nil, frame, C.ButtonTemplate)
    cancelBtn:SetSize(60, 20)
    cancelBtn:SetText("Cancel")
    local doneBtn = CreateFrame("Button", nil, frame, C.ButtonTemplate)
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 12)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() frame:Hide() end)

    local checks = {}
    local Layout, SetMode

    local function Player() return pickKey and db and db.players[pickKey] end

    local function Check(i)
        if checks[i] then return checks[i] end
        local cb = C.CreateCheckbox(frame)
        cb:SetSize(20, 20)
        cb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cb.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        cb.label:SetWidth(COL_W - 26)
        cb.label:SetJustifyH("LEFT")
        cb.label:SetWordWrap(false)
        cb:SetScript("OnClick", function(self, mouse)
            local p = Player()
            if not p then return end
            if mouse == "RightButton" then
                self:SetChecked(not self:GetChecked())   -- a right-click isn't a toggle
                if Tags.IsCustom(self.tag) then
                    local tag = self.tag
                    C.ShowContextMenu(self, {
                        { text = tag, isTitle = true },
                        { text = "Rename...", func = function() SetMode("rename", tag) end },
                        { text = T.off .. "Delete...|r", func = function() SetMode("delete", tag) end },
                        { text = "Cancel" },
                    })
                end
                return
            end
            Tags.Set(p, self.tag, self:GetChecked())
            People.Changed()
            Layout()
        end)
        cb:SetScript("OnEnter", function(self)
            if not Tags.IsCustom(self.tag) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tag, 1, 0.82, 0)
            GameTooltip:AddLine("Your own tag. Right-click to rename or delete it.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        checks[i] = cb
        return cb
    end

    Layout = function()
        local p = Player()
        if not p then return end
        local all = Tags.All()
        local _, whole = Tags.Of(p)   -- including linked characters'
        for i, tag in ipairs(all) do
            local cb = Check(i)
            local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", frame, "TOPLEFT", 16 + col * COL_W, -TOP - row * ROW_H)
            cb.tag = tag
            local own = p.tags and p.tags[tag]
            cb:SetChecked(own and true or false)
            local color = Tags.IsCustom(tag) and T.manual or T.light
            cb.label:SetText(color .. tag .. "|r" .. ((not own and whole[tag]) and (T.dim .. " (alt)|r") or ""))
            cb:Show()
            cb.label:Show()
        end
        for i = #all + 1, #checks do
            checks[i]:Hide()
            checks[i].label:Hide()
        end
        local rows = math.ceil(#all / 2)
        local y = -TOP - rows * ROW_H - 10
        modeLabel:ClearAllPoints()
        modeLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, y - 4)
        newBox:ClearAllPoints()
        newBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 92, y)
        actionBtn:ClearAllPoints()
        if mode == "delete" then
            -- The question takes the whole line, so its buttons go underneath.
            actionBtn:SetPoint("TOPLEFT", modeLabel, "BOTTOMLEFT", 0, -6)
        else
            actionBtn:SetPoint("LEFT", newBox, "RIGHT", 6, 0)
        end
        cancelBtn:ClearAllPoints()
        cancelBtn:SetPoint("LEFT", actionBtn, "RIGHT", 4, 0)
        frame:SetHeight(-y + 64 + (mode == "delete" and 26 or 0))
    end

    SetMode = function(newMode, tag)
        mode, modeTag = newMode, tag
        newBox:ClearFocus()
        if mode == "rename" then
            modeLabel:SetText(T.soft .. "Rename to:|r")
            newBox:SetText(tag or "")
            newBox:Show()
            actionBtn:SetText("Rename")
            cancelBtn:Show()
            newBox:SetFocus()
            newBox:HighlightText()
        elseif mode == "delete" then
            local n = 0
            for _, p in pairs(db.players) do
                if p.tags and p.tags[tag] then n = n + 1 end
            end
            modeLabel:SetText(T.soft .. "Delete \"" .. tag .. "\"? It's on " .. n .. " player" .. (n == 1 and "" or "s") .. ".|r")
            newBox:Hide()
            actionBtn:SetText(T.off .. "Delete|r")
            cancelBtn:Show()
        else
            mode, modeTag = "add", nil
            modeLabel:SetText(T.soft .. "New tag:|r")
            newBox:SetText("")
            newBox:Show()
            actionBtn:SetText("Add")
            cancelBtn:Hide()
        end
        Layout()
    end

    local function DoAction()
        local p = Player()
        if not p then return end
        if mode == "add" then
            local tag, why = Tags.AddCustom(newBox:GetText())
            if not tag then
                if why ~= "empty" then P("Can't add that tag: " .. why .. ".") end
                return
            end
            Tags.Set(p, tag, true)
            P("New tag " .. T.manual .. tag .. "|r added to " .. p.name .. ".")
        elseif mode == "rename" then
            local ok, why = Tags.Rename(modeTag, newBox:GetText())
            if not ok then P("Can't rename that tag: " .. why .. "."); return end
            P("Tag renamed everywhere it was used.")
        elseif mode == "delete" then
            local n = Tags.Remove(modeTag)
            P("Tag " .. T.manual .. modeTag .. "|r deleted (" .. n .. " player" .. (n == 1 and "" or "s") .. ").")
        end
        -- A renamed or deleted tag can't stay the list filter.
        if mode ~= "add" and listFilters.tag == modeTag then
            listFilters.tagBtn.idx = 1
            listFilters.tagBtn:Show1()
        end
        SetMode("add")
        People.Changed()
    end
    actionBtn:SetScript("OnClick", DoAction)
    newBox:SetScript("OnEnterPressed", DoAction)
    cancelBtn:SetScript("OnClick", function() SetMode("add") end)

    nickBox:SetScript("OnTextChanged", function(self, userInput)
        local p = Player()
        if not (userInput and p) then return end
        Tags.SetNick(p, self:GetText())
        People.Changed()
    end)

    function Tags.ShowPicker(key)
        local p = key and db and db.players[key]
        if not p then return end
        pickKey = key
        title:SetText("Tags for " .. ClassColor(p.class) .. p.name .. "|r")
        nickBox:SetText(p.nick or "")
        SetMode("add")
        frame:Show()
    end
    Tags.pickerFrame = frame
end

----------------------------------------------------------------------
-- Rate-your-group card
--
-- Everyone from one group, each with a row of rating buttons, so a whole
-- dungeon can be rated in a few clicks. Opens by itself when a group ends
-- (if "Rate Your Group Afterwards" is on, and never during combat), from
-- the Groups tab, or with /wtfay recap.
----------------------------------------------------------------------
do
    local MAX_ROWS, ROW_H, BTN = 10, 24, 18
    local recapId

    local card = CreateFrame("Frame", "WTFAYRecap", UIParent)
    card:SetSize(420, 120)
    card:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    -- DIALOG like the main window (so it opens on top of the Groups tab) and
    -- not FULLSCREEN_DIALOG, so the note popups it opens can draw above it.
    card:SetFrameStrata("DIALOG")
    card:SetMovable(true)
    card:EnableMouse(true)
    card:RegisterForDrag("LeftButton")
    card:SetClampedToScreen(true)
    card:SetScript("OnDragStart", function(s) s:StartMoving() end)
    card:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    card:Hide()
    C.SkinPanel(card, { edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    card:SetToplevel(true)
    tinsert(UISpecialFrames, card:GetName())

    local close = CreateFrame("Button", nil, card, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -2)

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -14)
    title:SetText("|cFF" .. ACCENT .. "Rate your group|r")
    local sub = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetPoint("RIGHT", card, "RIGHT", -30, 0)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)

    local more = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- When the card pops up by itself, say how to stop it doing that.
    local hint = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 42)
    hint:SetPoint("RIGHT", card, "RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(T.dim .. "Opens whenever a group ends. Turn it off under Settings > General > Rate Your Group Afterwards.|r")
    local auto = false
    local noteBtn = CreateFrame("Button", nil, card, C.ButtonTemplate)
    noteBtn:SetSize(90, 22)
    noteBtn:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 14, 12)
    noteBtn:SetText("Group Note")
    noteBtn:SetScript("OnClick", function()
        Outings.editingId = recapId
        StaticPopup_Show("WTFAY_EDIT_GROUP_NOTE")
    end)
    local doneBtn = CreateFrame("Button", nil, card, C.ButtonTemplate)
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -14, 12)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() card:Hide() end)

    local rows = {}

    local function PaintRow(row)
        local p = row.playerKey and db.players[row.playerKey]
        if not p then return end
        local current = People.Rating(p)
        local nick = Tags.Nick(p)
        row.name:SetText(ClassColor(p.class) .. p.name .. "|r"
            .. (nick and (" " .. T.soft .. "\"" .. nick .. "\"|r") or "")
            .. (p.pending and (" " .. T.warn .. "new|r") or ""))
        for _, b in ipairs(row.buttons) do
            local on = (not p.pending) and b.value == current
            b.bg:SetAlpha(on and 1 or 0.45)
            b.label:SetText((on and T.white or T.soft) .. (b.value > 0 and "+" or "") .. b.value .. "|r")
        end
    end

    local function Row(i)
        if rows[i] then return rows[i] end
        local row = CreateFrame("Frame", nil, card)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -46 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", card, "RIGHT", -14, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name:SetWidth(150)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.buttons = {}
        for v = -3, 5 do
            local b = CreateFrame("Button", nil, row)
            b:SetSize(BTN, BTN)
            b:SetPoint("LEFT", row, "LEFT", 154 + (v + 3) * (BTN + 2), 0)
            b.bg = b:CreateTexture(nil, "BACKGROUND")
            b.bg:SetAllPoints()
            local r, g
            if v < 0 then r, g = 1.0, ((v + 3) / 3) * 0.6 else r, g = 1.0 - (v / 5) * 0.7, 0.5 + (v / 5) * 0.5 end
            if b.bg.SetColorTexture then b.bg:SetColorTexture(r, g, 0, 0.9) else b.bg:SetTexture(r, g, 0, 0.9) end
            b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            b.label:SetPoint("CENTER")
            b.value = v
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText((self.value > 0 and "+" or "") .. self.value .. "  " .. (RATING_LABELS[self.value] or ""), 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            b:SetScript("OnClick", function(self)
                local p = row.playerKey and db.players[row.playerKey]
                if not p then return end
                People.SetRating(p, self.value)
                p.pending = nil
                People.Changed()
                -- Linked characters share a rating, so repaint every row.
                for _, other in ipairs(rows) do
                    if other:IsShown() then PaintRow(other) end
                end
            end)
            row.buttons[#row.buttons + 1] = b
        end
        row.noteBtn = CreateFrame("Button", nil, row, C.ButtonTemplate)
        row.noteBtn:SetSize(44, 18)
        row.noteBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.noteBtn:SetText("Note")
        row.noteBtn:SetNormalFontObject(GameFontNormalSmall)
        row.noteBtn:SetScript("OnClick", function()
            local p = row.playerKey and db.players[row.playerKey]
            if not p then return end
            popupActiveKey = row.playerKey
            StaticPopup_Show("WTFAY_EDIT_NOTE", p.name)
        end)
        rows[i] = row
        return row
    end

    function Outings.RefreshRecap()
        local o = Outings.Get(recapId)
        if not o then card:Hide(); return end
        local info = SOURCE_INFO[o.kind] or SOURCE_INFO.group
        local where = Outings.Where(o, 2)
        sub:SetText(T.light .. (o.time or "?") .. "|r  |cFF" .. info.color .. info.label .. "|r  "
            .. T.dim .. Outings.Duration(o) .. "|r" .. (where ~= "" and ("  " .. T.brass .. where .. "|r") or "")
            .. (o.note and ("  " .. T.dim .. "- " .. o.note .. "|r") or ""))
        local _, keys = Outings.Members(o)
        local shown = math.min(#keys, MAX_ROWS)
        for i = 1, shown do
            local row = Row(i)
            row.playerKey = keys[i]
            PaintRow(row)
            row:Show()
        end
        for i = shown + 1, #rows do rows[i]:Hide() end
        more:ClearAllPoints()
        more:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -50 - shown * ROW_H)
        if #keys > MAX_ROWS then
            more:SetText(T.dim .. "+" .. (#keys - MAX_ROWS) .. " more - right-click this group in the Groups tab and choose Show Players.|r")
        elseif #keys == 0 then
            more:SetText(T.dim .. "None of this group's players are in your database any more.|r")
        else
            more:SetText("")
        end
        hint:SetShown(auto)
        card:SetHeight(46 + math.max(shown, 1) * ROW_H + ((#keys > MAX_ROWS or #keys == 0) and 18 or 0) + 46
            + (auto and 30 or 0))
    end

    -- opened: it popped up by itself because a group ended, so show the hint.
    function Outings.ShowRecap(id, opened)
        if not Outings.Get(id) then
            P("No group to rate yet - they're saved as you group with people.")
            return
        end
        recapId = id
        auto = opened and true or false
        Outings.RefreshRecap()
        card:Show()
        card:Raise()
    end

    -- Shown when a group ends: a moment later (so a loading screen can pass),
    -- and only once you're out of combat.
    local waiter = CreateFrame("Frame")
    waiter:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if self.pending then
            local id = self.pending
            self.pending = nil
            Outings.ShowRecap(id, true)
        end
    end)
    function Outings.QueueRecap(id)
        C_Timer.After(2, function()
            if not Outings.Get(id) or #(Outings.Members(Outings.Get(id))) == 0 then return end
            if InCombatLockdown and InCombatLockdown() then
                waiter.pending = id
                waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
                return
            end
            Outings.ShowRecap(id, true)
        end)
    end
    Outings.recapFrame = card
end

----------------------------------------------------------------------
-- Core API
----------------------------------------------------------------------
-- Defined further down in the /who enrichment section; declared here so
-- AddPlayer can queue a lookup for players added by name alone.
local WhoEnrich

local function AddPlayer(nameRealm, source)
    local name, realm = SplitNameRealm(nameRealm)
    if not name or name == "" then return nil end
    local key = MakeKey(name, realm)
    if db.players[key] then
        db.players[key].seen   = Timestamp()
        db.players[key].source = source or db.players[key].source
        LogEncounter(key, source or db.players[key].source, nil, nil, true)   -- added by name
        P("Updated " .. T.white .. name .. "|r (already tracked)")
    else
        db.players[key] = {
            name       = name,
            realm      = realm,
            class      = "Unknown",
            race       = "",
            level      = 0,
            rating     = 0,
            note       = "",
            source     = source or "manual",
            seen       = Timestamp(),
            encounters = {},
        }
        LogEncounter(key, source or "manual", nil, nil, true)   -- added by name
        P("Added " .. T.white .. name .. "-" .. realm .. "|r")
        -- Added by name alone, so there is no unit to read class/level from.
        if WhoEnrich and db.settings and db.settings.whoEnrich then
            WhoEnrich(key, false)
        end
    end
    RefreshList()
    return key
end

local function RemovePlayer(nameRealm)
    local name, realm = SplitNameRealm(nameRealm)
    if not name or name == "" then return end
    local key = MakeKey(name, realm)

    if db.players[key] then
        People.Unlink(key)
        db.players[key] = nil
        P("Removed " .. T.dangerSoft .. name .. "|r")
        RefreshList()
    else
        P("Player " .. T.white .. name .. "|r not found.")
    end
end

local function SearchPlayers(query)
    query = query:lower()
    local found = 0
    for key, p in pairs(db.players) do
        if p.name:lower():find(query, 1, true) or (p.note or ""):lower():find(query, 1, true) then
            local cc = ClassColor(p.class)
            P(cc .. p.name .. "|r  " .. ColorRating(People.Rating(p)) .. "  " .. T.muted .. (p.note or "") .. "|r")
            found = found + 1
        end
    end
    if found == 0 then
        P("No players matching " .. T.white .. query .. "|r")
    else
        P(found .. " result" .. (found == 1 and "" or "s") .. " found.")
    end
end

local function RatePlayer(nameRealm, rating)
    local name, realm = SplitNameRealm(nameRealm)
    if not name or name == "" then return end
    local key = MakeKey(name, realm)

    if not db.players[key] then
        P("Player " .. T.white .. name .. "|r not found. Add them first.")
        return
    end
    rating = math.max(-3, math.min(5, math.floor(rating)))
    People.SetRating(db.players[key], rating)
    if db.players[key].pending then db.players[key].pending = nil end
    P(ClassColor(db.players[key].class) .. name .. "|r rated " .. ColorRating(rating))
    RefreshList()
    if RefreshInbox then RefreshInbox() end
    UpdateInboxTabLabel()
end

local function NotePlayer(nameRealm, note)
    local name, realm = SplitNameRealm(nameRealm)
    if not name or name == "" then return end
    local key = MakeKey(name, realm)

    if not db.players[key] then
        P("Player " .. T.white .. name .. "|r not found. Add them first.")
        return
    end
    db.players[key].note = note
    P("Note set for " .. ClassColor(db.players[key].class) .. name .. "|r")
    RefreshList()
end

D("core API OK")

----------------------------------------------------------------------
-- /who enrichment
--
-- Group scans read class/race/level straight off the unit, but players
-- added by name (/wtfay add, an import, or someone who left before we
-- scanned) land with class "Unknown" and level 0. A throttled /who lookup
-- fills those in, plus guild and current zone, which no unit API exposes.
--
-- C_FriendList.GetWhoInfo exists on 2.5.6 and hands back a structured
-- record, so we never parse chat text. info.filename is the
-- locale-independent class token ("WARRIOR"), which is what we store —
-- info.classStr would be "Krieger" on a German client and break class
-- colors. Results are routed to the UI (SetWhoToUi) while a query is in
-- flight so lookups don't spam the chat frame.
----------------------------------------------------------------------
local WhoEnrichMissing
do
    local WHO_INTERVAL  = 5    -- seconds between queries; the server throttles /who
    local WHO_TIMEOUT   = 10   -- abandon a query that gets no answer
    local WHO_MAX_QUEUE = 40

    local whoQueue    = {}     -- pending { key, report } entries
    local whoQueued   = {}     -- key -> true, dedup
    local whoActive   = nil    -- { key, name, report, sentAt }
    local whoLastSent = 0

    local function WhoAvailable()
        return C_FriendList and C_FriendList.SendWho and C_FriendList.GetWhoInfo
            and C_FriendList.GetNumWhoResults and C_FriendList.SetWhoToUi
    end

    -- Queue a lookup. report=true prints the outcome (manual lookups only).
    WhoEnrich = function(key, report)
        if not WhoAvailable() then
            if report then P("/who lookups aren't available on this client.") end
            return false
        end
        if not db or not db.players[key] then return false end
        if whoQueued[key] then return true end
        if #whoQueue >= WHO_MAX_QUEUE then
            if report then P("/who queue is full, try again shortly.") end
            return false
        end
        whoQueue[#whoQueue + 1] = { key = key, report = report and true or false }
        whoQueued[key] = true
        return true
    end

    -- Queue every player still missing class, level, or a previous lookup.
    WhoEnrichMissing = function()
        if not db or not db.players then return 0 end
        local n = 0
        for key, p in pairs(db.players) do
            if (p.class or "Unknown") == "Unknown" or (p.level or 0) == 0 or not p.whoChecked then
                if WhoEnrich(key, false) then n = n + 1 end
            end
        end
        return n
    end

    local function ApplyWhoInfo(key, info)
        local p = db and db.players[key]
        if not p then return nil end
        local changed = {}

        local classToken = info.filename
        if classToken and classToken ~= "" then
            local className = TitleCase(classToken)
            if className ~= "" and className ~= p.class then
                p.class = className
                changed[#changed + 1] = "class"
            end
        end

        local lvl = tonumber(info.level) or 0
        if lvl > (p.level or 0) then
            p.level = lvl
            changed[#changed + 1] = "level"
        end

        if info.raceStr and info.raceStr ~= "" and info.raceStr ~= p.race then
            p.race = info.raceStr
            changed[#changed + 1] = "race"
        end

        if info.fullGuildName and info.fullGuildName ~= "" and info.fullGuildName ~= p.guild then
            p.guild = info.fullGuildName
            changed[#changed + 1] = "guild"
        end

        if info.area and info.area ~= "" then
            p.zone = info.area
            p.zoneSeen = Timestamp()
        end

        p.whoChecked = Timestamp()
        return changed
    end

    local function WhoFinish()
        whoActive = nil
        if WhoAvailable() then pcall(C_FriendList.SetWhoToUi, false) end
    end

    local function WhoSendNext()
        if whoActive or #whoQueue == 0 then return end
        if not WhoAvailable() then return end
        if InCombatLockdown() then return end
        -- Don't fight the player's own /who while the social panel is open.
        if FriendsFrame and FriendsFrame:IsShown() then return end
        if (time() - whoLastSent) < WHO_INTERVAL then return end

        local entry = table.remove(whoQueue, 1)
        whoQueued[entry.key] = nil
        local p = db and db.players[entry.key]
        if not p or not p.name then return end

        whoActive   = { key = entry.key, name = p.name, report = entry.report, sentAt = time() }
        whoLastSent = time()
        pcall(C_FriendList.SetWhoToUi, true)
        pcall(C_FriendList.SendWho, 'n-"' .. p.name .. '"')
        D("who: querying " .. p.name)
    end

    local whoFrame = CreateFrame("Frame")
    whoFrame:RegisterEvent("WHO_LIST_UPDATE")
    whoFrame:SetScript("OnEvent", function()
        if not whoActive then return end

        local matched
        local num = C_FriendList.GetNumWhoResults and C_FriendList.GetNumWhoResults() or 0
        for i = 1, num do
            local info = C_FriendList.GetWhoInfo(i)
            if info and info.fullName then
                local shortName = info.fullName:match("^([^%-]+)") or info.fullName
                if shortName:lower() == (whoActive.name or ""):lower() then
                    matched = info
                    break
                end
            end
        end

        local active = whoActive
        WhoFinish()

        if not matched then
            if active.report then
                P(T.white .. active.name .. "|r wasn't found by /who (offline, hidden, or opposite faction).")
            end
            return
        end

        local changed = ApplyWhoInfo(active.key, matched)
        local p = db and db.players[active.key]
        if active.report and p then
            local guildStr = (p.guild and p.guild ~= "") and ("  " .. T.guild .. "<" .. p.guild .. ">|r") or ""
            local zoneStr  = (p.zone and p.zone ~= "") and ("  " .. T.dim .. "in " .. p.zone .. "|r") or ""
            P(ClassColor(p.class) .. p.name .. "|r  " .. T.soft .. "Lv " .. (p.level or "?") .. " "
              .. (p.race or "") .. " " .. (p.class or "Unknown") .. "|r" .. guildStr .. zoneStr)
            if changed and #changed == 0 then
                P(T.dim .. "(nothing new)|r")
            end
        end
        RefreshList()
    end)

    if WhoAvailable() then
        C_Timer.NewTicker(1, function()
            if whoActive and (time() - whoActive.sentAt) > WHO_TIMEOUT then
                local active = whoActive
                WhoFinish()
                D("who: timed out for " .. tostring(active.name))
                if active.report then
                    P(T.dim .. "/who lookup for " .. active.name .. " timed out.|r")
                end
            end
            WhoSendNext()
        end)
        D("/who enrichment OK")
    else
        D("/who enrichment unavailable on this client")
    end
end

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------
local HELP_TEXT = {
    " ",
    "|cFF" .. ACCENT .. "========== WTFAY - Who The F* Are You? ==========|r",
    T.dim .. "Track, rate, and remember every player you encounter.|r",
    " ",
    "|cFF" .. ACCENT .. "General:|r",
    "  " .. T.gold .. "/wtfay|r - Toggle the main panel",
    "  " .. T.gold .. "/wtfay help|r - Show this help",
    "  " .. T.gold .. "/wtfay settings|r - Open settings panel",
    "  " .. T.gold .. "/wtfay stats|r - Show database statistics",
    " ",
    "|cFF" .. ACCENT .. "Player Management:|r",
    "  " .. T.gold .. "/wtfay target|r - Add your current target (auto-detects class, race, level)",
    "  " .. T.gold .. "/wtfay add Name|r or " .. T.gold .. "Name-Realm|r - Add a player manually",
    "  " .. T.gold .. "/wtfay remove Name|r - Remove a player from the database",
    "  " .. T.gold .. "/wtfay rate Name 3|r - Rate a player (-3 to 5)",
    "  " .. T.gold .. "/wtfay note Name Some text|r - Set a note on a player",
    "  " .. T.gold .. "/wtfay search term|r - Search players by name",
    " ",
    "|cFF" .. ACCENT .. "Same player, several characters:|r",
    "  " .. T.gold .. "/wtfay link Alt, Main|r - Link two characters (they share one rating)",
    "  " .. T.gold .. "/wtfay unlink Name|r - Undo a link (their own rating comes back)",
    "  " .. T.gold .. "/wtfay main Name|r - Make a linked character the main",
    " ",
    "|cFF" .. ACCENT .. "Groups:|r",
    "  " .. T.gold .. "/wtfay groups|r - Every group you've been in, with who was there",
    "  " .. T.gold .. "/wtfay recap|r - Rate everyone from your last group",
    " ",
    "|cFF" .. ACCENT .. "Data:|r",
    "  " .. T.gold .. "/wtfay export|r - Export your database to share with friends",
    "  " .. T.gold .. "/wtfay import|r - Import a database (merge or replace)",
    "  " .. T.gold .. "/wtfay restore|r - Undo last Replace All from a backup",
    " ",
    "|cFF" .. ACCENT .. "Lookups:|r",
    "  " .. T.gold .. "/wtfay who Name|r - Fill in class, level, guild, and zone via /who",
    "  " .. T.gold .. "/wtfay whoall|r - Queue a /who for every player missing details",
    " ",
    "|cFF" .. ACCENT .. "Options:|r",
    "  " .. T.gold .. "/wtfay minimap|r - Toggle minimap button on/off",
    "  " .. T.gold .. "/wtfay debug|r - Toggle debug logging",
    " ",
    T.dim .. "Tips: Left-click a player row for details. Right-click for context menu.|r",
    T.dim .. "Use the filters at the top to narrow by rating, class, tag, source, or when you last saw them.|r",
    T.dim .. "Right-click a player for Tags & Nickname. Search finds nicknames and tags too.|r",
    T.dim .. "Right-click a player anywhere in the UI for \"WTFAY: Rate / Note\".|r",
    T.dim .. "Click the minimap icon to quickly open WTFAY.|r",
    "|cFF" .. ACCENT .. "=================================================|r",
}

SLASH_WTFAY1 = "/wtfay"
SlashCmdList["WTFAY"] = function(msg)
    D("slash command fired with: '" .. tostring(msg) .. "'")
    msg = (msg or ""):trim()
    if msg == "" then
        if f:IsShown() then f:Hide() else f:Show() end
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):trim()

    if cmd == "target" or cmd == "tar" then
        AddTargetPlayer()

    elseif cmd == "add" and rest ~= "" then
        AddPlayer(rest, "manual")

    elseif cmd == "remove" or cmd == "rm" or cmd == "delete" then
        if rest ~= "" then RemovePlayer(rest) else P("Usage: /wtfay remove PlayerName") end

    elseif cmd == "rate" then
        local target, val = rest:match("^([^%s,]+)[%s,]+([%-]?%d+)")
        -- Forever names contain a space, so there the number is the last word.
        if not target then target, val = rest:match("^(.-[^%s,])[%s,]+([%-]?%d+)$") end
        if target and val then
            RatePlayer(target, tonumber(val))
        else
            P("Usage: /wtfay rate PlayerName 3")
        end

    elseif cmd == "note" then
        -- Forever names contain a space, so the name runs up to the longest known
        -- player. A comma only ends it there too: notes can contain commas.
        local target, noteText = rest:match("^([^%s,]+)[%s,]+(.*)")
        for pos in rest:gmatch("()[%s,]+[^%s,]") do
            local prefix = rest:sub(1, pos - 1)
            if db.players[MakeKey(SplitNameRealm(prefix))] then
                target, noteText = prefix, rest:sub(pos):match("^[%s,]*(.*)")
            end
        end
        -- Just a name and no note: don't read the surname as the note.
        if db.players[MakeKey(SplitNameRealm(rest))] then target = nil end
        if target and noteText and noteText ~= "" then
            NotePlayer(target, noteText)
        else
            P("Usage: /wtfay note PlayerName Some text here")
        end

    elseif cmd == "who" then
        if rest == "" then
            P("Usage: /wtfay who PlayerName")
        else
            local name, realm = SplitNameRealm(rest)
            local key = MakeKey(name, realm)
            if not db.players[key] then
                P("Player " .. T.white .. name .. "|r not found. Add them first: " .. T.gold .. "/wtfay add " .. name .. "|r")
            elseif WhoEnrich(key, true) then
                P("Looking up " .. T.white .. name .. "|r via /who...")
            end
        end

    elseif cmd == "whoall" then
        local n = WhoEnrichMissing()
        if n == 0 then
            P("Nothing to look up - every player already has class, level, and a /who check.")
        else
            P("Queued " .. T.gold .. n .. "|r player(s) for /who lookup (~5s apart).")
        end

    elseif cmd == "link" then
        -- A comma is the separator, because Forever names contain spaces.
        local a, b = rest:match("^(.-)%s*,%s*(.+)$")
        if not a then a, b = rest:match("^(%S+)%s+(%S+)$") end
        if not a or a == "" then
            P("Usage: /wtfay link Alt, Main")
        else
            local keyA, keyB = People.Find(a), People.Find(b)
            if not keyA or not keyB then
                P("Player " .. T.white .. (keyA and b or a) .. "|r not found, or more than one match. Add them first: " .. T.gold .. "/wtfay add|r")
            else
                People.LinkAndReport(keyA, keyB)
            end
        end

    elseif cmd == "unlink" then
        local key = People.Find(rest)
        if rest == "" then
            P("Usage: /wtfay unlink Name")
        elseif not key then
            P("Player " .. T.white .. rest .. "|r not found, or more than one match.")
        else
            People.UnlinkAndReport(key)
        end

    elseif cmd == "main" then
        local key = People.Find(rest)
        if rest == "" then
            P("Usage: /wtfay main Name")
        elseif not key then
            P("Player " .. T.white .. rest .. "|r not found, or more than one match.")
        elseif People.SetMain(key) then
            P(T.white .. db.players[key].name .. "|r is now the main character.")
            People.Changed()
        else
            P(T.white .. db.players[key].name .. "|r isn't linked to anyone.")
        end

    elseif cmd == "recap" then
        -- Rate everyone from your last group (or the one you're in).
        Outings.ShowRecap(Outings.currentId or Outings.Latest())

    elseif cmd == "groups" then
        ShowMainTab("Groups")
        f:Show()

    elseif cmd == "search" or cmd == "find" then
        if rest ~= "" then SearchPlayers(rest) else P("Usage: /wtfay search term") end

    elseif cmd == "help" or cmd == "?" then
        for _, line in ipairs(HELP_TEXT) do P(line) end

    elseif cmd == "reset" then
        wipe(db.players)
        wipe(db.people)
        wipe(db.outings)
        db.lastOuting, Outings.currentId = nil, nil
        RefreshList()
        if Outings.RefreshTab then Outings.RefreshTab() end
        P("Database wiped.")

    elseif cmd == "debug" then
        DEBUG = not DEBUG
        if db and db.settings then db.settings.debug = DEBUG end
        P("Debug mode: " .. (DEBUG and T.on .. "ON|r" or T.off .. "OFF|r"))

    elseif cmd == "export" then
        if importExportPanel and importExportPanel.ShowExport then
            importExportPanel.ShowExport()
        end

    elseif cmd == "import" then
        if importExportPanel and importExportPanel.ShowImport then
            importExportPanel.ShowImport()
        end

    elseif cmd == "restore" or cmd == "backup" then
        if not db.backups or #db.backups == 0 then
            P("No backups available. Backups are created automatically before a Replace All import.")
        else
            local bk = db.backups[1]
            local count = bk.count or 0
            wipe(db.players)
            for k, p in pairs(bk.players) do
                db.players[k] = {}
                for field, val in pairs(p) do
                    if field == "encounters" then
                        db.players[k].encounters = {}
                        for idx, e in ipairs(val) do
                            local copy = {}
                            for ek, ev in pairs(e) do copy[ek] = ev end
                            db.players[k].encounters[idx] = copy
                        end
                    else
                        db.players[k][field] = val
                    end
                end
            end
            -- Backups made before links existed have no people.
            db.people = bk.people or {}
            People.Reconcile()
            table.remove(db.backups, 1)
            P("Restored backup from " .. T.gold .. (bk.time or "?") .. "|r (" .. count .. " players). " .. #db.backups .. " backup(s) remaining.")
            RefreshList()
        end

    elseif cmd == "stats" then
        if statsPanel and statsPanel.Toggle then
            statsPanel.Toggle()
        end

    elseif cmd == "minimap" then
        local hidden = db.minimapHidden
        db.minimapHidden = not hidden
        if db.minimapHidden then minimapBtn:Hide() else minimapBtn:Show() end
        P("Minimap button: " .. (db.minimapHidden and T.off .. "hidden|r" or T.on .. "shown|r"))

    elseif cmd == "settings" or cmd == "config" or cmd == "options" then
        -- Open the Settings tab in the main window. The game's AddOns page
        -- is generated from the same settings spec.
        if settingsPanel and settingsPanel.Toggle then
            settingsPanel.Toggle()
        elseif settingsPanel and settingsPanel.OpenBliz then
            settingsPanel.OpenBliz()
        end

    else
        P("Unknown command: " .. cmd .. ". Type " .. T.gold .. "/wtfay help|r")
    end
end

D("slash command registered OK")

----------------------------------------------------------------------
-- Addon Compartment (Mainline only)
--
-- The native entry point for addons on modern clients, declared via
-- ## AddonCompartmentFunc in the TOC. Classic ignores the tag, so this
-- global simply never gets called there.
----------------------------------------------------------------------
function WTFAY_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then
        if settingsPanel and settingsPanel.Toggle then settingsPanel.Toggle() end
    else
        if f:IsShown() then f:Hide() else f:Show() end
    end
end

function WTFAY_OnAddonCompartmentEnter()
    if not GameTooltip or not AddonCompartmentFrame then return end
    GameTooltip:SetOwner(AddonCompartmentFrame, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cFF" .. ACCENT .. "WTFAY|r")
    GameTooltip:AddLine("Left-click to open the player browser", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click for settings", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function WTFAY_OnAddonCompartmentLeave()
    if GameTooltip then GameTooltip:Hide() end
end

----------------------------------------------------------------------
-- Known Player Alert Popup
----------------------------------------------------------------------
local alertPopupFrame = CreateFrame("Frame", "WTFAYAlertPopup", UIParent)
alertPopupFrame:SetSize(360, 60)  -- height grows dynamically
alertPopupFrame:SetPoint("TOP", UIParent, "TOP", 0, -80)
alertPopupFrame:SetFrameStrata("FULLSCREEN_DIALOG")
alertPopupFrame:SetMovable(true)
alertPopupFrame:EnableMouse(true)
alertPopupFrame:RegisterForDrag("LeftButton")
alertPopupFrame:SetClampedToScreen(true)
alertPopupFrame:SetScript("OnDragStart", function(s) s:StartMoving() end)
alertPopupFrame:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
alertPopupFrame:Hide()

if BackdropTemplateMixin then
    Mixin(alertPopupFrame, BackdropTemplateMixin)
    alertPopupFrame:OnBackdropLoaded()
end
C.SkinPanel(alertPopupFrame, { edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 }, bg = { 0.10, 0.03, 0.03, 0.95 } })
alertPopupFrame:SetToplevel(true)

-- Close on Escape
do
    local nm = alertPopupFrame:GetName()
    if nm then tinsert(UISpecialFrames, nm) end
end

-- Close button
local alertClose = CreateFrame("Button", nil, alertPopupFrame, "UIPanelCloseButton")
alertClose:SetPoint("TOPRIGHT", alertPopupFrame, "TOPRIGHT", -2, -2)

-- Title
local alertTitle = alertPopupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
alertTitle:SetPoint("TOP", alertPopupFrame, "TOP", 0, -14)

-- Content: dynamically created player lines
local alertLines = {}

-- Dismiss button
local alertDismiss = CreateFrame("Button", nil, alertPopupFrame, C.ButtonTemplate)
alertDismiss:SetSize(80, 22)
alertDismiss:SetText("Dismiss")
alertDismiss:SetScript("OnClick", function() alertPopupFrame:Hide() end)

-- Auto-dismiss timer (optional: fade out after 15 seconds)
local alertTimer = nil

local function ShowAlertPopup(knownPlayers, isLeave)
    if not knownPlayers or #knownPlayers == 0 then return end

    -- Cancel previous timer
    if alertTimer then alertTimer = nil end

    -- Count blacklisted
    local blacklistCount = 0
    for _, kp in ipairs(knownPlayers) do
        if People.Rating(kp.player) <= -3 then
            blacklistCount = blacklistCount + 1
        end
    end

    -- Title
    if isLeave then
        alertTitle:SetText(T.slate .. "Known Player Left|r")
        if alertPopupFrame.SetBackdropColor then
            alertPopupFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
        end
    elseif blacklistCount > 0 then
        alertTitle:SetText(T.off .. "!! Known Players Alert !!|r")
        if alertPopupFrame.SetBackdropColor then
            alertPopupFrame:SetBackdropColor(0.12, 0.02, 0.02, 0.96)
        end
    else
        alertTitle:SetText("|cFF" .. ACCENT .. "Known Players in Group|r")
        if alertPopupFrame.SetBackdropColor then
            alertPopupFrame:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
        end
    end

    -- Clear old lines
    for _, line in ipairs(alertLines) do line:Hide() end

    -- Build player lines
    local yOffset = -38
    local lineHeight = 32
    for i, kp in ipairs(knownPlayers) do
        local p = kp.player
        local line = alertLines[i]
        if not line then
            line = CreateFrame("Frame", nil, alertPopupFrame)
            line:SetHeight(lineHeight)
            line:SetPoint("LEFT", alertPopupFrame, "LEFT", 14, 0)
            line:SetPoint("RIGHT", alertPopupFrame, "RIGHT", -14, 0)

            line.nameText = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            line.nameText:SetPoint("TOPLEFT", line, "TOPLEFT", 0, 0)
            line.nameText:SetJustifyH("LEFT")

            line.noteText = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            line.noteText:SetPoint("TOPLEFT", line.nameText, "BOTTOMLEFT", 2, -1)
            line.noteText:SetPoint("RIGHT", line, "RIGHT", 0, 0)
            line.noteText:SetJustifyH("LEFT")
            line.noteText:SetWordWrap(false)

            alertLines[i] = line
        end

        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", alertPopupFrame, "TOPLEFT", 14, yOffset)
        line:SetPoint("RIGHT", alertPopupFrame, "RIGHT", -14, 0)

        local cc = ClassColor(p.class)
        local ratingStr = C.RatingIcon(People.Rating(p)) .. ColorRating(People.Rating(p))
        local prefix = ""
        if People.Rating(p) <= -3 then
            prefix = T.blacklist .. "[BLACKLISTED]|r  "
        end
        line.nameText:SetText(prefix .. cc .. p.name .. "|r  " .. cc .. (p.class or "") .. "|r  Lv " .. (p.level or "?") .. "  Rating: " .. ratingStr)

        local personTag = People.Tag(p)
        local bestNote = People.BestNote(p)
        line.noteText:SetText((personTag and (T.dim .. "(" .. personTag .. ")|r  ") or "")
            .. (bestNote and (T.soft .. "\"" .. bestNote .. "\"|r") or ""))

        line:Show()
        yOffset = yOffset - lineHeight
    end

    -- Hide excess lines
    for i = #knownPlayers + 1, #alertLines do
        alertLines[i]:Hide()
    end

    -- Resize frame to fit content
    local totalHeight = 38 + (#knownPlayers * lineHeight) + 36
    alertPopupFrame:SetSize(360, totalHeight)

    -- Position dismiss button at bottom
    alertDismiss:ClearAllPoints()
    alertDismiss:SetPoint("BOTTOM", alertPopupFrame, "BOTTOM", 0, 10)

    alertPopupFrame:Show()

    -- Play alert sound if enabled
    PlayAlertSound(blacklistCount > 0)

    -- Auto-dismiss: leave alerts after 10s, normal after 20s, blacklisted stays
    local dismissSeconds = isLeave and 10 or (blacklistCount == 0 and 20 or nil)
    if dismissSeconds then
        local dismissTime = time() + dismissSeconds
        alertTimer = dismissTime
        C_Timer.After(dismissSeconds, function()
            if alertTimer == dismissTime and alertPopupFrame:IsShown() then
                alertPopupFrame:Hide()
            end
        end)
    end
end

D("alert popup OK")

----------------------------------------------------------------------
-- Auto-tracking: automatically log party/raid members
----------------------------------------------------------------------
local autoTracker = CreateFrame("Frame")

-- Helper: determine source and zone from current instance
local function GetGroupSourceAndZone()
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        local zoneName = GetInstanceInfo and select(1, GetInstanceInfo()) or GetRealZoneText() or ""
        if instanceType == "raid" then
            return "raid", zoneName
        elseif instanceType == "party" then
            return "dungeon", zoneName
        elseif instanceType == "pvp" or instanceType == "arena" then
            -- Battleground and arena groups are strangers queued together:
            -- ScanGroupMembers records nothing for them.
            return "pvp", zoneName
        else
            return "group", zoneName
        end
    else
        return "group", nil
    end
end

-- Helper: build a set of guild member names for fast lookup
local function GetGuildMemberSet()
    local guildSet = {}
    if not IsInGuild() then return guildSet end
    local numGuild = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, numGuild do
        local fullName = GetGuildRosterInfo(i)
        if fullName then
            -- fullName may be "Name" or "Name-Realm"
            local shortName = fullName:match("^([^%-]+)") or fullName
            guildSet[shortName] = true
            guildSet[fullName] = true
        end
    end
    return guildSet
end

-- Alert state tracking
local lastAlertSet = {}       -- set of player keys seen this session (only grows)
local lastScanMembers = nil   -- set of known player keys from previous scan (nil = first scan)

-- Helper: show alert in chat and optionally popup/sound
local function FireAlert(players, title, isLeave)
    if #players == 0 then return end
    P(title)
    for _, kp in ipairs(players) do
        local p = kp.player
        local cc = ClassColor(p.class)
        local ratingStr = ColorRating(People.Rating(p))
        local bestNote = People.BestNote(p)
        local noteStr = bestNote and ("  " .. T.soft .. "\"" .. bestNote .. "\"|r") or ""
        local personTag = People.Tag(p)
        local tagStr = personTag and (T.dim .. " (" .. personTag .. ")|r") or ""
        if People.Rating(p) <= -3 then
            P("  " .. T.blacklist .. ">>> BLACKLISTED <<<|r  " .. cc .. p.name .. "|r" .. tagStr .. " (" .. cc .. (p.class or "?") .. "|r) " .. ratingStr .. noteStr)
        else
            P("  " .. cc .. p.name .. "|r" .. tagStr .. " (" .. cc .. (p.class or "?") .. "|r) " .. ratingStr .. noteStr)
        end
    end
    if db.settings.alertPopup then
        ShowAlertPopup(players, isLeave)
    else
        local hasBlacklist = false
        for _, kp in ipairs(players) do
            if People.Rating(kp.player) <= -3 then hasBlacklist = true; break end
        end
        PlayAlertSound(hasBlacklist)
    end
end

-- Scan all current group/raid members and add/update them
local function ScanGroupMembers()
    if not db or not db.settings or not db.settings.autoTrack then return end
    if not IsInGroup() and not IsInRaid() then
        -- Left group: reset alert state so next join triggers fresh
        lastAlertSet = {}
        lastScanMembers = nil
        autoTracker.grouped = nil
        -- The group is over: offer to rate who was in it (a setting, on by default).
        local _, endedId = Outings.Close()
        if endedId and db.settings.groupRecap and Outings.QueueRecap then
            Outings.QueueRecap(endedId)
        end
        local inboxCount = GetInboxCount()
        if inboxCount > 0 then
            P(T.warn .. inboxCount .. "|r player" .. (inboxCount == 1 and "" or "s") .. " in your inbox to review. Type " .. T.gold .. "/wtfay|r to open.")
        end
        RefreshList()
        if RefreshInbox then RefreshInbox() end
        UpdateInboxTabLabel()
        return
    end

    local source, zone = GetGroupSourceAndZone()
    -- Battlegrounds and arenas: no players, no encounters, no alerts. Your own
    -- party (if you queued with one) picks up again when you're back out.
    if source == "pvp" then
        D("ScanGroupMembers: in a battleground/arena, not recording")
        return
    end
    local myName = C.UnitIdentity("player") or ""
    local numMembers
    local knownPlayers = {}  -- collect known players for alerts
    local guildSet = nil     -- lazy-loaded
    -- Everyone grouped at the previous scan: they're still on the same outing,
    -- so zoning around together doesn't log a new encounter each time.
    local wasGrouped = autoTracker.grouped or {}
    local nowGrouped = {}
    autoTracker.grouped = nowGrouped

    -- Who's here, before anything is logged, so the outing knows its members.
    local units = {}
    if IsInRaid() then
        numMembers = GetNumRaidMembers and GetNumRaidMembers() or GetNumGroupMembers() or 0
        for i = 1, numMembers do units[#units + 1] = "raid" .. i end
    else
        numMembers = GetNumPartyMembers and GetNumPartyMembers() or (GetNumGroupMembers and GetNumGroupMembers() or 0)
        for i = 1, numMembers do units[#units + 1] = "party" .. i end
    end
    do
        local keys = {}
        for _, unit in ipairs(units) do
            local key, name = UnitKey(unit)
            if key and name ~= myName then keys[key] = true end
        end
        Outings.Touch(keys, source, zone or (GetRealZoneText and GetRealZoneText()) or nil)
    end

    -- Helper: process a single unit
    local function ProcessUnit(unit)
        local name, realm = C.UnitIdentity(unit)
        if not name or name == myName then return end
        local _, classFile = UnitClass(unit)
        local className = classFile and TitleCase(classFile) or "Unknown"
        local raceName = UnitRace(unit) or ""
        local level = UnitLevel(unit) or 0
        local role = C.UnitRole(unit)
        local key = MakeKey(name, realm)
        local wasKnown = db.players[key] ~= nil
        nowGrouped[key] = true

        if wasKnown then
            local p = db.players[key]
            p.seen = Timestamp()
            if className ~= "Unknown" then p.class = className end
            if raceName ~= "" then p.race = raceName end
            if level > 0 and level > (p.level or 0) then p.level = level end
            p.source = source
            LogEncounter(key, source, zone, level, nil, wasGrouped[key], role)
        else
            db.players[key] = {
                name = name, realm = realm, class = className,
                race = raceName, level = level, rating = 0,
                note = "", source = source, seen = Timestamp(),
                encounters = {}, pending = true,
            }
            LogEncounter(key, source, zone, level, nil, nil, role)
            D("New player added to inbox: " .. name)
            P(ClassColor(className) .. name .. "|r added to inbox.")
            UpdateInboxTabLabel()
        end

        -- Collect for alert if this player was already in the database
        if wasKnown and db.settings.knownAlerts then
            local p = db.players[key]
            -- Skip guild members if setting is on
            local skipThis = false
            if db.settings.alertSkipGuild then
                if not guildSet then guildSet = GetGuildMemberSet() end
                if guildSet[name] or guildSet[key] then skipThis = true end
            end
            if not skipThis then
                knownPlayers[#knownPlayers + 1] = { key = key, player = p }
            end
        end
    end

    for _, unit in ipairs(units) do ProcessUnit(unit) end

    D("ScanGroupMembers: source=" .. source .. " zone=" .. tostring(zone) .. " members=" .. tostring(numMembers))

    -- Build current set of known player keys
    local currentKnownSet = {}
    for _, kp in ipairs(knownPlayers) do currentKnownSet[kp.key] = kp end

    -- Determine alert context
    local isFirstScan = (lastScanMembers == nil)

    if db.settings.knownAlerts and #knownPlayers > 0 then
        if isFirstScan then
            -- I just joined a group — all known players are "already here"
            if db.settings.alertOnMeJoin then
                FireAlert(knownPlayers, T.white .. "Known players in your group:|r", false)
            end
        else
            -- Ongoing group: detect joins and leaves
            -- Joined: in current set but NOT in previous scan
            if db.settings.alertOnJoin then
                local joined = {}
                for _, kp in ipairs(knownPlayers) do
                    if not lastScanMembers[kp.key] then
                        joined[#joined + 1] = kp
                    end
                end
                if #joined > 0 then
                    FireAlert(joined, T.white .. "Known player joined your group:|r", false)
                end
            end

            -- Left: in previous scan but NOT in current set
            if db.settings.alertOnLeave then
                local left = {}
                for prevKey, _ in pairs(lastScanMembers) do
                    if not currentKnownSet[prevKey] then
                        local p = db.players[prevKey]
                        if p then
                            left[#left + 1] = { key = prevKey, player = p }
                        end
                    end
                end
                if #left > 0 then
                    FireAlert(left, T.muted .. "Known player left your group:|r", true)
                end
            end
        end
    end

    -- Update tracking sets for next scan
    lastScanMembers = {}
    for _, kp in ipairs(knownPlayers) do lastScanMembers[kp.key] = true end
    for _, kp in ipairs(knownPlayers) do lastAlertSet[kp.key] = true end

    RefreshList()
end

-- Events to listen for
autoTracker:RegisterEvent("GROUP_ROSTER_UPDATE")      -- group composition changes
autoTracker:RegisterEvent("ZONE_CHANGED_NEW_AREA")     -- entered a new zone/instance
-- TBC fallbacks
if not select(2, autoTracker:IsEventRegistered("GROUP_ROSTER_UPDATE")) then
    -- In some TBC versions, these events are named differently
    pcall(function() autoTracker:RegisterEvent("PARTY_MEMBERS_CHANGED") end)
    pcall(function() autoTracker:RegisterEvent("RAID_ROSTER_UPDATE") end)
end

autoTracker:SetScript("OnEvent", function(self, event)
    if not db or not db.settings or not db.settings.autoTrack then return end

    if event == "ZONE_CHANGED_NEW_AREA" then
        -- Any zone change while grouped: entering an instance starts its own
        -- encounter line, and the group's record collects the places visited.
        -- Zoning around together only extends existing entries (LogEncounter).
        if IsInGroup() or IsInRaid() then
            -- Small delay to let unit info populate
            C_Timer.After(2, ScanGroupMembers)
        end
    else
        -- GROUP_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE
        -- Small delay to let unit info populate after group change
        C_Timer.After(1, ScanGroupMembers)
    end
end)

D("auto-tracking system OK")

----------------------------------------------------------------------
-- Unit right-click menu integration
--
-- Adds a "WTFAY: Rate / Note" entry to Blizzard's unit dropdowns so a
-- player can be rated straight from a raid frame, a chat name, or the
-- friends list instead of targeting them and typing a slash command.
--
-- Two completely different APIs underneath (Menu.ModifyMenu on Mainline,
-- UnitPopupMenus on Classic) - the compat layer picks one and calls us back
-- with a plain name/realm/unit.
----------------------------------------------------------------------
do
    local menuOK, menuErr, impl = C.RegisterUnitMenu(
        -- Someone you've already rated shows that rating instead of a bare "Rate".
        function(name, realm)
            local p = name and db and db.players and db.players[MakeKey(name, realm)]
            if not p or p.pending then return "Rate / Note" end
            local r = People.Rating(p)
            local tag = People.Tag(p)
            return ColorRating(r) .. " " .. (RATING_LABELS[r] or "")
                .. (tag and (" " .. T.dim .. "(" .. tag .. ")|r") or "")
                .. "  -  Change / Note"
        end,
        function(name, realm, unit)
            if not db or not db.players then return end
            if not name or name == "" then return end

            local myName = C.UnitIdentity("player")
            if myName and name == myName then
                P("You can't rate yourself.")
                return
            end

            -- Read what we can off the unit; a chat/friends-list entry has none.
            local className, raceName, level
            if unit and UnitExists(unit) and UnitIsPlayer(unit) then
                local _, classFile = UnitClass(unit)
                if classFile then className = TitleCase(classFile) end
                raceName = UnitRace(unit)
                level    = UnitLevel(unit)
            end

            local key = MakeKey(name, realm)
            local p   = db.players[key]
            if not p then
                local realmNorm = NormalizeRealm(realm)
                if realmNorm == "" then realmNorm = C.MyRealm() end
                if realmNorm == "" and C.UsesRealms then realmNorm = "Unknown" end
                p = {
                    name   = TitleCase(name), realm = realmNorm,
                    class  = className or "Unknown", race = raceName or "",
                    level  = level or 0, rating = 0, note = "",
                    source = "manual", seen = Timestamp(), encounters = {},
                }
                db.players[key] = p
                -- A chat or friends-list entry has no unit, so no location for them.
                LogEncounter(key, "manual", nil, level, not (unit and UnitExists(unit)))
                P("Added " .. ClassColor(p.class) .. p.name .. "|r from the unit menu.")
                if (p.class or "Unknown") == "Unknown" and WhoEnrich and db.settings.whoEnrich then
                    WhoEnrich(key, false)
                end
            else
                if className and className ~= "" then p.class = className end
                if raceName and raceName ~= "" then p.race  = raceName end
                if level and level > (p.level or 0) then p.level = level end
            end

            RefreshList()
            if ShowRatingPicker then ShowRatingPicker(key) end
        end,
        function() return db and db.settings and db.settings.unitMenu end
    )

    if menuOK then
        D("unit menu integration OK via " .. tostring(impl))
    else
        D("unit menu setup FAILED: " .. tostring(menuErr))
    end
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        D("ADDON_LOADED fired for WTFAY")
        InitDB()

        if db.frame and db.frame.point then
            f:ClearAllPoints()
            f:SetPoint(db.frame.point, UIParent, db.frame.relPoint, db.frame.x, db.frame.y)
        end
        if db.frame and db.frame.width then
            -- Clamp: sizes saved under older, smaller bounds would squeeze the
            -- fixed columns past the Name column and break the list layout.
            local w = math.max(MIN_W, math.min(MAX_W, db.frame.width or MIN_W))
            local h = math.max(MIN_H, math.min(MAX_H, db.frame.height or MIN_H))
            f:SetSize(w, h)
            db.frame.width, db.frame.height = w, h
        end

        -- Restore settings
        DEBUG = db.settings.debug

        -- Window style: repaints every registered window, tab and border, and
        -- re-runs the main layout (bottom tabs vs pills).
        local skin = db.settings.skin
        C.SetSkin((skin == "native" or skin == "dark") and skin or C.DefaultSkin())

        -- Restore minimap button position and visibility
        if db.minimapAngle then
            minimapAngle = db.minimapAngle
            minimapBtn:ClearAllPoints()
            MinimapBtn_SetAngle(minimapAngle)
        end
        if db.minimapHidden then
            minimapBtn:Hide()
        else
            minimapBtn:Show()
        end

        -- Restore sort preferences
        if db.sortField then sortField = db.sortField end
        if db.sortDirection then sortDirection = db.sortDirection end
        UpdateHeaderArrows()

        D("DB initialized")
        local count = 0
        for _ in pairs(db.players) do count = count + 1 end
        D("player count: " .. count)

    elseif event == "PLAYER_LOGIN" then
        D("PLAYER_LOGIN fired")

        -- Register Blizzard Interface Options panel (must happen after full UI init)
        if settingsPanel and settingsPanel.RegisterBliz then
            settingsPanel.RegisterBliz()
        end

        P("v" .. ADDON_VERSION .. " loaded! Type " .. T.gold .. "/wtfay|r to open.  " .. T.gold .. "/wtfay help|r for commands.")
        self:UnregisterAllEvents()
    end
end)

----------------------------------------------------------------------
-- Add current target: /wtfay target
-- Grabs name, class, race, level from your current target
----------------------------------------------------------------------
AddTargetPlayer = function()
    if not UnitExists("target") then
        P("You have no target.")
        return
    end
    if not UnitIsPlayer("target") then
        P("Your target is not a player.")
        return
    end

    local name, realm = C.UnitIdentity("target")
    if not name then P("Could not read your target's name."); return end

    local _, classFile = UnitClass("target")
    local className = classFile and TitleCase(classFile) or "Unknown"

    local raceName = UnitRace("target") or ""

    local level = UnitLevel("target") or 0

    if not db then return end
    local key = MakeKey(name, realm)
    if db.players[key] then
        db.players[key].seen  = Timestamp()
        db.players[key].class = className
        db.players[key].race  = raceName
        if level > 0 then db.players[key].level = level end
        LogEncounter(key, "manual", nil, level)
        P("Updated " .. ClassColor(className) .. name .. "|r (already tracked)")
    else
        db.players[key] = {
            name       = name,
            realm      = realm,
            class      = className,
            race       = raceName,
            level      = level,
            rating     = 0,
            note       = "",
            source     = "manual",
            seen       = Timestamp(),
            encounters = {},
        }
        LogEncounter(key, "manual", nil, level)
        P("Added " .. ClassColor(className) .. name .. "|r (" .. raceName .. " " .. className .. ")")
    end
    RefreshList()
end

----------------------------------------------------------------------
-- Tooltip integration: show WTFAY info on player tooltips
----------------------------------------------------------------------
D("setting up tooltip hook...")

-- The compat layer decides how to hook (TooltipDataProcessor on Mainline,
-- OnTooltipSetUnit on Classic) and hands us a resolved unit token.
local tooltipOK, tooltipErr = C.HookUnitTooltip(function(tooltip, unit)
    if not db or not db.players then return end
    if not (db.settings and db.settings.tooltipEnabled) then return end
    if not UnitIsPlayer(unit) then return end

    local key = UnitKey(unit)
    if not key then return end

    local p = db.players[key]
    if p then
        tooltip:AddLine(" ")
        tooltip:AddDoubleLine(
            "|cFF" .. ACCENT .. "WTFAY|r",
            C.RatingIcon(People.Rating(p)) .. ColorRating(People.Rating(p)) .. " " .. (RATING_LABELS[People.Rating(p)] or "")
        )
        local personLine = People.Line(p)
        if personLine then tooltip:AddLine(T.accent .. personLine .. "|r") end
        -- Notes, tags and nicknames are yours alone; this setting keeps them
        -- off a streamed or shared screen.
        if db.settings.tooltipNotes then
            local nick = Tags.Nick(p)
            if nick then tooltip:AddLine(T.soft .. "\"" .. nick .. "\"|r") end
            local tagText = Tags.Text(p)
            if tagText then tooltip:AddLine(T.manual .. tagText .. "|r", 1, 1, 1, true) end
            if p.note and p.note ~= "" then
                tooltip:AddLine(T.text .. p.note .. "|r", 1, 1, 1, true)
            end
            for _, other in ipairs(People.OtherNotes(p)) do
                tooltip:AddLine(T.dim .. other.name .. ": |r" .. T.text .. other.note .. "|r", 1, 1, 1, true)
            end
        end
        local roles = People.RoleSummary(p)
        if roles then tooltip:AddLine(T.soft .. "Played: " .. roles .. "|r") end
        if db.settings.tooltipGuild and p.guild and p.guild ~= "" then
            tooltip:AddLine(T.guild .. "<" .. p.guild .. ">|r")
        end
        local met = MetLineFor(p)
        if met then tooltip:AddLine(T.brass .. met .. "|r") end
        tooltip:AddLine(T.faint .. (p.source or "manual") .. " - " .. (p.seen or "") .. "|r")
    elseif db.settings.tooltipHint then
        tooltip:AddLine("|cFF" .. ACCENT .. "WTFAY|r " .. T.dim .. "- /wtfay target to track|r")
    else
        -- Unknown player and the hint is off: leave the tooltip untouched.
        return
    end
    tooltip:Show()
end)

if tooltipOK then
    D("tooltip hook OK")
else
    D("tooltip hook FAILED: " .. tostring(tooltipErr))
end

D(">>> File loading COMPLETE — all sections parsed OK")
