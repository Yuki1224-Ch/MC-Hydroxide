local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local BugFinder = {}
local Methods = import("modules/BugFinder")

if not hasMethods(Methods.RequiredMethods) then
    return BugFinder
end

local List, ListButton = import("ui/controls/List")
local MessageBox, MessageType = import("ui/controls/MessageBox")
local ContextMenu, ContextMenuButton = import("ui/controls/ContextMenu")
local TabSelector = import("ui/controls/TabSelector")
local CheckBox = import("ui/controls/CheckBox")
local Dropdown = import("ui/controls/Dropdown")

local Page = import("rbxassetid://11389137937").Base.Body.Pages.BugFinder
local Assets = import("rbxassetid://5042114982").BugFinder

local BugList = Page.List
local ListQuery = BugList.Query
local ListSearch = ListQuery.Search
local ListRefresh = ListQuery.Refresh
local ListFilters = BugList.Filters
local ListResults = BugList.Results.Clip.Content

local BugInfo = Page.Info
local InfoBack = BugInfo.Back
local InfoBug = BugInfo.BugObject
local InfoSections = BugInfo.Sections

local InfoDetails = InfoSections.Details
local InfoClosure = InfoSections.Closure
local InfoRelated = InfoSections.Related

local ClosureSpy = import("modules/ClosureSpy")

local bugList = List.new(ListResults)
local relatedList = List.new(InfoRelated.Results.Clip.Content)

local currentBugs = {}
local selectedBug = nil
local selectedBugLog = nil
local scanInProgress = false
local lastScanResults = nil

-- Optimized search with debounce and request queuing
local searchDebounce = false
local searchQueue = {}
local searchCooldown = 0.15 -- Reduced cooldown for snappier response

local severityColors = {
    critical = Color3.fromRGB(255, 0, 0),
    high = Color3.fromRGB(255, 100, 0),
    medium = Color3.fromRGB(255, 200, 0),
    low = Color3.fromRGB(100, 200, 100)
}

local categoryIcons = {
    security = "rbxassetid://4891641806",
    performance = "rbxassetid://4907151581",
    logic = "rbxassetid://4702850565",
    error_handling = "rbxassetid://4892169181",
    compatibility = "rbxassetid://4842578510",
    anti_tamper = "rbxassetid://4666593447"
}

local constants = {
    fadeLength = TweenInfo.new(0.15),
    textWidth = Vector2.new(1337420, 20)
}

-- Context menus
local spyClosureContext = ContextMenuButton.new("rbxassetid://4666593447", "Spy Closure")
local viewClosureContext = ContextMenuButton.new("rbxassetid://5179169654", "View Closure")
local getScriptContext = ContextMenuButton.new("rbxassetid://4891705738", "Get Script Path")
local copyPathContext = ContextMenuButton.new("rbxassetid://4891705738", "Copy Path")

local bugListMenu = ContextMenu.new({ spyClosureContext, viewClosureContext, getScriptContext })
bugList:BindContextMenu(bugListMenu)

-- Filter options
local filterDeepScan = CheckBox.new(ListFilters.DeepScan)
local filterFuzzy = CheckBox.new(ListFilters.FuzzySearch)
local filterSecurity = CheckBox.new(ListFilters.Categories.Security)
local filterPerformance = CheckBox.new(ListFilters.Categories.Performance)
local filterLogic = CheckBox.new(ListFilters.Categories.Logic)
local filterErrorHandling = CheckBox.new(ListFilters.Categories.ErrorHandling)
local filterAntiTamper = CheckBox.new(ListFilters.Categories.AntiTamper)

local filterOptions = {
    deepScan = false,
    fuzzySearch = false,
    categories = {"security", "performance", "logic", "error_handling", "anti_tamper"}
}

filterDeepScan:SetCallback(function(enabled)
    filterOptions.deepScan = enabled
    if enabled then
        MessageBox.Show("Notice", "Deep scanning will analyze upvalues and constants, which may take longer!", MessageType.OK)
    end
end)

filterFuzzy:SetCallback(function(enabled)
    filterOptions.fuzzySearch = enabled
end)

local function toggleCategory(category, enabled)
    if enabled then
        if not table.find(filterOptions.categories, category) then
            table.insert(filterOptions.categories, category)
        end
    else
        local idx = table.find(filterOptions.categories, category)
        if idx then
            table.remove(filterOptions.categories, idx)
        end
    end
end

filterSecurity:SetCallback(function(enabled) toggleCategory("security", enabled) end)
filterPerformance:SetCallback(function(enabled) toggleCategory("performance", enabled) end)
filterLogic:SetCallback(function(enabled) toggleCategory("logic", enabled) end)
filterErrorHandling:SetCallback(function(enabled) toggleCategory("error_handling", enabled) end)
filterAntiTamper:SetCallback(function(enabled) toggleCategory("anti_tamper", enabled) end)

