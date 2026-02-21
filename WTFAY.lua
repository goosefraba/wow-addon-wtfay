----------------------------------------------------------------------
-- WTFAY - Who The F* Are You?   v0.5.0
-- Database, slash commands, browse UI, rating, notes
----------------------------------------------------------------------
local ADDON_NAME = "WTFAY"
local ADDON_VERSION = "0.5.0"
local ACCENT     = "00CCFF"
local PREFIX     = "|cFF" .. ACCENT .. "[WTFAY]|r "
local DEBUG      = false  -- overridden by db.settings.debug after ADDON_LOADED

local function P(msg) print(PREFIX .. msg) end
local function D(msg) if DEBUG then print("|cFF999999[WTFAY-DBG]|r " .. tostring(msg)) end end

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

local CLASS_COLORS = {
    WARRIOR     = "C79C6E", PALADIN   = "F58CBA", HUNTER    = "ABD473",
    ROGUE       = "FFF569", PRIEST    = "FFFFFF", SHAMAN    = "0070DE",
    MAGE        = "69CCF0", WARLOCK   = "9482C9", DRUID     = "FF7D0A",
}

local function ClassColor(class)
    local c = CLASS_COLORS[(class or ""):upper()] or "AAAAAA"
    return "|cFF" .. c
end

local function Timestamp()
    return date("%Y-%m-%d %H:%M")
end

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

local SEED_PLAYERS = {
    { name="Thrallgaze",   realm="Shazzrah",   class="Shaman",  race="Orc",      level=70, rating= 5, note="Great healer, always has totems down",   source="raid"    },
    { name="Legolazz",     realm="Shazzrah",   class="Hunter",  race="Night Elf", level=70, rating=-2, note="Pulled half the dungeon on purpose",     source="dungeon" },
    { name="Stabsworth",   realm="Shazzrah",   class="Rogue",   race="Undead",   level=68, rating= 3, note="Solid DPS, shared lockpicking",          source="group"   },
    { name="Holysmokes",   realm="Shazzrah",   class="Priest",  race="Dwarf",    level=70, rating= 4, note="Clutch heals in Karazhan",               source="raid"    },
    { name="Moonkindle",   realm="Shazzrah",   class="Druid",   race="Tauren",   level=69, rating= 0, note="",                                       source="dungeon" },
    { name="Felcaster",    realm="Shazzrah",   class="Warlock", race="Gnome",    level=70, rating=-3, note="Lifetapped to death then blamed healer",  source="dungeon" },
    { name="Shieldwall",   realm="Shazzrah",   class="Warrior", race="Human",    level=70, rating= 4, note="Great tank, marks targets",              source="raid"    },
    { name="Froztbolt",    realm="Shazzrah",   class="Mage",    race="Troll",    level=66, rating= 1, note="Decent but kept pulling aggro",          source="group"   },
    { name="Retbull",      realm="Shazzrah",   class="Paladin", race="Blood Elf", level=70, rating= 2, note="Off-tank, wings are flashy",             source="raid"    },
    { name="Sneakypete",   realm="Shazzrah",   class="Rogue",   race="Blood Elf", level=70, rating=-1, note="Rolled need on healer gear",             source="dungeon" },
    { name="Natureboi",    realm="Shazzrah",   class="Druid",   race="Night Elf", level=70, rating= 5, note="Best resto druid on the server",         source="raid"    },
    { name="Zugzug",       realm="Shazzrah",   class="Warrior", race="Orc",      level=64, rating= 0, note="",                                       source="manual"  },
}

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
    alertPopup       = true,   -- Also show a popup panel (not just chat)
    alertSound       = true,   -- Play a sound when the alert popup appears
    alertSoundChoice = 1,      -- Index into ALERT_SOUNDS (default: Quest Complete)
    alertSkipGuild   = true,   -- Skip guild members from known player alerts
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

    -- Initialize settings with defaults (preserves existing values)
    if not db.settings then db.settings = {} end
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end

    -- Seed sample data on first install so the addon isn't empty
    local SEED_VERSION = 4
    if (db.seedVersion or 0) < SEED_VERSION then
        local fakeEncounters = {
            Thrallgaze  = { "raid", "raid", "raid", "raid", "raid", "dungeon", "raid", "raid" },
            Legolazz    = { "dungeon", "dungeon" },
            Stabsworth  = { "group", "dungeon", "group" },
            Holysmokes  = { "raid", "raid", "raid", "raid", "dungeon", "raid" },
            Moonkindle  = { "dungeon" },
            Felcaster   = { "dungeon", "dungeon", "dungeon" },
            Shieldwall  = { "raid", "raid", "raid", "raid", "raid", "raid", "raid", "raid", "raid", "raid" },
            Froztbolt   = { "group", "group" },
            Retbull     = { "raid", "raid", "raid" },
            Sneakypete  = { "dungeon", "dungeon", "dungeon", "dungeon" },
            Natureboi   = { "raid", "raid", "raid", "raid", "raid", "raid", "raid" },
            Zugzug      = { "manual" },
        }
        for _, p in ipairs(SEED_PLAYERS) do
            local key = p.name .. "-" .. p.realm
            local encounters = {}
            local srcList = fakeEncounters[p.name] or { p.source }
            for idx, src in ipairs(srcList) do
                local daysAgo = (#srcList - idx) * 3 + math.random(0, 2)
                encounters[#encounters + 1] = {
                    time   = date("%Y-%m-%d %H:%M", time() - daysAgo * 86400 - math.random(0, 43200)),
                    source = src,
                }
            end
            db.players[key] = {
                name       = p.name,
                realm      = p.realm,
                class      = p.class,
                race       = p.race or "",
                level      = p.level,
                rating     = p.rating,
                note       = p.note,
                source     = p.source,
                seen       = Timestamp(),
                encounters = encounters,
            }
        end
        db.seedVersion = SEED_VERSION
        db.seeded = true
    end
end

-- Reseed function (can be called from slash command)
local function ReseedDB()
    if not db then return end
    db.seedVersion = 0
    InitDB()
end

-- Log an encounter for a player (appends to encounters list)
-- zone is optional: e.g. "Karazhan", "Shattered Halls"
local function LogEncounter(key, source, zone)
    if not db or not db.players[key] then return end
    if not db.players[key].encounters then
        db.players[key].encounters = {}
    end
    local enc = db.players[key].encounters

    -- Dedup logic:
    -- Instanced content (dungeon/raid with a zone): skip if same source + same zone
    --   → wipes, corpse runs, reloads won't create duplicates
    --   → running a different dungeon creates a new encounter
    -- Non-instanced (group/manual, no zone): skip if same source within 30 minutes
    --   → regrouping after a break creates a new encounter
    local now = time()
    local effectiveSource = source or db.players[key].source or "manual"
    local effectiveZone = (zone and zone ~= "") and zone or nil
    if #enc > 0 then
        local last = enc[#enc]
        if last.source == effectiveSource then
            if effectiveZone and effectiveZone == (last.zone or nil) then
                -- Same instance — skip (covers wipes, corpse runs)
                return
            elseif not effectiveZone and not last.zone and last._ts and (now - last._ts) < 1800 then
                -- Same non-instanced source within 30 min — skip
                return
            end
        end
    end

    -- Append newest at the end (we'll display newest-first)
    local entry = {
        time   = Timestamp(),
        source = effectiveSource,
        _ts    = now,
    }
    if effectiveZone then
        entry.zone = effectiveZone
    end
    enc[#enc + 1] = entry
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

local function RebuildSorted(filterText, ratingMin, ratingMax, sourceFilter, classFilter)
    wipe(sortedKeys)
    filterText = (filterText or ""):lower()
    local classLower = classFilter and classFilter:lower() or nil
    for key, p in pairs(db.players) do
        local match = true
        -- Skip pending (inbox) players
        if p.pending then match = false end
        -- Text search: name only
        if match and filterText ~= "" and not p.name:lower():find(filterText, 1, true) then
            match = false
        end
        -- Rating range filter
        local r = p.rating or 0
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
            va, vb = pa.rating or 0, pb.rating or 0
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
local MIN_W, MIN_H = 440, 320
local MAX_W, MAX_H = 800, 700

D("creating main frame...")
local f = CreateFrame("Frame", "WTFAYFrame", UIParent)
D("main frame created (no template)")

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

if f.SetBackdrop then
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    D("backdrop set OK")
end

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

D("title + close OK")

----------------------------------------------------------------------
-- Main window tabs: Database / Inbox
----------------------------------------------------------------------
local mainTabButtons = {}
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
    if mainTabButtons["Inbox"] then
        local count = GetInboxCount()
        if count > 0 then
            mainTabButtons["Inbox"].label:SetText("Inbox (|cFFFF8800" .. count .. "|r)")
        else
            mainTabButtons["Inbox"].label:SetText("Inbox")
        end
    end
end

local activeMainTab = "Database"
local function ShowMainTab(name)
    activeMainTab = name
    for tname, btn in pairs(mainTabButtons) do
        if tname == name then
            btn.label:SetTextColor(1, 0.82, 0.1)
            btn.underline:Show()
        else
            btn.label:SetTextColor(0.6, 0.6, 0.6)
            btn.underline:Hide()
        end
    end
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
end

do
    local MAIN_TAB_NAMES = { "Database", "Inbox" }
    local tabW = 80
    local totalW = tabW * #MAIN_TAB_NAMES
    local sx = (MIN_W - totalW) / 2  -- will be re-centered on resize but good enough
    for i, tname in ipairs(MAIN_TAB_NAMES) do
        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(tabW, 18)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 60 + (i - 1) * (tabW + 8), -34)
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
        lbl:SetText(tname)
        btn.label = lbl
        local ul = btn:CreateTexture(nil, "ARTWORK")
        ul:SetHeight(2)
        ul:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, 0)
        ul:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 0)
        if ul.SetColorTexture then ul:SetColorTexture(0.9, 0.7, 0.2, 1) else ul:SetTexture(0.9, 0.7, 0.2, 1) end
        ul:Hide()
        btn.underline = ul
        btn:SetScript("OnClick", function() ShowMainTab(tname) end)
        mainTabButtons[tname] = btn
    end
end

D("main tabs OK")

----------------------------------------------------------------------
-- Search bar
----------------------------------------------------------------------
D("creating search box...")
local searchBox = CreateFrame("EditBox", "WTFAYSearchBox", f, "InputBoxTemplate")
D("search box created")
searchBox:SetSize(120, 22)
searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -56)
searchBox:SetAutoFocus(false)
searchBox:SetFontObject(ChatFontNormal)
searchBox:SetMaxLetters(40)

