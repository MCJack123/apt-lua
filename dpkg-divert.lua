-- dpkg-divert.lua
-- apt-lua
--
-- This file provides functions that tell dpkg to install a file in a package to
-- a different location.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

local dpkg_divert = {}

dpkg_divert.admindir = "/var/lib/dpkg"

function dpkg_divert.parse()
    local file = io.open(fs.combine(admindir, "diversions"), "r")
    local l = 1
    local retval = {}
    local name
    for line in file:lines() do
        if l == 1 then retval[line] = {}; name = line
        elseif l == 2 then retval[name].name = line
        elseif l == 3 then retval[name].package = line end
        l = l + 1
        if l > 3 then l = 1 end
    end
    file:close()
    return retval
end

function dpkg_divert.get(file, package) 
    local retval = dpkg_divert.parse()[file]
    if not retval or retval.package == package then return nil end
    return retval
end

local function save(data)
    fs.copy(fs.combine(admindir, "diversions"), fs.combine(admindir, "diversions-old"))
    local file = io.open(fs.combine(admindir, "diversions"), "w")
    for k,v in pairs(data) do
        file.writeLine(k)
        file.writeLine(v.name)
        file.writeLine(v.package)
    end
    file.close()
end

function dpkg_divert.add(old, new, package)
    local d = dpkg_divert.parse()
    d[old] = {name = new or old .. ".distrib", package = package or ":"}
    save(d)
end

function dpkg_divert.remove(old)
    local d = dpkg_divert.parse()
    d[old] = nil
    save(d)
end

if pcall(require, "dpkg-divert") then
    local args = {}
    local mode = 0
    local instdir = "/"
    local new = nil
    local package = ":"
    local quiet = false
    local rename = nil
    local test = false
    local nextarg = nil
    for k,v in pairs({...}) do
        if nextarg then
            if nextarg == 0 then dpkg_divert.admindir = v
            elseif nextarg == 1 then instdir = v
            elseif nextarg == 2 then instdir = v; dpkg_divert.admindir = fs.combine(v, "var/lib/dpkg")
            elseif nextarg == 3 then new = v
            elseif nextarg == 4 then package = v end
            nextarg = nil
        elseif v == "--add" then mode = 0
        elseif v == "--remove" then mode = 1
        elseif v == "--list" then mode = 2
        elseif v == "--listpackage" then mode = 3
        elseif v == "--truename" then mode = 4
        elseif v == "--admindir" then nextarg = 0
        elseif v == "--instdir" then nextarg = 1
        elseif v == "--root" then nextarg = 2
        elseif v == "--divert" then nextarg = 3
        elseif v == "--local" then package = ":"
        elseif v == "--package" then nextarg = 4
        elseif v == "--quiet" then quiet = true
        elseif v == "--rename" then rename = true
        elseif v == "--no-rename" then rename = false
        elseif v == "--test" then test = true
        elseif v == "-?" or v == "--help" then print([[Usage: dpkg-divert [<option> ...] <command>
Commands:
    [--add] <file>           add a diversion.
    --remove <file>          remove the diversion.
    --list [<glob-pattern>]  show file diversions.
    --listpackage <file>     show what package diverts the file.
    --truename <file>        return the diverted file.]]); return 2
        elseif v == "--version" then print("dpkg-divert v1.0\nPart of apt-lua for CraftOS\nCopyright (c) 2019 JackMacWindows."); return 2 
        else table.insert(args, v) end
    end
    if mode == 0 then
        if #args < 1 then error("Usage: dpkg-divert [options...] [--add] <file>") end
        new = new or args[1] .. ".distrib"
        if package == ":" and not quiet then print("Adding 'local diversion of " .. args[1] .. " to " .. new .. "'")
        elseif not quiet then print("Adding 'diversion of " .. args[1] .. " to " .. new .. " by " .. package .. "'") end
        if not test then dpkg_divert.add(args[1], new, package) end
        if rename then fs.move(args[1], new) end
    elseif mode == 1 then
        if #args < 1 then error("Usage: dpkg-divert [options...] --remove <file>") end
        local d = dpkg_divert.parse()
        if d[args[1]] == nil then return end
        if package == ":" and not quiet then print("Removing 'local diversion of " .. args[1] .. " to " .. d[args[1]].name .. "'")
        elseif not quiet then print("Removing 'diversion of " .. args[1] .. " to " .. d[args[1]].name .. " by " .. d[args[1]].package .. "'") end
        if not test then dpkg_divert.remove(args[1]) end
        if rename then fs.move(d[args[1]].name, args[1]) end
    elseif mode == 2 then
        if quiet then return end
        if #args < 1 then error("Usage: dpkg-divert [options...] --list <glob>") end
        args[1] = string.gsub(args[1], "%*", "%.%*")
        for k,v in pairs(dpkg_divert.parse()) do if string.match(k, args[1]) then
            if v.package == ":" then print("local diversion of " .. k .. " to " .. v.name)
            else print("diversion of " .. k .. " to " .. v.name .. " by " .. v.package) end
        end end
    elseif mode == 3 then
        if quiet then return end
        if #args < 1 then error("Usage: dpkg-divert [options...] --listpackage <file>") end
        local p = dpkg_divert.parse()[args[1]]
        if p ~= nil then if p.package == ":" then print("LOCAL") else print(p.package) end end
    elseif mode == 4 then
        if quiet then return end
        if #args < 1 then error("Usage: dpkg-divert [options...] --truename <file>") end
        local p = dpkg_divert.parse()[args[1]]
        if p == nil then print(args[1]) else print(p.name) end
    end
end

return dpkg_divert