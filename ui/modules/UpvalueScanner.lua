--[[
    ui/modules/UpvalueScanner.lua  –  FULLY FIXED VERSION
    -------------------------------------------------------
    Root-cause fixes applied:
      1. ALL cloned Roblox instances are now created inside a dedicated
         ScreenGui that is parented to CoreGui (or getHui()).  This means
         they are ALWAYS behind the ClipsDescendants containers and can
         NEVER appear as floating world-space text.
      2. clearAllLogs() now calls :Destroy() on every cloned instance and
         resets every tracking table, so no stale references survive.
      3. scanInProgress is always released in a `finally`-style pcall
         wrapper, so the UI can never get permanently stuck.
      4. The RenderStepped update loop is fully suspended while the panel
         is invisible and during an active scan.
      5. Every context-menu / prompt is hidden on panel-close.
      6. Tab-switch now properly destroys logs from the OLD tab before
         showing the NEW one.
      7. addUpvalues() clears logs BEFORE spawning the scan task, so old
         text cannot stay visible while the new scan runs.
      8. ResultStatus is always hidden before a new scan starts.
]]

local RunService   = game:GetService("RunService")
local TextService  = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local CoreGui      = game:GetService("CoreGui")

local UpvalueScanner = {}
local ClosureSpy     = import("modules/ClosureSpy")
local Methods        = import("modules/UpvalueScanner")

if not hasMethods(Methods.RequiredMethods) then
    return UpvalueScanner
end

local Upvalue = import("objects/Upvalue")

local Prompt,   _         = import("ui/controls/Prompt"),   nil
local CheckBox            = import("ui/controls/CheckBox")
local Dropdown            = import("ui/controls/Dropdown")
local List, ListButton    = import("ui/controls/List")
local TabSelector         = import("ui/controls/TabSelector")
local MessageBox, MessageType = import("ui/controls/MessageBox")
local ContextMenu, ContextMenuButton = import("ui/controls/ContextMenu")

local Base   = import("rbxassetid://11389137937").Base
local Assets = import("rbxassetid://5042114982").UpvalueScanner

local Prompts     = Base.Prompts
local Page        = Base.Body.Pages.UpvalueScanner

local Query        = Page.Query
local Search       = Query.Search
local SearchBox    = Query.Query
local Filters      = Page.Filters
local ResultsClip  = Page.Results.Clip
local ResultStatus = ResultsClip.ResultStatus

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1: Safe container – all cloned instances go inside a dedicated
--         ScreenGui that is parented to CoreGui.  They can NEVER escape
--         this container and appear as floating world text.
-- ─────────────────────────────────────────────────────────────────────────────
local safeContainer
do
    local sg = Instance.new("ScreenGui")
    sg.Name            = "OHUpvalueContainer_" .. tostring(math.random(1e8))
    sg.ResetOnSpawn    = false
    sg.IgnoreGuiInset  = true
    sg.Enabled         = false          -- invisible; only used as a parent sink
    sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
    pcall(function()
        sg.Parent = (getHui and getHui()) or CoreGui
    end)
    if not sg.Parent then
        sg.Parent = CoreGui
    end
    safeContainer = sg
end

local modifyUpvalue = Prompt.new(Prompts.ModifyUpvalue)
local modifyElement = Prompt.new(Prompts.ModifyElement)
local deepSearch    = CheckBox.new(Filters.SearchInTables)
local upvalueList   = List.new(ResultsClip.Content)

local deepSearchFlag = false
local currentUpvalues = {}
local isVisible       = false
local scanInProgress  = false

local selectedLog
local selectedUpvalue
local selectedUpvalueLog
local selectedElement

local lastUpdateTime  = 0
local updateInterval  = 1 / 20

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
    tempElementColor = Color3.fromRGB(30, 10, 10),
    tempUpvalueColor = Color3.fromRGB(40, 20, 20),
    tempBorderColor  = Color3.fromRGB(20, 0, 0),
}

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2: clearAllLogs – destroys EVERY cloned instance completely.
--         No instance is merely hidden; all are removed from the tree.
-- ─────────────────────────────────────────────────────────────────────────────
local function clearAllLogs()
    for _, log in pairs(currentUpvalues) do
        if log and log.Instance then
            pcall(function() log.Instance:Destroy() end)
        end
    end
    currentUpvalues    = {}
    selectedLog        = nil
    selectedUpvalue    = nil
    selectedUpvalueLog = nil
    selectedElement    = nil
    upvalueList:Clear()
    ResultStatus.Visible = false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function typeMismatchMessage()
    MessageBox.Show("Error", "Value does not match selected type", MessageType.OK)