-- Optimized search queue processor
local function processSearchQueue()
    if searchDebounce or #searchQueue == 0 then return end
    
    searchDebounce = true
    local searchText = table.remove(searchQueue, 1)
    
    task.spawn(function()
        -- Filter visible bugs based on search
        for bugData, log in pairs(currentBugs) do
            if not log.Button.Instance then continue end
            local instance = log.Button.Instance
            if not instance.Parent then continue end
            
            local shouldShow = true
            if searchText ~= "" then
                local bugName = (bugData.bugs[1].type or ""):lower()
                local description = (bugData.bugs[1].description or ""):lower()
                local closureName = ""
                
                pcall(function()
                    closureName = (getInfo(bugData.closure.Data).name or ""):lower()
                end)
                
                shouldShow = bugName:find(searchText, 1, true) or 
                            description:find(searchText, 1, true) or 
                            closureName:find(searchText, 1, true)
            end
            
            instance.Visible = shouldShow
        end
        
        bugList:Recalculate()
        
        task.wait(searchCooldown)
        searchDebounce = false
        
        if #searchQueue > 0 then
            processSearchQueue()
        end
    end)
end

-- Create bug log UI element
local function createBugLog(bugData)
    local bug = bugData.bugs[1]
    local instance = Assets.BugLog:Clone()
    local listButton = ListButton.new(instance, bugList)
    
    local severity = bug.severity
    local category = bug.category
    local bugType = bug.type
    
    instance.Name = bugType
    instance.BugType.Text = bugType
    instance.Severity.Text = severity:upper()
    instance.Category.Text = category:gsub("_", " "):upper()
    
    -- Color coding
    instance.Severity.TextColor3 = severityColors[severity] or Color3.white
    instance.CategoryIcon.Image = categoryIcons[category] or categoryIcons.logic
    
    instance.MouseButton1Click:Connect(function()
        if selectedBugLog ~= bugData then
            showBugDetails(bugData)
        end
    end)
    
    listButton:SetRightCallback(function()
        selectedBugLog = bugData
    end)
    
    currentBugs[bugData] = bugData
    return bugData
end

-- Show detailed bug information
local function showBugDetails(bugData)
    local bug = bugData.bugs[1]
    local closure = bugData.closure
    
    selectedBug = bug
    selectedBugLog = bugData
    
    BugList.Visible = false
    BugInfo.Visible = true
    
    local nameLength = TextService:GetTextSize(bug.type, 18, "SourceSans", constants.textWidth).X + 20
    
    InfoBug.Icon.Image = categoryIcons[bug.category] or categoryIcons.logic
    InfoBug.Label.Text = bug.type
    InfoBug.Label.Size = UDim2.new(0, nameLength, 0, 20)
    InfoBug.Position = UDim2.new(1, -nameLength, 0, 0)
    InfoBug.Label.TextColor3 = severityColors[bug.severity] or Color3.white
    
    -- Populate details section
    InfoDetails.Severity.Value.Text = bug.severity:upper()
    InfoDetails.Severity.Value.TextColor3 = severityColors[bug.severity] or Color3.white
    InfoDetails.Category.Value.Text = bug.category:gsub("_", " ")
    InfoDetails.Description.Value.Text = bug.description
    
    -- Get script info
    local scriptName = "Unknown"
    local scriptPath = "N/A"
    
    pcall(function()
        local env = getfenv(closure.Data)
        if env and env.script then
            scriptName = env.script.Name
            scriptPath = getInstancePath(env.script)
        end
    end)
    
    InfoDetails.Script.Value.Text = scriptName
    
    -- Clear and populate related bugs
    relatedList:Clear()
    
    if lastScanResults and lastScanResults.results then
        local relatedCount = 0
        for _, otherBugData in ipairs(lastScanResults.results) do
            if otherBugData ~= bugData and relatedCount < 10 then
                local otherBug = otherBugData.bugs[1]
                if otherBug.category == bug.category or otherBug.severity == bug.severity then
                    local relatedInstance = Assets.RelatedBug:Clone()
                    relatedInstance.BugType.Text = otherBug.type
                    relatedInstance.Severity.Text = otherBug.severity:upper()
                    relatedInstance.Severity.TextColor3 = severityColors[otherBug.severity] or Color3.white
                    
                    ListButton.new(relatedInstance, relatedList):SetCallback(function()
                        showBugDetails(otherBugData)
                    end)
                    
                    relatedCount = relatedCount + 1
                end
            end
        end
    end
    
    relatedList:Recalculate()
