-- dpkg-query.lua
-- apt-lua
--
-- This file provides functions to access the package database.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

local dpkg_control = require "dpkg-control"

local function trim(s) return string.match(s, '^()[%s%z]*$') and '' or string.match(s, '^[%s%z]*(.*[^%s%z])') end
local function pad(str, len, c) return string.len(str) < len and string.sub(str, 1, len) .. string.rep(c or " ", len - string.len(str)) or string.sub(str, 1, len) end

local dpkg_query = {status = {}}
dpkg_query.admindir = "/var/lib/dpkg"
if not fs.isDir(dpkg_query.admindir) then fs.makeDir(dpkg_query.admindir) end

function dpkg_query.readDatabase()
    local file = io.open(fs.combine(dpkg_query.admindir, "status"), "r")
    if file == nil then error("Couldn't find status file") end
    local retval = {{}}
    local last_key = nil
    local s = 1
    for line in file:lines() do
        if line == "" then 
            s=s+1
            retval[s] = {}
            last_key = nil
        else
            if string.sub(line, 1, 1) == " " and last_key ~= nil then
                if last_key == "Description" then
                    if type(retval[s][last_key]) == "string" then retval[s][last_key] = {Short = retval[s][last_key], Long = ""} end
                    retval[s][last_key].Long = retval[s][last_key].Long .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2))
                else retval[s][last_key] = retval[s][last_key] .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2)) end
            else
                last_key = string.sub(line, 1, (string.find(line, ":") or 0) - 1)
                retval[s][last_key] = trim(string.sub(line, (string.find(line, ":") or -1) + 1))
            end
        end
    end
    file:close()
    local realretval = {}
    for k,v in pairs(retval) do if v.Package then realretval[v.Package] = v end end
    return realretval
end

local function readAvailable()
    local file = io.open(fs.combine(dpkg_query.admindir, "available"), "r")
    if file == nil then error("Couldn't find status file") end
    local retval = {{}}
    local last_key = nil
    local s = 1
    for line in file:lines() do
        if line == "" then 
            s=s+1
            retval[s] = {}
            last_key = nil
        else
            if string.sub(line, 1, 1) == " " and last_key ~= nil then
                if last_key == "Description" then
                    if type(retval[s][last_key]) == "string" then retval[s][last_key] = {Short = retval[s][last_key], Long = ""} end
                    retval[s][last_key].Long = retval[s][last_key].Long .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2))
                else retval[s][last_key] = retval[s][last_key] .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2)) end
            else
                last_key = string.sub(line, 1, (string.find(line, ":") or 0) - 1)
                retval[s][last_key] = trim(string.sub(line, (string.find(line, ":") or -1) + 1))
            end
        end
    end
    file:close()
    local realretval = {}
    for k,v in pairs(retval) do if v.Package then realretval[v.Package] = v end end
    return realretval
end

function dpkg_query.writeDatabase(data)
    fs.copy(fs.combine(dpkg_query.admindir, "status"), fs.combine(dpkg_query.admindir, "status-old"))
    local file = fs.open(fs.combine(dpkg_query.admindir, "status"), "w")
    if file == nil then error("Couldn't find status file") end
    local function check(v) if type(v) == "table" then return (v.Short or "") .. "\n " .. string.gsub(v.Long or "", "\n\n", "\n .\n") else return v end end
    for k,v in pairs(data) do
        file.writeLine("Package: " .. k)
        for l,w in pairs(v) do if l ~= "Package" and l ~= "Description" then file.writeLine(l .. ": " .. check(w)) end end
        file.writeLine("Description: " .. check(v.Description))
        file.writeLine("")
    end
    file.close()
end

function dpkg_query.findPackage(name, db)
    db = db or dpkg_query.readDatabase()
    for k,v in pairs(db) do if string.match(k, "^" .. name .. "$") then return v end end
    return nil
end

function dpkg_query.status.configured(state) return state == "triggers-pending" or state == "installed" end
function dpkg_query.status.present(state) return state ~= "not-installed" and state ~= "config-files" and state ~= "half-installed" end
function dpkg_query.status.needs_configure(state) return state == "config-failed" or state == "half-configured" or state == "unpacked" end

