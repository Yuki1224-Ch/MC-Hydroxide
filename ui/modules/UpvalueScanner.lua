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
local fastSearchFlag = true
local currentUpvalues = {}
local updateConnection = nil
local isVisible = false

-- FIX: Single atomic scan lock – set true before scanning, false in a
-- finally-style pcall wrapper so it ALWAYS gets cleared.
local scanInProgress = false

local selectedLog
local selectedUpvalue
local selectedUpvalueLog
local selectedElement

local lastUpdateTime = 0
local updateInterval = 1 / 20 -- 20 FPS for value polling (plenty smooth)
local visibleClosureLogs = {}

local spyClosureContext    = ContextMenuButton.new("rbxassetid://4666593447", "Spy Closure")
local viewUpvaluesContext  = ContextMenuButton.new("rbxassetid://5179169654", "View All Upvalues")
local changeUpvalueContext = ContextMenuButton.new("rbxassetid://5458573463", "Change Upvalue")
local changeTableContext   = ContextMenuButton.new("rbxassetid://5458573463", "Change Upvalue")
local viewElementsContext  = ContextMenuButton.new("rbxassetid://5179169654", "View All Elements")
local changeElementContext = ContextMenuButton.new("rbxassetid://5458573463", "Change Element")
local upvalueScriptContext = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local tableScriptContext   = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local elementScriptContext = ContextMenuButton.new("rbxassetid://4800244808", "Generate Script")
local getScriptContext     = ContextMenuButton.new("rbxassetid://4891705738", "Get Script Path")

local closureContextMenu = ContextMenu.new({ spyClosureContext, viewUpvaluesContext, getScriptContext })
local tableContextMenu   = ContextMenu.new({ changeTableContext, viewElementsContext, tableScriptContext })
local upvalueContextMenu = ContextMenu.new({ changeUpvalueContext, upvalueScriptContext })
local elementContextMenu = ContextMenu.new({ changeElementContext, elementScriptContext })

local modifyUpvalueInner   = modifyUpvalue.Instance.Inner
local modifyUpvalueContent = modifyUpvalueInner.Content
local modifyUpvalueButtons = modifyUpvalueInner.Buttons.SetCancel
local modifyUpvalueType    = modifyUpvalueContent.Type
local modifyUpvalueValue   = modifyUpvalueContent.Value.Input

local modifyElementInner   = modifyElement.Instance.Inner
local modifyElementContent = modifyElementInner.Content
local modifyElementButtons = modifyElementInner.Buttons.SetCancel
local modifyElementType    = modifyElementContent.Type
local modifyElementValue   = modifyElementContent.Value.Input

local upvalueTypeDropdown = Dropdown.new(modifyUpvalueType)
local elementTypeDropdown = Dropdown.new(modifyElementType)

