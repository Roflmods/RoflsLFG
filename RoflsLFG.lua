local addonName, ns = ...

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local ROLE_DIVIDER_TANK    = 10
local ROLE_DIVIDER_HEALER  = 11
local ROLE_DIVIDER_DPS     = 12
local ROLE_DIVIDER_GROUPS  = 13

-- Role sections are for SOLO PLAYERS only.
-- Groups get their own separate section.
local ROLE_INFO = {
    { key = "TANK",    roleField = "tank",   dividerType = ROLE_DIVIDER_TANK,
      label = "Tanks",   atlas = "groupfinder-icon-role-large-tank" },
    { key = "HEALER",  roleField = "healer", dividerType = ROLE_DIVIDER_HEALER,
      label = "Healers", atlas = "groupfinder-icon-role-large-heal" },
    { key = "DAMAGER", roleField = "dps",    dividerType = ROLE_DIVIDER_DPS,
      label = "DPS",     atlas = "groupfinder-icon-role-large-dps" },
}

local DIVIDER_BASE_LABELS = {}
for _, ri in ipairs(ROLE_INFO) do
    DIVIDER_BASE_LABELS[ri.dividerType] =
        "|A:" .. ri.atlas .. ":16:16|a " .. ri.label
end
DIVIDER_BASE_LABELS[ROLE_DIVIDER_GROUPS] = "|A:groupfinder-icon-leader:16:16|a Groups"

-- Playstyle colour table (keyed by LFGEntryGeneralPlaystyle enum value)
local PLAYSTYLE_COLORS  -- populated after enums are available

local function EnsurePlaystyleColors()
    if PLAYSTYLE_COLORS then return end
    PLAYSTYLE_COLORS = {}
    if Enum and Enum.LFGEntryGeneralPlaystyle then
        PLAYSTYLE_COLORS[Enum.LFGEntryGeneralPlaystyle.Learning]   = CreateColor(0.12, 0.81, 0.12, 1)
        PLAYSTYLE_COLORS[Enum.LFGEntryGeneralPlaystyle.FunRelaxed] = CreateColor(0.20, 0.75, 1.00, 1)
        PLAYSTYLE_COLORS[Enum.LFGEntryGeneralPlaystyle.FunSerious] = CreateColor(1.00, 0.50, 0.00, 1)
        PLAYSTYLE_COLORS[Enum.LFGEntryGeneralPlaystyle.Expert]     = CreateColor(0.78, 0.20, 0.78, 1)
    end
end

-- Build a fast class-index lookup from CLASS_SORT_ORDER.
local CLASS_ORDER_INDEX = {}
local function EnsureClassIndex()
    if next(CLASS_ORDER_INDEX) then return end
    for i, c in ipairs(CLASS_SORT_ORDER) do
        CLASS_ORDER_INDEX[c] = i
    end
end

-------------------------------------------------------------------------------
-- Filter State  (persists only for the session)
-------------------------------------------------------------------------------
local filters = {
    showGroups      = true,
    showIndividuals = true,
    roles   = { TANK = true, HEALER = true, DAMAGER = true },
    classes = {},  -- populated in Initialize
}

-- Section collapse state (per-session)
local sectionCollapsed = {}

-------------------------------------------------------------------------------
-- /Who Location Lookup
-------------------------------------------------------------------------------
local whoLocationCache = {}   -- [leaderName] = "Zone Name"
local whoPendingName = nil
local whoLastQueryTime = 0
local WHO_COOLDOWN = 5
local whoFrameRegistry = {}   -- weak set of frames that have who elements

local function UpdateWhoLocationOnFrame(frame)
    if not frame or not frame.RoflsWhoLocation or not frame.resultID then return end
    local info = C_LFGList.GetSearchResultInfo(frame.resultID)
    if not info or not info.leaderName then
        frame.RoflsWhoLocation:Hide()
        return
    end
    local location = whoLocationCache[info.leaderName]
    if location then
        frame.RoflsWhoLocation:SetText(location)
        frame.RoflsWhoLocation:Show()
    else
        frame.RoflsWhoLocation:Hide()
    end
end

local function RefreshAllWhoLocations()
    for frame in pairs(whoFrameRegistry) do
        if frame.RoflsWhoLocation then
            UpdateWhoLocationOnFrame(frame)
        end
    end
