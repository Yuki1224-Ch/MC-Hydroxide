local UpvalueScanner = {}
local Closure = import("objects/Closure")
local Upvalue = import("objects/Upvalue")

local requiredMethods = {
    ["getGc"] = true,
    ["getInfo"] = true,
    ["isXClosure"] = true,
    ["getUpvalue"] = true,
    ["setUpvalue"] = true,
    ["getUpvalues"] = true
}

local function compareUpvalue(query, upvalue, ignore)
    local upvalueType = typeof(upvalue)

    local stringCheck = upvalueType == "string" and (query == upvalue or upvalue:lower():find(query:lower()))
    local numberCheck = not ignore and upvalueType == "number" and (tonumber(query) == upvalue or ("%.2f"):format(upvalue) == query)
    
    if upvalueType == "userdata" then
        if typeof(upvalue) == "Instance" then
            local instanceName = upvalue.Name
            return (instanceName == query or instanceName:find(query))
        end

        local success, str = pcall(toString, upvalue)
        return success and str == query
    elseif upvalueType == "function" then
        local closureName = getInfo(upvalue).name or ''
        return query == closureName or closureName:lower():find(query:lower())
    elseif upvalueType == "table" then
        -- Direct table reference check
        return false
    elseif upvalueType == "boolean" then
        local queryBool = query:lower()
        if queryBool == "true" or queryBool == "false" then
            return tostring(upvalue) == queryBool
        end
    end

    return stringCheck or numberCheck
end

local function scan(query, deepSearch, maxResults, fastMode)
    maxResults = maxResults or 500 -- Default limit to prevent lag
    local upvalues = {}
    local resultCount = 0
    local processedClosures = 0
    local totalClosures = 0
    
    -- Pre-count closures for progress tracking (optional, can be skipped in fast mode)
    if not fastMode then
        for _i, closure in pairs(getGc()) do
            if type(closure) == "function" and not isXClosure(closure) then
                totalClosures = totalClosures + 1
            end
        end
    end

    for _i, closure in pairs(getGc()) do
        if resultCount >= maxResults then break end
        
        if type(closure) == "function" and not isXClosure(closure) and not upvalues[closure] then
            local closureHasMatch = false
            
            for index, value in pairs(getUpvalues(closure)) do
                if resultCount >= maxResults then break end
                
                local valueType = typeof(value)

                if valueType ~= "table" and compareUpvalue(query, value) then
                    local storage = upvalues[closure]

                    if not storage then
                        local newClosure = Closure.new(closure)
                        newClosure.Upvalues[index] = Upvalue.new(newClosure, index, value)
                        upvalues[closure] = newClosure
                        resultCount = resultCount + 1
                    else
                        storage.Upvalues[index] = Upvalue.new(storage, index, value)
                    end
                    closureHasMatch = true
                elseif deepSearch and valueType == "table" then
                    local storage = upvalues[closure]
                    local table

                    for i, v in pairs(value) do
                        if (i ~= value and v ~= value) and (compareUpvalue(query, i, true) or compareUpvalue(query, v)) then
                            if not storage then
                                local newClosure = Closure.new(closure)
                                storage = newClosure
                                upvalues[closure] = newClosure
                                resultCount = resultCount + 1
                            end

                            if not table then
                                table = Upvalue.new(storage, index, value)
                                table.Scanned = {}
                                storage.Upvalues[index] = table
                            end

                            table.Scanned[i] = v
                            closureHasMatch = true
                        end
                    end
                    
                    -- Deep nested table search (only in non-fast mode)
                    if not fastMode then
                        local function deepTableSearch(tbl, depth, maxDepth)
                            if depth > maxDepth or type(tbl) ~= "table" then return end
                            
                            for k, val in pairs(tbl) do
                                if resultCount >= maxResults then return end
                                
                                local valType = typeof(val)
                                if valType == "table" then
                                    for ki, vi in pairs(val) do
                                        if (ki ~= val and vi ~= val) and (compareUpvalue(query, ki, true) or compareUpvalue(query, vi)) then
                                            if not storage then
                                                local newClosure = Closure.new(closure)
                                                storage = newClosure
                                                upvalues[closure] = newClosure
                                                resultCount = resultCount + 1
                                            end

                                            if not table then
                                                table = Upvalue.new(storage, index, value)
                                                table.Scanned = {}
                                                storage.Upvalues[index] = table
                                            end

                                            table.Scanned[ki] = vi
                                            closureHasMatch = true
                                        end
                                    end
                                    deepTableSearch(val, depth + 1, maxDepth)
                                end
                            end
                        end
                        
                        deepTableSearch(value, 1, 3) -- Search up to 3 levels deep
                    end
                end
            end
        end
        
        processedClosures = processedClosures + 1
        
        -- Yield more frequently in fast mode, less frequently in deep mode
        local yieldInterval = fastMode and 50 or 100
        if processedClosures % yieldInterval == 0 then
            task.wait(0)
        end
    end

    return upvalues, processedClosures, totalClosures
end

UpvalueScanner.Scan = scan
UpvalueScanner.RequiredMethods = requiredMethods
return UpvalueScanner
