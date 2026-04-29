local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local UpvalueScanner = {}
local ClosureSpy = import("modules/ClosureSpy")
local Methods = import("modules/UpvalueScanner")

if not hasMethods(Methods.RequiredMethods) then
    return UpvalueScanner
end

local Upvalue = import("objects/Upvalue")

local Prompt = import("ui/controls/Prompt")
local CheckBox = import("ui/controls/CheckBox")
local Dropdown = import("ui/controls/Dropdown")
local List, ListButton = import("ui/controls/List")
local TabSelector = import("ui/controls/TabSelector")
local MessageBox, MessageType = import("ui/controls/MessageBox")
local ContextMenu, ContextMenuButton = import("ui/controls/ContextMenu")

local Base = import("rbxassetid://11389137937").Base
local Assets = import("rbxassetid://5042114982").UpvalueScanner

local Prompts = Base.Prompts
local Page = Base.Body.Pages.UpvalueScanner

local Query = Page.Query
local Search = Query.Search
local SearchBox = Query.Query
local Filters = Page.Filters
local ResultsClip = Page.Results.Clip
local ResultStatus = ResultsClip.ResultStatus

local modifyUpvalue = Prompt.new(Prompts.ModifyUpvalue)
local modifyElement = Prompt.new(Prompts.ModifyElement)
local deepSearch = CheckBox.new(Filters.SearchInTables)
local upvalueList = List.new(ResultsClip.Content)

local deepSearchFlag = false
local currentUpvalues = {}
local updateConnection = nil
local isVisible = false
local scanDebounce = false
local pendingSearchQuery = nil
local lastSearchTime = 0
local searchCooldown = 0.25 -- Reduced cooldown for snappier search

local selectedLog
local selectedUpvalue
local selectedUpvalueLog
local selectedElement

-- Smooth UI update tracking
local lastUpdateTime = 0
local updateInterval = 1/60 -- 60 FPS target
local pendingUpdates = {}
local isUpdating = false

local spyClosureContext = ContextMenuButton.new("rbxassetid://4666593447", "Spy Closure")
local viewUpvaluesContext = ContextMenuButton.new("rbxassetid://5179169654", "View All Upvalues")
local changeUpvalueContext = ContextMenuButton.new("rbxassetid://5458573463", "Change Upvalue")
local changeTableContext = ContextMenuButton.new("rbxassetid://5458573463", "Change Upvalue")
local viewElementsContext = ContextMenuButton.new("rbxassetid://5179169654", "View All Elements")
local changeElementContext = ContextMenuButton.new("rbxassetid://5458573463", "Change Element")
local upvalueScriptContext = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local tableScriptContext = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local elementScriptContext = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local getScriptContext = ContextMenuButton.new("rbxassetid://4891705738", "Get Script Path")

local closureContextMenu = ContextMenu.new({ spyClosureContext, viewUpvaluesContext, getScriptContext })
local tableContextMenu = ContextMenu.new({ changeTableContext, viewElementsContext, tableScriptContext })
local upvalueContextMenu = ContextMenu.new({ changeUpvalueContext, upvalueScriptContext })
local elementContextMenu = ContextMenu.new({ changeElementContext, elementScriptContext })

local modifyUpvalueInner = modifyUpvalue.Instance.Inner
local modifyUpvalueContent = modifyUpvalueInner.Content
local modifyUpvalueButtons = modifyUpvalueInner.Buttons.SetCancel
local modifyUpvalueType = modifyUpvalueContent.Type
local modifyUpvalueValue = modifyUpvalueContent.Value.Input

local modifyElementInner = modifyElement.Instance.Inner
local modifyElementContent = modifyElementInner.Content
local modifyElementButtons = modifyElementInner.Buttons.SetCancel
local modifyElementType = modifyElementContent.Type
local modifyElementValue = modifyElementContent.Value.Input

local upvalueTypeDropdown = Dropdown.new(modifyUpvalueType)
local elementTypeDropdown = Dropdown.new(modifyElementType)

