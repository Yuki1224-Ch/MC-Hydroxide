local BugFinder = {}

-- Advanced pattern matching and heuristic analysis for bug detection
local LocalScript = import("objects/LocalScript")
local Closure = import("objects/Closure")
local Upvalue = import("objects/Upvalue")
local Constant = import("objects/Constant")

local requiredMethods = {
    ["getGc"] = true,
    ["getSenv"] = true,
    ["getProtos"] = true,
    ["getConstants"] = true,
    ["getScriptClosure"] = true,
    ["isXClosure"] = true,
    ["getUpvalues"] = true,
    ["getUpvalue"] = true
}

-- Bug patterns database with severity levels
local bugPatterns = {
    -- Security vulnerabilities
    { name = "RemoteSpy Bypass", pattern = "fireclickdetector|firesignal|firetouchinterest", severity = "high", category = "security" },
    { name = "Environment Access", pattern = "getfenv|getscriptclosure|getsenv", severity = "medium", category = "security" },
    { name = "Metatable Manipulation", pattern = "debug%.setmetatable|hookmetamethod", severity = "high", category = "security" },
    { name = "Remote Function Exploit", pattern = "invokeclients|invokeserver", severity = "critical", category = "security" },
    
    -- Performance issues
    { name = "Unbounded Loop", pattern = "while%s+true%s+do|for%s+%w+%s+=%s+1,%s*math%.huge", severity = "medium", category = "performance" },
    { name = "Heavy String Concatenation", pattern = "%.%..*%.%.|string%.rep%s*%(", severity = "low", category = "performance" },
    { name = "Recursive Without Yield", pattern = "function%s+%w+%s*%([^)]*%)%s*.-[^p]call", severity = "medium", category = "performance" },
    { name = "Memory Leak Pattern", pattern = "table%.insert.*without.*remove|spawn%s*%(%s*function", severity = "medium", category = "performance" },
    
    -- Common bugs
    { name = "Nil Comparison", pattern = "==%s+nil|~=%s+nil", severity = "low", category = "logic" },
    { name = "Type Mismatch Risk", pattern = "tonumber%s*%([^)]*%)%s*==", severity = "low", category = "logic" },
    { name = "Deprecated API", pattern = "wait%s*%(|deprecated", severity = "low", category = "compatibility" },
    { name = "Unhandled PCall", pattern = "pcall%s*%([^)]*%)%s*$", severity = "medium", category = "error_handling" },
    { name = "Missing Error Handler", pattern = "coroutine%.resume%s*%([^,]+%)", severity = "medium", category = "error_handling" },
    
    -- Anti-tamper detection
    { name = "Anti-Tamper Check", pattern = "checkcaller|islclosure|isscriptable", severity = "high", category = "anti_tamper" },
    { name = "Executor Detection", pattern = "identifyexecutor|executorname|getexecutorname", severity = "high", category = "anti_tamper" },
    { name = "Virtualization Check", pattern = "vmprotect|themida|obfuscation", severity = "medium", category = "anti_tamper" },
}

-- Suspicious function names that might indicate bugs or exploits
local suspiciousFunctions = {
    "exploit", "cheat", "hack", "bypass", "inject", "hook", "spy", 
    "monitor", "intercept", "modify", "patch", "crack", "keygen",
    "memory", "pointer", "address", "offset", "scan", "pattern"
}

-- Optimized string search using Boyer-Moore-Horspool algorithm for large texts
local function createBadCharTable(pattern)
    local badChar = {}
    local m = #pattern
    for i = 1, m - 1 do
        badChar[pattern:sub(i, i):lower()] = m - i
    end
    return badChar
end

local function boyerMooreHorspool(text, pattern)
    local n = #text
    local m = #pattern
    if m == 0 or m > n then return false end
    
    local badChar = createBadCharTable(pattern)
    local shift = 0
    
    while shift <= (n - m) do
        local j = m
        while j >= 1 and pattern:sub(j, j):lower() == text:sub(shift + j, shift + j):lower() do
            j = j - 1
        end
        
        if j == 0 then
            return true
        end
        
        local char = text:sub(shift + m, shift + m):lower()
        shift = shift + (badChar[char] or m)
    end
    
    return false