local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -4, 0)
searchLabel:SetText("|cFFCCCCCCSearch:|r")

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
ratingFilterBtn:SetText("|cFFFFD100" .. ratingFilterPresets[1].label .. "|r")

local ratingFilterBg = ratingFilterBtn:CreateTexture(nil, "BACKGROUND")
ratingFilterBg:SetAllPoints()
if ratingFilterBg.SetColorTexture then
    ratingFilterBg:SetColorTexture(0.2, 0.2, 0.2, 0.6)
else
    ratingFilterBg:SetTexture(0.2, 0.2, 0.2, 0.6)
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
    { label = "All Sources", value = nil   },
    { label = "Raid",        value = "raid"    },
    { label = "Dungeon",     value = "dungeon" },
    { label = "Group",       value = "group"   },
    { label = "Manual",      value = "manual"  },
}
local currentSourceFilterIdx = 1

local sourceFilterBtn = CreateFrame("Button", nil, f)
sourceFilterBtn:SetSize(80, 22)
sourceFilterBtn:SetPoint("LEFT", ratingFilterBtn, "RIGHT", 2, 0)
sourceFilterBtn:SetNormalFontObject(GameFontNormalSmall)
sourceFilterBtn:SetHighlightFontObject(GameFontHighlightSmall)
sourceFilterBtn:SetText("|cFFAADDFF" .. sourceFilterPresets[1].label .. "|r")

local sourceFilterBg = sourceFilterBtn:CreateTexture(nil, "BACKGROUND")
sourceFilterBg:SetAllPoints()
if sourceFilterBg.SetColorTexture then
    sourceFilterBg:SetColorTexture(0.2, 0.2, 0.2, 0.6)
else
    sourceFilterBg:SetTexture(0.2, 0.2, 0.2, 0.6)
end

sourceFilterBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Source Filter", 0.67, 0.87, 1)
    GameTooltip:AddLine("Left-click to cycle forward", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click to cycle back", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
sourceFilterBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

D("source filter button OK")

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
classFilterBtn:SetPoint("LEFT", sourceFilterBtn, "RIGHT", 2, 0)
classFilterBtn:SetNormalFontObject(GameFontNormalSmall)
classFilterBtn:SetHighlightFontObject(GameFontHighlightSmall)
classFilterBtn:SetText("|cFF" .. classFilterPresets[1].color .. classFilterPresets[1].label .. "|r")

local classFilterBg = classFilterBtn:CreateTexture(nil, "BACKGROUND")
classFilterBg:SetAllPoints()
if classFilterBg.SetColorTexture then
    classFilterBg:SetColorTexture(0.2, 0.2, 0.2, 0.6)
else
    classFilterBg:SetTexture(0.2, 0.2, 0.2, 0.6)
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
headerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -82)
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

-- Forward declare RefreshList (will be defined later, but we need it in header click)
local RefreshList

-- Header column definitions: { field, label, point, offsetX }
local HEADER_COLS = {
    { field = "name",   label = "Name",    point = "LEFT",  offsetX = 4   },
    { field = "level",  label = "Lv",      point = "LEFT",  offsetX = 120 },
    { field = "class",  label = "Class",   point = "LEFT",  offsetX = 155 },
    { field = "source", label = "Source",  point = "LEFT",  offsetX = 225 },
    { field = "seen",   label = "Last Seen", point = "LEFT", offsetX = 295 },
    { field = "rating", label = "Rating",  point = "RIGHT", offsetX = -4  },
}

local headerButtons = {}

local function UpdateHeaderArrows()
    for _, hb in ipairs(headerButtons) do
        if hb.field == sortField then
            local arrow = (sortDirection == "asc") and " |cFF00CCFF^|r" or " |cFF00CCFFv|r"
            hb.label:SetText("|cFFFFD100" .. hb.labelText .. arrow .. "|r")
        else
            hb.label:SetText("|cFF999999" .. hb.labelText .. "|r")
        end
    end
end

for i, col in ipairs(HEADER_COLS) do
    local btn = CreateFrame("Button", nil, headerBar)
    btn:SetHeight(HEADER_HEIGHT)

    if col.point == "RIGHT" then
        btn:SetPoint("RIGHT", headerBar, "RIGHT", col.offsetX, 0)
        btn:SetWidth(60)
    else
        -- Calculate width from this column to the next (or a default)
        local nextOffset = 9999
        for j = i + 1, #HEADER_COLS do
            if HEADER_COLS[j].point == "LEFT" then
                nextOffset = HEADER_COLS[j].offsetX
                break
            end
        end
        local w = math.min(nextOffset - col.offsetX, 100)
        btn:SetPoint("LEFT", headerBar, "LEFT", col.offsetX, 0)
        btn:SetWidth(w)
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
            self.label:SetText("|cFFCCCCCC" .. self.labelText .. "|r")
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

D("scroll frame OK")

----------------------------------------------------------------------
-- Row pool
----------------------------------------------------------------------
local rows = {}
-- Forward declaration so CreateRow closures can see it
local ShowDetailPanel

local function CreateRow(index)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Backdrop via mixin if available
    if BackdropTemplateMixin then
        Mixin(row, BackdropTemplateMixin)
        row:OnBackdropLoaded()
    end

    if row.SetBackdrop then
        row:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            insets = { left = 0, right = 0, top = 0, bottom = 1 },
        })
        if index % 2 == 0 then
            row:SetBackdropColor(0.12, 0.12, 0.15, 0.8)
        else
            row:SetBackdropColor(0.08, 0.08, 0.10, 0.8)
        end
    end

    -- Store base color for restoring after hover; updated per-row in RefreshList
    row.baseR, row.baseG, row.baseB, row.baseA = 0.08, 0.08, 0.10, 0.8

    -- Hover highlight
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

    -- Name + class + level (line 1)
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row.nameText:SetJustifyH("LEFT")

    -- Rating (right side)
    row.ratingText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.ratingText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.ratingText:SetJustifyH("RIGHT")

    -- Note (line 2)
    row.noteText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.noteText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -2)
    row.noteText:SetPoint("RIGHT", row.ratingText, "LEFT", -12, 0)
    row.noteText:SetJustifyH("LEFT")
    row.noteText:SetWordWrap(false)

    -- Source badge
    row.sourceText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sourceText:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 4)
    row.sourceText:SetJustifyH("RIGHT")

    row.playerKey = nil
    row:SetFrameLevel(content:GetFrameLevel() + 5)

    -- Left-click = detail, Right-click = context menu
    row:SetScript("OnClick", function(self, button)
        D("row clicked: " .. tostring(self.playerKey) .. " button=" .. tostring(button))
        if button == "RightButton" then
            RowMenu(self)
        elseif button == "LeftButton" then
            ShowDetailPanel(self.playerKey)
        end
    end)

    rows[index] = row
    return row
end

D("row pool code OK")

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
D("EasyMenu exists: " .. tostring(EasyMenu ~= nil))
D("UIDropDownMenu_Initialize exists: " .. tostring(UIDropDownMenu_Initialize ~= nil))

local menuFrame
local menuOK, menuErr = pcall(function()
    menuFrame = CreateFrame("Frame", "WTFAYDropDown", UIParent, "UIDropDownMenuTemplate")
end)
D("UIDropDownMenuTemplate create: " .. tostring(menuOK) .. " err=" .. tostring(menuErr))

function RowMenu(self)
    local key = self.playerKey
    D("RowMenu called for key=" .. tostring(key))
    if not key or not db or not db.players[key] then
        D("RowMenu: early return - key/db/player missing")
        return
    end
    local p = db.players[key]

    -- Build the whisper target: "Name-Realm" for cross-realm, "Name" for same-realm
    local whisperTarget = p.name
    local myRealm = GetRealmName() or ""
    if p.realm and p.realm ~= "" and p.realm ~= myRealm then
        whisperTarget = p.name .. "-" .. p.realm
    end

    if EasyMenu and menuFrame then
        D("RowMenu: using EasyMenu")
        local menu = {
            { text = ClassColor(p.class) .. p.name .. "|r", isTitle = true, notCheckable = true },
            { text = "Whisper",     notCheckable = true, func = function()
                ChatFrame_OpenChat("/w " .. whisperTarget .. " ")
            end },
            { text = "Invite",      notCheckable = true, func = function()
                InviteUnit(whisperTarget)
                P("Invited " .. ClassColor(p.class) .. p.name .. "|r")
            end },
            { text = "Set Rating",  notCheckable = true, func = function()
                ShowRatingPicker(key)
            end },
            { text = "Edit Note",   notCheckable = true, func = function()
                popupActiveKey = key
                StaticPopup_Show("WTFAY_EDIT_NOTE", p.name)
            end },
            { text = "|cFFFF4444Remove|r", notCheckable = true, func = function()
                popupActiveKey = key
                StaticPopup_Show("WTFAY_CONFIRM_REMOVE", p.name)
            end },
            { text = "Cancel", notCheckable = true },
        }
        local ok, err = pcall(EasyMenu, menu, menuFrame, "cursor", 0, 0, "MENU")
        D("EasyMenu result: ok=" .. tostring(ok) .. " err=" .. tostring(err))
    elseif UIDropDownMenu_Initialize and menuFrame then
        D("RowMenu: using UIDropDownMenu_Initialize fallback")
        UIDropDownMenu_Initialize(menuFrame, function(self, level)
            local info
            info = UIDropDownMenu_CreateInfo()
            info.text = ClassColor(p.class) .. p.name .. "|r"
            info.isTitle = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Whisper"
            info.notCheckable = true
            info.func = function() ChatFrame_OpenChat("/w " .. whisperTarget .. " ") end
            UIDropDownMenu_AddButton(info, level)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Invite"
            info.notCheckable = true
            info.func = function() InviteUnit(whisperTarget); P("Invited " .. ClassColor(p.class) .. p.name .. "|r") end
            UIDropDownMenu_AddButton(info, level)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Set Rating"
            info.notCheckable = true
            info.func = function() ShowRatingPicker(key) end
            UIDropDownMenu_AddButton(info, level)

            info = UIDropDownMenu_CreateInfo()
            info.text = "Edit Note"
            info.notCheckable = true
            info.func = function() popupActiveKey = key; StaticPopup_Show("WTFAY_EDIT_NOTE", p.name) end
            UIDropDownMenu_AddButton(info, level)

            info = UIDropDownMenu_CreateInfo()
            info.text = "|cFFFF4444Remove|r"
            info.notCheckable = true
            info.func = function() popupActiveKey = key; StaticPopup_Show("WTFAY_CONFIRM_REMOVE", p.name) end
            UIDropDownMenu_AddButton(info, level)
        end, "MENU")
        ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
    else
        D("RowMenu: NO menu system available, falling back to rating picker")
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
    countLabel:SetText("|cFFAAAAAA" .. total .. " player" .. (total == 1 and "" or "s") .. "|r")

    local parentH = scrollParent:GetHeight()
    local parentW = scrollParent:GetWidth()
    if parentH < 1 then parentH = MIN_H - 110 end
    local visibleRows = math.floor(parentH / ROW_HEIGHT)
    if visibleRows < 1 then visibleRows = 1 end

    D("RefreshList: total=" .. total .. " parentH=" .. string.format("%.0f", parentH)
      .. " parentW=" .. string.format("%.0f", parentW)
      .. " visibleRows=" .. visibleRows
      .. " contentW=" .. string.format("%.0f", content:GetWidth()))

    FauxScrollFrame_Update(scrollFrame, total, visibleRows, ROW_HEIGHT)

    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    for i = 1, visibleRows do
        local row = rows[i] or CreateRow(i)
        local dataIdx = offset + i
        if dataIdx <= total then
            local key = sortedKeys[dataIdx]
            local p   = db.players[key]

            local cc = ClassColor(p.class)
            local raceStr = (p.race and p.race ~= "") and ("|cFFBBBBBB" .. p.race .. "|r ") or ""
            row.nameText:SetText(cc .. p.name .. "|r  |cFFBBBBBBLv " .. (p.level or "?") .. "|r  " .. raceStr .. cc .. (p.class or "") .. "|r")
            row.ratingText:SetText(ColorRating(p.rating or 0))

            if p.note and p.note ~= "" then
                row.noteText:SetText("|cFFDDDDDD" .. p.note .. "|r")
            else
                row.noteText:SetText("|cFF666666(no note)|r")
            end

            local _, srcDisplay = GetPlayerSources(p)
            row.sourceText:SetText(srcDisplay .. " |cFF666666" .. (p.seen or "") .. "|r")

            row.playerKey = key

            -- Subtle row tint based on rating
            local r = p.rating or 0
            local baseEven = (dataIdx % 2 == 0)
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
        else
            row:Hide()
        end
    end

    for i = visibleRows + 1, #rows do
        rows[i]:Hide()
    end

    UpdateInboxTabLabel()