local constants = {
    tempElementColor = Color3.fromRGB(30, 10, 10),
    tempUpvalueColor = Color3.fromRGB(40, 20, 20),
    tempBorderColor = Color3.fromRGB(20, 0, 0)
}

local function typeMismatchMessage()
    MessageBox.Show("Error", 
        "Value does not match selected type",
        MessageType.OK)
end

local function addElement(upvalueLog, upvalue, index, value, temporary)
    local elementLog = Assets.Element:Clone()
    local elementIndexType = type(index)
    local elementValueType = type(value)
    local indexText = toString(index)

    if temporary then
        elementLog.ImageColor3 = constants.tempElementColor
        elementLog.Border.ImageColor3 = constants.tempBorderColor
    end

    elementLog.Name = indexText
    elementLog.Index.Label.Text = indexText
    elementLog.Value.Label.Text = toString(value)
    elementLog.Index.Label.TextColor3 = oh.Constants.Syntax[elementIndexType]
    elementLog.Index.Icon.Image = oh.Constants.Types[elementIndexType]
    elementLog.Value.Label.TextColor3 = oh.Constants.Syntax[elementValueType]
    elementLog.Value.Icon.Image = oh.Constants.Types[elementValueType]

    elementLog.MouseButton2Click:Connect(function()
        selectedUpvalue = upvalue
        selectedUpvalueLog = upvalueLog
        selectedElement = index
        elementTypeDropdown:SetSelected(typeof(value))
        elementContextMenu:Show()
    end)
    
    elementLog.MouseButton1Click:Connect(function()
    	if pressHold then
	        selectedUpvalue = upvalue
	        selectedUpvalueLog = upvalueLog
	        selectedElement = index
	        elementTypeDropdown:SetSelected(typeof(value))
	        elementContextMenu:Show()
        end
    end)

    return elementLog
end

local function setTextSafely(label, newText)
    -- Clear text first to force refresh, then set new value
    if label and label.Parent then
        label.Text = ""
        task.defer(function()
            if label and label.Parent then
                label.Text = newText
            end
        end)
    end
end

local function updateElement(upvalueLog, index, value)
    local indexText = toString(index)
    local elementIndexType = type(index)
    local elementValueType = type(value)
    local elementLog = upvalueLog.Elements:FindFirstChild(indexText)
    
    -- Skip if element UI no longer exists
    if not elementLog then
        return
    end

    -- Force complete refresh with safe text setting to prevent stuck state
    local newValueText = toString(value)
    setTextSafely(elementLog.Value.Label, newValueText)
    elementLog.Value.Label.TextColor3 = oh.Constants.Syntax[elementValueType]
    elementLog.Value.Icon.Image = oh.Constants.Types[elementValueType]
    
    setTextSafely(elementLog.Index.Label, indexText)
    elementLog.Index.Label.TextColor3 = oh.Constants.Syntax[elementIndexType]
    elementLog.Index.Icon.Image = oh.Constants.Types[elementIndexType]
end

