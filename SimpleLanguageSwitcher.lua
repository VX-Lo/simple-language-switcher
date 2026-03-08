local addonName = ...

--[[
Simple Language Switcher
------------------------
This addon does one thing: it changes the active speaking language used by
chat edit boxes.

Design notes for future maintainers / forks:
- Slash commands are the primary interface and should continue to work even if
  optional UI libraries are unavailable.
- The minimap button is an optional convenience layer powered by LDB/LibDBIcon.
- We store only the minimum persistent state needed:
  - selected language ID
  - minimap icon settings (when LibDBIcon is present)
]]

local ADDON_TAG = "|cff00ccff[SLS]|r"

local knownLanguages = {}
local currentIndex = 1

local ldbObject
local dbIcon
local minimapButton
local refreshTooltip

local function Print(message)
    print(ADDON_TAG .. " " .. message)
end

local function EnsureDB()
    if type(SimpleLanguageSwitcherDB) ~= "table" then
        SimpleLanguageSwitcherDB = {}
    end

    if type(SimpleLanguageSwitcherDB.minimap) ~= "table" then
        SimpleLanguageSwitcherDB.minimap = {}
    end
end

-- Refresh the character's currently known languages from the WoW API.
local function RefreshLanguages()
    wipe(knownLanguages)

    for i = 1, GetNumLanguages() do
        local name, id = GetLanguageByIndex(i)
        if name and id then
            table.insert(knownLanguages, {
                name = name,
                id = id,
            })
        end
    end
end

-- Determine which language is currently active on the primary chat edit box.
-- If that cannot be determined, we fall back to the first known language.
local function FindCurrentIndex()
    local editBox = ChatFrame1EditBox

    if editBox and editBox.languageID then
        for i, lang in ipairs(knownLanguages) do
            if lang.id == editBox.languageID then
                return i
            end
        end
    end

    return 1
end

-- Apply the selected language to every chat edit box so that whichever chat
-- frame the user opens next will use the same language consistently.
local function ApplyLanguageToEditBoxes(language)
    for i = 1, NUM_CHAT_WINDOWS do
        local editBox = _G["ChatFrame" .. i .. "EditBox"]
        if editBox then
            editBox.languageID = language.id
            editBox.language = language.name
        end
    end
end

local function SetSpeakingLanguage(index, silent)
    if index < 1 or index > #knownLanguages then
        return false
    end

    local language = knownLanguages[index]
    if not language then
        return false
    end

    currentIndex = index
    ApplyLanguageToEditBoxes(language)

    EnsureDB()
    SimpleLanguageSwitcherDB.languageID = language.id

    if not silent then
        Print("Now speaking in " .. language.name .. ".")
    end

    return true
end