local constants = {
    tempElementColor  = Color3.fromRGB(30, 10, 10),
    tempUpvalueColor  = Color3.fromRGB(40, 20, 20),
    tempBorderColor   = Color3.fromRGB(20, 0, 0),
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function typeMismatchMessage()
    MessageBox.Show("Error", "Value does not match selected type", MessageType.OK)
end

local function addElement(upvalueLog, upvalue, index, value, temporary)
    local elementLog      = Assets.Element:Clone()
    local elementIndexType = typeof(index)
    local elementValueType = typeof(value)
    local indexText        = toString(index)

    if temporary then
        elementLog.ImageColor3        = constants.tempElementColor
        elementLog.Border.ImageColor3 = constants.tempBorderColor
    end

    elementLog.Name                       = indexText
    elementLog.Index.Label.Text           = indexText
    local ok, vt = pcall(toString, value)
    elementLog.Value.Label.Text           = ok and vt or "<error>"
    elementLog.Index.Label.TextColor3     = oh.Constants.Syntax[elementIndexType]
    elementLog.Index.Icon.Image           = oh.Constants.Types[elementIndexType]
    elementLog.Value.Label.TextColor3     = oh.Constants.Syntax[elementValueType]
    elementLog.Value.Icon.Image           = oh.Constants.Types[elementValueType]

    local function showElementContext()
        selectedUpvalue    = upvalue
        selectedUpvalueLog = upvalueLog
        selectedElement    = index
        elementTypeDropdown:SetSelected(typeof(value))
        elementContextMenu:Show()
    end

    elementLog.MouseButton2Click:Connect(showElementContext)
    elementLog.MouseButton1Click:Connect(function()
        if pressHold then showElementContext() end
    end)

    return elementLog
end

local function updateElementFast(upvalueLog, index, value)
    local elementLog = upvalueLog.Elements:FindFirstChild(toString(index))
    if not elementLog then return end
    local ok, newText = pcall(toString, value)
    if ok and elementLog.Value.Label.Text ~= newText then
        elementLog.Value.Label.Text = newText
    end
end

local function addUpvalue(upvalue, temporary)
    local upvalueLog
    local index     = upvalue.Index
    local value     = upvalue.Value
    local valueType = typeof(value)

    if valueType == "table" then
        upvalueLog = Assets.Table:Clone()
        local height = 25

        if temporary then
            upvalueLog.ImageColor3        = constants.tempUpvalueColor
            upvalueLog.Border.ImageColor3 = constants.tempBorderColor
        end

        if not temporary and upvalue.Scanned then
            for i, v in pairs(upvalue.Scanned) do
                local el = addElement(upvalueLog, upvalue, i, v)
                el.Parent = upvalueLog.Elements
                height    = height + el.AbsoluteSize.Y + 5
            end
        end

        upvalueLog.Size = UDim2.new(1, 0, 0, height)
    else
        upvalueLog = Assets.Upvalue:Clone()

        if temporary then
            upvalueLog.ImageColor3        = constants.tempUpvalueColor
            upvalueLog.Border.ImageColor3 = constants.tempBorderColor
        end

        if valueType == "function" then
            local n = getInfo(value).name or ''
            upvalueLog.Value.Text = (n == '' and "Unnamed function") or n
        else
            local ok, vt = pcall(toString, value)
            upvalueLog.Value.Text = ok and vt or "<error>"
        end
    end

    upvalueLog.Name            = index
    upvalueLog.Index.Text      = index
    upvalueLog.Value.TextColor3 = oh.Constants.Syntax[valueType]
    upvalueLog.Icon.Image      = oh.Constants.Types[valueType]

    local function showUpvalueContext()
        selectedUpvalue    = upvalue
        selectedUpvalueLog = upvalueLog
        upvalueTypeDropdown:SetSelected(typeof(upvalue.Value))
        if upvalue.Scanned then
            tableContextMenu:Show()
        else
            upvalueContextMenu:Show()
        end
    end

    upvalueLog.MouseButton2Click:Connect(showUpvalueContext)
    upvalueLog.MouseButton1Click:Connect(function()
        if pressHold then showUpvalueContext() end
    end)

    return upvalueLog
end

local function updateUpvalue(closureLog, upvalue)
    if not closureLog.Instance or not closureLog.Instance.Parent then return end

    local upvalueLog = closureLog.Instance.Upvalues[tostring(upvalue.Index)]
    if not upvalueLog then return end

    local closure  = upvalue.Closure
    local index    = upvalue.Index
    local newValue = getUpvalue(closure, index)
    local valueType = typeof(newValue)

    if valueType == "function" then
        local n       = getInfo(newValue).name or ''
        local newText = (n == '' and "Unnamed function") or n
        if upvalueLog.Value.Text ~= newText then
            upvalueLog.Value.Text = newText
        end
    elseif valueType == "table" and upvalue.Scanned then
        for i, v in pairs(upvalue.Scanned) do
            updateElementFast(upvalueLog, i, v)
        end
        if upvalue.TemporaryElements then
            local tbl = upvalue.Value
            for idx in pairs(upvalue.TemporaryElements) do
                updateElementFast(upvalueLog, idx, tbl[idx])
            end
        end
    else
        local ok, newText = pcall(toString, newValue)
        local display = ok and newText or "<error>"
        if upvalueLog.Value.Text ~= display then
            upvalueLog.Value.Text = display
        end
    end

    upvalue:Update(newValue)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Log Object
-- ─────────────────────────────────────────────────────────────────────────────

local Log = {}

function Log.new(closure)
    local log       = {}
    local instance  = Assets.ClosureLog:Clone()
    local listButton = ListButton.new(instance, upvalueList)
    local logHeight = 30

    log.Instance = instance
    log.Closure  = closure
    log.Upvalues = {}
    log.Update   = Log.update

    for i, upvalue in pairs(closure.Upvalues) do
        local upvalueLog = addUpvalue(upvalue)
        upvalueLog.Parent = instance.Upvalues
        logHeight         = logHeight + upvalueLog.AbsoluteSize.Y + 5
        log.Upvalues[i]   = upvalueLog
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
    if not log.Closure or not log.Instance or not log.Instance.Parent then return end

    local nameLabel = log.Instance:FindFirstChild("Name")
    if nameLabel and log.Closure.Name and nameLabel.Text ~= log.Closure.Name then
        nameLabel.Text = log.Closure.Name
    end

    for _, upvalue in pairs(log.Closure.Upvalues) do
        updateUpvalue(log, upvalue)
    end
    for _, upvalue in pairs(log.Closure.TemporaryUpvalues) do
        updateUpvalue(log, upvalue)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX: addUpvalues – proper lock/unlock with pcall so it NEVER stays locked
-- ─────────────────────────────────────────────────────────────────────────────

local function addUpvalues()
    -- Guard: only one scan at a time
    if scanInProgress then return end

    local query = SearchBox.Text
    -- FIX: clear the box immediately so it doesn't flicker later
    SearchBox.Text = ""

    if query:gsub("%s", "") == "" then
        MessageBox.Show("Invalid query", "Your query is too short", MessageType.OK)
        return
    end

    if not tonumber(query) and query:len() <= 1 then
        MessageBox.Show("Invalid query", "Your query is too short", MessageType.OK)
        return
    end

    scanInProgress = true
    oh.setStatus("Scanning upvalues…")

    -- Run in a coroutine so yields work, but wrap everything in pcall so the
    -- lock is ALWAYS released even on error.
    task.spawn(function()
        local ok, err = pcall(function()
            local scanResults = Methods.Scan(query, deepSearchFlag, 300, not deepSearchFlag)

            -- Build array for controlled iteration
            local resultsArray = {}
            for _, closure in pairs(scanResults) do
                table.insert(resultsArray, closure)
            end

            local resultCount = #resultsArray

            -- Hide all existing logs (filter approach – avoids destroy/recreate)
            for _, log in pairs(currentUpvalues) do
                if log.Instance and log.Instance.Parent then
                    log.Instance.Visible = false
                end
            end

            -- Process in small batches so the UI stays responsive
            local totalShown = 0
            local batchSize  = 8

            for i = 1, resultCount do
                local closure    = resultsArray[i]
                local closureData = closure.Data
                local existing   = currentUpvalues[closureData]

                if existing then
                    existing.Instance.Visible = true
                    existing:Update()
                else
                    Log.new(closure)
                end

                totalShown = totalShown + 1

                -- Yield every batchSize items
                if i % batchSize == 0 then
                    task.wait(0.04)
                end
            end

            ResultStatus.Visible      = (totalShown > 0)
            ResultStatus.Label.Text   = string.format(
                "Found %d result%s", totalShown, totalShown ~= 1 and "s" or "")

            upvalueList:Recalculate()

            if totalShown == 0 then
                oh.setStatus("No upvalues found")
            else
                oh.setStatus(string.format("Upvalue Scanner – %d result%s",
                    totalShown, totalShown ~= 1 and "s" or ""))
            end
        end)

        -- FIX: ALWAYS unlock, whether scan succeeded or errored
        scanInProgress = false

        if not ok then
            oh.setStatus("Scan error")
            warn("[UpvalueScanner] Scan error:", err)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Context menus / bindings (unchanged logic, just wired up)
-- ─────────────────────────────────────────────────────────────────────────────

upvalueList:BindContextMenu(closureContextMenu)

deepSearch:SetCallback(function(enabled)
    deepSearchFlag = enabled
    if enabled then
        MessageBox.Show("Notice", "Deep searching may result in longer scan times!", MessageType.OK)
    end
end)

Search.MouseButton1Click:Connect(function()
    if not scanInProgress then addUpvalues() end
end)

SearchBox.FocusLost:Connect(function(returned)
    if returned and SearchBox.Text ~= "" then
        if not scanInProgress then addUpvalues() end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- setValue / typeDropdownAdjust helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function setValue(valueText, value, dropdown)
    local raw       = valueText
    local valueType = typeof(value)
    local newValue

    if valueType == "string" then
        newValue = raw
    elseif valueType == "number" then
        local n = tonumber(raw)
        if n then newValue = n else typeMismatchMessage() end
    elseif valueType == "boolean" then
        if raw == "true" then
            newValue = true
        elseif raw == "false" then
            newValue = false
        else
            typeMismatchMessage()
        end
    else
        local ok, result = pcall(loadstring("return " .. raw))
        if ok then
            if typeof(result) == dropdown.Selected.Name then
                newValue = result
            else
                typeMismatchMessage()
            end
        else
            MessageBox.Show("Error", "There is an error in your input", MessageType.OK)
        end
    end

    return newValue
end

local function typeDropdownAdjust(dropdown, button)
    local icon = oh.Constants.Types[button.Name] or oh.Constants.Types["userdata"]
    dropdown.Instance.Icon.Image = icon
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Modify upvalue / element prompts
-- ─────────────────────────────────────────────────────────────────────────────

modifyUpvalueButtons.Set.MouseButton1Click:Connect(function()
    local newValue = setValue(modifyUpvalueValue.Text, selectedUpvalue.Value, upvalueTypeDropdown)
    if newValue ~= nil then
        selectedUpvalue:Set(newValue)
        modifyUpvalueValue.Text = ""
    end
end)

modifyUpvalueButtons.Cancel.MouseButton1Click:Connect(function()
    modifyUpvalueValue.Text = ""
    modifyUpvalue:Hide()
end)

modifyElementButtons.Set.MouseButton1Click:Connect(function()
    local newValue = setValue(modifyElementValue.Text, selectedUpvalue.Value[selectedElement], elementTypeDropdown)
    if newValue ~= nil then
        selectedUpvalue.Value[selectedElement] = newValue
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Script generation
-- ─────────────────────────────────────────────────────────────────────────────

local function generateScriptFormat(elementIndex)
    local base = [[-- Generated by Hydroxide's Upvalue Scanner: https://github.com/Upbolt/Hydroxide

local aux = loadstring(game:HttpGetAsync("https://raw.githubusercontent.com/Upbolt/Hydroxide/revision/ohaux.lua"))()

local scriptPath      = %s
local closureName     = "%s"
local upvalueIndex    = %d
local closureConstants = %s

local closure = aux.searchClosure(scriptPath, closureName, upvalueIndex, closureConstants)
local value   = YOUR_NEW_VALUE_HERE
]]

    if elementIndex and elementIndex ~= "nil" then
        base = base .. ("local elementIndex = %s\n"):format(elementIndex)
        base = base .. "\n\n-- DO NOT RELY ON THIS FEATURE TO PRODUCE %s FUNCTIONAL SCRIPTS\n"
        return base .. "debug.getupvalue(closure, upvalueIndex)[elementIndex] = value"
    end

    return base .. "\n\n-- DO NOT RELY ON THIS FEATURE TO PRODUCE %s FUNCTIONAL SCRIPTS\ndebug.setupvalue(closure, upvalueIndex, value)"
end

local function generateScript(elementIndex)
    local index       = selectedUpvalue.Index
    local closure     = selectedUpvalue.Closure
    local closureData = closure.Data
    local closureScript = rawget(getfenv(closureData), "script")

    local generated = generateScriptFormat(dataToString(elementIndex))

    local currentConstants = {}
    local currentIndex     = 0

    if closureScript and not closureScript.Parent then
        closureScript = nil
    end

    for idx, constant in pairs(getConstants(closureData)) do
        if currentIndex > 5 then break end
        if type(constant) ~= "function" then
            currentConstants[idx] = constant
            currentIndex = currentIndex + 1
        end
    end

    setClipboard(
        generated:format(
            (closureScript and getInstancePath(closureScript)) or "nil",
            closure.Name,
            index,
            tableToString(currentConstants),
            "100%"
        )
    )
end

upvalueScriptContext:SetCallback(function() generateScript() end)
tableScriptContext:SetCallback(function() generateScript() end)
elementScriptContext:SetCallback(function() generateScript(selectedElement) end)

-- ─────────────────────────────────────────────────────────────────────────────
-- ClosureSpy integration
-- ─────────────────────────────────────────────────────────────────────────────

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
    if not selectedLog then return end

    local temporaryUpvalues = selectedLog.TemporaryUpvalues
    local instance = selectedLog.Instance
    local newHeight = 0

    if temporaryUpvalues then
        for _, upvalueLog in pairs(temporaryUpvalues) do
            newHeight = newHeight - (upvalueLog.AbsoluteSize.Y + 5)
            upvalueLog:Destroy()
        end
        selectedLog.TemporaryUpvalues = nil
        selectedLog.Closure.TemporaryUpvalues = {}
    else
        local closure       = selectedLog.Closure
        temporaryUpvalues   = {}

        for i, v in pairs(getUpvalues(closure)) do
            if not closure.Upvalues[i] then
                local upvalue = Upvalue.new(closure, i, v)
                if type(v) == "table" then upvalue.Scanned = {} end

                local upvalueLog = addUpvalue(upvalue, true)
                upvalueLog.Parent = instance.Upvalues

                newHeight = newHeight + upvalueLog.AbsoluteSize.Y + 5
                temporaryUpvalues[i]            = upvalueLog
                closure.TemporaryUpvalues[i]    = upvalue
            end
        end

        selectedLog.TemporaryUpvalues = temporaryUpvalues
    end

    instance.Upvalues.Size = instance.Upvalues.Size + UDim2.new(0, 0, 0, newHeight)
    instance.Size          = instance.Size          + UDim2.new(0, 0, 0, newHeight)
    upvalueList:Recalculate()
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
        for index in pairs(temporaryElements) do
            local el = selectedUpvalueLog.Elements[toString(index)]
            newHeight = newHeight - (el.AbsoluteSize.Y + 5)
            el:Destroy()
        end
        selectedUpvalue.TemporaryElements = nil
    else
        local scanned       = selectedUpvalue.Scanned
        temporaryElements   = {}

        for i, v in pairs(selectedUpvalue.Value) do
            if not scanned[i] then
                local el = addElement(selectedUpvalueLog, selectedUpvalue, i, v, true)
                el.Parent = selectedUpvalueLog.Elements
                newHeight = newHeight + el.AbsoluteSize.Y + 5
                temporaryElements[i] = el
            end
        end

        selectedUpvalue.TemporaryElements = temporaryElements
    end

    selectedUpvalueLog.Size = selectedUpvalueLog.Size + UDim2.new(0, 0, 0, newHeight)
    selectedUpvalueLog.Parent.Parent.Size = selectedUpvalueLog.Parent.Parent.Size + UDim2.new(0, 0, 0, newHeight)
    upvalueList:Recalculate()
end)

local function changeUpvalue()
    if selectedUpvalue then
        local index      = selectedUpvalue.Index
        local indexFrame = modifyUpvalueContent.Index
        local indexWidth = TextService:GetTextSize(tostring(index), 18, "SourceSans", indexFrame.AbsoluteSize).X

        indexFrame.Number.Text = index
        indexFrame.Number.Size = UDim2.new(0, indexWidth, 0, 25)
        modifyUpvalue:Show()
    end
end

changeUpvalueContext:SetCallback(changeUpvalue)
changeTableContext:SetCallback(changeUpvalue)

changeElementContext:SetCallback(function()
    if selectedUpvalue and selectedElement then
        local index      = selectedElement
        local indexType  = typeof(index)
        local indexFrame = modifyElementContent.Index
        local indexLabel = indexFrame.Data
        local indexWidth = TextService:GetTextSize(index, 18, "SourceSans", indexFrame.AbsoluteSize).X

        indexLabel.Text           = index
        indexLabel.TextColor3     = oh.Constants.Syntax[indexType]
        indexLabel.Size           = UDim2.new(0, indexWidth, 0, 25)
        modifyElement:Show()
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX: RenderStepped update loop – skip entirely when scan is running;
--      use simple viewport culling without a stale visibility cache.
-- ─────────────────────────────────────────────────────────────────────────────

local lastScrollY        = 0
local cacheResetInterval = 2.0
local lastCacheReset     = 0

oh.Events.UpdateUpvalues = RunService.RenderStepped:Connect(function()
    if not isVisible or scanInProgress then return end

    local now = tick()
    if now - lastUpdateTime < updateInterval then return end
    lastUpdateTime = now

    -- Viewport bounds
    local viewTop    = ResultsClip.AbsolutePosition.Y
    local viewBottom = viewTop + ResultsClip.AbsoluteSize.Y
    local buffer     = 200

    -- Periodic full-cache clear to fix any permanently stuck text
    if now - lastCacheReset > cacheResetInterval then
        lastCacheReset  = now
        visibleClosureLogs = {}
    end

    local updated = 0
    local maxPerFrame = 3

    for _, closureLog in pairs(currentUpvalues) do
        if updated >= maxPerFrame then break end
        if not (closureLog and closureLog.Instance and closureLog.Instance.Parent) then continue end
        if not closureLog.Instance.Visible then continue end

        local absY   = closureLog.Instance.AbsolutePosition.Y
        local absH   = closureLog.Instance.AbsoluteSize.Y
        local inView = (absY + absH >= viewTop - buffer) and (absY <= viewBottom + buffer)

        if inView then
            closureLog:Update()
            updated = updated + 1
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX: Page visibility handler – fully resets ALL state so nothing gets stuck
-- ─────────────────────────────────────────────────────────────────────────────

local function onPageVisible(visible)
    isVisible = visible

    if not visible then
        -- Cancel any in-flight scan to prevent it mutating the UI after switch
        -- (the scan task will naturally exit via its own pcall, lock resets itself)
        -- We force the lock off so the next visit isn't permanently blocked.
        scanInProgress = false

        -- Clear selections
        selectedLog        = nil
        selectedUpvalue    = nil
        selectedUpvalueLog = nil
        selectedElement    = nil

        -- Dismiss any open UI
        modifyUpvalue:Hide()
        modifyElement:Hide()
        closureContextMenu:Hide()
        tableContextMenu:Hide()
        upvalueContextMenu:Hide()
        elementContextMenu:Hide()

        -- Release focus so text box doesn't keep holding keystrokes
        pcall(function() SearchBox:ReleaseFocus() end)
        SearchBox.Text = ""

        -- Reset update tracking so stale positions don't affect next visit
        visibleClosureLogs = {}
        lastScrollY        = 0
        lastCacheReset     = 0
    else
        -- Force one full update pass so values aren't stale on revisit
        task.defer(function()
            upvalueList:Recalculate()
            local count = 0
            for _, closureLog in pairs(currentUpvalues) do
                if closureLog and closureLog.Instance and closureLog.Instance.Visible then
                    closureLog:Update()
                    count = count + 1
                    if count % 10 == 0 then task.wait(0.02) end
                end
            end
        end)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tab selector integration
-- ─────────────────────────────────────────────────────────────────────────────

local originalSelectTab = TabSelector.SelectTab
TabSelector.SelectTab = function(tabName)
    if isVisible and tabName ~= "UpvalueScanner" then
        onPageVisible(false)
    end

    local result = originalSelectTab(tabName)

    if tabName == "UpvalueScanner" and result then
        task.wait(0.02)
        onPageVisible(true)
    end

    return result
end

-- Also react to direct Visible changes (e.g. from other tab-switching code)
Page:GetPropertyChangedSignal("Visible"):Connect(function()
    if Page.Visible and not isVisible then
        onPageVisible(true)
    elseif not Page.Visible and isVisible then
        onPageVisible(false)
    end
end)

-- Initial check
task.spawn(function()
    task.wait(0.1)
    if Page.Visible then
        onPageVisible(true)
    end
end)

return UpvalueScanner
