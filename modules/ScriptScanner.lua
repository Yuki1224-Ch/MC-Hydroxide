local ScriptScanner = {}
local LocalScript = import("objects/LocalScript")

local requiredMethods = {
    ["getGc"] = true,
    ["getSenv"] = true,
    ["getProtos"] = true,
    ["getConstants"] = true,
    ["getScriptClosure"] = true,
    ["isXClosure"] = true
}

-- Optimized scan with caching and fast string matching
local scriptCache = {}
local cacheTime = 0
local cacheDuration = 2.0 -- Cache valid for 2 seconds

local function scan(query)
    local scripts = {}
    query = query or ""
    local queryLower = query:lower()
    
    -- Check if we can use cached results (only for empty query)
    if query == "" and #scriptCache > 0 and (tick() - cacheTime) < cacheDuration then
        for k, v in pairs(scriptCache) do
            scripts[k] = v
        end
        return scripts
    end
    
    -- Use fast string matching for better performance
    local function matchesQuery(name)
        if query == "" then return true end
        return name:lower():find(queryLower, 1, true) ~= nil
    end

    for _i, v in pairs(getGc()) do
        if type(v) == "function" and not isXClosure(v) then
            local success, script = pcall(function()
                return rawget(getfenv(v), "script")
            end)

            if success and typeof(script) == "Instance" and 
                not scripts[script] and 
                script:IsA("LocalScript") and 
                matchesQuery(script.Name) and
                getScriptClosure(script) and
                pcall(function() getsenv(script) end)
            then
                local localScript = LocalScript.new(script)
                scripts[script] = localScript
                
                -- Cache only full scans (empty query)
                if query == "" then
                    scriptCache[script] = localScript
                end
            end
        end
    end
    
    -- Update cache time
    if query == "" then
        cacheTime = tick()
    end

    return scripts
end

ScriptScanner.RequiredMethods = requiredMethods
ScriptScanner.Scan = scan
return ScriptScanner