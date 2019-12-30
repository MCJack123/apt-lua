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

function dpkg_trigger.list() return fs.list(dir("triggers")) end

function dpkg_trigger.readDatabase()
    local file = io.open(dir("triggers/File"), "r")
    if not file then error("Missing trigger file") end
    local retval = {}
    for l in file:lines() do
        local path, package = string.match(l, "([^ ]+) ([^ ]+)")
        retval[path] = {package = package, await = true}
        if string.find(package, "/noawait") then retval[path].await = false end
    end
    file:close()
    return retval
end

function dpkg_trigger.register(name, package, await)
    if await == nil then await = true end
    if string.find(name, "/") then
        local file = fs.open(dir("triggers/File"), fs.exists(dir("triggers/File")) and "a" or "w")
        file.writeLine(name .. " " .. package .. (not await and "/noawait" or ""))
        file.close()
    else
        local file = fs.open(dir("triggers/" .. name), "w")
        file.writeLine(package .. (not await and "/noawait" or ""))
        file.close()
    end
end

function dpkg_trigger.deregister(name) 
    if string.find(name, "/") then
        local file = io.open(dir("triggers/File"), "r")
        if not file then return end
        local retval = ""
        for l in file:lines() do if not string.match(l, "^" .. name .. " ") then retval = retval .. l .. "\n" end end
        file:close()
        file = fs.open(dir("triggers/File"), "w")
        file.write(retval)
        file.close()
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
        packagedb[interest.package].Status = selection .. " " .. flag .. " triggers-pending"
        selection, flag, state = string.match(packagedb[package].Status, "([^ ]+) ([^ ]+) ([^ ]+)")
        if await then 
            packagedb[package].Status = selection .. " " .. flag .. " triggers-awaited" 
            packagedb[package]["Triggers-Awaited"] = (packagedb[package]["Triggers-Awaited"] or "") .. (packagedb[package]["Triggers-Awaited"] and " " or "") .. interest.package
        end
        packagedb[interest.package]["Triggers-Pending"] = (packagedb[interest.package]["Triggers-Pending"] or "") .. (packagedb[interest.package]["Triggers-Pending"] and " " or "") .. name
        dpkg_query.writeDatabase(packagedb)
        local file = io.open(dir("triggers/Unincorp"), "r")
        local lines = {}
        for l in file:lines() do table.insert(lines, l) end
        file:close()
        file = fs.open(dir("triggers/Unincorp"), "w")
        local found = false
        for _,v in ipairs(lines) do
            if not found and string.match(v, "^" .. name .. " ") then
                found = true
                if await then
                    if string.match(v, "[^ ]+ (.+)") == "-" then v = name end
                    v = v .. " " .. package
                end
                file.writeLine(v)
            else file.writeLine(v) end
        end
        if not found then file.writeLine(name .. " " .. (await and package or "-")) end
        file.close()
        return true, triggerdb, packagedb
    else
        -- Explicit trigger
        if not fs.exists(dir("triggers/" .. name)) then error("Invalid trigger " .. name, 2) end
    end
end

function dpkg_trigger.commit(package)

end

return dpkg_trigger