end

scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshList)
end)

searchBox:SetScript("OnTextChanged", function() RefreshList() end)

ratingFilterBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        currentRatingFilterIdx = currentRatingFilterIdx - 1
        if currentRatingFilterIdx < 1 then currentRatingFilterIdx = #ratingFilterPresets end
    else
        currentRatingFilterIdx = currentRatingFilterIdx + 1
        if currentRatingFilterIdx > #ratingFilterPresets then currentRatingFilterIdx = 1 end
    end
    self:SetText("|cFFFFD100" .. ratingFilterPresets[currentRatingFilterIdx].label .. "|r")
    RefreshList()
end)
ratingFilterBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

sourceFilterBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        currentSourceFilterIdx = currentSourceFilterIdx - 1
        if currentSourceFilterIdx < 1 then currentSourceFilterIdx = #sourceFilterPresets end
    else
        currentSourceFilterIdx = currentSourceFilterIdx + 1
        if currentSourceFilterIdx > #sourceFilterPresets then currentSourceFilterIdx = 1 end
    end
    self:SetText("|cFFAADDFF" .. sourceFilterPresets[currentSourceFilterIdx].label .. "|r")
    RefreshList()
end)
sourceFilterBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

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
        elseif RefreshInbox then
            RefreshInbox()
        end
    end)
end)

D("refresh list code OK")

-- Register database-specific UI elements for tab switching
dbElements = { searchBox, searchLabel, ratingFilterBtn, sourceFilterBtn, classFilterBtn, countLabel, headerBar, scrollParent, scrollFrame, content }

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
    inboxTitle:SetText("|cFFAAAAAAPlayers to review — rate or dismiss:|r")

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
        local row = CreateFrame("Frame", nil, inboxContentFrame)
        row:SetHeight(INBOX_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", inboxContentFrame, "TOPLEFT", 0, -((index - 1) * INBOX_ROW_HEIGHT))
        row:SetPoint("RIGHT", inboxContentFrame, "RIGHT", 0, 0)

        if BackdropTemplateMixin then Mixin(row, BackdropTemplateMixin); row:OnBackdropLoaded() end
        if row.SetBackdrop then
            row:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = nil, tile = true, tileSize = 16,
            })
            row:SetBackdropColor(0.1, 0.1, 0.13, 0.8)
        end

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)

        row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.infoText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -1)
        row.infoText:SetText("")

        -- Dismiss button
        row.dismissBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
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
        row.rateBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.rateBtn:SetSize(42, 20)
        row.rateBtn:SetPoint("RIGHT", row.dismissBtn, "LEFT", -4, 0)
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
                    if p.seen then parts[#parts + 1] = "|cFF666666" .. p.seen .. "|r" end
                    row.infoText:SetText("|cFFAAAAAA" .. table.concat(parts, "  ") .. "|r")
                    row.playerKey = key
                    -- Alternate row colors
                    if row.SetBackdropColor then
                        if i % 2 == 0 then
                            row:SetBackdropColor(0.12, 0.12, 0.15, 0.8)
                        else
                            row:SetBackdropColor(0.08, 0.08, 0.10, 0.8)
                        end
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

    inboxScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, INBOX_ROW_HEIGHT, RefreshInbox)
    end)
end

D("inbox tab OK")

-- Forward declaration for minimap button (created after settings, referenced by settings toggles)
local minimapBtn

----------------------------------------------------------------------
-- Settings Panel
----------------------------------------------------------------------
local settingsPanel = {}

