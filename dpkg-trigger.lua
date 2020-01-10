-- dpkg-trigger.lua
-- apt-lua
--
-- This file provides functions that can activate an event for a different
-- package than the one that's being installed.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

local dpkg_query = require "dpkg-query"

local dpkg_trigger = {}
dpkg_trigger.admindir = "/var/lib/dpkg"
dpkg_trigger.log = function(text) end -- called when logging events, used for dpkg

--[[
    * Triggered packages run `postinst trigger <name>` for each trigger
    * Triggers activated with await will add the trigger to a list and set "trigger-await" on the triggering package and won't configure until cleared
    * Triggers activated with noawait will add the trigger to a list without setting "trigger-await" on the triggering package
    * Both activations will set "trigger-pending" on the triggered package (?)
    * Triggers will be run all at once
    * Await modifier in interest/activate directives:
    | interest | activate | result  |
    |----------|----------|---------|
    | await    | await    | await   |
    | await    | noawait  | noawait |
    | noawait  | await    | noawait |
    | noawait  | noawait  | noawait |
    basically: await = interest-await && activate-await; noawait = interest-noawait || activate-noawait
]]

local trigger_list = {}

local function dir(p) return fs.combine(dpkg_trigger.admindir, p) end
local function split(str, sep)
    local t={}
    for s in string.gmatch(str, "([^"..(sep or "%s").."]+)") do table.insert(t, s) end
    return t
end

function dpkg_trigger.list() return fs.list(dir("triggers")) end

function dpkg_trigger.lock()
    while fs.exists(dir("triggers/Lock")) do os.pullEvent() end
    local file = fs.open(dir("triggers/Lock"), "w")
    file.write("Lock")
    file.flush()
    return function()
        file.close()
        fs.delete(dir("triggers/Lock"))
        if fs.exists(dir("triggers/Lock")) then error("Lock still exists!") end
    end
end

function dpkg_trigger.readDatabase()
    local file = io.open(dir("triggers/File"), "r")
    if not file then error("Missing trigger file") end
    local unlock = dpkg_trigger.lock()
    local retval = {}
    for l in file:lines() do if l ~= "" then
        local path, package = string.match(l, "([^ ]+) ([^ ]+)")
        retval[path] = {package = package, await = true}
        if string.find(package, "/noawait") then retval[path].await = false end
    end end
    file:close()
    unlock()
    return retval
end

function dpkg_trigger.register(name, package, await)
    if await == nil then await = true end
    local unlock = dpkg_trigger.lock()
    if string.find(name, "/") then
        local file = fs.open(dir("triggers/File"), fs.exists(dir("triggers/File")) and "a" or "w")
        file.writeLine(name .. " " .. package .. (not await and "/noawait" or ""))
        file.close()
    else
        local file = fs.open(dir("triggers/" .. name), "w")
        file.writeLine(package .. (not await and "/noawait" or ""))
        file.close()
    end
    unlock()
end

function dpkg_trigger.deregister(name) 
    if string.find(name, "/") then
        local unlock = dpkg_trigger.lock()
        local file = io.open(dir("triggers/File"), "r")
        if not file then return unlock() end
        local retval = ""
        for l in file:lines() do if not string.match(l, "^" .. name .. " ") then retval = retval .. l .. "\n" end end
        file:close()
        file = fs.open(dir("triggers/File"), "w")
        file.write(retval)
        file.close()
        unlock()
    else fs.delete(dir("triggers/" .. name)) end
end

