----------------------------------------------------------------------
-- WTFAY - Compat layer
--
-- WTFAY runs on two incompatible client families:
--   * Classic-era  - TBC Anniversary (Interface 20506)
--   * Mainline     - WoW Forever (16001) and Midnight/retail (120100+)
--
-- Everything that differs between them lives here behind one contract, so
-- WTFAY.lua only ever calls ns.C.* and never branches on flavor itself.
-- Each Lua file is its own chunk, so the locals in here do NOT count
-- against WTFAY.lua's Lua 5.1 200-locals-per-scope budget.
--
-- See the wow-addon-dev skill, references/forever-and-mainline.md.
----------------------------------------------------------------------
local ADDON_NAME, ns = ...

local C = {}
ns.C = C

----------------------------------------------------------------------
-- Flavor detection
--
-- TRAP: Forever's interface number (16001) sits inside the range addons
-- normally use for Vanilla Classic (0..20000). Cap the vanilla range at
-- 16000 or a Classic path silently runs on a Mainline client.
----------------------------------------------------------------------
local uiVersion = select(4, GetBuildInfo())
if type(uiVersion) ~= "number" then uiVersion = 20506 end

local function inRange(v, lo, hi)
    return v >= (lo or 0) and v < (hi or 100000000)
end

C.uiVersion = uiVersion
C.Vanilla   = inRange(uiVersion, 0, 16000)
C.Forever   = inRange(uiVersion, 16000, 20000)
C.TBC       = inRange(uiVersion, 20000, 30000)
C.Midnight  = inRange(uiVersion, 120000)
C.Mainline  = C.Forever or C.Midnight or (Menu ~= nil and Menu.ModifyMenu ~= nil)
C.Classic   = not C.Mainline

C.flavorName = C.Forever and "Forever" or C.Midnight and "Midnight"
    or C.TBC and "TBC" or C.Vanilla and "Vanilla" or "Unknown"

-- issecretvalue only exists on Midnight-era clients.
local issecret = (type(issecretvalue) == "function") and issecretvalue
    or function() return false end
C.IsSecret = issecret

----------------------------------------------------------------------
-- Identity
--
-- Classic: a character is "Name" plus a separate realm -> key "Name-Realm".
-- Forever: there are no realm suffixes. Characters have SURNAMES, so the
--          name is "Firstname Surname" and that whole string is the identity.
--          Never split it on "-", never strip its spaces, and never
--          lower-case past the first word or the surname gets mangled.
----------------------------------------------------------------------
C.UsesRealms = not C.Forever

function C.TitleCase(name)
    if not name or name == "" then return "" end
    if C.Forever then
        -- Title-case every word so a surname survives, and capitalize after
        -- hyphens and apostrophes too ("anne-marie o'brien" -> "Anne-Marie O'Brien").
        -- %a is ASCII-only, so accented leading letters are left untouched
        -- rather than mangled.
        name = name:lower()
        name = name:gsub("^(%a)", string.upper)
        name = name:gsub("([%s%-'])(%a)", function(sep, ch) return sep .. ch:upper() end)
        return name
    end
    name = name:lower()
    return name:sub(1, 1):upper() .. name:sub(2)
end

function C.NormalizeRealm(realm)
    if C.Forever then return "" end        -- realms are not part of identity
    if not realm or realm == "" then return "" end
    return (realm:gsub("[%s%-]", ""))
end

function C.MyRealm()
    if C.Forever then return "" end
    return C.NormalizeRealm(GetRealmName() or "")
end

-- The one true key builder.
function C.MakeKey(name, realm)
    name = C.TitleCase(name or "")
    if C.Forever then return name end
    realm = C.NormalizeRealm(realm)
    if realm == "" then realm = C.MyRealm() end
    if realm == "" then realm = "Unknown" end
    return name .. "-" .. realm
end

-- Parse user input ("Bob", "Bob-Azjol Nerub", or "Bob Ironhide" on Forever).
function C.SplitInput(input)
    if not input then return nil, nil end
    input = input:trim()
    if input == "" then return nil, nil end
    if C.Forever then
        return C.TitleCase(input), ""
    end
    local name, realm = input:match("^([^%-]+)%-(.+)$")
    if not name then
        name, realm = input, nil
    end
    realm = C.NormalizeRealm(realm)
    if realm == "" then realm = C.MyRealm() end
    if realm == "" then realm = "Unknown" end
    return C.TitleCase(name), realm
end