end

local function DoWhoQuery(playerName)
    if not playerName or playerName == "" then return end
    local now = GetTime()
    if now - whoLastQueryTime < WHO_COOLDOWN then
        local remaining = math.ceil(WHO_COOLDOWN - (now - whoLastQueryTime))
        print("|cFF00CCFFRofls LFG|r: /who cooldown (" .. remaining .. "s)")
        return
    end
    whoPendingName = playerName
    whoLastQueryTime = now
    C_FriendList.SendWho(playerName)
end

local whoEventFrame = CreateFrame("Frame")
whoEventFrame:RegisterEvent("WHO_LIST_UPDATE")
whoEventFrame:SetScript("OnEvent", function(self, event)
    if event ~= "WHO_LIST_UPDATE" or not whoPendingName then return end
    local numWhos, totalCount = C_FriendList.GetNumWhoResults()
    if numWhos and numWhos > 0 then
        local info = C_FriendList.GetWhoInfo(1)
        if info and info.area then
            whoLocationCache[whoPendingName] = info.area
        else
            whoLocationCache[whoPendingName] = "Unknown"
        end
    else
        whoLocationCache[whoPendingName] = "Not Found"
    end
    whoPendingName = nil
    C_Timer.After(0, RefreshAllWhoLocations)
end)

local function SetupWhoElements(frame)
    if frame.RoflsWhoButton then return end

    -- Track this frame for later refresh
    whoFrameRegistry[frame] = true

    -- Small magnifying-glass button inside the top-right of the entry
    local btn = CreateFrame("Button", nil, frame)
    btn:SetSize(14, 14)
    btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -6)
    btn:SetFrameLevel(frame:GetFrameLevel() + 5)

    local ico = btn:CreateTexture(nil, "OVERLAY")
    ico:SetAllPoints()
    ico:SetTexture("Interface\\COMMON\\UI-Searchbox-Icon")
    btn.icon = ico

    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("/who this player")
        local ri = frame.resultID
                   and C_LFGList.GetSearchResultInfo(frame.resultID)
        if ri and ri.leaderName and whoLocationCache[ri.leaderName] then
            GameTooltip:AddLine("Location: " .. whoLocationCache[ri.leaderName],
                                0.67, 0.67, 1.0)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)

    btn:SetScript("OnClick", function(self)
        if not frame.resultID then return end
        local ri = C_LFGList.GetSearchResultInfo(frame.resultID)
        if not ri or not ri.leaderName then return end
        DoWhoQuery(ri.leaderName)
    end)

    frame.RoflsWhoButton = btn

    -- Location text below the Roles area (OVERLAY so it draws on top)
    local loc = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    loc:SetPoint("TOPRIGHT", frame.DataDisplay, "BOTTOMRIGHT", 0, -1)
    loc:SetJustifyH("RIGHT")
    loc:SetTextColor(0.67, 0.67, 1.0)
    loc:Hide()
    frame.RoflsWhoLocation = loc
end

-- Guard flag
local initialized = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- For a SOLO player, return which LFG roles they have selected.
local function GetSoloRoles(resultID)
    local roles = {}
    local member = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
    if member and member.lfgRoles then
        if member.lfgRoles.tank   then roles.TANK   = true end
        if member.lfgRoles.healer then roles.HEALER  = true end
        if member.lfgRoles.dps    then roles.DAMAGER  = true end
    end
    if not next(roles) then roles.DAMAGER = true end
    return roles
end

--- Collect sort-key info for a result (queried once, reused in every section).
local function GetSortInfo(resultID)
    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info then return nil end

    local isSolo = info.numMembers == 1
    local classFilename, level

    if isSolo then
        local m = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
        if m then classFilename = m.classFilename; level = m.level or 0 end
    else
        local l = C_LFGList.GetSearchResultLeaderInfo(resultID)
        if l then classFilename = l.classFilename; level = l.level or 0 end
    end

    return {
        isSolo      = isSolo,
        classFilename = classFilename,
        classIndex  = classFilename and (CLASS_ORDER_INDEX[classFilename] or 999) or 999,
        level       = level or 0,
        numMembers  = info.numMembers,
        hasSelf     = info.hasSelf,
        age         = info.age or 0,
    }
end