end

local function addElement(upvalueLog, upvalue, index, value, temporary)
    local elementLog       = Assets.Element:Clone()
    local elementIndexType = typeof(index)
    local elementValueType = typeof(value)
    local indexText        = toString(index)

    if temporary then
        elementLog.ImageColor3        = constants.tempElementColor
        elementLog.Border.ImageColor3 = constants.tempBorderColor
    end

    elementLog.Name                   = indexText
    elementLog.Index.Label.Text       = indexText
    local ok, vt = pcall(toString, value)
    elementLog.Value.Label.Text       = ok and vt or "<error>"
    elementLog.Index.Label.TextColor3 = oh.Constants.Syntax[elementIndexType]
    elementLog.Index.Icon.Image       = oh.Constants.Types[elementIndexType]
    elementLog.Value.Label.TextColor3 = oh.Constants.Syntax[elementValueType]
    elementLog.Value.Icon.Image       = oh.Constants.Types[elementValueType]

    -- FIX: parent to safeContainer FIRST so it is never world-visible
    elementLog.Parent = safeContainer

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

    upvalueLog.Name             = tostring(index)
    upvalueLog.Index.Text       = index
    upvalueLog.Value.TextColor3 = oh.Constants.Syntax[valueType]
    upvalueLog.Icon.Image       = oh.Constants.Types[valueType]

    -- FIX: always park in safeContainer immediately after cloning
    upvalueLog.Parent = safeContainer

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

    local closure   = upvalue.Closure
    local index     = upvalue.Index
    local newValue  = getUpvalue(closure, index)
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
    local log      = {}
    local instance = Assets.ClosureLog:Clone()

    -- FIX: Park in safeContainer first, THEN hand off to ListButton which
    --      re-parents into the ScrollingFrame (which has ClipsDescendants).
    instance.Parent = safeContainer

    local listButton = ListButton.new(instance, upvalueList)
    local logHeight  = 30

    log.Instance = instance
    log.Closure  = closure
    log.Upvalues = {}
    log.Update   = Log.update

    for i, upvalue in pairs(closure.Upvalues) do
        local upvalueLog = addUpvalue(upvalue)
        -- Now parent into the log's Upvalues frame (inside the ScrollingFrame)
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
-- FIX 3: addUpvalues – clear BEFORE spawning the task; release scan lock in
--         a finally-equivalent block so the UI never gets permanently stuck.
-- ─────────────────────────────────────────────────────────────────────────────

local function addUpvalues()
    if scanInProgress then return end

    local query = SearchBox.Text
    SearchBox.Text = ""

    if query:gsub("%s", "") == "" or (not tonumber(query) and query:len() <= 1) then
        MessageBox.Show("Invalid query", "Your query is too short", MessageType.OK)
        return
    end

    scanInProgress       = true
    ResultStatus.Visible = false
    oh.setStatus("Scanning upvalues…")

    -- FIX: Destroy all old instances BEFORE the async scan starts.
    --      This prevents old text from staying on screen during the scan.
    clearAllLogs()

    task.spawn(function()
        local ok, err = pcall(function()
            local scanResults = Methods.Scan(query, deepSearchFlag, 300, not deepSearchFlag)

            local resultsArray = {}
            for _, closure in pairs(scanResults) do
                table.insert(resultsArray, closure)
            end

            local totalShown = 0
            local batchSize  = 8

            for i = 1, #resultsArray do
                -- If the panel was closed mid-scan, stop immediately
                if not isVisible then break end

                Log.new(resultsArray[i])
                totalShown = totalShown + 1

                if i % batchSize == 0 then
                    task.wait(0.04)
                end
            end

            upvalueList:Recalculate()

            if totalShown > 0 then
                ResultStatus.Visible    = true
                ResultStatus.Label.Text = string.format(
                    "Found %d result%s", totalShown, totalShown ~= 1 and "s" or "")
                oh.setStatus(string.format("Upvalue Scanner – %d result%s",
                    totalShown, totalShown ~= 1 and "s" or ""))
            else
                oh.setStatus("No upvalues found")
            end
        end)

        -- FIX: ALWAYS release the lock regardless of error
        scanInProgress = false

        if not ok then
            oh.setStatus("Scan error – check console")
            warn("[UpvalueScanner] Scan error:", err)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Context menu bindings
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

local scriptPath       = %s
local closureName      = "%s"
local upvalueIndex     = %d
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
    local index        = selectedUpvalue.Index
    local closure      = selectedUpvalue.Closure
    local closureData  = closure.Data
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
    local closure = selectedLog and selectedLog.Closure
    if not closure then return end
    if TabSelector.SelectTab("ClosureSpy") then
        local result = SpyHook.new(closure)
        if result == false then
            MessageBox.Show("Already hooked", "You are already spying " .. closure.Name)
        elseif result == nil then
            MessageBox.Show("Cannot hook",
                ('Cannot hook "%s" because there are no upvalues'):format(closure.Name))
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
        selectedLog.TemporaryUpvalues       = nil
        selectedLog.Closure.TemporaryUpvalues = {}
    else
        local closure     = selectedLog.Closure
        temporaryUpvalues = {}

        for i, v in pairs(getUpvalues(closure)) do
            if not closure.Upvalues[i] then
                local upvalue = Upvalue.new(closure, i, v)
                if type(v) == "table" then upvalue.Scanned = {} end

                local upvalueLog = addUpvalue(upvalue, true)
                upvalueLog.Parent = instance.Upvalues

                newHeight = newHeight + upvalueLog.AbsoluteSize.Y + 5
                temporaryUpvalues[i]         = upvalueLog
                closure.TemporaryUpvalues[i] = upvalue
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
    if not selectedUpvalue or not selectedUpvalueLog then return end

    local temporaryElements = selectedUpvalue.TemporaryElements
    local newHeight = 0

    if temporaryElements then
        for index in pairs(temporaryElements) do
            local el = selectedUpvalueLog.Elements[toString(index)]
            if el then
                newHeight = newHeight - (el.AbsoluteSize.Y + 5)
                el:Destroy()
            end
        end
        selectedUpvalue.TemporaryElements = nil
    else
        local scanned     = selectedUpvalue.Scanned
        temporaryElements = {}

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
    selectedUpvalueLog.Parent.Parent.Size =
        selectedUpvalueLog.Parent.Parent.Size + UDim2.new(0, 0, 0, newHeight)
    upvalueList:Recalculate()
end)