if pcall(require, "dpkg-query") then
    local args = {}
    local mode = nil
    local showformat = "${Package}\t${Version}\n"
    local load_avail = false
    local nextarg
    for k,v in pairs({...}) do
        if nextarg then 
            if nextarg == 0 then showformat = v
            elseif nextarg == 1 then dpkg_query.admindir = v
            elseif nextarg == 2 then showformat = v end
            nextarg = nil
        elseif v == "-l" or v == "--list" then mode = 0
        elseif v == "-W" or v == "--show" then mode = 1
        elseif v == "-s" or v == "--status" then mode = 2
        elseif v == "-L" or v == "--listfiles" then mode = 3
        elseif v == "--control-list" then mode = 4
        elseif v == "--control-show" then mode = 5
        elseif v == "-c" or v == "--control-path" then mode = 6
        elseif v == "-S" or v == "--search" then mode = 7
        elseif v == "-p" or v == "--print-avail" then mode = 8
        elseif v == "-?" or v == "--help" then print([[Usage: dpkg-query [<option> ...] <command>
Commands:
    -s|--status <package> ...        Display package status details.
    -p|--print-avail <package> ...   Display available version details.
    -L|--listfiles <package> ...     List files 'owned' by package(s).
    -l|--list [<pattern> ...]        List packages concisely.
    -W|--show [<pattern> ...]        Show information on package(s).
    -S|--search <pattern> ...        Find package(s) owning file(s).
        --control-list <package>     Print the package control file list.
        --control-show <package> <file>
                                     Show the package control file.
    -c|--control-path <package> [<file>]
                                     Print path for package control file.
    -?, --help                       Show this help message.
        --version                    Show the version.]]); return 2
        elseif v == "--version" then print("dpkg-query v1.0\nPart of apt-lua for CraftOS\nCopyright (c) 2019 JackMacWindows."); return 2
        elseif string.find(v, "--admindir=") == 1 then dpkg_query.admindir = string.sub(v, 12)
        elseif v == "--admindir" then nextarg = 1
        elseif v == "--load-avail" then load_avail = true
        elseif string.find(v, "--showformat=") == 1 then showformat = string.sub(v, 14)
        elseif v == "--showformat" then nextarg = 2
        elseif v == "-f" then nextarg = 0
        else table.insert(args, v) end
    end
    showformat = string.gsub(string.gsub(showformat, "\\n", "\n"), "\\t", "\t")
    if mode == 0 then
        local pattern = nil
        if args[1] ~= nil then pattern = string.gsub(args[1], "%*", ".+") end
        local db = dpkg_query.readDatabase()
        local function printPackage(v)
            local state = ""
            if string.find(v.Status, "^install ") then state = "i"
            elseif string.find(v.Status, " hold") then state = "h"
            elseif string.find(v.Status, " deinstall") then state = "r"
            elseif string.find(v.Status, " purge") then state = "p"
            else state = "u" end
            if string.find(v.Status, " not-installed") then state = state .. "n"
            elseif string.find(v.Status, " config-files") then state = state .. "c"
            elseif string.find(v.Status, " half-installed") then state = state .. "H"
            elseif string.find(v.Status, " unpacked") then state = state .. "U"
            elseif string.find(v.Status, " half-configured") then state = state .. "F"
            elseif string.find(v.Status, " triggers-awaited") then state = state .. "W"
            elseif string.find(v.Status, " triggers-pending") then state = state .. "t"
            elseif string.find(v.Status, " installed") then state = state .. "i"
            else state = state .. "u" end
            if string.find(v.Status, " reinst-required") then state = state .. "R" else state = state .. " " end -- i hope nobody ever sees the R ever at any point in time :(((((
            local w = term.getSize() - 4
            print(string.format("%3s %s %s %s", state, pad(v.Package, w / 4), pad(v.Version, w / 4), pad(v.Description.Short, w / 2)))
        end
        if pattern then for k,v in pairs(db) do if string.match(v.Package, pattern) then printPackage(v) end end 
        else for k,v in pairs(db) do if string.find(v.Status, " config-files") == nil and string.find(v.Status, " not-installed") == nil then printPackage(v) end end end
    elseif mode == 1 then
        local pattern = nil
        if args[1] ~= nil then pattern = string.gsub(args[1], "%*", ".+") end
        local db = dpkg_query.readDatabase()
        local function printPackage(v)
            local state = ""
            if string.find(v.Status, "^install ") then state = "i"
            elseif string.find(v.Status, "hold") then state = "h"
            elseif string.find(v.Status, "deinstall") then state = "r"
            elseif string.find(v.Status, "purge") then state = "p"
            else state = "u" end
            if string.find(v.Status, "not-installed") then state = state .. "n"
            elseif string.find(v.Status, "config-files") then state = state .. "c"
            elseif string.find(v.Status, "half-installed") then state = state .. "H"
            elseif string.find(v.Status, "unpacked") then state = state .. "U"
            elseif string.find(v.Status, "half-configured") then state = state .. "F"
            elseif string.find(v.Status, "triggers-awaited") then state = state .. "W"
            elseif string.find(v.Status, "triggers-pending") then state = state .. "t"
            elseif string.find(v.Status, " installed") then state = state .. "i"
            else state = state .. "u" end
            if string.find(v.Status, " reinst-required") then state = state .. "R" else state = state .. " " end
            local function getsub(field, width) return width ~= "" and pad(v[field], tonumber(string.sub(width, 2))) or v[field] end
            write(string.gsub(showformat, "%${(.-)(;?%d*)}", getsub))
        end
        if pattern then for k,v in pairs(db) do if string.match(v.Package, pattern) then printPackage(v) end end 
        else for k,v in pairs(db) do if string.find(v.Status, " config-files") == nil and string.find(v.Status, " not-installed") == nil then printPackage(v) end end end
    elseif mode == 2 then
        if #args < 1 then error("Usage: dpkg-query [options...] --status <package-name...>") end
        local db = dpkg_query.readDatabase()
        local function check(v) if type(v) == "table" then return v.Short .. "\n" .. string.gsub(v.Long, "\n\n", "\n .\n") else return v end end
        for _,a in pairs(args) do
            for k,v in pairs(db) do if k == a then
                for l,w in pairs(v) do print(l .. ": " .. check(w)) end
                break
            end end
            print("")
        end
    elseif mode == 3 then
        if #args < 1 then error("Usage: dpkg-query [options...] --listfiles <package-name...>") end
        local db = dpkg_query.readDatabase()
        for _,a in pairs(args) do
            local path
            if fs.exists(fs.combine(dpkg_query.admindir, "info/" .. a .. ".list")) then path = fs.combine(dpkg_query.admindir, "info/" .. a .. ".list")
            else for k,v in pairs(db) do if k == a then
                if not fs.exists(fs.combine(dpkg_query.admindir, "info/" .. a .. "!" .. v.Architecture .. ".list")) then error("Could not find list of files for " .. a) end
                path = fs.combine(dpkg_query.admindir, "info/" .. a .. "!" .. v.Architecture .. ".list")
                break
            end end end
            local file = fs.open(path, "r")
            print(file.readAll())
            file.close()
        end
    elseif mode == 4 then
        if #args < 1 then error("Usage: dpkg-query [options...] --control-list <package-name>") end
        local files = {}
        for k,v in pairs(fs.list(fs.combine(dpkg_query.admindir, "info"))) do 
            if string.match(v, "^" .. string.gsub(args[1], "%-", "%%-") .. "%..+") then table.insert(files, fs.combine(dpkg_query.admindir, "info/" .. v)) end
            if k % 1000 == 0 then
                os.queueEvent("nosleep")
                os.pullEvent()
            end
        end
        if #files == 0 then
            local db = dpkg_query.readDatabase()
            for k,v in pairs(db) do if k == args[1] then 
                local mstr = "^" .. string.gsub(args[1], "%-", "%%-") .. "!" .. v.Architecture .. "%.(.+)"
                for l,w in pairs(fs.list(fs.combine(dpkg_query.admindir, "info"))) do 
                    if string.match(w, mstr) then table.insert(files, string.match(w, mstr)) end
                    if l % 1000 == 0 then
                        os.queueEvent("nosleep")
                        os.pullEvent()
                    end
                end
                break
            end end
        end
        for k,v in pairs(files) do if v ~= "list" then print(v) end end
    elseif mode == 5 then
        if #args < 2 then error("Usage: dpkg-query [options...] --control-show <package-name> <control-file>") end
        if fs.exists(fs.combine(dpkg_query.admindir, "info/" .. args[1] .. "." .. args[2])) then
            local file = fs.open(fs.combine(dpkg_query.admindir, "info/" .. args[1] .. "." .. args[2]), "r")
            print(file.readAll())
            file.close()
        else
            local db = dpkg_query.readDatabase()
            for k,v in pairs(db) do if k == args[1] then 
                if fs.exists(fs.combine(dpkg_query.admindir, "info/" .. args[1] .. "!" .. v.Architecture .. "." .. args[2])) then
                    local file = fs.open(fs.combine(dpkg_query.admindir, "info/" .. args[1] .. "!" .. v.Architecture .. "." .. args[2]), "r")
                    print(file.readAll())
                    file.close()
                end
                break
            end end
        end
    elseif mode == 6 then
        error("This command is deprecated upstream, therefore it will remain unimplemented here.")
    elseif mode == 7 then
        if #args < 1 then error("Usage: dpkg-query [options...] --search <pattern>") end
        local plain = false
        local found = false
        local pattern = string.gsub(string.gsub(args[1], "([^\\])%*", "%1%.%*"), "([^\\])%?", "%1%.%-")
        if string.find(args[1], "[%*%[%?/]") ~= 1 then pattern = ".*" .. pattern .. ".*"
        elseif string.find(args[1], "[%*%[%?/]") == nil then plain = true 
        else pattern = "^" .. pattern .. "$" end
        local files = fs.find(fs.combine(dpkg_query.admindir, "info/*.list"))
        print("Searching...")
        for k,v in pairs(files) do
            local file = io.open(v, "r")
            for line in file:lines() do if string.find(line, pattern, 1, plain) then 
                print(string.sub(fs.getName(v), 1, string.find(fs.getName(v), "[!.]") - 1) .. ": " .. line)
                found = true
            end end
            file:close()
            os.queueEvent("nosleep")
            os.pullEvent()
        end
        if not found then error("no pattern matching " .. args[1]) end
    elseif mode == 8 then
        if #args < 1 then error("Usage: dpkg-query [options...] --print-avail <package-name...>") end
        local db = readAvailable()
        local function check(v) if type(v) == "table" then return v.Short .. "\n" .. string.gsub(v.Long, "\n\n", "\n .\n") else return v end end
        for _,a in pairs(args) do
            for k,v in pairs(db) do if k == a then
                for l,w in pairs(v) do print(l .. ": " .. check(w)) end
                break
            end end
            print("")
        end
    else error("Usage: dpkg-query [options...] <command>") end
end

return dpkg_query