--- Does a solo player pass filters for a given role section?
local function SoloPassesFilters(resultID, roleKey)
    if not filters.showIndividuals then return false end
    if not filters.roles[roleKey]  then return false end

    local m = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
    if m and m.classFilename and not filters.classes[m.classFilename] then
        return false
    end
    return true
end

--- Does a group pass filters?
local function GroupPassesFilters(resultID)
    if not filters.showGroups then return false end
    return true
end

--- Sort: solo role sections → by class, then level desc, then age desc
local function SortSoloEntries(a, b)
    local ia, ib = a.sortInfo, b.sortInfo
    if ia.hasSelf ~= ib.hasSelf then return ia.hasSelf end
    if ia.classIndex ~= ib.classIndex then return ia.classIndex < ib.classIndex end
    if ia.level      ~= ib.level      then return ia.level      > ib.level      end
    return ia.age > ib.age
end

--- Sort: group section → by member count desc, then age desc
local function SortGroupEntries(a, b)
    local ia, ib = a.sortInfo, b.sortInfo
    if ia.hasSelf    ~= ib.hasSelf    then return ia.hasSelf end
    if ia.numMembers ~= ib.numMembers then return ia.numMembers > ib.numMembers end
    return ia.age > ib.age
end

-------------------------------------------------------------------------------
-- Playstyle colouring (hooked onto the entry update)
-------------------------------------------------------------------------------
local function ApplyPlaystyleColor(frame)
    if not frame or not frame.resultID then return end

    local label = frame.PlaystyleLabel or frame.RoflsPlaystyleLabel
    if not label then return end

    local info = C_LFGList.GetSearchResultInfo(frame.resultID)
    if not info or not info.generalPlaystyle then return end

    EnsurePlaystyleColors()
    local c = PLAYSTYLE_COLORS[info.generalPlaystyle]
    if c then
        label:SetTextColor(c.r, c.g, c.b)
    end
end

-------------------------------------------------------------------------------
-- Filter Button
-------------------------------------------------------------------------------
local function CreateFilterButton(browseFrame)
    local btn = CreateFrame("Button", "RoflsLFGFilterButton", browseFrame)
    btn:SetSize(20, 20)
    btn:SetPoint("TOP", browseFrame.OptionsButton, "BOTTOM", 0, -3)

    -- Filter icon (magnifying glass)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\COMMON\\UI-Searchbox-Icon")
    btn.icon = icon

    -- Highlight on hover
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    -- Tooltip so the icon is discoverable
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Filter Results")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)

    btn:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(_, root)

            -- ---- Type ----
            root:CreateTitle("Type")

            root:CreateCheckbox("Groups",
                function() return filters.showGroups end,
                function()
                    filters.showGroups = not filters.showGroups
                    browseFrame:UpdateResults()
                end)

            root:CreateCheckbox("Individuals",
                function() return filters.showIndividuals end,
                function()
                    filters.showIndividuals = not filters.showIndividuals
                    browseFrame:UpdateResults()
                end)

            -- ---- Roles (solo players only) ----
            root:CreateTitle("Roles")

            for _, ri in ipairs(ROLE_INFO) do
                local icon = "|A:" .. ri.atlas .. ":14:14|a "
                root:CreateCheckbox(icon .. ri.label,
                    function() return filters.roles[ri.key] end,
                    function()
                        filters.roles[ri.key] = not filters.roles[ri.key]
                        browseFrame:UpdateResults()
                    end)
            end

            -- ---- Classes (solo players only) ----
            root:CreateTitle("Classes")

            for _, class in ipairs(CLASS_SORT_ORDER) do
                local name  = LOCALIZED_CLASS_NAMES_MALE
                              and LOCALIZED_CLASS_NAMES_MALE[class] or class
                local color = RAID_CLASS_COLORS[class]
                local lbl   = color and color:WrapTextInColorCode(name) or name

                root:CreateCheckbox(lbl,
                    function() return filters.classes[class] end,
                    function()
                        filters.classes[class] = not filters.classes[class]
                        browseFrame:UpdateResults()
                    end)
            end
        end)
    end)

    browseFrame.RoflsFilterButton = btn
end

