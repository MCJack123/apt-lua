-- dpkg-trigger.lua
-- apt-lua
--
-- This file provides functions that can activate an event for a different
-- package than the one that's being installed.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

admindir = "/var/lib/dpkg"
os.loadAPI("apt-lua/dpkg-query.lua")
local dpkg_query = _G["dpkg-query"]

--[[
    * Triggered packages run `postinst trigger <name>` for each trigger
    * Triggers activated with await will add the trigger to a list and set "trigger-await" on the triggering package and won't configure until cleared
    * Triggers activated with noawait will add the trigger to a list without setting "trigger-await" on the triggering package
    * Both activations will set "trigger-pending" on the triggered package (?)
    * Triggers will be run all at once
]]

function list() return fs.list(fs.combine(admindir, "triggers")) end

function register(name, package)
    local file = fs.open(fs.combine(admindir, "triggers/" .. name), "w")
    file.writeLine(package)
    file.close()
end

function deregister(name) fs.delete(fs.combine(admindir, "triggers/" .. name)) end

function activate(name)
    if not fs.exists(fs.combine(admindir, "triggers/" .. name)) then error("Invalid trigger " .. name, 2) end

end