-- name, realm for a unit token (realm is "" on Forever).
function C.UnitIdentity(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    if C.Forever then
        -- No showServerName argument on Forever; this already carries the surname.
        local name = GetUnitName(unit)
        if not name or name == "" then return nil end
        return name, ""
    end
    local name, realm = UnitName(unit)
    if not name or name == "" then return nil end
    return name, C.NormalizeRealm(realm)
end

-- Normalized key straight from a unit token.
function C.UnitKey(unit)
    local name, realm = C.UnitIdentity(unit)
    if not name then return nil end
    return C.MakeKey(name, realm), name, realm
end

----------------------------------------------------------------------
-- Class colors
--
-- RAID_CLASS_COLORS is correct on every flavor and picks up classes we
-- don't know about; the table is only a fallback.
----------------------------------------------------------------------
local FALLBACK_CLASS_COLORS = {
    WARRIOR = "C79C6E", PALADIN = "F58CBA", HUNTER  = "ABD473",
    ROGUE   = "FFF569", PRIEST  = "FFFFFF", SHAMAN  = "0070DE",
    MAGE    = "69CCF0", WARLOCK = "9482C9", DRUID   = "FF7D0A",
    DEATHKNIGHT = "C41F3B", MONK = "00FF96", DEMONHUNTER = "A330C9",
    EVOKER  = "33937F",
}

function C.ClassColorHex(class)
    local token = (class or ""):upper():gsub("%s", "")
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c and c.r then
        return string.format("%02X%02X%02X", c.r * 255, c.g * 255, c.b * 255)
    end
    return FALLBACK_CLASS_COLORS[token] or "AAAAAA"
end

----------------------------------------------------------------------
-- Group / invite
----------------------------------------------------------------------
function C.InviteByName(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    end
end

----------------------------------------------------------------------
-- Unit tooltip
--
-- Mainline removed the OnTooltipSetUnit script in 10.0.2; the unit now
-- comes from data.guid via UnitTokenFromGUID, and that GUID is a secret
-- value for creatures inside instances.
----------------------------------------------------------------------
function C.HookUnitTooltip(handler)
    local ok, err = pcall(function()
        if C_TooltipInfo and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
                if tooltip ~= GameTooltip then return end
                local guid = data and data.guid
                if not guid or issecret(guid) then return end
                local unit = UnitTokenFromGUID and UnitTokenFromGUID(guid)
                if not unit then return end
                handler(tooltip, unit)
            end)
            return "TooltipDataProcessor"
        end

        if GameTooltip and GameTooltip.HookScript then
            GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
                local _, unit = tooltip:GetUnit()
                if not unit then return end
                handler(tooltip, unit)
            end)
            return "HookScript"
        end
    end)
    return ok, err
end

----------------------------------------------------------------------
-- Context menu (right-clicking a row in our own UI)
--
-- entries = { { text=, func=, isTitle=, isDivider=, disabled= }, ... }
----------------------------------------------------------------------
local legacyDropdown