-------------------------------------------------------------------------------
-- Core: replace the scroll-view factory & UpdateResults
-------------------------------------------------------------------------------
local function Initialize()
    if initialized then return end

    local bf = LFGBrowseFrame
    if not bf or not bf.ScrollBox then return end

    initialized = true

    EnsureClassIndex()
    EnsurePlaystyleColors()

    -- Populate class filter defaults
    for _, class in ipairs(CLASS_SORT_ORDER) do
        if filters.classes[class] == nil then
            filters.classes[class] = true
        end
    end

    ---------------------------------------------------------------------------
    -- 1.  Replace the element factory on the existing scroll view.
    ---------------------------------------------------------------------------
    local view = bf.ScrollBox:GetView()
    if view and view.SetElementFactory then
        view:SetElementFactory(function(factory, elementData)
            local data = elementData.data

            if data.dividerType then
                ---------------------------------------------------------------
                -- SECTION HEADER  (role or groups)
                ---------------------------------------------------------------
                factory("LFGBrowseSearchEntryGroupingTemplate",
                    function(frame, elementNode)
                        frame.CategoryLabel:SetText(
                            data.customLabel
                            or DIVIDER_BASE_LABELS[data.dividerType]
                            or "")
                        frame.CategoryLabel:Show()

                        if elementNode.collapsed then
                            frame.ExpandIcon:Show()
                            frame.CollapseIcon:Hide()
                        else
                            frame.ExpandIcon:Hide()
                            frame.CollapseIcon:Show()
                        end

                        frame:SetScript("OnClick", function(self)
                            local dt = data.dividerType
                            elementNode:ToggleCollapsed(
                                nil, TreeDataProviderConstants.DoInvalidation)
                            sectionCollapsed[dt] = elementNode.collapsed
                            if elementNode.collapsed then
                                self.ExpandIcon:Show()
                                self.CollapseIcon:Hide()
                            else
                                self.ExpandIcon:Hide()
                                self.CollapseIcon:Show()
                            end
                        end)
                    end)

            elseif data.category then
                ---------------------------------------------------------------
                -- NESTED ENTRY (inside a section – has PlaystyleLabel)
                ---------------------------------------------------------------
                factory("LFGBrowseNestedSearchEntryTemplate",
                    function(frame, elementNode)
                        LFGBrowseSearchEntry_Init(frame, elementNode.data, bf)
                        ApplyPlaystyleColor(frame)
                        SetupWhoElements(frame)
                        UpdateWhoLocationOnFrame(frame)
                    end)

            else
                ---------------------------------------------------------------
                -- TOP-LEVEL ENTRY (e.g. self-listing, outside sections)
                ---------------------------------------------------------------
                factory("LFGBrowseSearchEntryTemplate",
                    function(frame, elementNode)
                        LFGBrowseSearchEntry_Init(frame, elementNode.data, bf)
                        SetupWhoElements(frame)
                        UpdateWhoLocationOnFrame(frame)
                    end)
            end
        end)
    end

    ---------------------------------------------------------------------------
    -- 2.  Replace UpdateResults
    --
    --     Layout:
    --       [Self listing]           ← top-level, always first if present
    --       ▸ Tanks   (N)            ← solo players who selected Tank
    --       ▸ Healers (N)            ← solo players who selected Healer
    --       ▸ DPS     (N)            ← solo players who selected DPS
    --       ▸ Groups  (N)            ← all multi-member listings
    --
    --     A solo player listed as Tank+DPS appears in BOTH Tank and DPS.
    --     Groups are always in the Groups section, never in role sections.
    ---------------------------------------------------------------------------
    bf.UpdateResults = function(self)
        self.selectionBehavior:ClearSelections()
        self.ScrollBox:RemoveDataProvider()

        if self.searching then
            self.SearchingSpinner:Show()
        else
            self.SearchingSpinner:Hide()

            if self.totalResults == 0 or self.searchFailed then
                self.NoResultsFound:Show()
                self.NoResultsFound:SetText(
                    self.searchFailed and LFG_LIST_SEARCH_FAILED
                    or LFG_LIST_NO_RESULTS_FOUND)
            else
                self.NoResultsFound:Hide()

                local dp      = CreateTreeDataProvider()
                local results = self.results

                -- Buckets: one per role section (solo only) + one for groups
                local byRole  = { TANK = {}, HEALER = {}, DAMAGER = {} }
                local groups  = {}

                for idx = 1, #results do
                    local rid  = results[idx]
                    local info = C_LFGList.GetSearchResultInfo(rid)

                    if info then
                        if info.hasSelf then
                            -- Own listing pinned at the very top
                            dp:Insert({ index = idx, resultID = rid })

                        elseif info.numMembers == 1 then
                            ---------------------------------------------------
                            -- SOLO PLAYER → goes into every role they selected
                            ---------------------------------------------------
                            local roles = GetSoloRoles(rid)
                            local si    = GetSortInfo(rid)
                            if si then
                                for roleKey in pairs(roles) do
                                    if SoloPassesFilters(rid, roleKey) then
                                        tinsert(byRole[roleKey], {
                                            resultID = rid,
                                            index    = idx,
                                            sortInfo = si,
                                        })
                                    end
                                end
                            end

                        else
                            ---------------------------------------------------
                            -- GROUP → goes into the Groups section
                            ---------------------------------------------------
                            if GroupPassesFilters(rid) then
                                local si = GetSortInfo(rid)
                                if si then
                                    tinsert(groups, {
                                        resultID = rid,
                                        index    = idx,
                                        sortInfo = si,
                                    })
                                end
                            end
                        end
                    end
                end

                -- ---- Build role sections (solo players) ----
                for _, ri in ipairs(ROLE_INFO) do
                    if filters.showIndividuals and filters.roles[ri.key] then
                        local entries = byRole[ri.key]
                        table.sort(entries, SortSoloEntries)

                        local label = DIVIDER_BASE_LABELS[ri.dividerType]
                                      .. "  (" .. #entries .. ")"

                        local subtree = dp:Insert({
                            dividerType = ri.dividerType,
                            customLabel = label,
                        })

                        for _, e in ipairs(entries) do
                            subtree:Insert({
                                index    = e.index,
                                resultID = e.resultID,
                                category = ri.dividerType,
                            })
                        end

                        if sectionCollapsed[ri.dividerType] then
                            subtree:SetCollapsed(true)
                        end
                    end
                end

                -- ---- Build groups section ----
                if filters.showGroups then
                    table.sort(groups, SortGroupEntries)

                    local label = DIVIDER_BASE_LABELS[ROLE_DIVIDER_GROUPS]
                                  .. "  (" .. #groups .. ")"

                    local subtree = dp:Insert({
                        dividerType = ROLE_DIVIDER_GROUPS,
                        customLabel = label,
                    })

                    for _, e in ipairs(groups) do
                        subtree:Insert({
                            index    = e.index,
                            resultID = e.resultID,
                            category = ROLE_DIVIDER_GROUPS,
                        })
                    end

                    if sectionCollapsed[ROLE_DIVIDER_GROUPS] then
                        subtree:SetCollapsed(true)
                    end
                end

                self.ScrollBox:SetDataProvider(
                    dp, ScrollBoxConstants.RetainScrollPosition)
            end
        end

        self:UpdateButtonState()
    end

    ---------------------------------------------------------------------------
    -- 3.  Hook entry update to recolour the playstyle label every refresh
    ---------------------------------------------------------------------------
    hooksecurefunc("LFGBrowseSearchEntry_Update", function(frame)
        ApplyPlaystyleColor(frame)
        UpdateWhoLocationOnFrame(frame)
    end)

    ---------------------------------------------------------------------------
    -- 4.  Create the filter button
    ---------------------------------------------------------------------------
    CreateFilterButton(bf)

    ---------------------------------------------------------------------------
    -- 5.  If the browse frame is already visible, refresh it now
    ---------------------------------------------------------------------------
    if bf:IsShown() and bf.totalResults and bf.totalResults > 0 then
        bf:UpdateResultList()
    end

    print("|cFF00CCFFRofls LFG Enhanced|r loaded – browse sorted by role.")
end

-------------------------------------------------------------------------------
-- Bootstrap: wait for the Blizzard LFG addon to load, then initialise
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addon)
    if addon == addonName then
        if LFGBrowseFrame then
            C_Timer.After(0, Initialize)
        end
    elseif addon == "Blizzard_GroupFinder_VanillaStyle" then
        C_Timer.After(0, Initialize)
    end
end)

if LFGBrowseFrame then
    C_Timer.After(0, Initialize)
end