local function addUpvalue(upvalue, temporary)
    local upvalueLog
    local index = upvalue.Index
    local value = upvalue.Value
    local valueType = type(value)
    
    if valueType == "table" then
        upvalueLog = Assets.Table:Clone()
        local height = 25

        if temporary then
            upvalueLog.ImageColor3 = constants.tempUpvalueColor
            upvalueLog.Border.ImageColor3 = constants.tempBorderColor
        end

        if not temporary then
            for i, v in pairs(upvalue.Scanned) do
                local elementLog = addElement(upvalueLog, upvalue, i, v)
                elementLog.Parent = upvalueLog.Elements
                
                height = height + elementLog.AbsoluteSize.Y + 5
            end
        end

        upvalueLog.Size = UDim2.new(1, 0, 0, height)
    else
        upvalueLog = Assets.Upvalue:Clone()

        if temporary then
            upvalueLog.ImageColor3 = constants.tempUpvalueColor
            upvalueLog.Border.ImageColor3 = constants.tempBorderColor
        end

        if valueType == "function" then
            local closureName = getInfo(value).name or ''
            upvalueLog.Value.Text = (closureName == '' and "Unnamed function") or closureName
        else
            upvalueLog.Value.Text = toString(value)
        end
    end
    
    upvalueLog.Name = index
    upvalueLog.Index.Text = index
    upvalueLog.Value.TextColor3 = oh.Constants.Syntax[valueType]
    upvalueLog.Icon.Image = oh.Constants.Types[valueType]

    upvalueLog.MouseButton2Click:Connect(function()
        selectedUpvalue = upvalue
        selectedUpvalueLog = upvalueLog
        upvalueTypeDropdown:SetSelected(typeof(upvalue.Value))

        if upvalue.Scanned then
            tableContextMenu:Show()
        else
            upvalueContextMenu:Show()
        end
    end)
    
	upvalueLog.MouseButton1Click:Connect(function()
		if pressHold then
	        selectedUpvalue = upvalue
	        selectedUpvalueLog = upvalueLog
	        upvalueTypeDropdown:SetSelected(typeof(upvalue.Value))
	
	        if upvalue.Scanned then
	            tableContextMenu:Show()
	        else
	            upvalueContextMenu:Show()
	        end
		end
	end)

    return upvalueLog
end

local function updateUpvalue(closureLog, upvalue)
    local upvalueLog = closureLog.Instance.Upvalues[tostring(upvalue.Index)]
    
    -- Skip if upvalue UI no longer exists
    if not upvalueLog then
        return
    end
    
    local closure = upvalue.Closure
    local index = upvalue.Index
    local newValue = getUpvalue(closure, index)
    local valueType = type(newValue)

    -- Safe text update with clearing to prevent stuck text
    if valueType == "function" then
        local closureName = getInfo(newValue).name or ''
        local newValueText = (closureName == '' and "Unnamed function") or closureName
        setTextSafely(upvalueLog.Value, newValueText)
    elseif valueType == "table" and upvalue.Scanned then
        for i, v in pairs(upvalue.Scanned) do
            updateElement(upvalueLog, i, v)
        end

        if upvalue.TemporaryElements then
            local table = upvalue.Value

            for idx, _v in pairs(upvalue.TemporaryElements) do
                updateElement(upvalueLog, idx, table[idx])
            end
        end
    else
        local newValueText = toString(newValue)
        setTextSafely(upvalueLog.Value, newValueText)
    end

    upvalueLog.Value.TextColor3 = oh.Constants.Syntax[valueType]
    upvalueLog.Icon.Image = oh.Constants.Types[valueType]

    upvalue:Update(newValue)
end

-- Log Object
local Log = {}

function Log.new(closure)
    local log = {}
    local instance = Assets.ClosureLog:Clone()
    local listButton = ListButton.new(instance, upvalueList)
    local logHeight = 30

    log.Instance = instance
    log.Closure = closure
    log.Upvalues = {}
    log.Update = Log.update

    for i, upvalue in pairs(closure.Upvalues) do
        local upvalueLog = addUpvalue(upvalue)
        upvalueLog.Parent = instance.Upvalues

        logHeight = logHeight + upvalueLog.AbsoluteSize.Y + 5
        log.Upvalues[i] = upvalueLog
    end

    instance.Size = UDim2.new(1, 0, 0, logHeight)
    instance:FindFirstChild("Name").Text = closure.Name
    
    listButton:SetRightCallback(function()
        selectedLog = log
    end)
    
    currentUpvalues[closure.Data] = log

    return log
end