local function changeUpvalue()
    if selectedUpvalue then
        local index      = selectedUpvalue.Index
        local indexFrame = modifyUpvalueContent.Index
        local indexWidth = TextService:GetTextSize(
            tostring(index), 18, "SourceSans", indexFrame.AbsoluteSize).X

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
        local indexWidth = TextService:GetTextSize(
            tostring(index), 18, "SourceSans", indexFrame.AbsoluteSize).X

        indexLabel.Text       = index
        indexLabel.TextColor3 = oh.Constants.Syntax[indexType]
        indexLabel.Size       = UDim2.new(0, indexWidth, 0, 25)
        modifyElement:Show()
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 4: RenderStepped – only runs when visible AND not scanning.
-- ─────────────────────────────────────────────────────────────────────────────

oh.Events.UpdateUpvalues = RunService.RenderStepped:Connect(function()
    if not isVisible or scanInProgress then return end

    local now = tick()
    if now - lastUpdateTime < updateInterval then return end
    lastUpdateTime = now

    local viewTop    = ResultsClip.AbsolutePosition.Y
    local viewBottom = viewTop + ResultsClip.AbsoluteSize.Y
    local buffer     = 200
    local updated    = 0
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
-- FIX 5: onPageVisible – destroys ALL logs on hide so nothing floats.
-- ─────────────────────────────────────────────────────────────────────────────

local function onPageVisible(visible)
    isVisible = visible

    if not visible then
        -- Release scan lock so next visit is never blocked
        scanInProgress = false

        -- Destroy every log instance immediately
        clearAllLogs()

        -- Dismiss all overlays
        pcall(function() modifyUpvalue:Hide() end)
        pcall(function() modifyElement:Hide() end)
        pcall(function() closureContextMenu:Hide() end)
        pcall(function() tableContextMenu:Hide() end)
        pcall(function() upvalueContextMenu:Hide() end)
        pcall(function() elementContextMenu:Hide() end)

        pcall(function() SearchBox:ReleaseFocus() end)
        SearchBox.Text = ""
    else
        task.defer(function()
            upvalueList:Recalculate()
        end)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 6: Tab selector override – destroy old logs before switching tabs.
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

Page:GetPropertyChangedSignal("Visible"):Connect(function()
    if Page.Visible and not isVisible then
        onPageVisible(true)
    elseif not Page.Visible and isVisible then
        onPageVisible(false)
    end
end)

task.spawn(function()
    task.wait(0.1)
    if Page.Visible then
        onPageVisible(true)
    end
end)

return UpvalueScanner
