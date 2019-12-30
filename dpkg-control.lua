-- dpkg-control.lua
-- apt-lua
--
-- This file provides functions to parse control files.
--
-- Copyright (c) 2019 JackMacWindows.

local function trim(s) return string.match(s, '^()[%s%z]*$') and '' or string.match(s, '^[%s%z]*(.*[^%s%z])') end

local dpkg_control = {}

function dpkg_control.parseControl(data)
    local retval = {}
    local last_key = nil
    for line in string.gmatch(data, "[^\n]+") do
        if string.sub(line, 1, 1) == " " and last_key ~= nil then
            if last_key == "Description" then
                if type(retval[last_key]) == "string" then retval[last_key] = {Short = retval[last_key], Long = ""} end
                retval[last_key].Long = retval[last_key].Long .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2))
            else retval[last_key] = retval[last_key] .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2)) end
        else
            last_key = string.sub(line, 1, (string.find(line, ":") or 0) - 1)
            retval[last_key] = trim(string.sub(line, (string.find(line, ":") or -1) + 1))
        end
    end
    return retval
end

function dpkg_control.parseControlList(data)
    local retval = {}
    local sections = {}
    local s = 1
    for line in string.gmatch(data, "[^\n]*\n") do
        if line == "\n" or line == "" then s = s + 1
        else sections[s] = (sections[s] or "") .. line end
    end
    for k,v in pairs(sections) do table.insert(retval, dpkg_control.parseControl(v)) end
    return retval
end

function dpkg_control.parseDependencies(deps)
    local retval = {}
    for dep in string.gmatch(deps, "[^,]+") do
        dep = trim(dep)
        local d = {}
        if string.find(dep, "|") then
            d.multiple = true
            d.names = {}
            for ddep in string.gmatch(dep, "[^|]+") do
                ddep = trim(ddep)
                local dd = {}
                dd.name = string.match(ddep, "%S+")
                if string.match(ddep, "%([<>=]+ [%d.%-%+%~]+%)") then
                    dd.rel = string.match(ddep, "%(([<>=]+) [%d.%-%+%~]+%)")
                    dd.version = string.match(ddep, "%([<>=]+ ([%d.%-%+%~]+)%)")
                end
                table.insert(d.names, dd)
            end
        else
            d.name = string.match(dep, "%S+")
            if string.match(dep, "%([<>=]+ [%d%.%-%+%~]+%)") then
                d.rel = string.match(dep, "%(([<>=]+) [%d.%-%+%~]+%)")
                d.version = string.match(dep, "%([<>=]+ ([%d.%-%+%~]+)%)")
            end
        end
        table.insert(retval, d)
    end
    return retval
end

return dpkg_control