function Log.update(log)
    -- Skip update if closure is no longer valid
    if not log.Closure or not log.Instance or not log.Instance.Parent then
        return
    end
    
    -- Update closure name with safe text setting to prevent stuck text
    local nameLabel = log.Instance:FindFirstChild("Name")
    if nameLabel then
        setTextSafely(nameLabel, log.Closure.Name or "")
    end
    
    for _i, upvalue in pairs(log.Closure.Upvalues) do
        updateUpvalue(log, upvalue)
    end
    
    for _i, upvalue in pairs(log.Closure.TemporaryUpvalues) do
        updateUpvalue(log, upvalue)
    end
end

local function addUpvalues()
    local query = SearchBox.Text
    local currentTime = tick()
    
    -- Prevent search if already scanning or in cooldown
    if scanDebounce then
        pendingSearchQuery = query
        return
    end
    
    -- Time-based debounce for smoother UI
    if currentTime - lastSearchTime < searchCooldown then
        pendingSearchQuery = query
        return
    end

    if query:gsub(' ', '') ~= '' then
        if not tonumber(query) and query:len() <= 1 then
            MessageBox.Show("Invalid query", "Your query is too short", MessageType.OK)
            SearchBox.Text = ""
            return
        end

        -- Set debounce to prevent lag
        scanDebounce = true
        lastSearchTime = currentTime
        
        local showResultLabel = false
        local totalResults = 0

        -- Use debounce to prevent lag during search
        local scanResults = Methods.Scan(query, deepSearchFlag)
        
        -- Convert to array for controlled iteration
        local resultsArray = {}
        for _i, closure in pairs(scanResults) do
            table.insert(resultsArray, closure)
        end
        
        local resultCount = #resultsArray
        
        -- Create a set of new result closures for fast lookup
        local newResultClosures = {}
        for i = 1, resultCount do
            newResultClosures[resultsArray[i].Data] = true
        end
        
        -- Hide all existing logs first (visibility filtering approach)
        local hiddenLogs = {}
        for closureData, log in pairs(currentUpvalues) do
            if log.Instance and log.Instance.Parent then
                log.Instance.Visible = false
                table.insert(hiddenLogs, closureData)
            end
        end
        
        -- Process results in batches to prevent freezing
        local processed = 0
        local batchSize = 30 -- Increased batch size for faster display
        
        while processed < resultCount do
            local batchEnd = math.min(processed + batchSize, resultCount)
            
            for i = processed + 1, batchEnd do
                local closure = resultsArray[i]
                local closureData = closure.Data
                
                -- Check if this closure already has a log
                local existingLog = currentUpvalues[closureData]
                
                if existingLog then
                    -- Reuse existing log - just update values and make visible
                    existingLog.Instance.Visible = true
                    existingLog:Update()
                    totalResults = totalResults + 1
                else
                    -- Create new log for this closure
                    Log.new(closure)
                    totalResults = totalResults + 1
                end
            end
            
            processed = batchEnd
            
            -- Yield to prevent freezing if more results to process
            if processed < resultCount then
                task.wait(0.01)
            end
        end

        ResultStatus.Visible = (totalResults > 0)
        ResultStatus.Label.Text = string.format("Found %d result%s", totalResults, totalResults ~= 1 and "s" or "")

        upvalueList:Recalculate()
        
        -- Reset debounce after a short delay
        task.delay(searchCooldown, function()
            scanDebounce = false
            -- Process pending search if any
            if pendingSearchQuery and pendingSearchQuery:gsub(' ', '') ~= '' then
                local tempQuery = pendingSearchQuery
                pendingSearchQuery = nil
                SearchBox.Text = tempQuery
                addUpvalues()
            end
        end)
    else
        MessageBox.Show("Invalid query", "Your query is too short", MessageType.OK)
    end

    SearchBox.Text = ""
end

upvalueList:BindContextMenu(closureContextMenu)

deepSearch:SetCallback(function(enabled)
    deepSearchFlag = enabled
    if enabled then
        MessageBox.Show("Notice", "Deep searching may result in longer scan times!", MessageType.OK)
    end
end)

-- Optimized search trigger with debounce
local function triggerSearch()
    if not scanDebounce then
        addUpvalues()
    end