function C.ShowContextMenu(owner, entries)
    -- Mainline: MenuUtil. EasyMenu and UIDropDownMenu are gone in 11.0+.
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner or UIParent, function(_, root)
            for _, e in ipairs(entries) do
                if e.isDivider then
                    root:CreateDivider()
                elseif e.isTitle then
                    root:CreateTitle(e.text)
                else
                    local btn = root:CreateButton(e.text, function()
                        if e.func then e.func() end
                    end)
                    if e.disabled and btn and btn.SetEnabled then btn:SetEnabled(false) end
                end
            end
        end)
        return true
    end

    -- Classic: EasyMenu if present, else a raw UIDropDownMenu.
    if not legacyDropdown then
        legacyDropdown = CreateFrame("Frame", "WTFAYCompatDropDown", UIParent, "UIDropDownMenuTemplate")
    end

    local menu = {}
    for _, e in ipairs(entries) do
        if e.isDivider then
            menu[#menu + 1] = { text = "", disabled = true, notClickable = true }
        else
            menu[#menu + 1] = {
                text         = e.text,
                isTitle      = e.isTitle or nil,
                notCheckable = true,
                disabled     = e.disabled or nil,
                func         = e.func,
            }
        end
    end

    if EasyMenu then
        EasyMenu(menu, legacyDropdown, "cursor", 0, 0, "MENU")
        return true
    end

    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(legacyDropdown, function(_, level)
            for _, item in ipairs(menu) do
                local info = UIDropDownMenu_CreateInfo()
                info.text         = item.text
                info.isTitle      = item.isTitle
                info.notCheckable = true
                info.disabled     = item.disabled
                info.func         = item.func
                UIDropDownMenu_AddButton(info, level)
            end
        end, "MENU")
        ToggleDropDownMenu(1, nil, legacyDropdown, "cursor", 0, 0)
        return true
    end

    return false
end

----------------------------------------------------------------------
-- Unit right-click menu entry (Blizzard's own unit dropdowns)
--
-- Mainline: Menu.ModifyMenu. The whole UnitPopupButtons/UnitPopupMenus/
--           UnitPopup_OnClick family was removed in 11.0.
-- Classic:  load-time insert into UnitPopupMenus + secure post-hooks.
--
-- callback(name, realm, unit); isEnabled() gates the entry.
----------------------------------------------------------------------
local MAINLINE_MENU_TAGS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_FRIEND", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_COMMUNITIES_MEMBER",
}

local CLASSIC_MENUS = {
    "PARTY", "RAID", "RAID_PLAYER", "PLAYER", "FRIEND",
    "TARGET", "FOCUS", "CHAT_ROSTER", "GUILD", "GUILD_OFFLINE",
}

local CLASSIC_BUTTON = "WTFAY_RATE"

function C.RegisterUnitMenu(label, callback, isEnabled)
    local function enabled()
        return (not isEnabled) or isEnabled()
    end

    ------------------------------------------------------------------
    -- Mainline
    ------------------------------------------------------------------
    if Menu and Menu.ModifyMenu then
        local function Handler(owner, rootDescription, contextData)
            if not enabled() then return end
            if not (contextData and contextData.name) then return end
            -- Battle.net entries arrive as "|K..." tokens; skip them.
            if contextData.name:sub(1, 1) == "|" then return end

            local name = contextData.name
            -- Forever exposes the surname as its own field.
            if C.Forever and contextData.surname and contextData.surname ~= "" then
                name = name .. " " .. contextData.surname
            end

            rootDescription:CreateDivider()
            rootDescription:CreateTitle("WTFAY")
            rootDescription:CreateButton(label, function()
                callback(name, contextData.server, contextData.unit)
            end)
        end

        local ok, err = pcall(function()
            for _, tag in ipairs(MAINLINE_MENU_TAGS) do
                Menu.ModifyMenu(tag, Handler)
            end
        end)
        return ok, err, "Menu.ModifyMenu"
    end

    ------------------------------------------------------------------
    -- Classic
    ------------------------------------------------------------------
    local ok, err = pcall(function()
        if not UnitPopupButtons or not UnitPopupMenus then return end
        if type(UnitPopup_OnClick) ~= "function" then return end

        UnitPopupButtons[CLASSIC_BUTTON] = { text = label, dist = 0 }

        for _, menuName in ipairs(CLASSIC_MENUS) do
            local menu = UnitPopupMenus[menuName]
            if menu then
                local present = false
                for _, v in ipairs(menu) do
                    if v == CLASSIC_BUTTON then present = true end
                end
                if not present then
                    table.insert(menu, math.max(1, #menu), CLASSIC_BUTTON)
                end
            end
        end

        -- Hide the entry when disabled, without needing a reload.
        if UnitPopupShown and type(UnitPopup_HideButtons) == "function" then
            hooksecurefunc("UnitPopup_HideButtons", function()
                if enabled() then return end
                local dropdown = UIDROPDOWNMENU_INIT_MENU
                local which    = dropdown and dropdown.which
                local menu     = which and UnitPopupMenus[which]
                if not menu then return end
                local shown = UnitPopupShown[UIDROPDOWNMENU_MENU_LEVEL or 1]
                if not shown then return end
                for index, value in ipairs(menu) do
                    if value == CLASSIC_BUTTON then shown[index] = 0 end
                end
            end)
        end

        hooksecurefunc("UnitPopup_OnClick", function(self)
            if self.value ~= CLASSIC_BUTTON then return end
            if not enabled() then return end

            local dropdown = UIDROPDOWNMENU_INIT_MENU
            if not dropdown then return end

            local name, realm, unit = nil, nil, dropdown.unit
            if unit and UnitExists(unit) and UnitIsPlayer(unit) then
                name, realm = UnitName(unit)
            else
                name, realm = dropdown.name, dropdown.server
            end
            if not name or name == "" then return end
            -- Some dropdowns put "Name-Realm" in the name field alone.
            if not realm or realm == "" then
                local n2, r2 = name:match("^([^%-]+)%-(.+)$")
                if n2 then name, realm = n2, r2 end
            end
            callback(name, realm, unit)
        end)
    end)

    return ok, err, "UnitPopupMenus"
end

----------------------------------------------------------------------
-- Options panel registration
----------------------------------------------------------------------
local settingsCategoryID

function C.RegisterOptions(panel, name)
    local ok, err = pcall(function()
        if Settings and Settings.RegisterCanvasLayoutCategory then
            -- Exactly the pattern Leatrix Plus uses on Forever. Don't overwrite
            -- category.ID: the client assigns it, and OpenToCategory wants that.
            local category = Settings.RegisterCanvasLayoutCategory(panel, name)
            if category then
                Settings.RegisterAddOnCategory(category)
                settingsCategoryID = category.GetID and category:GetID() or category.ID
            end
            return
        end
        if InterfaceOptions_AddCategory then
            InterfaceOptions_AddCategory(panel)
        end
    end)
    return ok, err
end

-- Returns true if it actually opened something.
function C.OpenOptions()
    local opened = false
    pcall(function()
        if settingsCategoryID and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(settingsCategoryID)
            opened = true
        elseif InterfaceOptionsFrame_OpenToCategory then
            InterfaceOptionsFrame_OpenToCategory(ns.optionsPanel)
            InterfaceOptionsFrame_OpenToCategory(ns.optionsPanel)
            opened = true
        end
    end)
    return opened
end

----------------------------------------------------------------------
-- Dropdown widget
--
-- buildEntries() -> { { text=, func=, checked= }, ... }
-- Returns a frame with :SetLabel(text). UIDropDownMenu_* is deprecated on
-- Mainline, so there we use a plain button that opens a context menu.
----------------------------------------------------------------------
function C.CreateDropdown(parent, width, buildEntries)
    if MenuUtil and MenuUtil.CreateContextMenu then
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(width + 20, 22)
        btn:SetScript("OnClick", function(self)
            MenuUtil.CreateContextMenu(self, function(_, root)
                for _, e in ipairs(buildEntries()) do
                    root:CreateButton(e.text, function()
                        if e.func then e.func() end
                    end)
                end
            end)
        end)
        btn.SetLabel = function(self, text) self:SetText(text) end
        return btn
    end

    local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_Initialize(dd, function(_, level)
        for _, e in ipairs(buildEntries()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = e.text
            info.checked = e.checked
            info.func    = e.func
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    dd.SetLabel = function(self, text) UIDropDownMenu_SetText(self, text) end
    return dd
end

----------------------------------------------------------------------
-- Template probing
--
-- Mainline gained a new widget set in 11.0 (the "WowStyle1" family). We
-- can't assume it exists on every flavor or build, so probe once and fall
-- back to the long-standing templates.
----------------------------------------------------------------------
local templateCache = {}

function C.HasTemplate(name)
    if templateCache[name] == nil then
        local ok, info = pcall(function()
            return C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo(name)
        end)
        templateCache[name] = (ok and info ~= nil) or false
    end
    return templateCache[name]
end

-- First template in the list that actually exists, else nil.
local function pickTemplate(...)
    for i = 1, select("#", ...) do
        local name = select(i, ...)
        if name and C.HasTemplate(name) then return name end
    end
    return nil
end
C.PickTemplate = pickTemplate

----------------------------------------------------------------------
-- Theme
--
-- WTFAY's identity is the cyan accent, so that stays. What changes per
-- flavor is the *chrome*: on Mainline we let Blizzard draw the borders
-- (NineSlice dialog templates) instead of tinting vanilla parchment black.
--
-- Colors are read from Blizzard's own globals where one exists, so the
-- addon tracks the client's palette instead of hardcoding a guess.
----------------------------------------------------------------------
local function hexOf(colorMixin, fallback)
    if colorMixin and colorMixin.GenerateHexColor then
        local ok, hex = pcall(colorMixin.GenerateHexColor, colorMixin)
        -- GenerateHexColor returns "ffRRGGBB"; we want "RRGGBB".
        if ok and type(hex) == "string" and #hex >= 8 then return hex:sub(3) end
    end
    return fallback
end

C.Theme = {
    accent   = "00CCFF",                                  -- WTFAY brand cyan
    gold     = hexOf(NORMAL_FONT_COLOR, "FFD100"),         -- Blizzard UI gold
    white    = hexOf(HIGHLIGHT_FONT_COLOR, "FFFFFF"),
    dim      = "888888",

    -- Panel interior. Pure black reads as "addon"; Blizzard's own dark
    -- panels are a touch lighter and slightly blue, so match that.
    panelBg  = { 0.06, 0.06, 0.08, 0.94 },
    insetBg  = { 0.04, 0.04, 0.05, 0.85 },
    rowA     = { 0.08, 0.08, 0.10, 0.80 },
    rowB     = { 0.12, 0.12, 0.15, 0.80 },
    sep      = { 0.35, 0.30, 0.20, 0.85 },                 -- warm, matches gold trim
}

----------------------------------------------------------------------
-- Skins
--
-- Two looks, switchable live without a /reload (Baganator's model: build
-- on the game's own templates, and let a skin strip and restyle them):
--
--   "native"  Mainline only. Big windows are ButtonFrameTemplate frames, so
--             they wear the client's own window chrome (Forever's bronze
--             metal frame, title bar, close button). Small popups get the
--             native NineSlice dialog border.
--   "dark"    WTFAY's original look: the vanilla dialog border round a dark
--             interior. The only look on Classic, where TBC must render
--             exactly as it always has.
--
-- Every skinned frame is kept in a registry and repainted by C.SetSkin.
----------------------------------------------------------------------
C.skin = "dark"

local skinnedWindows = {}   -- frame -> opts
local skinnedPanels  = {}   -- frame -> opts
local skinnedTabs    = {}   -- button -> selected
local hairlined      = {}   -- frame -> true
local skinListeners  = {}

function C.DefaultSkin()
    return C.Mainline and "native" or "dark"
end

-- The skin picker is only meaningful where there is a native look to pick.
function C.CanChooseSkin()
    return C.Mainline
end

function C.OnSkinChanged(fn)
    if type(fn) == "function" then skinListeners[#skinListeners + 1] = fn end
end

local function ensureBackdrop(frame)
    if BackdropTemplateMixin and not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
        if frame.OnBackdropLoaded then frame:OnBackdropLoaded() end
    end
end

-- Paint a plain frame as a panel in the current skin.
local function paintPanel(frame, opts)
    opts = opts or {}
    ensureBackdrop(frame)

    local border = pickTemplate("DialogBorderDarkTemplate", "DialogBorderTemplate")
    if C.skin == "native" and C.Mainline and border then
        -- Native NineSlice chrome: flat dark interior + Blizzard's border art.
        if frame.SetBackdrop then
            frame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            frame:SetBackdropColor(unpack(opts.bg or C.Theme.panelBg))
        end
        if not frame.wtfayBorder then
            -- Border-only overlay that anchors itself to its parent, so it
            -- skins an already laid-out frame without moving any child.
            local ok, b = pcall(CreateFrame, "Frame", nil, frame, border)
            if ok and b then
                b:SetAllPoints(frame)
                b:SetFrameLevel(math.max(0, (frame:GetFrameLevel() or 1)))
                frame.wtfayBorder = b
            end
        end
        if frame.wtfayBorder then frame.wtfayBorder:Show() end
        return "nineslice"
    end

    -- Dark / Classic: vanilla dialog frame with a dark interior.
    if frame.wtfayBorder then frame.wtfayBorder:Hide() end
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = opts.edgeSize or 32,
            insets = opts.insets or { left = 8, right = 8, top = 8, bottom = 8 },
        })
        frame:SetBackdropColor(unpack(opts.bg or C.Theme.panelBg))
    end
    return "backdrop"
end

-- Skin a popup/dialog and keep it in the registry for live repaints.
function C.SkinPanel(frame, opts)
    if not frame then return end
    skinnedPanels[frame] = opts or {}
    return paintPanel(frame, skinnedPanels[frame])
end

----------------------------------------------------------------------
-- Windows
--
-- On Mainline a big window is created from ButtonFrameTemplate, which is how
-- the client's own windows (and Journey Tracker, Baganator, Polestar's
-- "forever" skin) get the native chrome. The template is created even in the
-- dark skin, which then hides its art, so the skin can change live.
----------------------------------------------------------------------
local WINDOW_TEMPLATES = { "ButtonFrameTemplateNoPortrait", "ButtonFrameTemplate" }

-- Template parts the dark skin hides and the native skin shows.
local TEMPLATE_PARTS = { "NineSlice", "Bg", "TopTileStreaks", "TitleBg", "TitleContainer", "CloseButton" }
-- Template parts we never use: WTFAY draws its own panes and has no portrait.
local UNUSED_PARTS = { "Inset", "PortraitContainer", "portrait", "PortraitButton" }

function C.CreateWindow(name, parent)
    parent = parent or UIParent
    if C.Mainline then
        for _, tmpl in ipairs(WINDOW_TEMPLATES) do
            if C.HasTemplate(tmpl) then
                local ok, f = pcall(CreateFrame, "Frame", name, parent, tmpl)
                if ok and f then
                    f.wtfayIsTemplate = true
                    if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
                    for _, key in ipairs(UNUSED_PARTS) do
                        if f[key] and f[key].Hide then f[key]:Hide() end
                    end
                    -- The template's title is ours to fill; blank its own.
                    local tt = (f.TitleContainer and f.TitleContainer.TitleText) or f.TitleText
                    if tt then tt:SetText("") end
                    return f
                end
            end
        end
    end
    return CreateFrame("Frame", name, parent)
end

local function templateTitle(frame)
    return (frame.TitleContainer and frame.TitleContainer.TitleText) or frame.TitleText
end

local function paintWindow(frame, opts)
    local native = (C.skin == "native") and frame.wtfayIsTemplate

    if frame.wtfayIsTemplate then
        for _, key in ipairs(TEMPLATE_PARTS) do
            local part = frame[key]
            if part and part.SetShown then part:SetShown(native and true or false) end
        end
        for _, key in ipairs(UNUSED_PARTS) do
            if frame[key] and frame[key].Hide then frame[key]:Hide() end
        end
    end

    local title = opts.title
    if native then
        -- The template draws the frame, its title bar and its close button.
        if frame.SetBackdrop then frame:SetBackdrop(nil) end
        if frame.wtfayBorder then frame.wtfayBorder:Hide() end
        if opts.close then opts.close:Hide() end
        if title then
            -- Mirror rather than move: our title stays where it is, invisible,
            -- so anything anchored to it (the detail panel chains its whole
            -- layout off its title) keeps its place, and the text shows in
            -- the template's own title bar instead.
            title:SetAlpha(0)
            local tt = templateTitle(frame)
            if tt then tt:SetText(title:GetText() or "") end
        end
        return "template"
    end

    -- Dark skin, or Mainline without the template: today's look.
    if opts.close then opts.close:Show() end
    if title then title:SetAlpha(1) end
    return paintPanel(frame, opts)
end

-- Register a window. opts: title (FontString), close (our close button),
-- plus the paintPanel options (edgeSize, insets, bg) for the dark skin.
function C.SkinWindow(frame, opts)
    if not frame then return end
    opts = opts or {}
    skinnedWindows[frame] = opts
    if frame.SetToplevel then frame:SetToplevel(true) end

    -- Keep the template's title bar in step with every later SetText.
    local title = opts.title
    if title and frame.wtfayIsTemplate and not title.wtfayMirrored then
        title.wtfayMirrored = true
        hooksecurefunc(title, "SetText", function(fs, text)
            if C.skin == "native" then
                local tt = templateTitle(frame)
                if tt then tt:SetText(text or "") end
            end
        end)
    end
    return paintWindow(frame, opts)
end

-- True when the frame is currently drawn by its native template.
function C.IsNativeWindow(frame)
    return C.skin == "native" and frame and frame.wtfayIsTemplate or false
end

----------------------------------------------------------------------
-- Pixel-perfect hairlines
--
-- A backdrop edgeFile is scaled with the UI and blurs at any scale but 1.0.
-- One physical pixel in a region's own coordinates is
-- PixelUtil.GetNearestPixelSize(1, effectiveScale, 1); four edge textures that
-- size stay crisp everywhere (Polestar, Theme.lua:958 and :970).
----------------------------------------------------------------------
function C.Pixel(region)
    local scale = region and region.GetEffectiveScale and region:GetEffectiveScale() or 1
    if PixelUtil and PixelUtil.GetNearestPixelSize then
        local ok, v = pcall(PixelUtil.GetNearestPixelSize, 1, scale, 1)
        if ok and v and v > 0 then return v end
    end
    if GetPhysicalScreenSize and scale > 0 then
        local _, h = GetPhysicalScreenSize()
        if h and h > 0 then return 768 / h / scale end
    end
    return 1
end

function C.Hairline(frame, r, g, b, a)
    if not frame then return end
    local e = frame.wtfayHair
    if not e then
        e = {}
        for i = 1, 4 do
            local t = frame:CreateTexture(nil, "BORDER", nil, 7)
            t:SetColorTexture(1, 1, 1, 1)
            e[i] = t
        end
        frame.wtfayHair = e
    end
    frame.wtfayHairColor = { r or 1, g or 1, b or 1, a or 1 }
    hairlined[frame] = true

    local px = C.Pixel(frame)
    e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(px)
    e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(px)
    e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(px)
    e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(px)
    for i = 1, 4 do
        e[i]:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
        e[i]:Show()
    end
end

function C.HideHairline(frame)
    if frame and frame.wtfayHair then
        for i = 1, 4 do frame.wtfayHair[i]:Hide() end
    end
end

----------------------------------------------------------------------
-- Native bottom tabs (like Character / Reputation / Skills)
--
-- PanelTabButtonTemplate where the client has it, CharacterFrameTabButtonTemplate
-- otherwise. The old Classic tab art is drawn to overlap its neighbour, so it
-- needs a negative gap where the modern template needs a small positive one
-- (Journey Tracker, JourneyTrackerUI.lua:1560).
----------------------------------------------------------------------
function C.CreateNativeTabs(frame, labels, onSelect)
    if not frame or not frame:GetName() then return nil end
    local tmpl = pickTemplate("PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate")
    if not tmpl then return nil end

    local tabs = {}
    for i, label in ipairs(labels) do
        local ok, tab = pcall(CreateFrame, "Button", frame:GetName() .. "Tab" .. i, frame, tmpl)
        if not ok or not tab then return nil end
        tab:SetID(i)
        tab:SetText(label)
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
        if i == 1 then
            tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
        else
            local gap = (tmpl == "CharacterFrameTabButtonTemplate") and -15 or 4
            tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", gap, 0)
        end
        tab:SetScript("OnClick", function()
            if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
                pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
            end
            onSelect(i)
        end)
        tabs[i] = tab
    end
    frame.Tabs = tabs
    frame.numTabs = #tabs
    if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, frame, #tabs) end
    return tabs, tmpl
end

function C.SelectNativeTab(frame, index)
    if frame and frame.Tabs and PanelTemplates_SetTab then
        pcall(PanelTemplates_SetTab, frame, index)
    end
end

function C.SetNativeTabText(tab, text)
    if not tab then return end
    tab:SetText(text)
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
end

----------------------------------------------------------------------
-- Settings-panel tabs in the client's own Options art
--
-- Forever draws the Settings panel's tabs from the Options_Tab_* atlases
-- (Polestar, GameSkins.lua:73). In the native skin a tab gets that three-
-- slice art; in the dark skin it keeps its gold underline.
----------------------------------------------------------------------
local function atlasInfo(name)
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, name)
        if ok then return info end
    end
    return nil
end

C.HasOptionsTabArt = (atlasInfo("Options_Tab_Left") ~= nil) and (atlasInfo("Options_Tab_Active_Left") ~= nil)

function C.SkinTab(btn, selected)
    if not btn then return end
    skinnedTabs[btn] = selected and true or false
    local native = (C.skin == "native") and C.Mainline and C.HasOptionsTabArt

    if native then
        if not btn.wtfayTabArt then
            btn.wtfayTabArt = {
                btn:CreateTexture(nil, "BACKGROUND"),
                btn:CreateTexture(nil, "BACKGROUND"),
                btn:CreateTexture(nil, "BACKGROUND"),
            }
        end
        local prefix = selected and "Options_Tab_Active_" or "Options_Tab_"
        local l, m, r = btn.wtfayTabArt[1], btn.wtfayTabArt[2], btn.wtfayTabArt[3]
        local h = btn:GetHeight()
        if not h or h <= 0 then h = 20 end
        local function sideWidth(name)
            local info = atlasInfo(name)
            if info and info.height and info.height > 0 then return info.width * h / info.height end
            return 8
        end
        l:SetAtlas(prefix .. "Left");   l:SetSize(sideWidth(prefix .. "Left"), h)
        r:SetAtlas(prefix .. "Right");  r:SetSize(sideWidth(prefix .. "Right"), h)
        m:SetAtlas(prefix .. "Middle"); m:SetHeight(h)
        l:ClearAllPoints(); l:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        r:ClearAllPoints(); r:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        m:ClearAllPoints(); m:SetPoint("BOTTOMLEFT", l, "BOTTOMRIGHT"); m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
        l:Show(); m:Show(); r:Show()
        if btn.underline then btn.underline:Hide() end
        return
    end

    if btn.wtfayTabArt then
        for _, t in ipairs(btn.wtfayTabArt) do t:Hide() end
    end
    if btn.underline then btn.underline:SetShown(selected and true or false) end
end

----------------------------------------------------------------------
-- Live skin switching
----------------------------------------------------------------------
function C.SetSkin(name)
    if not C.CanChooseSkin() then name = "dark" end
    if name ~= "native" and name ~= "dark" then name = C.DefaultSkin() end
    C.skin = name

    for frame, opts in pairs(skinnedWindows) do paintWindow(frame, opts) end
    for frame, opts in pairs(skinnedPanels)  do paintPanel(frame, opts) end
    for btn, selected in pairs(skinnedTabs)  do C.SkinTab(btn, selected) end
    for frame in pairs(hairlined) do
        local c = frame.wtfayHairColor
        if c and frame.wtfayHair and frame.wtfayHair[1]:IsShown() then
            C.Hairline(frame, c[1], c[2], c[3], c[4])
        end
    end
    for _, fn in ipairs(skinListeners) do
        local ok, err = pcall(fn, name)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

-- Re-apply the current skin, e.g. after a UI scale change moved the pixel grid.
function C.RefreshSkin()
    C.SetSkin(C.skin)
end

C.skin = C.DefaultSkin()

do
    local watcher = CreateFrame("Frame")
    for _, ev in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
        pcall(watcher.RegisterEvent, watcher, ev)
    end
    watcher:SetScript("OnEvent", function() C.RefreshSkin() end)
end

----------------------------------------------------------------------
-- Text colour tokens
--
-- The single place every inline colour comes from (Polestar's Tokens-Only
-- Rule): WTFAY.lua writes T.gold, never "|cFFFFD100". Both skins share one
-- text palette, since every ground they paint is dark.
----------------------------------------------------------------------
C.T = {
    accent     = "|cFF" .. C.Theme.accent,   -- WTFAY brand cyan
    gold       = "|cFF" .. C.Theme.gold,     -- Blizzard UI gold (NORMAL_FONT_COLOR)
    goldAlt    = "|cFFFFD700",
    white      = "|cFF" .. C.Theme.white,
    text       = "|cFFDDDDDD",
    light      = "|cFFCCCCCC",
    soft       = "|cFFBBBBBB",
    muted      = "|cFFAAAAAA",
    grey       = "|cFF999999",
    dim        = "|cFF888888",
    faint      = "|cFF666666",
    dark       = "|cFF444444",
    on         = "|cFF44FF44",               -- ON / shown / success
    off        = "|cFFFF4444",               -- OFF / hidden / danger
    dangerSoft = "|cFFFF6666",
    blacklist  = "|cFFFF0000",
    warn       = "|cFFFF8800",
    guild      = "|cFF88CCFF",
    manual     = "|cFFFFCC44",
    ember      = "|cFFFF8844",
    brass      = "|cFFDDAA44",
    slate      = "|cFFAAAABB",
}

----------------------------------------------------------------------
-- Settings toggles: tooltip + right-click restores the default
--
-- Polestar's "Row Rule": every setting explains itself in its tooltip, and a
-- right-click puts it back to its default. A CheckButton flips its own checked
-- state on any registered click, so a right-click just overwrites that with
-- the default before calling the setter.
----------------------------------------------------------------------
function C.BindToggle(btn, label, description, setter, default)
    if not btn then return end
    local name = (label or ""):gsub("^%s+", "")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    btn:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            if default == nil then
                self:SetChecked(not self:GetChecked())   -- no default: undo the flip
                return
            end
            self:SetChecked(default and true or false)
            setter(default and true or false)
            return
        end
        setter(self:GetChecked() and true or false)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(name, 1, 0.82, 0)
        if description and description ~= "" then
            GameTooltip:AddLine(description, 1, 1, 1, true)
        end
        if default ~= nil then
            GameTooltip:AddLine("Right-click to restore the default (" .. (default and "on" or "off") .. ").",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

----------------------------------------------------------------------
-- Two-click confirm for destructive buttons
--
-- Arms on the first click ("Click again", in the danger colour) and acts
-- only on a second click within 3 seconds; hiding the button disarms it
-- (Polestar, UI/Options.lua:587). Not for menu entries, which close on click.
----------------------------------------------------------------------
function C.ArmConfirm(button, onConfirm, armedText)
    if not button then return end
    local idle = button:GetText()
    local armedAt

    local function disarm()
        armedAt = nil
        button:SetText(idle)
    end

    button:SetScript("OnClick", function(self)
        if armedAt and (GetTime() - armedAt) <= 3 then
            disarm()
            onConfirm()
            return
        end
        armedAt = GetTime()
        self:SetText(armedText or (C.T.off .. "Click again|r"))
        C_Timer.After(3, function()
            if armedAt and (GetTime() - armedAt) >= 3 then disarm() end
        end)
    end)
    button:HookScript("OnHide", disarm)
end

-- A recessed area to sit a list in. Purely decorative, drawn behind content.
-- Created once but follows the skin live: the native skin shows the client's
-- InsetFrameTemplate, the dark skin a dark well edged by a 1px hairline.
function C.CreateInset(parent)
    local inset = CreateFrame("Frame", nil, parent)
    ensureBackdrop(inset)

    local native
    local tmpl = C.Mainline and pickTemplate("InsetFrameTemplate")
    if tmpl then
        local ok, n = pcall(CreateFrame, "Frame", nil, inset, tmpl)
        if ok and n then
            n:SetAllPoints(inset)
            n:EnableMouse(false)
            native = n
        end
    end

    local function paint()
        if native and C.skin == "native" then
            native:Show()
            if inset.SetBackdrop then inset:SetBackdrop(nil) end
            C.HideHairline(inset)
        else
            if native then native:Hide() end
            if inset.SetBackdrop then
                inset:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
                inset:SetBackdropColor(unpack(C.Theme.insetBg))
            end
            local c = C.Theme.sep
            C.Hairline(inset, c[1], c[2], c[3], c[4])
        end
    end

    paint()
    C.OnSkinChanged(paint)
    return inset
end
----------------------------------------------------------------------
-- Native widgets
----------------------------------------------------------------------
-- Template NAME, for the many existing CreateFrame call sites. Swapping the
-- name keeps each site's own sizing and anchoring untouched while still
-- picking up the modern widget where the client has it.
C.ButtonTemplate = (C.Mainline and pickTemplate("WowStyle1ButtonTemplate", "UIPanelButtonTemplate"))
    or "UIPanelButtonTemplate"

function C.CreateButton(parent, text, w, h)
    local btn = CreateFrame("Button", nil, parent, C.ButtonTemplate)
    if w and h then btn:SetSize(w, h) end
    if text then btn:SetText(text) end
    return btn
end

-- Native search field (magnifier + placeholder + clear button) where the
-- client has one, else a plain edit box.
C.SearchBoxTemplate = pickTemplate("SearchBoxTemplate") or "InputBoxTemplate"
C.HasSearchBox = (C.SearchBoxTemplate == "SearchBoxTemplate")

-- SearchBoxTemplate installs its own OnTextChanged to drive the clear button
-- and placeholder text. Overriding it blindly breaks both, so chain instead.
function C.HookSearchBoxChanged(box, handler)
    box:SetScript("OnTextChanged", function(self, userInput)
        if C.HasSearchBox and SearchBoxTemplate_OnTextChanged then
            pcall(SearchBoxTemplate_OnTextChanged, self)
        end
        handler(self, userInput)
    end)
end

function C.CreateCheckbox(parent)
    local tmpl = (C.Mainline and pickTemplate("WowStyle1CheckboxTemplate", "UICheckButtonTemplate"))
        or pickTemplate("UICheckButtonTemplate")
    if tmpl then
        local ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, tmpl)
        if ok and cb then return cb end
    end
    -- Hand-rolled from the same textures the template uses.
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    return cb
end

----------------------------------------------------------------------
-- Rating icons
--
-- Ready-check ticks/crosses are instantly readable and unmistakably WoW.
-- Returned as an inline texture escape so call sites can prepend it to an
-- existing FontString with no layout change.
--
-- NEVER put the result in a SendChatMessage payload: the "|" escape is
-- rejected by the chat system.
----------------------------------------------------------------------
function C.RatingIcon(rating, size)
    rating = rating or 0
    size = size or 12
    local path
    if rating > 0 then
        path = "Interface\\RAIDFRAME\\ReadyCheck-Ready"
    elseif rating < 0 then
        path = "Interface\\RAIDFRAME\\ReadyCheck-NotReady"
    else
        return ""
    end
    return "|T" .. path .. ":" .. size .. ":" .. size .. "|t "
end

----------------------------------------------------------------------
-- Addon Compartment (Mainline only)
--
-- The native place for an addon entry point on modern clients. Declared in
-- the TOC via ## AddonCompartmentFunc; Classic ignores the tag entirely.
----------------------------------------------------------------------
function C.HasAddonCompartment()
    return AddonCompartmentFrame ~= nil
end