end

-- Fast case-insensitive search
local function fastSearch(text, query)
    if not text or not query then return false end
    if #query < 3 then
        -- Use simple find for very short queries
        return text:lower():find(query:lower(), 1, true) ~= nil
    end
    -- Use optimized algorithm for longer queries
    return boyerMooreHorspool(text, query)
end

-- Calculate similarity score for fuzzy matching
local function calculateSimilarity(str1, str2)
    if not str1 or not str2 then return 0 end
    str1, str2 = str1:lower(), str2:lower()
    
    if str1 == str2 then return 1.0 end
    if str1:find(str2, 1, true) or str2:find(str1, 1, true) then return 0.8 end
    
    -- Levenshtein distance for fuzzy matching
    local len1, len2 = #str1, #str2
    if math.abs(len1 - len2) > 5 then return 0 end
    
    local matches = 0
    local minLen = math.min(len1, len2)
    for i = 1, minLen do
        if str1:sub(i, i) == str2:sub(i, i) then
            matches = matches + 1
        end
    end
    
    return matches / math.max(len1, len2)
end

-- Analyze closure for potential bugs
local function analyzeClosure(closure, deepScan)
    local bugs = {}
    local source = ""
    
    -- Get closure source if possible
    pcall(function()
        source = debug.getinfo(closure.Data, "S").source or ""
    end)
    
    -- Check function name for suspicious patterns
    local funcName = getInfo(closure.Data).name or ""
    for _, suspicious in ipairs(suspiciousFunctions) do
        if funcName:lower():find(suspicious) then
            table.insert(bugs, {
                type = "suspicious_name",
                severity = "medium",
                description = "Function name contains suspicious keyword: " .. suspicious,
                closure = closure
            })
        end
    end
    
    -- Scan source code for bug patterns
    if source ~= "" then
        for _, pattern in ipairs(bugPatterns) do
            if fastSearch(source, pattern.pattern) then
                table.insert(bugs, {
                    type = pattern.name,
                    severity = pattern.severity,
                    category = pattern.category,
                    description = "Detected: " .. pattern.name,
                    closure = closure,
                    pattern = pattern.pattern
                })
            end
        end
    end
    
    -- Analyze upvalues for suspicious data
    if deepScan then
        pcall(function()
            local upvalues = getUpvalues(closure.Data)
            if upvalues then
                for i, upvalue in ipairs(upvalues) do
                    local upvalueType = type(upvalue)
                    
                    -- Check for suspicious upvalue types
                    if upvalueType == "function" then
                        local upvalueInfo = getInfo(upvalue)
                        if upvalueInfo and upvalueInfo.name then
                            for _, suspicious in ipairs(suspiciousFunctions) do
                                if upvalueInfo.name:lower():find(suspicious) then
                                    table.insert(bugs, {
                                        type = "suspicious_upvalue",
                                        severity = "high",
                                        description = "Suspicious function in upvalue #" .. i .. ": " .. upvalueInfo.name,
                                        closure = closure,
                                        upvalueIndex = i
                                    })
                                end
                            end
                        end
                    elseif upvalueType == "userdata" or upvalueType == "thread" then
                        table.insert(bugs, {
                            type = "complex_upvalue",
                            severity = "low",
                            description = "Complex upvalue type at index #" .. i .. ": " .. upvalueType,
                            closure = closure,
                            upvalueIndex = i
                        })
                    end
                end
            end
        end)
    end
    
    -- Analyze constants
    pcall(function()
        local constants = getConstants(closure.Data)
        if constants then
            for i, constant in ipairs(constants) do
                if type(constant) == "string" then
                    for _, pattern in ipairs(bugPatterns) do
                        if fastSearch(constant, pattern.pattern) then
                            table.insert(bugs, {
                                type = pattern.name,
                                severity = pattern.severity,
                                category = pattern.category,
                                description = "Suspicious constant #" .. i .. ": " .. pattern.name,
                                closure = closure,
                                constantIndex = i
                            })
                            break
                        end
                    end
                end
            end
        end
    end)
    
    return bugs