end

Search.MouseButton1Click:Connect(triggerSearch)

SearchBox.FocusLost:Connect(function(returned)
    if returned then
        triggerSearch()
    end
end)

local function setValue(valueText, value, dropdown)
    local raw = valueText
    local valueType = typeof(value)
    local newValue

    if valueType == "string" then
        newValue = raw
    elseif valueType == "number" then
        local convert = tonumber(raw)

        if convert then
            newValue = convert
        else
            typeMismatchMessage()
        end
    elseif valueType == "boolean" then
        if raw == "true" then
            newValue = true
        elseif raw == "false" then
            newValue = false
        else
            typeMismatchMessage()
        end
    else
        local success, result = pcall(loadstring("return " .. raw))
        
        if success then
            if typeof(result) == dropdown.Selected.Name then
                newValue = result
            else
                typeMismatchMessage()
            end
        else
            MessageBox.Show("Error",
                "There is an error in your input",
                MessageType.OK)
        end
    end

    return newValue
end

local function typeDropdownAdjust(dropdown, button)
    local instance = dropdown.Instance
    local icon = oh.Constants.Types[button.Name] or oh.Constants.Types["userdata"]

    instance.Icon.Image = icon
end

modifyUpvalueButtons.Set.MouseButton1Click:Connect(function()
    local newValue = setValue(
        modifyUpvalueValue.Text, 
        selectedUpvalue.Value, 
        upvalueTypeDropdown)

    if newValue ~= nil then
        selectedUpvalue:Set(newValue)

        modifyUpvalueValue.Text = ""
        --modifyUpvalue:Hide()
    end
end)

modifyUpvalueButtons.Cancel.MouseButton1Click:Connect(function()
    modifyUpvalueValue.Text = ""
    modifyUpvalue:Hide()
end)

modifyElementButtons.Set.MouseButton1Click:Connect(function()
    local upvalueValue = selectedUpvalue.Value
    
    local newValue = setValue(
        modifyElementValue.Text, 
        upvalueValue[selectedElement], 
        elementTypeDropdown)

    if newValue ~= nil then
        upvalueValue[selectedElement] = newValue

        modifyElementValue.Text = ""
        modifyElement:Hide()
    end
end)

modifyElementButtons.Cancel.MouseButton1Click:Connect(function()
    modifyElementValue.Text = ""
    modifyElement:Hide()
end)

upvalueTypeDropdown:SetCallback(typeDropdownAdjust)
elementTypeDropdown:SetCallback(typeDropdownAdjust)

local function generateScriptFormat(elementIndex)
    local generatedScript = [[-- Generated by Hydroxide's Upvalue Scanner: https://github.com/Upbolt/Hydroxide

local aux = loadstring(game:HttpGetAsync("https://raw.githubusercontent.com/Upbolt/Hydroxide/revision/ohaux.lua"))()

local scriptPath = %s
local closureName = "%s"
local upvalueIndex = %d
local closureConstants = %s

local closure = aux.searchClosure(scriptPath, closureName, upvalueIndex, closureConstants)
local value = YOUR_NEW_VALUE_HERE
]]

    if elementIndex and elementIndex ~= "nil" then
        generatedScript = generatedScript .. ("local elementIndex = %s\n"):format(elementIndex)
        generatedScript = generatedScript .. "\n\n-- DO NOT RELY ON THIS FEATURE TO PRODUCE %s FUNCTIONAL SCRIPTS\n"
        return generatedScript .. "debug.getupvalue(closure, upvalueIndex)[elementIndex] = value"
    end
    
    return generatedScript .. "\n\n-- DO NOT RELY ON THIS FEATURE TO PRODUCE %s FUNCTIONAL SCRIPTS\ndebug.setupvalue(closure, upvalueIndex, value)"
end