end

-- Spy closure callback
spyClosureContext:SetCallback(function()
    if selectedBugLog then
        local closure = selectedBugLog.closure
        
        if TabSelector.SelectTab("ClosureSpy") then
            local SpyHook = ClosureSpy.Hook
            local result = SpyHook.new(closure)
            
            if result == false then
                MessageBox.Show("Already hooked", "You are already spying " .. (getInfo(closure.Data).name or "this closure"))
            elseif result == nil then
                MessageBox.Show("Cannot hook", ('Cannot hook "%s" because there are no upvalues'):format(getInfo(closure.Data).name or "this closure"))
            end
        end
    end
end)

-- View closure callback
viewClosureContext:SetCallback(function()
    if selectedBugLog then
        local closure = selectedBugLog.closure
        
        if TabSelector.SelectTab("UpvalueScanner") then
            -- Trigger upvalue scanner to focus on this closure
            -- This would require cross-module communication
            MessageBox.Show("Info", "Navigate to UpvalueScanner and search for: " .. (getInfo(closure.Data).name or ""), MessageType.OK)
        end
    end
end)

-- Get script path callback
getScriptContext:SetCallback(function()
    if selectedBugLog then
        local closure = selectedBugLog.closure
        
        pcall(function()
            local env = getfenv(closure.Data)
            if env and env.script and typeof(env.script) == "Instance" then
                setClipboard(getInstancePath(env.script))
                MessageBox.Show("Success", "Script path copied to clipboard!", MessageType.OK)
            end
        end)
    end
end)

-- Main scan function with batching and progress
local function performScan(query)
    if scanInProgress then
        MessageBox.Show("Scan in Progress", "A scan is already running. Please wait.", MessageType.OK)
        return
    end
    
    scanInProgress = true
    oh.setStatus("Scanning for bugs...")
    
    task.spawn(function()
        local success, results = pcall(function()
            return Methods.Scan(query or "", {
                deep = filterOptions.deepScan,
                fuzzy = filterOptions.fuzzySearch,
                categories = filterOptions.categories,
                maxResults = 300 -- Reduced from 500 for better performance
            })
        end)
        
        if not success then
            oh.setStatus("Scan failed!")
            MessageBox.Show("Scan Error", results, MessageType.OK)
            scanInProgress = false
            return
        end
        
        lastScanResults = results
        bugList:Clear()
        currentBugs = {}
        
        local totalBugs = results.totalBugs
        local scannedCount = results.scannedCount
        
        if totalBugs == 0 then
            oh.setStatus("Scan complete - No bugs found")
            MessageBox.Show("Scan Complete", 
                string.format("Scanned %d closures.\nNo bugs detected with current filters.", scannedCount), 
                MessageType.OK)
            scanInProgress = false
            return
        end
        
        -- Display results in batches to prevent freezing
        local batchSize = 20 -- Smaller batch size for smoother UI
        local displayedCount = 0
        local totalDisplayed = math.min(totalBugs, 80) -- Reduced from 100 to prevent UI lag
        
        for i, bugData in ipairs(results.results) do
            if displayedCount >= totalDisplayed then break end
            
            createBugLog(bugData)
            displayedCount = displayedCount + 1
            
            -- Yield more frequently to prevent freezing
            if displayedCount % batchSize == 0 then
                task.wait(0.02)
            end
        end
        
        bugList:Recalculate()
        
        local statusMsg = string.format("Found %d bug%s in %d scanned closures", totalBugs, totalBugs ~= 1 and "s" or "", scannedCount)
        oh.setStatus(statusMsg)
        
        if totalBugs > totalDisplayed then
            MessageBox.Show("Scan Complete", 
                string.format("%s\n\nShowing top %d results (sorted by severity).\nRefine your search or filters to see more specific results.", 
                    statusMsg, totalDisplayed), 
                MessageType.OK)
        else
            MessageBox.Show("Scan Complete", statusMsg, MessageType.OK)
        end
        
        scanInProgress = false
    end)
end

-- Search handlers
ListSearch.FocusLost:Connect(function(returned)
    if returned and ListSearch.Text ~= "" then
        table.insert(searchQueue, ListSearch.Text)
        processSearchQueue()
        ListSearch.Text = ""
    end
end)

ListRefresh.MouseButton1Click:Connect(function()
    performScan()
end)

-- Initialize with a scan
task.defer(function()
    task.wait(0.5)
    performScan()
end)

-- Back button
InfoBack.MouseButton1Click:Connect(function()
    BugInfo.Visible = false
    BugList.Visible = true
end)

return BugFinder