do
    local sp = CreateFrame("Frame", "WTFAYSettingsPanel", UIParent)
    sp:SetSize(280, 460)
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
    if sp.SetBackdrop then
        sp:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        sp:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
    end

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
    spTitle:SetText("|cFF" .. ACCENT .. "WTFAY Settings|r")

    ----------------------------------------------------------------
    -- Tab bar
    ----------------------------------------------------------------
    local TAB_NAMES = { "General", "Alerts", "Display" }
    local tabButtons = {}
    local tabContents = {}
    local activeTab = "General"

    local tabWidth = 80
    local tabBarY = -36
    local totalWidth = tabWidth * #TAB_NAMES
    local startX = (280 - totalWidth) / 2

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
                if tabContents[n] then
                    if n == name then tabContents[n]:Show() else tabContents[n]:Hide() end
                end
                if tabButtons[n] then
                    if n == name then
                        tabButtons[n].label:SetTextColor(1, 0.82, 0.1)
                        tabButtons[n].underline:Show()
                    else
                        tabButtons[n].label:SetTextColor(0.6, 0.6, 0.6)
                        tabButtons[n].underline:Hide()
                    end
                end
            end
        end)

        tabButtons[name] = btn
    end

    -- Content frames (one per tab)
    for _, name in ipairs(TAB_NAMES) do
        local cf = CreateFrame("Frame", nil, sp)
        cf:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, tabBarY - 24)
        cf:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", 0, 60)
        cf:Hide()
        tabContents[name] = cf
    end

    -- Show default tab
    local function ShowTab(name)
        tabButtons[name]:GetScript("OnClick")()
    end

    ----------------------------------------------------------------
    -- Helper: create a toggle row (checkbox + label + description)
    ----------------------------------------------------------------
    local function CreateToggle(parent, yOffset, label, description, getter, setter)
        local row = CreateFrame("CheckButton", nil, parent)
        row:SetSize(24, 24)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        row:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", row, "RIGHT", 4, 0)
        lbl:SetText(label)

        local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
        desc:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText("|cFF888888" .. description .. "|r")
        desc:SetWordWrap(true)

        row:SetScript("OnClick", function(self)
            local val = self:GetChecked() and true or false
            setter(val)
        end)

        row.Refresh = function()
            row:SetChecked(getter())
        end

        return row
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
            P("Debug mode: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local autoTrackToggle = CreateToggle(gc, -60,
        "Auto-Track Party Members",
        "Automatically add or update players when you join a party, raid, or dungeon.",
        function() return db and db.settings and db.settings.autoTrack or false end,
        function(val)
            if db and db.settings then db.settings.autoTrack = val end
            P("Auto-tracking: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
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
            P("Known player alerts: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local alertJoinToggle = CreateToggle(ac, -48,
        "  Player Joins",
        "Alert when a known player joins your group.",
        function() return db and db.settings and db.settings.alertOnJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnJoin = val end
            P("Alert on join: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local alertLeaveToggle = CreateToggle(ac, -86,
        "  Player Leaves",
        "Alert when a known player leaves your group.",
        function() return db and db.settings and db.settings.alertOnLeave or false end,
        function(val)
            if db and db.settings then db.settings.alertOnLeave = val end
            P("Alert on leave: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local alertMeJoinToggle = CreateToggle(ac, -124,
        "  I Join a Group",
        "Alert when you join a group with known players already in it.",
        function() return db and db.settings and db.settings.alertOnMeJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnMeJoin = val end
            P("Alert on me join: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local alertPopupToggle = CreateToggle(ac, -174,
        "Alert Popup Panel",
        "Also show a popup panel with known players (not just chat).",
        function() return db and db.settings and db.settings.alertPopup or false end,
        function(val)
            if db and db.settings then db.settings.alertPopup = val end
            P("Alert popup: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    local alertSoundToggle = CreateToggle(ac, -224,
        "Alert Sound",
        "Play a sound when the known player alert appears.",
        function() return db and db.settings and db.settings.alertSound or false end,
        function(val)
            if db and db.settings then db.settings.alertSound = val end
            P("Alert sound: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Sound picker label + dropdown + preview button
    local soundLabel = ac:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLabel:SetPoint("TOPLEFT", ac, "TOPLEFT", 22, -268)
    soundLabel:SetText("|cFFBBBBBBSound:|r")

    local soundDropdown = CreateFrame("Frame", "WTFAYSoundDropdownStandalone", ac, "UIDropDownMenuTemplate")
    soundDropdown:SetPoint("LEFT", soundLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(soundDropdown, 130)

    local function SoundDropdown_Init(self, level)
        for i, s in ipairs(ALERT_SOUNDS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s.name
            info.value = i
            info.func = function()
                if db and db.settings then db.settings.alertSoundChoice = i end
                UIDropDownMenu_SetSelectedValue(soundDropdown, i)
                UIDropDownMenu_SetText(soundDropdown, s.name)
                PlaySound(s.normal)
            end
            info.checked = (db and db.settings and db.settings.alertSoundChoice == i)
            UIDropDownMenu_AddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(soundDropdown, SoundDropdown_Init)

    local previewBtn = CreateFrame("Button", nil, ac, "UIPanelButtonTemplate")
    previewBtn:SetSize(40, 22)
    previewBtn:SetPoint("LEFT", soundDropdown, "RIGHT", -4, 2)
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

    local skipGuildToggle = CreateToggle(ac, -304,
        "Skip Guild Members in Alerts",
        "Don't show alerts for players in your guild.",
        function() return db and db.settings and db.settings.alertSkipGuild or false end,
        function(val)
            if db and db.settings then db.settings.alertSkipGuild = val end
            P("Skip guild in alerts: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
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
            P("Minimap button: " .. (val and "|cFF44FF44shown|r" or "|cFFFF4444hidden|r"))
        end
    )

    ----------------------------------------------------------------
    -- Common: About + Done (always visible)
    ----------------------------------------------------------------
    local aboutLabel = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aboutLabel:SetPoint("BOTTOM", sp, "BOTTOM", 0, 38)
    aboutLabel:SetText("|cFF888888v" .. ADDON_VERSION .. "  -  Developed by |r|cFF" .. ACCENT .. "goosefraba|r")

    local doneBtn = CreateFrame("Button", nil, sp, "UIPanelButtonTemplate")
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", sp, "BOTTOM", 0, 12)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() sp:Hide() end)

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
        local idx = db and db.settings and db.settings.alertSoundChoice or 1
        UIDropDownMenu_SetSelectedValue(soundDropdown, idx)
        UIDropDownMenu_SetText(soundDropdown, (ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]).name)
        ShowTab(activeTab)
    end)

    -- Public interface
    settingsPanel.Toggle = function()
        if sp:IsShown() then sp:Hide() else sp:Show() end
    end
    settingsPanel.frame = sp

    -- Initialize default tab
    ShowTab("General")
end

D("settings panel OK")

----------------------------------------------------------------------
-- Blizzard Interface Options panel (AddOns tab)
----------------------------------------------------------------------
do
    local optPanel = CreateFrame("Frame", "WTFAYOptionsPanel", UIParent)
    optPanel.name = "WTFAY"

    -- Title
    local optTitle = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    optTitle:SetPoint("TOPLEFT", 16, -16)
    optTitle:SetText("|cFF" .. ACCENT .. "WTFAY|r - Who The F* Are You?  |cFF888888v" .. ADDON_VERSION .. "|r")

    -- Subtitle
    local optSub = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -8)
    optSub:SetText("Track, rate, and remember every player you group with.")

    -- Helper: checkbox for Blizzard panel
    local function BlizCheckbox(parent, yOffset, label, description, getter, setter)
        local cb = CreateFrame("CheckButton", nil, parent)
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)

        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

        local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1)
        lbl:SetText(label)

        local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
        desc:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText(description)
        desc:SetWordWrap(true)

        cb:SetScript("OnClick", function(self)
            local val = self:GetChecked() and true or false
            setter(val)
        end)

        cb.Refresh = function()
            cb:SetChecked(getter())
        end

        return cb
    end

    -- Debug toggle
    local optDebug = BlizCheckbox(optPanel, -60,
        "Debug Logging",
        "Show verbose [WTFAY-DBG] messages in chat. Useful for troubleshooting.",
        function() return DEBUG end,
        function(val)
            DEBUG = val
            if db and db.settings then db.settings.debug = val end
            P("Debug mode: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Auto-track toggle
    local optAutoTrack = BlizCheckbox(optPanel, -110,
        "Auto-Track Party Members",
        "Automatically add or update players when you join a party, raid, or dungeon.",
        function() return db and db.settings and db.settings.autoTrack or false end,
        function(val)
            if db and db.settings then db.settings.autoTrack = val end
            P("Auto-tracking: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Known player alerts toggle (master)
    local optKnownAlerts = BlizCheckbox(optPanel, -160,
        "Known Player Alerts",
        "Master toggle for all known player notifications.",
        function() return db and db.settings and db.settings.knownAlerts or false end,
        function(val)
            if db and db.settings then db.settings.knownAlerts = val end
            P("Known player alerts: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Sub-toggle: Player Joins
    local optAlertJoin = BlizCheckbox(optPanel, -198,
        "  Player Joins",
        "Alert when a known player joins your group.",
        function() return db and db.settings and db.settings.alertOnJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnJoin = val end
            P("Alert on join: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Sub-toggle: Player Leaves
    local optAlertLeave = BlizCheckbox(optPanel, -236,
        "  Player Leaves",
        "Alert when a known player leaves your group.",
        function() return db and db.settings and db.settings.alertOnLeave or false end,
        function(val)
            if db and db.settings then db.settings.alertOnLeave = val end
            P("Alert on leave: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Sub-toggle: I Join Group
    local optAlertMeJoin = BlizCheckbox(optPanel, -274,
        "  I Join a Group",
        "Alert when you join a group with known players already in it.",
        function() return db and db.settings and db.settings.alertOnMeJoin or false end,
        function(val)
            if db and db.settings then db.settings.alertOnMeJoin = val end
            P("Alert on me join: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Alert popup toggle
    local optAlertPopup = BlizCheckbox(optPanel, -324,
        "Alert Popup Panel",
        "Also show a popup panel with known players (not just chat).",
        function() return db and db.settings and db.settings.alertPopup or false end,
        function(val)
            if db and db.settings then db.settings.alertPopup = val end
            P("Alert popup: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Alert sound toggle
    local optAlertSound = BlizCheckbox(optPanel, -374,
        "Alert Sound",
        "Play a sound when the known player alert appears.",
        function() return db and db.settings and db.settings.alertSound or false end,
        function(val)
            if db and db.settings then db.settings.alertSound = val end
            P("Alert sound: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Sound picker dropdown (Blizzard panel)
    local optSoundLabel = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    optSoundLabel:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 22, -418)
    optSoundLabel:SetText("Sound:")

    local optSoundDropdown = CreateFrame("Frame", "WTFAYSoundDropdownBliz", optPanel, "UIDropDownMenuTemplate")
    optSoundDropdown:SetPoint("LEFT", optSoundLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(optSoundDropdown, 130)

    local function OptSoundDropdown_Init(self, level)
        for i, s in ipairs(ALERT_SOUNDS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s.name
            info.value = i
            info.func = function()
                if db and db.settings then db.settings.alertSoundChoice = i end
                UIDropDownMenu_SetSelectedValue(optSoundDropdown, i)
                UIDropDownMenu_SetText(optSoundDropdown, s.name)
                PlaySound(s.normal)
            end
            info.checked = (db and db.settings and db.settings.alertSoundChoice == i)
            UIDropDownMenu_AddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(optSoundDropdown, OptSoundDropdown_Init)

    local optPreviewBtn = CreateFrame("Button", nil, optPanel, "UIPanelButtonTemplate")
    optPreviewBtn:SetSize(40, 22)
    optPreviewBtn:SetPoint("LEFT", optSoundDropdown, "RIGHT", -4, 2)
    optPreviewBtn:SetText("Test")
    optPreviewBtn:SetScript("OnClick", function()
        local idx = db and db.settings and db.settings.alertSoundChoice or 1
        local choice = ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]
        PlaySound(choice.normal)
    end)
    optPreviewBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Preview sound")
        GameTooltip:Show()
    end)
    optPreviewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Skip guild toggle
    local optSkipGuild = BlizCheckbox(optPanel, -462,
        "Skip Guild Members in Alerts",
        "Don't show alerts for players in your guild.",
        function() return db and db.settings and db.settings.alertSkipGuild or false end,
        function(val)
            if db and db.settings then db.settings.alertSkipGuild = val end
            P("Skip guild in alerts: " .. (val and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))
        end
    )

    -- Minimap button toggle
    local optMinimap = BlizCheckbox(optPanel, -512,
        "Minimap Button",
        "Show the WTFAY icon on your minimap for quick access.",
        function() return not (db and db.minimapHidden) end,
        function(val)
            if db then db.minimapHidden = not val end
            if val then minimapBtn:Show() else minimapBtn:Hide() end
            P("Minimap button: " .. (val and "|cFF44FF44shown|r" or "|cFFFF4444hidden|r"))
        end
    )

    -- About / credit
    local optAbout = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optAbout:SetPoint("BOTTOMLEFT", optPanel, "BOTTOMLEFT", 16, 32)
    optAbout:SetText("|cFF888888v" .. ADDON_VERSION .. "  -  Developed by |r|cFF" .. ACCENT .. "goosefraba|r")

    -- Info text at the bottom
    local optInfo = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    optInfo:SetPoint("BOTTOMLEFT", optPanel, "BOTTOMLEFT", 16, 16)
    optInfo:SetText("|cFF888888Type /wtfay to open the player browser.  /wtfay help for all commands.|r")

    -- Refresh checkboxes when panel is shown
    optPanel:SetScript("OnShow", function()
        optDebug.Refresh()
        optAutoTrack.Refresh()
        optKnownAlerts.Refresh()
        optAlertJoin.Refresh()
        optAlertLeave.Refresh()
        optAlertMeJoin.Refresh()
        optAlertPopup.Refresh()
        optAlertSound.Refresh()
        optSkipGuild.Refresh()
        optMinimap.Refresh()
        -- Refresh sound dropdown
        local idx = db and db.settings and db.settings.alertSoundChoice or 1
        UIDropDownMenu_SetSelectedValue(optSoundDropdown, idx)
        UIDropDownMenu_SetText(optSoundDropdown, (ALERT_SOUNDS[idx] or ALERT_SOUNDS[1]).name)
    end)

    -- Store reference; registration happens in PLAYER_LOGIN to ensure Blizzard UI is fully ready
    settingsPanel.blizPanel = optPanel
    settingsPanel.RegisterBliz = function()
        D("RegisterBliz called")
        D("InterfaceOptions_AddCategory exists: " .. tostring(InterfaceOptions_AddCategory ~= nil))
        D("optPanel.name = " .. tostring(optPanel.name))
        D("optPanel type = " .. tostring(type(optPanel)))

        if not InterfaceOptions_AddCategory then
            D("InterfaceOptions_AddCategory does not exist! Trying Settings.RegisterAddOnCategory...")
            -- Retail / newer API fallback
            if Settings and Settings.RegisterAddOnCategory then
                local category = Settings.RegisterCanvasLayoutCategory(optPanel, optPanel.name)
                if category then
                    Settings.RegisterAddOnCategory(category)
                    D("Registered via Settings API")
                end
            else
                D("No options registration API found.")
            end
            return
        end

        local regOK, regErr = pcall(function()
            InterfaceOptions_AddCategory(optPanel)
        end)
        D("InterfaceOptions_AddCategory: ok=" .. tostring(regOK) .. " err=" .. tostring(regErr))
        if not regOK then
            D("Will not be visible in Interface Options. Using standalone panel instead.")
        end
    end
    settingsPanel.OpenBliz = function()
        local ok, err = pcall(function()
            InterfaceOptionsFrame_OpenToCategory(optPanel)
            -- Need to call twice in some versions due to a Blizzard bug
            InterfaceOptionsFrame_OpenToCategory(optPanel)
        end)
        if not ok then
            D("OpenBliz error: " .. tostring(err))
            -- Fallback: open standalone panel
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
        if settingsPanel and settingsPanel.OpenBliz then
            settingsPanel.OpenBliz()
        elseif settingsPanel and settingsPanel.Toggle then
            settingsPanel.Toggle()
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
local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
addBtn:SetSize(100, 22)
addBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
addBtn:SetText("Add Target")
addBtn:SetScript("OnClick", function()
    AddTargetPlayer()
end)

local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
settingsBtn:SetSize(70, 22)
settingsBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
settingsBtn:SetText("Settings")
settingsBtn:SetScript("OnClick", function()
    if settingsPanel.OpenBliz then
        settingsPanel.OpenBliz()
    else
        settingsPanel.Toggle()
    end
end)

local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
exportBtn:SetSize(60, 22)
exportBtn:SetPoint("LEFT", settingsBtn, "RIGHT", 4, 0)
exportBtn:SetText("Export")
exportBtn:SetScript("OnClick", function()
    if importExportPanel.ShowExport then importExportPanel.ShowExport() end
end)

local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
importBtn:SetSize(60, 22)
importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 4, 0)
importBtn:SetText("Import")
importBtn:SetScript("OnClick", function()
    if importExportPanel.ShowImport then importExportPanel.ShowImport() end
end)

local statsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
statsBtn:SetSize(50, 22)
statsBtn:SetPoint("LEFT", importBtn, "RIGHT", 4, 0)
statsBtn:SetText("Stats")
statsBtn:SetScript("OnClick", function()
    if statsPanel and statsPanel.Toggle then statsPanel.Toggle() end
end)

local helpBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
helpBtn:SetSize(50, 22)
helpBtn:SetPoint("LEFT", statsBtn, "RIGHT", 4, 0)
helpBtn:SetText("Help")
helpBtn:SetScript("OnClick", function()
    if helpPanel and helpPanel.Toggle then helpPanel.Toggle() end
end)

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
        return s:gsub("\t", FIELD_ESC_TAB)
    end
    local function UnescField(s)
        s = (s or ""):gsub(FIELD_ESC_TAB, "\t")
        return s:gsub(FIELD_ESC_PIPE, "|")
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
                    tostring(p.rating or 0),
                    EscField(p.note or ""),
                    EscField(p.source or "manual"),
                    EscField(p.seen or ""),
                }
                lines[#lines + 1] = table.concat(parts, SEP)
            end
        end
        return table.concat(lines, "\n")
    end

    local function ImportDB(text)
        if not text or text == "" then return 0, 0 end
        local lines = { strsplit("\n", text) }
        local added, updated = 0, 0

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
            local line = (lines[i] or ""):trim()
            if line ~= "" then
                local parts = { strsplit(lineSep, line) }
                -- Need at least: key, name, realm, class, race, level, rating, note, source, seen
                if #parts >= 10 then
                    local key     = UnescField(parts[1])
                    local name    = UnescField(parts[2])
                    local realm   = UnescField(parts[3])
                    local class   = UnescField(parts[4])
                    local race    = UnescField(parts[5])
                    local level   = tonumber(parts[6]) or 0
                    local rating  = tonumber(parts[7]) or 0
                    local note    = UnescField(parts[8])
                    local source  = UnescField(parts[9])
                    local seen    = UnescField(parts[10])

                    if key ~= "" and name ~= "" then
                        if db.players[key] then
                            -- Merge: keep higher absolute rating, append note if different
                            local existing = db.players[key]
                            if math.abs(rating) > math.abs(existing.rating or 0) then
                                existing.rating = rating
                            end
                            if note ~= "" and note ~= existing.note then
                                if (existing.note or "") == "" then
                                    existing.note = note
                                else
                                    existing.note = existing.note .. " | " .. note
                                end
                            end
                            -- Update level if imported is higher
                            if level > (existing.level or 0) then
                                existing.level = level
                            end
                            -- Update class/race if we had Unknown
                            if (existing.class or "Unknown") == "Unknown" and class ~= "Unknown" then
                                existing.class = class
                            end
                            if (existing.race or "") == "" and race ~= "" then
                                existing.race = race
                            end
                            updated = updated + 1
                        else
                            db.players[key] = {
                                name       = name,
                                realm      = realm,
                                class      = class,
                                race       = race,
                                level      = level,
                                rating     = rating,
                                note       = note,
                                source     = source,
                                seen       = seen,
                                encounters = {},
                            }
                            added = added + 1
                        end
                    end
                end
            end
        end
        return added, updated
    end

    -- Export panel: scrollable editbox with select-all
    local expFrame = CreateFrame("Frame", "WTFAYExportFrame", UIParent)
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
    if expFrame.SetBackdrop then
        expFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        expFrame:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
    end

    do local nm = expFrame:GetName(); if nm then tinsert(UISpecialFrames, nm) end end

    local expClose = CreateFrame("Button", nil, expFrame, "UIPanelCloseButton")
    expClose:SetPoint("TOPRIGHT", -2, -2)

    local expTitle = expFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    expTitle:SetPoint("TOP", 0, -14)

    local expHint = expFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expHint:SetPoint("TOP", expTitle, "BOTTOM", 0, -4)

    -- ScrollFrame + EditBox for the text
    local expScroll = CreateFrame("ScrollFrame", "WTFAYExportScroll", expFrame, "UIPanelScrollFrameTemplate")
    expScroll:SetPoint("TOPLEFT", 14, -52)
    expScroll:SetPoint("BOTTOMRIGHT", -32, 44)

    local expEditBox = CreateFrame("EditBox", "WTFAYExportEditBox", expScroll)
    expEditBox:SetMultiLine(true)
    expEditBox:SetAutoFocus(false)
    expEditBox:SetFontObject(ChatFontNormal)
    expEditBox:SetWidth(450)
    expEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); expFrame:Hide() end)
    expScroll:SetScrollChild(expEditBox)

    -- Bottom buttons: Close (default), Merge + Replace (import mode)
    local btnClose = CreateFrame("Button", nil, expFrame, "UIPanelButtonTemplate")
    btnClose:SetSize(80, 22)
    btnClose:SetPoint("BOTTOM", 0, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() expFrame:Hide() end)

    local btnMerge = CreateFrame("Button", nil, expFrame, "UIPanelButtonTemplate")
    btnMerge:SetSize(100, 22)
    btnMerge:SetPoint("BOTTOMLEFT", expFrame, "BOTTOMLEFT", 60, 12)
    btnMerge:SetText("Merge")
    btnMerge:Hide()

    local btnReplace = CreateFrame("Button", nil, expFrame, "UIPanelButtonTemplate")
    btnReplace:SetSize(100, 22)
    btnReplace:SetPoint("LEFT", btnMerge, "RIGHT", 8, 0)
    btnReplace:SetText("|cFFFF6666Replace All|r")
    btnReplace:Hide()

    local btnCancel = CreateFrame("Button", nil, expFrame, "UIPanelButtonTemplate")
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
        expHint:SetText("|cFF888888Select all (Ctrl+A), copy (Ctrl+C), and share with a friend.|r")
        expEditBox:SetText(ExportDB())
        expEditBox:SetCursorPosition(0)
        ResetButtons()
        expFrame:Show()
        expEditBox:SetFocus()
        expEditBox:HighlightText()
    end

    importExportPanel.ShowImport = function()
        expTitle:SetText("|cFF" .. ACCENT .. "Import WTFAY Database|r")
        expHint:SetText("|cFF888888Paste exported data below. Merge adds new + updates existing. Replace overwrites everything.|r")
        expEditBox:SetText("")

        -- Show import buttons, hide close
        btnClose:Hide()
        btnMerge:Show()
        btnReplace:Show()
        btnCancel:Show()

        btnMerge:SetScript("OnClick", function()
            local text = expEditBox:GetText()
            if text == "" then P("Nothing to import."); expFrame:Hide(); ResetButtons(); return end
            local added, updated = ImportDB(text)
            P("Merge complete: |cFF44FF44" .. added .. " added|r, |cFFFFCC44" .. updated .. " updated|r")
            RefreshList()
            expFrame:Hide()
            ResetButtons()
        end)

        btnReplace:SetScript("OnClick", function()
            local text = expEditBox:GetText()
            if text == "" then P("Nothing to import."); expFrame:Hide(); ResetButtons(); return end
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
            })
            local backupCount = 0
            for _ in pairs(backup) do backupCount = backupCount + 1 end
            db.backups[1].count = backupCount
            while #db.backups > 3 do
                table.remove(db.backups)
            end
            P("Backup created (" .. backupCount .. " players saved). Use |cFFFFD100/wtfay restore|r to undo.")
            -- Wipe existing data and import fresh
            wipe(db.players)
            local added, _ = ImportDB(text)
            P("Replace complete: |cFF44FF44" .. added .. " players|r imported (old data wiped)")
            RefreshList()
            expFrame:Hide()
            ResetButtons()
        end)

        btnCancel:SetScript("OnClick", function()
            expFrame:Hide()
            ResetButtons()
        end)

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
    local sp = CreateFrame("Frame", "WTFAYStatsPanel", UIParent)
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
    if sp.SetBackdrop then
        sp:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        sp:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
    end

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

    lineSep1:SetText("|cFF444444———————————————————————|r")
    lineSep2:SetText("|cFF444444———————————————————————|r")

    -- Helper: colored count bar
    local function StatLine(label, count, total, color)
        local pct = total > 0 and math.floor(count / total * 100) or 0
        return "|cFF" .. color .. label .. "|r  |cFFFFFFFF" .. count .. "|r  |cFF888888(" .. pct .. "%)|r"
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
            local r = p.rating or 0
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

        lineTotalPlayers:SetText("|cFFFFFFFFTotal Players:|r  |cFF" .. ACCENT .. totalPlayers .. "|r")
        lineAvgRating:SetText("|cFFFFFFFFAverage Rating:|r  " .. ColorRating(math.floor(avgRating + 0.5)) .. " |cFF888888(" .. avgStr .. ")|r")

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

        lineEncounters:SetText("|cFFFFFFFFTotal Encounters:|r  |cFF" .. ACCENT .. totalEncounters .. "|r")
    end

    sp:SetScript("OnShow", RefreshStats)

    -- Done button
    local doneBtn = CreateFrame("Button", nil, sp, "UIPanelButtonTemplate")
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
    local hp = CreateFrame("Frame", "WTFAYHelpPanel", UIParent)
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
    if hp.SetBackdrop then
        hp:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        hp:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
    end

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
        "Open the main panel by typing |cFFFFD100/wtfay|r or clicking the minimap icon.",
        "You can also bind it to a key or use a macro!",
        " ",
        "|cFF" .. ACCENT .. "--- Adding Players ---|r",
        "The easiest way to add a player is to |cFFFFFFFFtarget them|r and click the",
        "|cFFFFD100Add Target|r button, or type |cFFFFD100/wtfay target|r.",
        " ",
        "|cFFFF8800Pro Tip:|r Create a macro for quick access:",
        " ",
        "|cFF44FF44/run SlashCmdList[\"WTFAY\"](\"target\")|r",
        " ",
        "Put this on your action bar and you can add any targeted player",
        "with a single click! Their name, class, race, and level are",
        "detected automatically.",
        " ",
        "You can also add players manually:",
        "  |cFFFFD100/wtfay add Playername|r",
        "  |cFFFFD100/wtfay add Playername-Realm|r",
        " ",
        "|cFF" .. ACCENT .. "--- Rating Players ---|r",
        "Rate players from |cFFFF4444-3|r (blacklist) to |cFFFFD7005|r (legend):",
        "  |cFFFF4444-3|r = Blacklisted  |cFFFF8844-2/-1|r = Negative",
        "  |cFFCCCCCC 0|r = Neutral       |cFF44FF441-4|r = Positive",
        "  |cFFFFD700 5|r = Legend",
        " ",
        "Click a player row, then use the rating stars in the detail view.",
        "Or right-click a row and choose |cFFFFD100Set Rating|r.",
        "Or via command: |cFFFFD100/wtfay rate Playername 3|r",
        " ",
        "|cFF" .. ACCENT .. "--- Notes ---|r",
        "Add notes to remember specific details about a player.",
        "Right-click a row and choose |cFFFFD100Edit Note|r,",
        "or: |cFFFFD100/wtfay note Playername Great tank, marks targets|r",
        " ",
        "|cFF" .. ACCENT .. "--- Browsing & Filtering ---|r",
        "The main panel has several tools at the top:",
        "  |cFFFFFFFFSearch|r - Filter by player name",
        "  |cFFFFFFFFRating filter|r - Show only certain ratings (click to cycle)",
        "  |cFFFFFFFFSource filter|r - Show Raid / Dungeon / Group / Manual",
        "  |cFFFFFFFFClass filter|r - Show only a specific class",
        " ",
        "All filters support |cFFFFD100left-click|r (forward) and |cFFFFD100right-click|r (backward).",
        " ",
        "Click any |cFFFFFFFFcolumn header|r to sort. Click again to reverse.",
        " ",
        "|cFF" .. ACCENT .. "--- Auto-Tracking ---|r",
        "When enabled (Settings), WTFAY automatically adds players you",
        "group with in parties, dungeons, and raids. Dungeon and raid",
        "encounters include the zone name. Toggle in Settings or:",
        "  |cFFFFD100Interface > AddOns > WTFAY|r",
        " ",
        "|cFF" .. ACCENT .. "--- Import / Export ---|r",
        "Share your database with friends!",
        "  |cFFFFD100Export|r - Copies your data as text. Send it to a friend.",
        "  |cFFFFD100Import|r - Paste data from a friend.",
        "    |cFFFFFFFFMerge|r keeps your existing data and adds new entries.",
        "    |cFFFFFFFFReplace All|r wipes your data first (a backup is created).",
        "  |cFFFFD100/wtfay restore|r - Undo the last Replace All.",
        " ",
        "|cFF" .. ACCENT .. "--- Quick Reference ---|r",
        "  |cFFFFD100/wtfay|r - Toggle panel",
        "  |cFFFFD100/wtfay target|r - Add current target",
        "  |cFFFFD100/wtfay add Name|r - Add manually",
        "  |cFFFFD100/wtfay remove Name|r - Remove player",
        "  |cFFFFD100/wtfay rate Name 3|r - Rate player",
        "  |cFFFFD100/wtfay note Name text|r - Set note",
        "  |cFFFFD100/wtfay search term|r - Search",
        "  |cFFFFD100/wtfay export / import|r - Data sharing",
        "  |cFFFFD100/wtfay restore|r - Undo replace",
        "  |cFFFFD100/wtfay stats|r - Database stats",
        "  |cFFFFD100/wtfay settings|r - Settings",
        "  |cFFFFD100/wtfay minimap|r - Toggle minimap icon",
        "  |cFFFFD100/wtfay help|r - Chat help",
        " ",
        "|cFF888888v" .. ADDON_VERSION .. "  -  Developed by goosefraba|r",
    }

    hpText:SetText(table.concat(helpLines, "\n"))

    -- Resize content frame to fit the text
    hp:SetScript("OnShow", function()
        local textH = hpText:GetStringHeight() or 400
        hpContent:SetSize(390, textH + 10)
    end)

    -- Close button at bottom
    local hpDone = CreateFrame("Button", nil, hp, "UIPanelButtonTemplate")
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
            db.players[key].note = note
            if note ~= "" and db.players[key].pending then
                db.players[key].pending = nil
                P("Note updated for " .. db.players[key].name .. " |cFF44FF44(moved to database)|r")
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
            if eb then
                if key and db and db.players[key] then
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
ratingPicker:SetSize(320, 130)
ratingPicker:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
ratingPicker:SetFrameStrata("FULLSCREEN_DIALOG")
ratingPicker:SetMovable(true)
ratingPicker:EnableMouse(true)
ratingPicker:RegisterForDrag("LeftButton")
ratingPicker:SetClampedToScreen(true)
ratingPicker:SetScript("OnDragStart", function(s) s:StartMoving() end)
ratingPicker:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
ratingPicker:Hide()

if BackdropTemplateMixin then
    Mixin(ratingPicker, BackdropTemplateMixin)
    ratingPicker:OnBackdropLoaded()
end
if ratingPicker.SetBackdrop then
    ratingPicker:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    ratingPicker:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
end

-- Close on Escape
do
    local name = ratingPicker:GetName()
    if name then tinsert(UISpecialFrames, name) end
end

-- Title
local rpTitle = ratingPicker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
rpTitle:SetPoint("TOP", ratingPicker, "TOP", 0, -12)

-- Subtitle labels
local rpBad = ratingPicker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rpBad:SetPoint("TOPLEFT", ratingPicker, "TOPLEFT", 14, -30)
rpBad:SetText("|cFFFF4444Avoid|r")

local rpGood = ratingPicker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rpGood:SetPoint("TOPRIGHT", ratingPicker, "TOPRIGHT", -14, -30)
rpGood:SetText("|cFF44FF44Great|r")

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

-- Create 9 buttons for -3 to +5
local ratingButtons = {}
local BTN_SIZE = 30
local BTN_GAP = 2
local totalW = 9 * BTN_SIZE + 8 * BTN_GAP
local startX = (320 - totalW) / 2

for i = -3, 5 do
    local idx = i + 4  -- 1-based index
    local btn = CreateFrame("Button", nil, ratingPicker)
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    btn:SetPoint("TOPLEFT", ratingPicker, "TOPLEFT", startX + (idx - 1) * (BTN_SIZE + BTN_GAP), -44)

    -- Color the button background based on rating
    local r, g, b
    if i < 0 then
        local pct = (i + 3) / 3  -- 0 at -3, 1 at 0
        r, g, b = 1.0, pct * 0.6, 0
    else
        local pct = i / 5  -- 0 at 0, 1 at 5
        r, g, b = 1.0 - pct * 0.7, 0.5 + pct * 0.5, 0
    end

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if bg.SetColorTexture then
        bg:SetColorTexture(r, g, b, 0.85)
    else
        bg:SetTexture(r, g, b, 0.85)
    end

    -- Highlight on hover
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if hl.SetColorTexture then
        hl:SetColorTexture(1, 1, 1, 0.3)
    else
        hl:SetTexture(1, 1, 1, 0.3)
    end

    -- Number label
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    local sign = i > 0 and "+" or ""
    label:SetText("|cFFFFFFFF" .. sign .. i .. "|r")

    btn.ratingValue = i
    btn.bgTex = bg
    ratingButtons[idx] = btn
end

-- Description text (updates on hover)
local rpDesc = ratingPicker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
rpDesc:SetPoint("TOP", ratingPicker, "TOP", 0, -80)
rpDesc:SetText("")

-- Current rating indicator
local rpCurrent = ratingPicker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rpCurrent:SetPoint("TOP", rpDesc, "BOTTOM", 0, -2)
rpCurrent:SetText("")

-- Cancel button
local rpCancel = CreateFrame("Button", nil, ratingPicker, "UIPanelButtonTemplate")
rpCancel:SetSize(70, 22)
rpCancel:SetPoint("BOTTOM", ratingPicker, "BOTTOM", 0, 10)
rpCancel:SetText("Cancel")
rpCancel:SetScript("OnClick", function() ratingPicker:Hide() end)

-- Set up hover and click for each button
for idx, btn in ipairs(ratingButtons) do
    btn:SetScript("OnEnter", function(self)
        local v = self.ratingValue
        rpDesc:SetText("|cFFFFFFFF" .. RATING_LABELS[v] .. "|r")
    end)
    btn:SetScript("OnLeave", function()
        rpDesc:SetText("")
    end)
    btn:SetScript("OnClick", function(self)
        local ok, err = pcall(function()
            local key = popupActiveKey
            D("RatingPicker click: val=" .. self.ratingValue .. " key=" .. tostring(key))
            if not key or not db or not db.players[key] then return end
            db.players[key].rating = self.ratingValue
            if db.players[key].pending then
                db.players[key].pending = nil
                P(db.players[key].name .. " rated " .. ColorRating(self.ratingValue) .. " |cFF44FF44(moved to database)|r")
            else
                P(db.players[key].name .. " rated " .. ColorRating(self.ratingValue))
            end
            RefreshList()
            if RefreshInbox then RefreshInbox() end
            UpdateInboxTabLabel()
            ratingPicker:Hide()
        end)
        if not ok then D("RatingPicker ERROR: " .. tostring(err)) end
    end)
end

-- Public function to show the picker
ShowRatingPicker = function(key)
    popupActiveKey = key
    local p = db and db.players[key]
    if not p then return end
    rpTitle:SetText("Rate " .. ClassColor(p.class) .. p.name .. "|r")
    rpCurrent:SetText("|cFF888888Current: " .. ColorRating(p.rating or 0) .. "|r")

    -- Highlight current rating button with a border effect
    for idx, btn in ipairs(ratingButtons) do
        if btn.ratingValue == (p.rating or 0) then
            btn.bgTex:SetAlpha(1.0)
            -- Make current one slightly bigger to stand out
            btn:SetSize(BTN_SIZE + 4, BTN_SIZE + 4)
        else
            btn.bgTex:SetAlpha(0.7)
            btn:SetSize(BTN_SIZE, BTN_SIZE)
        end
    end

    ratingPicker:Show()
end

StaticPopupDialogs["WTFAY_CONFIRM_REMOVE"] = {
    text = "Remove |cFFFF6666%s|r from WTFAY?",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self)
        local ok, err = pcall(function()
            local key = popupActiveKey
            D("WTFAY_CONFIRM_REMOVE OnAccept: key=" .. tostring(key))
            if key and db and db.players[key] then
                local name = db.players[key].name
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

local detail = CreateFrame("Frame", "WTFAYDetailPanel", UIParent)
detail:SetSize(340, 380)
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
if detail.SetBackdrop then
    detail:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    detail:SetBackdropColor(0.05, 0.05, 0.08, 0.96)
end

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
encHeader:SetPoint("TOPLEFT", detailNote, "BOTTOMLEFT", 0, -12)
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
    encSep:SetColorTexture(0.3, 0.3, 0.3, 0.8)
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

for i = 1, MAX_VISIBLE_ENC do
    local row = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row:SetPoint("TOPLEFT", encContainer, "TOPLEFT", 0, -((i - 1) * ENC_ROW_HEIGHT))
    row:SetPoint("RIGHT", encContainer, "RIGHT", 0, 0)
    row:SetJustifyH("LEFT")
    row:SetWordWrap(false)
    row:Hide()
    encRows[i] = row
end

-- Page navigation
local pageInfo = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pageInfo:SetPoint("BOTTOM", detail, "BOTTOM", 0, 30)

local prevBtn = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
prevBtn:SetSize(60, 20)
prevBtn:SetPoint("RIGHT", pageInfo, "LEFT", -8, 0)
prevBtn:SetText("Newer")
prevBtn:SetNormalFontObject(GameFontNormalSmall)

local nextBtn = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
nextBtn:SetSize(60, 20)
nextBtn:SetPoint("LEFT", pageInfo, "RIGHT", 8, 0)
nextBtn:SetText("Older")
nextBtn:SetNormalFontObject(GameFontNormalSmall)

-- Action buttons at bottom
local detailRateBtn = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
detailRateBtn:SetSize(70, 20)
detailRateBtn:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", 10, 8)
detailRateBtn:SetText("Rate")
detailRateBtn:SetNormalFontObject(GameFontNormalSmall)
detailRateBtn:SetScript("OnClick", function()
    if detailCurrentKey then ShowRatingPicker(detailCurrentKey) end
end)

local detailNoteBtn = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
detailNoteBtn:SetSize(80, 20)
detailNoteBtn:SetPoint("LEFT", detailRateBtn, "RIGHT", 4, 0)
detailNoteBtn:SetText("Edit Note")
detailNoteBtn:SetNormalFontObject(GameFontNormalSmall)
detailNoteBtn:SetScript("OnClick", function()
    if detailCurrentKey and db and db.players[detailCurrentKey] then
        popupActiveKey = detailCurrentKey
        StaticPopup_Show("WTFAY_EDIT_NOTE", db.players[detailCurrentKey].name)
    end
end)

local detailRemoveBtn = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
detailRemoveBtn:SetSize(70, 20)
detailRemoveBtn:SetPoint("LEFT", detailNoteBtn, "RIGHT", 4, 0)
detailRemoveBtn:SetText("|cFFFF4444Remove|r")
detailRemoveBtn:SetNormalFontObject(GameFontNormalSmall)
detailRemoveBtn:SetScript("OnClick", function()
    if detailCurrentKey and db and db.players[detailCurrentKey] then
        popupActiveKey = detailCurrentKey
        StaticPopup_Show("WTFAY_CONFIRM_REMOVE", db.players[detailCurrentKey].name)
    end
end)

-- Refresh the detail panel for the current player and page
local function RefreshDetailPanel()
    local key = detailCurrentKey
    if not key or not db or not db.players[key] then
        detail:Hide()
        return
    end

    local p = db.players[key]
    local cc = ClassColor(p.class)

    detailTitle:SetText(cc .. p.name .. "|r")

    local raceStr = (p.race and p.race ~= "") and (p.race .. " ") or ""
    detailInfo:SetText("|cFFBBBBBBLv " .. (p.level or "?") .. "  " .. raceStr .. "|r" .. cc .. (p.class or "Unknown") .. "|r  |cFF888888" .. (p.realm or "") .. "|r")

    detailRating:SetText("Rating: " .. ColorRating(p.rating or 0) .. "  |cFFAAAAAA" .. (RATING_LABELS[p.rating or 0] or "") .. "|r")

    if p.note and p.note ~= "" then
        detailNote:SetText("|cFFDDDDDD" .. p.note .. "|r")
    else
        detailNote:SetText("|cFF666666(no note)|r")
    end

    -- Encounters: display newest first
    local enc = p.encounters or {}
    local totalEnc = #enc
    encCount:SetText("|cFF888888(" .. totalEnc .. " total)|r")

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
            local zoneStr = (e.zone and e.zone ~= "") and ("  |cFFDDAA44" .. e.zone .. "|r") or ""
            encRows[visibleCount]:SetText(
                "|cFF666666#" .. num .. "|r  |cFFCCCCCC" .. (e.time or "?") .. "|r  |cFF" .. sc .. (e.source or "?") .. "|r" .. zoneStr
            )
            encRows[visibleCount]:Show()
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
        pageInfo:SetText("|cFFAAAAAA" .. detailPage .. " / " .. totalPages .. "|r")
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
    RefreshDetailPanel()
    detail:Show()
end

D("detail panel OK")

----------------------------------------------------------------------
-- Core API
----------------------------------------------------------------------
local function AddPlayer(nameRealm, source)
    local name, realm = nameRealm:match("^(.+)-(.+)$")
    if not name then
        name  = nameRealm
        realm = GetRealmName() or "Unknown"
    end
    name = name:sub(1,1):upper() .. name:sub(2):lower()

    local key = name .. "-" .. realm
    if db.players[key] then
        db.players[key].seen   = Timestamp()
        db.players[key].source = source or db.players[key].source
        LogEncounter(key, source or db.players[key].source)
        P("Updated |cFFFFFFFF" .. name .. "|r (already tracked)")
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
        LogEncounter(key, source or "manual")
        P("Added |cFFFFFFFF" .. name .. "-" .. realm .. "|r")
    end
    RefreshList()
    return key
end

local function RemovePlayer(nameRealm)
    local name, realm = nameRealm:match("^(.+)-(.+)$")
    if not name then
        name  = nameRealm
        realm = GetRealmName() or "Unknown"
    end
    name = name:sub(1,1):upper() .. name:sub(2):lower()
    local key = name .. "-" .. realm

    if db.players[key] then
        db.players[key] = nil
        P("Removed |cFFFF6666" .. name .. "|r")
        RefreshList()
    else
        P("Player |cFFFFFFFF" .. name .. "|r not found.")
    end
end

local function SearchPlayers(query)
    query = query:lower()
    local found = 0
    for key, p in pairs(db.players) do
        if p.name:lower():find(query, 1, true) or (p.note or ""):lower():find(query, 1, true) then
            local cc = ClassColor(p.class)
            P(cc .. p.name .. "|r  " .. ColorRating(p.rating) .. "  |cFFAAAAAA" .. (p.note or "") .. "|r")
            found = found + 1
        end
    end
    if found == 0 then
        P("No players matching |cFFFFFFFF" .. query .. "|r")
    else
        P(found .. " result" .. (found == 1 and "" or "s") .. " found.")
    end
end

local function RatePlayer(nameRealm, rating)
    local name, realm = nameRealm:match("^(.+)-(.+)$")
    if not name then
        name  = nameRealm
        realm = GetRealmName() or "Unknown"
    end
    name = name:sub(1,1):upper() .. name:sub(2):lower()
    local key = name .. "-" .. realm

    if not db.players[key] then
        P("Player |cFFFFFFFF" .. name .. "|r not found. Add them first.")
        return
    end
    rating = math.max(-3, math.min(5, math.floor(rating)))
    db.players[key].rating = rating
    if db.players[key].pending then db.players[key].pending = nil end
    P(ClassColor(db.players[key].class) .. name .. "|r rated " .. ColorRating(rating))
    RefreshList()
    if RefreshInbox then RefreshInbox() end
    UpdateInboxTabLabel()
end

local function NotePlayer(nameRealm, note)
    local name, realm = nameRealm:match("^(.+)-(.+)$")
    if not name then
        name  = nameRealm
        realm = GetRealmName() or "Unknown"
    end
    name = name:sub(1,1):upper() .. name:sub(2):lower()
    local key = name .. "-" .. realm

    if not db.players[key] then
        P("Player |cFFFFFFFF" .. name .. "|r not found. Add them first.")
        return
    end
    db.players[key].note = note
    P("Note set for " .. ClassColor(db.players[key].class) .. name .. "|r")
    RefreshList()
end

D("core API OK")

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------
local HELP_TEXT = {
    " ",
    "|cFF" .. ACCENT .. "========== WTFAY - Who The F* Are You? ==========|r",
    "|cFF888888Track, rate, and remember every player you encounter.|r",
    " ",
    "|cFF" .. ACCENT .. "General:|r",
    "  |cFFFFD100/wtfay|r - Toggle the main panel",
    "  |cFFFFD100/wtfay help|r - Show this help",
    "  |cFFFFD100/wtfay settings|r - Open settings panel",
    "  |cFFFFD100/wtfay stats|r - Show database statistics",
    " ",
    "|cFF" .. ACCENT .. "Player Management:|r",
    "  |cFFFFD100/wtfay target|r - Add your current target (auto-detects class, race, level)",
    "  |cFFFFD100/wtfay add Name|r or |cFFFFD100Name-Realm|r - Add a player manually",
    "  |cFFFFD100/wtfay remove Name|r - Remove a player from the database",
    "  |cFFFFD100/wtfay rate Name 3|r - Rate a player (-3 to 5)",
    "  |cFFFFD100/wtfay note Name Some text|r - Set a note on a player",
    "  |cFFFFD100/wtfay search term|r - Search players by name",
    " ",
    "|cFF" .. ACCENT .. "Data:|r",
    "  |cFFFFD100/wtfay export|r - Export your database to share with friends",
    "  |cFFFFD100/wtfay import|r - Import a database (merge or replace)",
    "  |cFFFFD100/wtfay restore|r - Undo last Replace All from a backup",
    " ",
    "|cFF" .. ACCENT .. "Options:|r",
    "  |cFFFFD100/wtfay minimap|r - Toggle minimap button on/off",
    "  |cFFFFD100/wtfay debug|r - Toggle debug logging",
    " ",
    "|cFF888888Tips: Left-click a player row for details. Right-click for context menu.|r",
    "|cFF888888Use the filters at the top to narrow by rating, source, or class.|r",
    "|cFF888888Click the minimap icon to quickly open WTFAY.|r",
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
        local target, val = rest:match("^(%S+)%s+([%-]?%d+)")
        if target and val then
            RatePlayer(target, tonumber(val))
        else
            P("Usage: /wtfay rate PlayerName 3")
        end

    elseif cmd == "note" then
        local target, noteText = rest:match("^(%S+)%s+(.*)")
        if target and noteText then
            NotePlayer(target, noteText)
        else
            P("Usage: /wtfay note PlayerName Some text here")
        end

    elseif cmd == "search" or cmd == "find" then
        if rest ~= "" then SearchPlayers(rest) else P("Usage: /wtfay search term") end

    elseif cmd == "help" or cmd == "?" then
        for _, line in ipairs(HELP_TEXT) do P(line) end

    elseif cmd == "reseed" then
        ReseedDB()
        RefreshList()
        P("Re-seeded fake player data.")

    elseif cmd == "reset" then
        wipe(db.players)
        ReseedDB()
        RefreshList()
        P("Database wiped and re-seeded with 12 fake players.")

    elseif cmd == "debug" then
        DEBUG = not DEBUG
        if db and db.settings then db.settings.debug = DEBUG end
        P("Debug mode: " .. (DEBUG and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r"))

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
            table.remove(db.backups, 1)
            P("Restored backup from |cFFFFD100" .. (bk.time or "?") .. "|r (" .. count .. " players). " .. #db.backups .. " backup(s) remaining.")
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
        P("Minimap button: " .. (db.minimapHidden and "|cFFFF4444hidden|r" or "|cFF44FF44shown|r"))

    elseif cmd == "settings" or cmd == "config" or cmd == "options" then
        if settingsPanel and settingsPanel.OpenBliz then
            settingsPanel.OpenBliz()
        elseif settingsPanel and settingsPanel.Toggle then
            settingsPanel.Toggle()
        end

    else
        P("Unknown command: " .. cmd .. ". Type |cFFFFD100/wtfay help|r")
    end
end

D("slash command registered OK")

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
if alertPopupFrame.SetBackdrop then
    alertPopupFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    alertPopupFrame:SetBackdropColor(0.08, 0.02, 0.02, 0.95)
end

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
local alertDismiss = CreateFrame("Button", nil, alertPopupFrame, "UIPanelButtonTemplate")
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
        if kp.player.rating and kp.player.rating <= -3 then
            blacklistCount = blacklistCount + 1
        end
    end

    -- Title
    if isLeave then
        alertTitle:SetText("|cFFAAAABBKnown Player Left|r")
        if alertPopupFrame.SetBackdropColor then
            alertPopupFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
        end
    elseif blacklistCount > 0 then
        alertTitle:SetText("|cFFFF4444!! Known Players Alert !!|r")
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
        local ratingStr = ColorRating(p.rating or 0)
        local prefix = ""
        if p.rating and p.rating <= -3 then
            prefix = "|cFFFF0000[BLACKLISTED]|r  "
        end
        line.nameText:SetText(prefix .. cc .. p.name .. "|r  " .. cc .. (p.class or "") .. "|r  Lv " .. (p.level or "?") .. "  Rating: " .. ratingStr)

        if p.note and p.note ~= "" then
            line.noteText:SetText("|cFFBBBBBB\"" .. p.note .. "\"|r")
        else
            line.noteText:SetText("")
        end

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
        local ratingStr = ColorRating(p.rating or 0)
        local noteStr = (p.note and p.note ~= "") and ("  |cFFBBBBBB\"" .. p.note .. "\"|r") or ""
        if p.rating and p.rating <= -3 then
            P("  |cFFFF0000>>> BLACKLISTED <<<|r  " .. cc .. p.name .. "|r (" .. cc .. (p.class or "?") .. "|r) " .. ratingStr .. noteStr)
        else
            P("  " .. cc .. p.name .. "|r (" .. cc .. (p.class or "?") .. "|r) " .. ratingStr .. noteStr)
        end
    end
    if db.settings.alertPopup then
        ShowAlertPopup(players, isLeave)
    else
        local hasBlacklist = false
        for _, kp in ipairs(players) do
            if kp.player.rating and kp.player.rating <= -3 then hasBlacklist = true; break end
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
        RefreshList()
        if RefreshInbox then RefreshInbox() end
        UpdateInboxTabLabel()
        return
    end

    local source, zone = GetGroupSourceAndZone()
    local myName = UnitName("player") or ""
    local numMembers
    local knownPlayers = {}  -- collect known players for alerts
    local guildSet = nil     -- lazy-loaded

    -- Helper: process a single unit
    local function ProcessUnit(unit)
        if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
        local name, realm = UnitName(unit)
        if not name or name == myName then return end

        realm = (realm and realm ~= "") and realm or (GetRealmName() or "Unknown")
        local _, classFile = UnitClass(unit)
        local className = classFile and (classFile:sub(1,1):upper() .. classFile:sub(2):lower()) or "Unknown"
        local raceName = UnitRace(unit) or ""
        local level = UnitLevel(unit) or 0
        local key = name .. "-" .. realm
        local wasKnown = db.players[key] ~= nil

        if wasKnown then
            local p = db.players[key]
            p.seen = Timestamp()
            if className ~= "Unknown" then p.class = className end
            if raceName ~= "" then p.race = raceName end
            if level > 0 and level > (p.level or 0) then p.level = level end
            p.source = source
            LogEncounter(key, source, zone)
        else
            db.players[key] = {
                name = name, realm = realm, class = className,
                race = raceName, level = level, rating = 0,
                note = "", source = source, seen = Timestamp(),
                encounters = {}, pending = true,
            }
            LogEncounter(key, source, zone)
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

    if IsInRaid() then
        numMembers = GetNumRaidMembers and GetNumRaidMembers() or GetNumGroupMembers() or 0
        for i = 1, numMembers do ProcessUnit("raid" .. i) end
    else
        numMembers = GetNumPartyMembers and GetNumPartyMembers() or (GetNumGroupMembers and GetNumGroupMembers() or 0)
        for i = 1, numMembers do ProcessUnit("party" .. i) end
    end

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
                FireAlert(knownPlayers, "|cFFFFFFFFKnown players in your group:|r", false)
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
                    FireAlert(joined, "|cFFFFFFFFKnown player joined your group:|r", false)
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
                    FireAlert(left, "|cFFAAAAAAKnown player left your group:|r", true)
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
        -- Only scan if we're in a group AND just entered an instance
        local inInstance = IsInInstance()
        if inInstance and (IsInGroup() or IsInRaid()) then
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
            f:SetSize(db.frame.width, db.frame.height)
        end

        -- Restore settings
        DEBUG = db.settings.debug

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

        D("DB initialized, " .. (db.seeded and "already seeded" or "freshly seeded"))
        local count = 0
        for _ in pairs(db.players) do count = count + 1 end
        D("player count: " .. count)

    elseif event == "PLAYER_LOGIN" then
        D("PLAYER_LOGIN fired")

        -- Register Blizzard Interface Options panel (must happen after full UI init)
        if settingsPanel and settingsPanel.RegisterBliz then
            settingsPanel.RegisterBliz()
        end

        P("v" .. ADDON_VERSION .. " loaded! Type |cFFFFD100/wtfay|r to open.  |cFFFFD100/wtfay help|r for commands.")
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

    local name, realm = UnitName("target")
    realm = (realm and realm ~= "") and realm or (GetRealmName() or "Unknown")

    local _, classFile = UnitClass("target")
    local className = classFile and (classFile:sub(1,1):upper() .. classFile:sub(2):lower()) or "Unknown"

    local raceName = UnitRace("target") or ""

    local level = UnitLevel("target") or 0

    if not db then return end
    local key = name .. "-" .. realm
    if db.players[key] then
        db.players[key].seen  = Timestamp()
        db.players[key].class = className
        db.players[key].race  = raceName
        if level > 0 then db.players[key].level = level end
        LogEncounter(key, "manual")
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
        LogEncounter(key, "manual")
        P("Added " .. ClassColor(className) .. name .. "|r (" .. raceName .. " " .. className .. ")")
    end
    RefreshList()
end

----------------------------------------------------------------------
-- Tooltip integration: show WTFAY info on player tooltips
----------------------------------------------------------------------
D("setting up tooltip hook...")
local tooltipOK, tooltipErr = pcall(function()
    local function OnTooltipSetUnit(tooltip)
        if not db or not db.players then return end
        local _, unit = tooltip:GetUnit()
        if not unit or not UnitIsPlayer(unit) then return end

        local name, realm = UnitName(unit)
        realm = (realm and realm ~= "") and realm or (GetRealmName() or "Unknown")
        local key = name .. "-" .. realm

        local p = db.players[key]
        if p then
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine(
                "|cFF" .. ACCENT .. "WTFAY|r",
                ColorRating(p.rating or 0) .. " " .. (RATING_LABELS[p.rating or 0] or "")
            )
            if p.note and p.note ~= "" then
                tooltip:AddLine("|cFFDDDDDD" .. p.note .. "|r", 1, 1, 1, true)
            end
            tooltip:AddLine("|cFF666666" .. (p.source or "manual") .. " - " .. (p.seen or "") .. "|r")
        else
            -- Hint to add unknown players
            tooltip:AddLine("|cFF" .. ACCENT .. "WTFAY|r |cFF888888- /wtfay target to track|r")
        end
        tooltip:Show()
    end

    -- Hook GameTooltip
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit)
        D("hooked GameTooltip:OnTooltipSetUnit OK")
    elseif GameTooltip and GameTooltip:GetScript("OnTooltipSetUnit") then
        local orig = GameTooltip:GetScript("OnTooltipSetUnit")
        GameTooltip:SetScript("OnTooltipSetUnit", function(self, ...)
            if orig then orig(self, ...) end
            OnTooltipSetUnit(self)
        end)
        D("wrapped GameTooltip:OnTooltipSetUnit OK")
    else
        D("WARNING: could not hook GameTooltip")
    end
end)

if tooltipOK then
    D("tooltip hook OK")
else
    D("tooltip hook FAILED: " .. tostring(tooltipErr))
end

D(">>> File loading COMPLETE — all sections parsed OK")