local function generateScript(elementIndex) 
    local index = selectedUpvalue.Index
    local closure = selectedUpvalue.Closure
    local closureData = closure.Data
    local closureScript = rawget(getfenv(closureData), "script")

    local generatedScript = generateScriptFormat(dataToString(elementIndex))

    local currentConstants = {}
    local currentIndex = 0

    if closureScript and not closureScript.Parent then
        closureScript = nil
    end

    for idx, constant in pairs(getConstants(closureData)) do
        if currentIndex > 5 then 
            break 
        elseif type(constant) ~= "function" then
            currentConstants[idx] = constant
            currentIndex = currentIndex + 1
        end
    end

    setClipboard(
        generatedScript:format(
            (closureScript and getInstancePath(closureScript)) or "nil", 
            closure.Name, 
            index,
            tableToString(currentConstants),
            "100%"
        )
    )
end

upvalueScriptContext:SetCallback(function()
    generateScript()
end)

tableScriptContext:SetCallback(function()
    generateScript()
end)

elementScriptContext:SetCallback(function()
    generateScript(selectedElement)
end)

local SpyHook = ClosureSpy.Hook
spyClosureContext:SetCallback(function()
    local closure = selectedLog.Closure

    if TabSelector.SelectTab("ClosureSpy") then
        local result = SpyHook.new(closure)

        if result == false then
            MessageBox.Show("Already hooked", "You are already spying " .. closure.Name)
        elseif result == nil then
            MessageBox.Show("Cannot hook", ('Cannot hook "%s" because there are no upvalues'):format(closure.Name))
        end
    end
end)

viewUpvaluesContext:SetCallback(function()
    if selectedLog then
        local temporaryUpvalues = selectedLog.TemporaryUpvalues 
        local instance = selectedLog.Instance
        local newHeight = 0

        if temporaryUpvalues then
            for _i, upvalueLog in pairs(temporaryUpvalues) do
                newHeight = newHeight - (upvalueLog.AbsoluteSize.Y + 5)
                upvalueLog:Destroy()
            end

            selectedLog.TemporaryUpvalues = nil
            selectedLog.Closure.TemporaryUpvalues = {}
        else
            local closure = selectedLog.Closure
            
            temporaryUpvalues = {}

            for i,v in pairs(getUpvalues(closure)) do
                if not closure.Upvalues[i] then
                    local upvalue = Upvalue.new(closure, i, v)
                    
                    if type(v) == "table" then
                        upvalue.Scanned = {}
                    end
                    
                    local upvalueLog = addUpvalue(upvalue, true)
                    upvalueLog.Parent = instance.Upvalues
                    
                    newHeight = newHeight + upvalueLog.AbsoluteSize.Y + 5
                    temporaryUpvalues[i] = upvalueLog
                    closure.TemporaryUpvalues[i] = upvalue
                end
            end

            selectedLog.TemporaryUpvalues = temporaryUpvalues
        end

        newHeight = UDim2.new(0, 0, 0, newHeight)

        instance.Upvalues.Size = instance.Upvalues.Size + newHeight
        instance.Size = instance.Size + newHeight

        upvalueList:Recalculate()
    end
end)

getScriptContext:SetCallback(function()
    if selectedLog then
        local script = getfenv(selectedLog.Closure.Data).script
            
        if typeof(script) == "Instance" then
            setClipboard(getInstancePath(script))
        end
    end
end)

viewElementsContext:SetCallback(function()
    local temporaryElements = selectedUpvalue and selectedUpvalue.TemporaryElements
    local newHeight = 0

    if temporaryElements then
        for index, _v in pairs(temporaryElements) do
            local elementLog = selectedUpvalueLog.Elements[toString(index)]
            newHeight = newHeight - (elementLog.AbsoluteSize.Y + 5)

            elementLog:Destroy()
        end

        selectedUpvalue.TemporaryElements = nil
    else
        local scanned = selectedUpvalue.Scanned
        temporaryElements = {}

        for i,v in pairs(selectedUpvalue.Value) do
            if not scanned[i] then
                local elementLog = addElement(selectedUpvalueLog, selectedUpvalue, i, v, true)
                elementLog.Parent = selectedUpvalueLog.Elements

                newHeight = newHeight + elementLog.AbsoluteSize.Y + 5
                temporaryElements[i] = elementLog
            end
        end 

        selectedUpvalue.TemporaryElements = temporaryElements
    end

    newHeight = UDim2.new(0, 0, 0, newHeight)

    selectedUpvalueLog.Size = selectedUpvalueLog.Size + newHeight
    selectedUpvalueLog.Parent.Parent.Size = selectedUpvalueLog.Parent.Parent.Size + newHeight
    upvalueList:Recalculate()
end)