function dpkg_trigger.activate(name, package, await, triggerdb, packagedb)
    if await == nil then await = true end
    if string.find(name, "/") then
        -- File trigger, may not be needed
        triggerdb = triggerdb or dpkg_trigger.readDatabase()
        local interest = false
        for k,v in pairs(triggerdb) do if string.match(name, "^" .. k) then interest = v end end
        if not interest then return false end
        await = await and interest.await
        packagedb = packagedb or dpkg_query.readDatabase()
        local selection, flag, state = string.match(packagedb[interest.package].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
        if state ~= "triggers-awaited" then packagedb[interest.package].Status = selection .. " " .. flag .. " triggers-pending" end
        selection, flag, state = string.match(packagedb[package].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
        if await then 
            packagedb[package].Status = selection .. " " .. flag .. " triggers-awaited" 
            packagedb[package]["Triggers-Awaited"] = (packagedb[package]["Triggers-Awaited"] or "") .. (packagedb[package]["Triggers-Awaited"] and " " or "") .. interest.package
        end
        packagedb[interest.package]["Triggers-Pending"] = (packagedb[interest.package]["Triggers-Pending"] or "") .. (packagedb[interest.package]["Triggers-Pending"] and " " or "") .. name
        --dpkg_query.writeDatabase(packagedb)
        local unlock = dpkg_trigger.lock()
        local file = io.open(dir("triggers/Unincorp"), "r")
        local out = fs.open(dir("triggers/Unincorp.new"), "w")
        local found = false
        for v in file:lines() do
            if not found and string.match(v, "^" .. name .. " ") then
                found = true
                if await then
                    if string.match(v, "[^ ]+ (.+)") == "-" then v = name end
                    v = v .. " " .. package
                end
            end
            out.writeLine(v)
        end
        if not found then out.writeLine(name .. " " .. (await and package or "-")) end
        file:close()
        out.close()
        fs.delete(dir("triggers/Unincorp"))
        fs.move(dir("triggers/Unincorp.new"), dir("triggers/Unincorp"))
        unlock()
        return true, triggerdb, packagedb
    else
        -- Explicit trigger
        if not fs.exists(dir("triggers/" .. name)) then error("Invalid trigger " .. name, 2) end
        -- I can't find any documentation or file evidence that shows how dpkg
        -- keeps track of whether explicit triggers should await, even after
        -- running an strace on dpkg/dpkg-trigger. For now, explicit triggers
        -- will ignore the package's await preference.
        local file = io.open(dir("triggers/" .. name), "r")
        if file == nil then error("Could not open trigger file") end
        packagedb = packagedb or dpkg_query.readDatabase()
        local packages
        for l in file:lines() do
            if packagedb[l] == nil then dpkg_trigger.log("Package " .. l .. " is interested in trigger " .. name .. " but is not installed") else
                local selection, flag, state = string.match(packagedb[l].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
                packagedb[l].Status = selection .. " " .. flag .. " triggers-pending"
                packagedb[l]["Triggers-Pending"] = (packagedb[l]["Triggers-Pending"] or "") .. (packagedb[l]["Triggers-Pending"] and " " or "") .. name
                selection, flag, state = string.match(packagedb[package].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
                if await then 
                    packagedb[package].Status = selection .. " " .. flag .. " triggers-awaited" 
                    packagedb[package]["Triggers-Awaited"] = (packagedb[package]["Triggers-Awaited"] or "") .. (packagedb[package]["Triggers-Awaited"] and " " or "") .. l
                end
                packages = (packages or "") .. (packages and " " or "") .. l
            end
        end
        file:close()
        --dpkg_query.writeDatabase(packagedb)
        local unlock = dpkg_trigger.lock()
        file = io.open(dir("triggers/Unincorp"), "r")
        local out = fs.open(dir("triggers/Unincorp.new"), "w")
        local found = false
        for v in file:lines() do
            if not found and string.match(v, "^" .. name .. " ") then 
                found = true
                if await then
                    if string.match(v, "[^ ]+ (.+)") == "-" then v = name end
                    v = v .. " " .. package
                end
            end
            out.writeLine(v)
        end
        if not found then out.writeLine(name .. " " .. (await and package or "-")) end
        file:close()
        out.close()
        fs.delete(dir("triggers/Unincorp"))
        fs.move(dir("triggers/Unincorp.new"), dir("triggers/Unincorp"))
        unlock()
        return true, triggerdb, packagedb
    end
end

function dpkg_trigger.commit(package, triggerdb, packagedb)
    packagedb = packagedb or dpkg_query.readDatabase()
    if packagedb[package] == nil then error("Package " .. package .. " not found") end
    local selection, flag, state = string.match(packagedb[package].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
    if packagedb[package]["Triggers-Pending"] == nil or not dpkg_query.status.configured(state) then return false, triggerdb, packagedb end
    local triggers = packagedb[package]["Triggers-Pending"]
    packagedb[package]["Triggers-Pending"] = nil
    local ok
    if shell.environment ~= nil then ok = shell.run("/" .. dir("info/" .. package .. ".postinst"), "triggered", '"' .. triggers .. '"')
    else ok = os.run(_ENV, dir("info/" .. package .. ".postinst"), "triggered", triggers) end
    packagedb[package].Status = selection .. " " .. flag .. (ok and (packagedb[package]["Triggers-Awaited"] and " triggers-awaited" or " installed") or " config-failed")
    local unlock = dpkg_trigger.lock()
    local new = fs.open(dir("triggers/Unincorp.new"), "w")
    for line in io.lines(dir("triggers/Unincorp")) do 
        local trigger = string.gsub(triggers, string.find(triggers, string.match(line, "^([^ ]+)"), 1, true))
        if trigger then
            for _,v in ipairs(split(string.match(line, "^[^ ]+ (.+)"))) do
                if packagedb[v] ~= nil and packagedb[v]["Triggers-Awaited"] ~= nil then
                    packagedb[v]["Triggers-Awaited"] = string.gsub(string.gsub(packagedb[v]["Triggers-Awaited"], "( ?)" .. package .. "( ?)", "%1"), " $", "")
                    if packagedb[v]["Triggers-Awaited"] == "" then
                        packagedb[v]["Triggers-Awaited"] = nil
                        packagedb[v].Status = string.gsub(packagedb[v].Status, "triggers%-awaited", "installed")
                    end
                end
            end
        else new.writeLine(line) end
    end
    new.close()
    fs.delete(dir("triggers/Unincorp"))
    fs.move(dir("triggers/Unincorp.new"), dir("triggers/Unincorp"))
    unlock()
    --dpkg_query.writeDatabase(packagedb)
    return ok and 1 or 0, triggerdb, packagedb
end

if shell and pcall(require, "dpkg-trigger") then
    local args = {}
    local package = _ENV.DPKG_MAINTSCRIPT_PACKAGE
    local await = true
    local act = true
    local nextarg
    for _,v in ipairs({...}) do
        if nextarg then
            if nextarg == 0 then dpkg_trigger.admindir = v; dpkg_query.admindir = v
            elseif nextarg == 1 then package = v end
            nextarg = nil
        elseif v == "--check-supported" then return 0
        elseif v == "-?" or v == "--help" then print([[Usage: dpkg-trigger [<options> ...] <trigger-name>
       dpkg-trigger [<options> ...] <command>

Commands:
  --check-supported                Check if the running dpkg supports triggers.

  -?, --help                       Show this help message.
      --version                    Show the version.

Options:
  --admindir=<directory>           Use <directory> instead of /var/lib/dpkg.
  --by-package=<package>           Override trigger awaiter (normally set
                                   by dpkg).
  --await                          Package needs to await the processing.
  --no-await                       No package needs to await the processing.
  --no-act                         Just test - don't actually change anything.
 ]]); return 0
        elseif v == "--version" then print([[Debian dpkg-trigger package trigger utility version 1.19.0.5 (ComputerCraft).]]); return 0
        elseif v == "--admindir" then nextarg = 0
        elseif string.match(v, "^--admindir=") then dpkg_trigger.admindir = string.sub(v, 12); dpkg_query.admindir = string.sub(v, 12)
        elseif v == "--by-package" then nextarg = 1
        elseif string.match(v, "^--by-package=") then package = string.sub(v, 14)
        elseif v == "--await" then await = true
        elseif v == "--no-await" then await = false
        elseif v == "--no-act" then act = false
        else table.insert(args, v) end
    end
    if args[1] == nil then error([[error: takes one argument, the trigger name

Type dpkg-trigger --help for help about this utility.]]) end
    if package == nil then error([[error: must be called from a maintainer script (or with a --by-package option)

Type dpkg-trigger --help for help about this utility.]]) end
    dpkg_trigger.log = printError
    if act then dpkg_trigger.activate(args[1], package, await) end
    return 0
end

return dpkg_trigger