-- Match user input against known languages with:
-- 1. exact match
-- 2. prefix match
-- 3. unique substring match
--
-- This keeps slash usage ergonomic without needing users to type the full
-- localized language name every time.
local function SetLanguageByName(name)
    if #knownLanguages == 0 then
        Print("No known languages are currently available.")
        return false
    end

    local query = name and strlower(strtrim(name))
    if not query or query == "" then
        return false
    end

    local exactMatch
    local prefixMatch
    local substringMatches = {}

    for i, language in ipairs(knownLanguages) do
        local lowercaseName = strlower(language.name)

        if lowercaseName == query then
            exactMatch = i
            break
        elseif strsub(lowercaseName, 1, #query) == query then
            if not prefixMatch then
                prefixMatch = i
            end
        elseif strfind(lowercaseName, query, 1, true) then
            table.insert(substringMatches, i)
        end
    end

    local chosenIndex

    if exactMatch then
        chosenIndex = exactMatch
    elseif prefixMatch then
        chosenIndex = prefixMatch
        Print("No exact match for '" .. name .. "', using closest match '" .. knownLanguages[chosenIndex].name .. "'.")
    elseif #substringMatches == 1 then
        chosenIndex = substringMatches[1]
        Print("Interpreting '" .. name .. "' as '" .. knownLanguages[chosenIndex].name .. "'.")
    elseif #substringMatches > 1 then
        local options = {}

        for _, index in ipairs(substringMatches) do
            table.insert(options, knownLanguages[index].name)
        end

        Print("Ambiguous input '" .. name .. "'. Possible matches:")
        print("  |cff00ff00" .. table.concat(options, ", ") .. "|r")
        return false
    else
        Print("Could not find a language close to '" .. name .. "'.")
        print("  Use |cff00ccff/sls list|r to see all known languages.")
        return false
    end

    return SetSpeakingLanguage(chosenIndex, false)
end

local function CycleLanguage()
    RefreshLanguages()

    if #knownLanguages == 0 then
        Print("No known languages are currently available.")
        return
    end

    currentIndex = FindCurrentIndex()

    local nextIndex = (currentIndex % #knownLanguages) + 1
    SetSpeakingLanguage(nextIndex, false)
end

local function ShowLanguageMenu(anchor)
    if not MenuUtil or not MenuUtil.CreateContextMenu then
        Print("Context menus are not available in this client.")
        return
    end

    if #knownLanguages == 0 then
        Print("No known languages are currently available.")
        return
    end

    MenuUtil.CreateContextMenu(anchor, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle("Select Language")

        local activeIndex = FindCurrentIndex()

        for i, language in ipairs(knownLanguages) do
            local text = language.name

            if i == activeIndex then
                text = "|cff00ff00" .. text .. " (current)|r"
            end

            rootDescription:CreateButton(text, function()
                SetSpeakingLanguage(i, false)
            end)
        end
    end)
end

local function RefreshTooltip()
    if not refreshTooltip then
        return
    end

    refreshTooltip()
end

local function ToggleMinimapIcon()
    if not dbIcon then
        Print("Minimap support is unavailable because LibDBIcon-1.0 is not loaded.")
        return
    end

    EnsureDB()

    local minimapSettings = SimpleLanguageSwitcherDB.minimap
    minimapSettings.hide = not minimapSettings.hide

    if minimapSettings.hide then
        dbIcon:Hide(addonName)
        Print("Minimap icon hidden.")
    else
        dbIcon:Show(addonName)
        Print("Minimap icon shown.")
    end
end

local function HideMinimapIcon()
    if not dbIcon then
        Print("Minimap support is unavailable because LibDBIcon-1.0 is not loaded.")
        return
    end

    EnsureDB()
    SimpleLanguageSwitcherDB.minimap.hide = true
    dbIcon:Hide(addonName)

    if minimapButton and GameTooltip:IsOwned(minimapButton) then
        GameTooltip:Hide()
    end

    Print("Minimap icon hidden. Type |cff00ccff/sls minimap|r to show it again.")
end

-- Re-apply the saved language whenever a chat edit box is activated.
-- This keeps the user's chosen language sticky even if Blizzard recreates or
-- reinitializes edit box state.
local function HookChatSystem()
    if not ChatEdit_ActivateChat then
        return
    end

    hooksecurefunc("ChatEdit_ActivateChat", function(editBox)
        local savedLanguageID = SimpleLanguageSwitcherDB and SimpleLanguageSwitcherDB.languageID
        if not savedLanguageID then
            return
        end

        for _, language in ipairs(knownLanguages) do
            if language.id == savedLanguageID then
                editBox.languageID = language.id
                editBox.language = language.name
                return
            end
        end
    end)
end

local function InitializeOptionalMinimapSupport()
    local libStub = _G.LibStub
    if not libStub then
        return
    end

    local ldb = libStub:GetLibrary("LibDataBroker-1.1", true)
    local icon = libStub:GetLibrary("LibDBIcon-1.0", true)

    if not ldb or not icon then
        return
    end

    dbIcon = icon

    ldbObject = ldb:NewDataObject(addonName, {
        type = "data source",
        text = "SLS",
        icon = 458228,

        OnClick = function(frame, button)
            if button == "LeftButton" then
                CycleLanguage()
            elseif button == "RightButton" then
                RefreshLanguages()
                ShowLanguageMenu(frame)
            elseif button == "MiddleButton" then
                HideMinimapIcon()
                return
            end

            RefreshTooltip()
        end,

        OnTooltipShow = function(tooltip)
            if not tooltip or not tooltip.AddLine then
                return
            end

            RefreshLanguages()

            tooltip:AddLine("Simple Language Switcher", 1, 1, 1)

            local activeIndex = FindCurrentIndex()
            local activeLanguage = knownLanguages[activeIndex]

            if activeLanguage then
                tooltip:AddLine("Current: " .. activeLanguage.name, 0.8, 0.8, 0.8)
            end

            tooltip:AddLine(" ")
            tooltip:AddLine("Left-Click: Cycle language")
            tooltip:AddLine("Right-Click: Select language")

            if dbIcon then
                tooltip:AddLine("Middle-Click: Hide minimap icon")
            end
        end,
    })

    refreshTooltip = function()
        C_Timer.After(0.05, function()
            if minimapButton and minimapButton:IsMouseOver() then
                local onEnter = minimapButton:GetScript("OnEnter")
                if onEnter then
                    onEnter(minimapButton)
                end
            end
        end)
    end

    dbIcon:Register(addonName, ldbObject, SimpleLanguageSwitcherDB)
    minimapButton = _G["LibDBIcon10_" .. addonName]
end

SLASH_SLS1 = "/sls"
SlashCmdList.SLS = function(msg)
    msg = strtrim(msg or "")
    local loweredMsg = strlower(msg)

    if loweredMsg == "" or loweredMsg == "help" then
        print("|cff00ccff--- Simple Language Switcher (SLS) ---|r")
        print("  |cff00ccff/sls|r - Show this help")
        print("  |cff00ccff/sls <language>|r - Switch to a language (e.g. |cff00ccff/sls common|r)")
        print("  |cff00ccff/sls cycle|r - Cycle to the next known language")
        print("  |cff00ccff/sls list|r - List all known languages")
        print("  |cff00ccff/sls minimap|r - Toggle the minimap button")

        if not dbIcon then
            print("  |cffffcc00Note: minimap support is unavailable because optional libraries are not loaded.|r")
        end

    elseif loweredMsg == "cycle" then
        CycleLanguage()

    elseif loweredMsg == "list" then
        RefreshLanguages()

        if #knownLanguages == 0 then
            Print("No known languages are currently available.")
            return
        end

        print("|cff00ccff[SLS]|r Known languages:")

        local activeIndex = FindCurrentIndex()

        for i, language in ipairs(knownLanguages) do
            if i == activeIndex then
                print("  |cff00ff00> " .. language.name .. " (current)|r")
            else
                print("    " .. language.name)
            end
        end

    elseif loweredMsg == "minimap" then
        ToggleMinimapIcon()

    else
        RefreshLanguages()
        SetLanguageByName(msg)
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    if event ~= "PLAYER_LOGIN" then
        return
    end

    self:UnregisterEvent("PLAYER_LOGIN")

    EnsureDB()
    RefreshLanguages()

    if SimpleLanguageSwitcherDB.languageID then
        for i, language in ipairs(knownLanguages) do
            if language.id == SimpleLanguageSwitcherDB.languageID then
                SetSpeakingLanguage(i, true)
                break
            end
        end
    else
        currentIndex = FindCurrentIndex()
    end

    HookChatSystem()
    InitializeOptionalMinimapSupport()
end)