local function changeUpvalue()
    if selectedUpvalue then
        local index = selectedUpvalue.Index
        local indexFrame = modifyUpvalueContent.Index
        local indexNumber = indexFrame.Number
        local indexWidth = TextService:GetTextSize(tostring(index), 18, "SourceSans", indexFrame.AbsoluteSize).X
        
        indexNumber.Text = index
        indexNumber.Size = UDim2.new(0, indexWidth, 0, 25)
        
        modifyUpvalue:Show()
    end
end

changeUpvalueContext:SetCallback(changeUpvalue)
changeTableContext:SetCallback(changeUpvalue)

changeElementContext:SetCallback(function()
    if selectedUpvalue and selectedElement then
        local index = selectedElement
        local indexType = type(index)
        local indexFrame = modifyElementContent.Index
        local indexLabel = indexFrame.Data
        local indexWidth = TextService:GetTextSize(index, 18, "SourceSans", indexFrame.AbsoluteSize).X
        
        indexLabel.Text = index
        indexLabel.TextColor3 = oh.Constants.Syntax[indexType]
        indexLabel.Size = UDim2.new(0, indexWidth, 0, 25)
        
        modifyElement:Show()
    end
end)

-- Optimized smooth update loop with improved scroll handling and text refresh
local visibleClosureLogs = {}
local lastScrollPosition = 0
local scrollCheckInterval = 0.05
local lastScrollCheck = 0
local cacheRefreshInterval = 0.2
local lastCacheRefresh = 0

oh.Events.UpdateUpvalues = RunService.RenderStepped:Connect(function(deltaTime)
    -- Only update if the page is visible
    if not isVisible then
        return
    end
    
    -- Skip update if scanning is in progress to reduce lag
    if scanDebounce then
        return
    end
    
    local currentTime = tick()
    
    -- Check scroll position periodically to invalidate cache
    if ResultsClip then
        local currentScroll = ResultsClip.CanvasPosition.Y
        
        -- Detect scroll movement
        if math.abs(currentScroll - lastScrollPosition) > 1 then
            lastScrollPosition = currentScroll
            lastScrollCheck = currentTime
            -- Clear visible cache when scrolling to force fresh updates
            visibleClosureLogs = {}
        end
        
        -- Periodic cache refresh even without scroll to prevent stuck text
        if currentTime - lastCacheRefresh > cacheRefreshInterval then
            lastCacheRefresh = currentTime
            visibleClosureLogs = {}
        end
    end
    
    -- Smooth time-based updates
    if currentTime - lastUpdateTime < updateInterval then
        return
    end
    lastUpdateTime = currentTime
    
    -- Get current visible range
    local clip = ResultsClip
    local viewportTop = 0
    local viewportBottom = 0
    
    if clip then
        viewportTop = clip.AbsolutePosition.Y
        viewportBottom = viewportTop + clip.AbsoluteSize.Y
    end
    
    -- Batch updates for smoother performance
    local updateCount = 0
    local maxUpdatesPerFrame = 8
    
    for _i, closureLog in pairs(currentUpvalues) do
        if updateCount >= maxUpdatesPerFrame then
            break
        end
        
        -- Check if the log still exists and is valid
        if closureLog and closureLog.Instance and closureLog.Instance.Parent then
            local instance = closureLog.Instance
            
            -- Skip invisible items (search filtered out)
            if not instance.Visible then
                visibleClosureLogs[closureLog] = nil
                goto continue
            end
            
            local absPos = instance.AbsolutePosition.Y
            local absSize = instance.AbsoluteSize.Y
            
            -- Buffer zone for preloading
            local bufferZone = 250
            
            -- Check if within or near visible area
            local isInView = (absPos + absSize >= viewportTop - bufferZone) and (absPos <= viewportBottom + bufferZone)
            
            if isInView then
                -- Force update visible items to prevent stuck text
                closureLog:Update()
                updateCount = updateCount + 1
                visibleClosureLogs[closureLog] = true
            elseif visibleClosureLogs[closureLog] then
                -- Item was visible but now scrolled away - final update then remove from cache
                closureLog:Update()
                visibleClosureLogs[closureLog] = nil
            end
        else
            -- Clean up invalid entries
            visibleClosureLogs[closureLog] = nil
        end
        
        ::continue::
    end
end)