end

-- Main scan function with multi-threading support
local function scan(query, options)
    options = options or {}
    local results = {}
    local queryLower = query and query:lower() or ""
    local useFuzzy = options.fuzzy or false
    local deepScan = options.deep or false
    local maxResults = options.maxResults or 1000
    local categories = options.categories or {"security", "performance", "logic", "error_handling", "anti_tamper"}
    
    local resultCount = 0
    local scannedCount = 0
    
    -- Create a worker function for parallel scanning
    local function scanWorker(closures)
        local workerResults = {}
        
        for _, closure in pairs(closures) do
            if resultCount >= maxResults then break end
            
            scannedCount = scannedCount + 1
            
            -- If query provided, filter by name first
            if queryLower ~= "" then
                local closureName = (getInfo(closure.Data).name or ""):lower()
                local scriptName = ""
                
                pcall(function()
                    local env = getfenv(closure.Data)
                    if env and env.script then
                        scriptName = env.script.Name:lower()
                    end
                end)
                
                local nameMatch = closureName:find(queryLower, 1, true) or scriptName:find(queryLower, 1, true)
                
                if useFuzzy and not nameMatch then
                    local similarity = math.max(
                        calculateSimilarity(closureName, queryLower),
                        calculateSimilarity(scriptName, queryLower)
                    )
                    if similarity >= 0.6 then
                        nameMatch = true
                    end
                end
                
                if not nameMatch then
                    continue
                end
            end
            
            -- Analyze closure for bugs
            local bugs = analyzeClosure(closure, deepScan)
            
            -- Filter by category if specified
            if #bugs > 0 then
                for _, bug in ipairs(bugs) do
                    if not categories or #categories == 0 or table.find(categories, bug.category) then
                        table.insert(workerResults, {
                            closure = closure,
                            bugs = {bug}
                        })
                        resultCount = resultCount + 1
                        break
                    end
                end
            end
        end
        
        return workerResults
    end
    
    -- Collect all closures from GC
    local allClosures = {}
    pcall(function()
        for _, v in pairs(getgc()) do
            if type(v) == "function" and not isxclosure(v) then
                local success, script = pcall(function()
                    return rawget(getfenv(v), "script")
                end)
                
                if success and typeof(script) == "Instance" and script:IsA("LocalScript") then
                    local success2, closureObj = pcall(function()
                        return Closure.new(script)
                    end)
                    
                    if success2 and closureObj then
                        table.insert(allClosures, closureObj)
                    end
                end
            end
        end
    end)
    
    -- Process closures in batches to prevent freezing
    local batchSize = 50
    local totalBatches = math.ceil(#allClosures / batchSize)
    
    for batchNum = 1, totalBatches do
        local startIndex = (batchNum - 1) * batchSize + 1
        local endIndex = math.min(batchNum * batchSize, #allClosures)
        
        local batch = {}
        for i = startIndex, endIndex do
            table.insert(batch, allClosures[i])
        end
        
        local batchResults = scanWorker(batch)
        for _, result in ipairs(batchResults) do
            table.insert(results, result)
        end
        
        -- Yield periodically to prevent freezing
        if batchNum % 5 == 0 then
            task.wait(0.01)
        end
    end
    
    -- Sort results by severity
    local severityOrder = { critical = 1, high = 2, medium = 3, low = 4 }
    table.sort(results, function(a, b)
        local severityA = severityOrder[a.bugs[1].severity] or 5
        local severityB = severityOrder[b.bugs[1].severity] or 5
        return severityA < severityB
    end)
    
    return {
        results = results,
        scannedCount = scannedCount,
        totalBugs = #results,
        query = query
    }
end

-- Quick scan for real-time usage
local function quickScan(closure)
    return analyzeClosure(closure, false)
end

BugFinder.RequiredMethods = requiredMethods
BugFinder.Scan = scan
BugFinder.QuickScan = quickScan
BugFinder.BugPatterns = bugPatterns
BugFinder.SuspiciousFunctions = suspiciousFunctions
BugFinder.FastSearch = fastSearch
BugFinder.CalculateSimilarity = calculateSimilarity

return BugFinder