-- Handle page visibility to prevent stuck text and unnecessary updates
local Pages = Base.Body.Pages
local function onPageVisible(visible)
    isVisible = visible

    if not visible then
        -- Clear selections when page is hidden to prevent stuck text
        selectedLog = nil
        selectedUpvalue = nil
        selectedUpvalueLog = nil
        selectedElement = nil

        -- Hide any open prompts immediately
        modifyUpvalue:Hide()
        modifyElement:Hide()

        -- Hide context menus immediately
        closureContextMenu:Hide()
        tableContextMenu:Hide()
        upvalueContextMenu:Hide()
        elementContextMenu:Hide()
        
        -- Reset search box and clear pending searches
        SearchBox.Text = ""
        pendingSearchQuery = nil
        scanDebounce = false
        
        -- Clear focus from search box to prevent text sticking
        if SearchBox and SearchBox.Parent then
            SearchBox:ReleaseFocus()
        end
        
        -- Clear visible cache to prevent stuck text on next visit
        visibleClosureLogs = {}
        lastScrollPosition = 0
        
        -- Force UI to refresh and clear any stuck elements with multiple cleanup passes
        task.spawn(function()
            for i = 1, 3 do
                task.wait(0.02)
                if SearchBox and SearchBox.Parent then
                    SearchBox:ReleaseFocus()
                end
            end
        end)
    else
        -- When becoming visible, force a recalculation to fix any stuck positions
        task.defer(function()
            if ResultsClip and upvalueList then
                upvalueList:Recalculate()
            end
        end)
        -- Force update all visible items immediately
        task.defer(function()
            for _, closureLog in pairs(currentUpvalues) do
                if closureLog and closureLog.Instance and closureLog.Instance.Visible then
                    closureLog:Update()
                end
            end
        end)
    end
end

-- Connect to tab selector to track visibility with improved switching
local originalSelectTab = TabSelector.SelectTab
TabSelector.SelectTab = function(tabName)
    -- Hide current page before switching to prevent stuck UI
    if isVisible and tabName ~= "UpvalueScanner" then
        onPageVisible(false)
    end

    local result = originalSelectTab(tabName)

    -- Show new page if it's UpvalueScanner
    if tabName == "UpvalueScanner" and result then
        task.wait(0.02) -- Reduced delay for snappier response
        onPageVisible(true)
    end

    return result
end

-- Also listen for direct page visibility changes with better cleanup
if Page:GetPropertyChangedSignal("Visible") then
    Page:GetPropertyChangedSignal("Visible"):Connect(function()
        if not Page.Visible and isVisible then
            onPageVisible(false)
        elseif Page.Visible and not isVisible then
            onPageVisible(true)
        end
    end)
end

-- Initial visibility check with faster response
task.spawn(function()
    task.wait(0.05)
    local currentPage = Pages and Pages.UpvalueScanner
    if currentPage and currentPage.Visible then
        onPageVisible(true)
    end
end)

return UpvalueScanner 
