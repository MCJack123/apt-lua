-- dpkg.lua
-- apt-lua
--
-- This file is the actual dpkg script. It manages installation, removal,
-- configuration, and other functions. Frontends can import this script to
-- automate installation.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

local class = require "class"
local diff = require "diff"
local dpkg_control = require "dpkg-control"
local dpkg_deb = require "dpkg-deb"
local dpkg_divert = require "dpkg-divert"
local dpkg_query = require "dpkg-query"
local dpkg_trigger = require "dpkg-trigger"
local md5 = require "md5"
local tar = require "tar"

--[[ Actions:
* Install package
    * Unpack deb to root
    * Configure package
    * Run triggers
* Remove package
* Purge config files
* Verify packages
* Audit packages
* Update available package list
* Assert features
* Validate string
* Compare versions
* Interface with dpkg-deb
    * -b, -c, -e, -x, -X, -f, --ctrl-tarfile, --fsys-tarfile, -I
* Interface with dpkg-query
    * -l, -s, -L, -S, -p
]]

local dpkg = {}
dpkg.admindir = "/var/lib/dpkg"
dpkg.write = write
dpkg.print = print
dpkg.read = read
dpkg.warn = function(text) print("dpkg: warning: " .. text) end
dpkg.error = function(text)
    term.blit("dpkg: error: ", "000000eeeee00", "fffffffffffff")
    print(text)
end
--dpkg.debug = function(text) end
local debugger = peripheral.find("debugger"); dpkg.debug = function(text) if debugger then debugger.print(text) else print("DEBUG: " .. text) end end

local function dir(p) return fs.combine(dpkg.admindir, p) end
local function trim(s) return string.match(s, '^()[%s%z]*$') and '' or string.match(s, '^[%s%z]*(.*[^%s%z])') end
local function readFile(path)
    local file = fs.open(path, "r")
    local retval = file.readAll()
    file.close()
    return retval
end
local function readLines(path)
    local retval = {}
    for l in io.lines(path) do table.insert(retval, l) end
    return retval
end
local function writeFile(path, data)
    local file = fs.open(path, "w")
    file.write(data)
    file.close()
end
local function writeLines(path, lines)
    local file = fs.open(path, "w")
    for _,v in ipairs(lines) do file.writeLine(v) end
    file.close()
end
local function getStatus(package, id) return ({string.match(package.Status, "(%S+) (%S+) (%S+)")})[id] end
local function updateStatus(package, id, status)
    local stati = {string.match(package.Status, "(%S+) (%S+) (%S+)")}
    stati[id] = status
    package.Status = table.concat(stati, " ")
    return package.Status
end
local function split(str, sep)
    local t={}
    for s in string.gmatch(str, "([^"..(sep or "%s").."]+)") do table.insert(t, s) end
    return t
end

local script_unwind = {
    preinst = "postrm",
    prerm = "postinst",
    postrm = "preinst"
}

self = {} -- to silence IDE warnings

dpkg.options = {
    triggers = true,
    pager = true,
    auto_deconfigure = false,
    skip_same_version = false,
    dry_run = false,
    ignore_depends = {},
}

dpkg.force = {
    downgrade = false,
    configure_any = false,
    hold = false,
    remove_reinstreq = false,
    remove_essential = false,
    depends = false,
    depends_version = false,
    breaks = false,
    conflicts = false,
    confmiss = false,
    confmode = nil, -- 0 = always new, 1 = always old, 2 = default, nil = ask
    overwrite = false,
    overwrite_dir = false,
    overwrite_diverted = false,
    statoverride_add = false,
    statoverride_remove = false,
    architecture = false,
    bad_version = false,
    bad_verify = false
}

local package_old = _G.package
dpkg.package = class "package" {
    static = {
        packagedb = nil,
        triggerdb = nil,
        filedb = nil,
        filecount = 0,
        scriptCallStack = {},
        setPackageDB = function(db) dpkg.package.packagedb = db or dpkg_query.readDatabase() end,
        setTriggerDB = function(db) dpkg.package.triggerdb = db or dpkg_trigger.readDatabase() end,
        setFileDB = function(db, count) if db then dpkg.package.filedb, dpkg.package.filecount = db, count else dpkg.package.filedb, dpkg.package.filecount = dpkg_query.readFileLists() end end,
        unwindScriptErrors = function(completion)
            local retval = true
            while #dpkg.package.scriptCallStack > 0 do
                local run = table.remove(dpkg.package.scriptCallStack)
                local res = run.pkg.callMaintainerScript(script_unwind[run.script], "abort-" .. run.args[1], table.unpack(run.args, 2, run.args.n))
                if completion then completion(run.pkg, res, run.script, table.unpack(run.args, 1, run.args.n)) end
                if not res then retval = false end
            end
            return retval
        end,
        clearScriptErrors = function() dpkg.package.scriptCallStack = {} end,
    },
    __init = function(path)
        if fs.exists(path) then 
            local deb = dpkg_deb.load(path, true)
            self.isUnpacked = false
            self.name = deb.name
            self.path = fs.getName(path)
            self.files = deb.data
            self.filelist = nil
            self.control = deb.control
            self.controlArchive = deb.control_archive
            self.conffiles = deb.conffiles
            self.md5sums = deb.md5sums
            self.preinst = deb.preinst
            self.postinst = deb.postinst
            self.prerm = deb.prerm
            self.postrm = deb.postrm
            self.triggers = deb.triggers
        elseif dpkg.package.packagedb ~= nil and dpkg.package.packagedb[path] ~= nil then
            self.isUnpacked = true
            self.name = path
            self.path = nil
            self.files = nil
            self.filelist = fs.exists(dir("info/" .. path .. ".list")) and readLines(dir("info/" .. path .. ".list")) or nil
            self.control = dpkg.package.packagedb[path]
            self.controlArchive = nil
            self.conffiles = fs.exists(dir("info/" .. path .. ".conffiles")) and readLines(dir("info/" .. path .. ".conffiles")) or nil
            if fs.exists(dir("info/" .. path .. ".md5sums")) then
                local md5sums = readFile(dir("info/" .. path .. ".md5sums"))
                self.md5sums = {}
                for line in string.gmatch(md5sums, "[^\n]+") do if string.find(line, "  ") ~= nil then self.md5sums[string.sub(line, string.find(line, "  ") + 2)] = string.sub(line, 1, string.find(line, "  ") - 1) end end
            end
            self.preinst = fs.exists(dir("info/" .. path .. ".preinst")) and readFile(dir("info/" .. path .. ".preinst")) or nil
            self.postinst = fs.exists(dir("info/" .. path .. ".postinst")) and readFile(dir("info/" .. path .. ".postinst")) or nil
            self.prerm = fs.exists(dir("info/" .. path .. ".prerm")) and readFile(dir("info/" .. path .. ".prerm")) or nil
            self.postrm = fs.exists(dir("info/" .. path .. ".postrm")) and readFile(dir("info/" .. path .. ".postrm")) or nil
            self.triggers = fs.exists(dir("info/" .. path .. ".triggers")) and readFile(dir("info/" .. path .. ".triggers")) or nil
        else error("Could not find package " .. path) end
    end,
    callMaintainerScript = function(script, ...)
        -- TODO: Add unwind scripts to track actions
        local path, nostack = nil, false
        if self.isUnpacked or string.sub(script, 1, 1) == '.' then path = dir("info/" .. self.name .. "." .. string.gsub(script, "^%.", ""))
        else path = dir("tmp.ci/" .. script) end
        if string.sub(script, #script) == '!' then nostack = true end
        script = script:gsub("!$", "")
        if not nostack and (...):find("abort") == nil then table.insert(dpkg.package.scriptCallStack, {pkg = self, script = script, args = table.pack(...)}) end
        script = script:gsub("^%.", "")
        if not fs.exists(path) then return true end
        return shell.run(path, ...)
    end,
    unpack = function()
        local self = self
        if self.isUnpacked then 
            dpkg.error("internal error: attempted to unpack package without archive")
            return false
        end
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
            if dpkg.force.hold then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is currently held")
            else
                dpkg.error("package is currently held")
                return false
            end
        end
        if self.control.Architecture ~= "craftos" and self.control.Architecture ~= "all" then
            if dpkg.force.architecture then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is not built for the host architecture")
            else
                dpkg.error("package is not built for the host architecture")
                return false
            end
        end
        -- Write maintainer scripts to temp folder
        if fs.isDir(dir("tmp.ci")) then fs.delete(dir("tmp.ci")) end
        tar.extract(self.controlArchive, dir("tmp.ci"))
        dpkg.print("Preparing to unpack " .. self.path .. " ...")
        -- Check if downgrading
        local downgrade = false
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) == "installed" and dpkg.compareVersions(self.version, dpkg.package.packagedb[self.name].Version) == -1 then
            if dpkg.force.downgrade then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("downgrading " .. self.name .. " from " .. dpkg.package.packagedb[self.name].Version .. " to " .. self.Version)
                downgrade = true
            else
                dpkg.error("attempted to downgrade " .. self.name .. " from " .. dpkg.package.packagedb[self.name].Version .. " to " .. self.Version)
                return false
            end
        end
        -- Check pre-dependencies
        local predepend_errors = {}
        if self.control["Pre-Depends"] ~= nil and not downgrade then
            for _,v in ipairs(split(self.control["Pre-Depends"], ",")) do
                local ok, name = dpkg.checkDependency(v, function(state, package)
                    return dpkg_query.status.configured(state) or (package["Config-Version"] ~= nil and dpkg_query.status.present(state))
                end)
                if not ok then table.insert(predepend_errors, {name, trim(v)}) end
            end
        end
        if #predepend_errors > 0 then
            if dpkg.force.depends then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(predepend_errors) do dpkg.print(" " .. self.name .. " pre-depends on " .. v[2] .. "; however:\n  Package " .. v[1] .. " is not installed.\n") end
            else
                dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(predepend_errors) do dpkg.print(" " .. self.name .. " pre-depends on " .. v[2] .. "; however:\n  Package " .. v[1] .. " is not installed.\n") end
                return false
            end
        end
        -- Check if any packages conflict with this one
        local breaks_errors = {}
        for k,v in pairs(dpkg.package.packagedb) do
            if v.Conflicts and dpkg_query.status.present(getStatus(v.Status, 3)) and dpkg.findRelationship(self.name, self.control.Version, v.Conflicts) then
                table.insert(breaks_errors, k)
            end
        end
        if #breaks_errors > 0 then
            if dpkg.force.conflicts then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("conflicting packages prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(breaks_errors) do dpkg.print(" " .. v .. " conflicts with " .. self.name .. ", however:\n  Package " .. self.name .. " (" .. self.control.Version .. ") is being installed.\n") end
            else
                dpkg.error("conflicting packages prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(breaks_errors) do dpkg.print(" " .. v .. " conflicts with " .. self.name .. ", however:\n  Package " .. self.name .. " (" .. self.control.Version .. ") is being installed.\n") end
                return false
            end
        end
        -- Is this an upgrade?
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) == "installed" then
            dpkg.debug("Upgrading pre-existing package (" .. dpkg.package.packagedb[self.name].Version .. " => " .. self.control.Version .. ")")
            -- Call old prerm with `upgrade <new version>`
            if not self.callMaintainerScript(".prerm", "upgrade", self.control.Version) then
                dpkg.debug("Old package's prerm upgrade failed")
                -- Call new prerm with `failed-upgrade <old version>`
                if not self.callMaintainerScript("prerm!", "failed-upgrade", dpkg.package.packagedb[self.name].Version) then
                    dpkg.debug("New package's prerm failed-upgrade failed")
                    -- Call old postinst with `abort-upgrade <new version>`
                    if dpkg.package.unwindScriptErrors() then
                        -- Leave old package installed
                        dpkg.error("package pre-upgrade script failed to run")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "installed")
                    else
                        dpkg.debug("Old package's postinst abort-upgrade failed")
                        -- Leave old package half-configured
                        dpkg.error("package pre-upgrade script failed to run, and old package failed to revert changes")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-configured")
                    end
                    fs.delete(dir("tmp.ci"))
                    return false
                end
            end
        end
        -- Deconfigure each package that is conflicting
        local conflicts = {}
        do
            local match, name
            if self.control.Breaks ~= nil then for _,v in ipairs(split(self.control.Breaks, ",")) do match, name = dpkg.checkDependency(v); if match then conflicts[name] = 0 end end end
            if self.control.Conflicts ~= nil then for _,v in ipairs(split(self.control.Conflicts, ",")) do match, name = dpkg.checkDependency(v, true); if match then conflicts[name] = 1 end end end
        end
        if not dpkg.options.auto_deconfigure and next(conflicts) ~= nil then
            if dpkg.force.conflicts then dpkg.warn("dependency problems, but unpacking " .. self.name .. " anyway as you requested:")
            else dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":") end
            for v,_ in ipairs(conflicts) do dpkg.print(" " .. v .. " conflicts with " ..  self.name .. ".") end
            if not dpkg.force.conflicts then
                dpkg.unwindScriptErrors()
                fs.delete(dir("tmp.ci"))
                return false
            end
        end
        local found, removed = next(conflicts) and true or false, conflicts
        while found do
            local errors, newremoved = {}, {}
            found = false
            for k,v in pairs(dpkg.package.packagedb) do
                for l,w in pairs(removed) do
                    if (v.Depends and dpkg.findRelationship(l, dpkg.package.packagedb[l].Version, v.Depends)) or (v["Pre-Depends"] and dpkg.findRelationship(l, dpkg.package.packagedb[l].Version, v["Pre-Depends"])) then
                        found = true
                        newremoved[k] = (v["Pre-Depends"] and dpkg.findRelationship(l, dpkg.package.packagedb[l].Version, v["Pre-Depends"])) and 1 or 0
                        local deconf = dpkg.package(k)
                        dpkg.debug("Deconfiguring " .. k .. " since it depends on conflicting package " .. l)
                        if deconf.prerm then
                            if deconf.callMaintainerScript("prerm", "deconfigure", "in-favour", self.name, self.control.Version, "removing", l, dpkg.package.packagedb[l].Version) then
                                v["Config-Version"] = v.Version
                                updateStatus(v, 3, "unpacked")
                                -- TODO: add prerm
                            else
                                dpkg.debug("Deconfigure failed.")
                                table.insert(errors, {k, l})
                            end
                        else
                            v["Config-Version"] = v.Version
                            updateStatus(v, 3, "unpacked") 
                        end
                    end
                end
            end
            if #errors > 0 then
                if dpkg.force.depends and dpkg.force.conflicts then
                    dpkg.warn("overriding problem because --force enabled:")
                    dpkg.warn("dependency problems prevent unpacking of " .. self.name .. ":")
                else dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":") end
                for _,v in ipairs(errors) do
                    dpkg.print(" " .. v[1] .. " depends on " .. v[2] .. " which conflicts with " .. self.name .. ", however:")
                    dpkg.print("  deconfiguring " .. v[1] .. " failed\n")
                end
                if not (dpkg.force.depends and dpkg.force.conflicts) then
                    dpkg.package.unwindScriptErrors(function(pkg, res, script)
                        if pkg.name ~= self.name and script == "prerm" then
                            if res then updateStatus(dpkg.package.packagedb[pkg.name], 3, "installed")
                            else updateStatus(dpkg.package.packagedb[pkg.name], 3, "half-configured") end
                        end
                    end)
                    fs.delete(dir("tmp.ci"))
                    return false
                end
            end
            removed = newremoved
        end
        local conflict_errors = {}
        for k,v in pairs(conflicts) do if k ~= self.name then
            local deconf = dpkg.package(k)
            dpkg.debug("Deconfiguring " .. k .. " since it conflicts with the current package")
            if deconf.callMaintainerScript("prerm", "deconfigure", "in-favour", self.name, self.control.Version) then
                dpkg.package.packagedb[k]["Config-Version"] = dpkg.package.packagedb[k].Version
                updateStatus(dpkg.package.packagedb[k], 3, "unpacked")
                if v == 1 then
                    updateStatus(dpkg.package.packagedb[k], 3, "half-installed")
                    if not deconf.callMaintainerScript("prerm", "remove", "in-favour", self.name, self.control.Version) then
                        dpkg.debug("Pre-remove failed, aborting.")
                        table.insert(conflict_errors, k)
                    end
                end
            else
                dpkg.debug("Deconfigure failed, aborting.")
                table.insert(conflict_errors, k)
            end
        end end
        if #conflict_errors > 0 then
            if dpkg.force.conflicts then 
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("dependency problems prevent unpacking of " .. self.name .. ":")
            else dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":") end
            for _,v in ipairs(conflict_errors) do
                dpkg.print(" " .. v .. " conflicts with " ..  self.name .. ", however:")
                dpkg.print("  deconfiguring " .. v .. " failed\n")
            end
            if not dpkg.force.conflicts then
                dpkg.unwindScriptErrors(function(pkg, res, script, ...)
                    if pkg.name ~= self.name and script == "prerm" then
                        if ... == "remove" then
                            if res then updateStatus(dpkg.package.packagedb[pkg.name], 3, "unpacked") end
                        elseif ... == "deconfigure" then
                            if res then updateStatus(dpkg.package.packagedb[pkg.name], 3, "installed")
                            else updateStatus(dpkg.package.packagedb[pkg.name], 3, "half-configured") end
                        end
                    end
                end)
                fs.delete(dir("tmp.ci"))
                return false
            end
        end
        -- Call new preinst
        -- Is this an upgrade?
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" then
            -- Are there config files still installed?
            if getStatus(dpkg.package.packagedb[self.name], 3) ~= "config-files" then
                -- Upgrade
                dpkg.debug("Upgrading from " .. dpkg.package.packagedb[self.name].Version .. " to " .. self.control.Version)
                if not self.callMaintainerScript("preinst!", "upgrade", dpkg.package.packagedb[self.name].Version) then
                    dpkg.debug("New preinst upgrade failed")
                    if self.callMaintainerScript("postrm", "abort-upgrade", dpkg.package.packagedb[self.name].Version) then
                        if self.callMaintainerScript(".postinst", "abort-upgrade", self.control.Version) then
                            dpkg.debug("Leaving package as-is")
                            dpkg.error("package pre-install script failed to upgrade, leaving old version installed")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "installed")
                            dpkg.package.unwindScriptErrors()
                            return false
                        else
                            dpkg.debug("Old postinst abort-upgrade failed")
                            dpkg.error("package pre-install script failed to upgrade, and previous version failed to revert changes")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "unpacked")
                            dpkg.package.unwindScriptErrors()
                            return false
                        end
                    else
                        dpkg.debug("New postrm abort-upgrade failed")
                        dpkg.error("package pre-install script failed to run")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        dpkg.package.unwindScriptErrors()
                        return false
                    end
                end
            else
                -- Install with config files
                dpkg.debug("Installing with config files")
                if not self.callMaintainerScript("preinst", "install", dpkg.package.packagedb[self.name]["Config-Version"]) then
                    dpkg.debug("Preinst install failed")
                    if dpkg.package.unwindScriptErrors() then
                        dpkg.error("package pre-install script failed to install")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "config-files")
                        return false
                    else
                        dpkg.error("package pre-install script failed to run, reinstallation required")
                        updateStatus(dpkg.package.packagedb[self.name], 2, "reinstreq")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        return false
                    end
                end
            end
        else
            -- New install
            dpkg.debug("Installing new")
            if not self.callMaintainerScript("preinst", "install") then
                dpkg.debug("Preinst install failed")
                if dpkg.package.unwindScriptErrors() then
                    dpkg.error("package pre-install script failed to install")
                    updateStatus(dpkg.package.packagedb[self.name], 3, "not-installed")
                    return false
                else
                    dpkg.error("package pre-install script failed to run, reinstallation required")
                    updateStatus(dpkg.package.packagedb[self.name], 2, "reinstreq")
                    updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                    return false
                end
            end
        end
        -- Unpack files
        dpkg.print("Unpacking " .. self.name .. " (" .. self.control.Version .. ") ...")
        self.filelist = {}
        local replaced = {}
        local function unpack_rollback()
            for _,v in ipairs(self.filelist) do if not fs.isDir(v) then
                fs.delete(v .. ".dpkg-new")
                if fs.exists(v .. ".dpkg-old") then fs.move(v .. ".dpkg-old", v) end
            end end
            self.filelist = nil
            if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" then
                if getStatus(dpkg.package.packagedb[self.name], 3) ~= "config-files" then
                    if self.callMaintainerScript("postrm", "abort-upgrade", dpkg.package.packagedb[self.name].Version) then
                        if self.callMaintainerScript(".postinst", "abort-upgrade", self.control.Version) then
                            updateStatus(dpkg.package.packagedb[self.name], 3, "installed")
                            dpkg.package.unwindScriptErrors()
                            return false
                        else
                            dpkg.error("previous version failed to revert changes")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "unpacked")
                            dpkg.package.unwindScriptErrors()
                            return false
                        end
                    else
                        dpkg.error("package post-removal script failed to run")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        dpkg.package.unwindScriptErrors()
                        return false
                    end
                else
                    if dpkg.package.unwindScriptErrors() then
                        updateStatus(dpkg.package.packagedb[self.name], 3, "config-files")
                        return false
                    else
                        dpkg.error("package post-remove script failed to run, reinstallation required")
                        updateStatus(dpkg.package.packagedb[self.name], 2, "reinstreq")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        return false
                    end
                end
            else
                if dpkg.package.unwindScriptErrors() then
                    updateStatus(dpkg.package.packagedb[self.name], 3, "not-installed")
                    return false
                else
                    dpkg.error("package post-removal script failed to run, reinstallation required")
                    updateStatus(dpkg.package.packagedb[self.name], 2, "reinstreq")
                    updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                    return false
                end
            end
        end
        local movedConfFiles = {}
        for _,v in ipairs(self.files) do
            -- TODO: Fix (relearn) diversions
            local k = v.name:gsub("^./+", "/"):gsub("^[^/]", "/%1")
            dpkg.debug("Writing " .. k)
            if (dpkg.package.filedb[k] ~= nil and dpkg.package.filedb[k] ~= self.name) and v.type == 0 then
                if not (self.control.Replaces and dpkg.findRelationship(dpkg.package.filedb[k], dpkg.package.packagedb[dpkg.package.filedb[k]].Version, self.control.Replaces)) then
                    if (dpkg.force.overwrite_dir and fs.isDir(k)) or (dpkg.force.overwrite and not fs.isDir(k)) then
                        dpkg.warn("overriding problem because --force enabled:")
                        dpkg.print(("dpkg: error processing archive %s:\n trying to overwrite '%s', which is also in package %s %s"):format(self.path, k, dpkg.package.filedb[k], dpkg.package.packagedb[dpkg.package.filedb[k]].Version))
                    else
                        dpkg.print(("dpkg: error processing archive %s:\n trying to overwrite '%s', which is also in package %s %s"):format(self.path, k, dpkg.package.filedb[k], dpkg.package.packagedb[dpkg.package.filedb[k]].Version))
                        return unpack_rollback()
                    end
                else
                    replaced[dpkg.package.filedb[k]] = replaced[dpkg.package.filedb[k]] or {}
                    table.insert(replaced[dpkg.package.filedb[k]], k)
                end
            end
            if v.type == 5 then fs.makeDir(k)
            elseif v.type == 0 then
                if self.md5sums and self.md5sums[k:gsub("^/+", "")] and md5.sumhexa(v.data) ~= self.md5sums[k:gsub("^/+", "")] then
                    dpkg.debug(("Invalid checksum for file %s (expected %s, got %s)"):format(k, self.md5sums[k:gsub("^/+", "")], md5.sumhexa(v.data)))
                    if dpkg.force.bad_verify then
                        dpkg.warn("overriding problem because --force enabled:")
                        dpkg.warn("invalid checksum for file " .. k)
                    else
                        dpkg.error("invalid checksum for file " .. k)
                        return unpack_rollback()
                    end
                end
                if fs.exists(k) then fs.move(k, k .. ".dpkg-old") end
                local file = fs.open(k .. ".dpkg-new", "wb")
                if not file then
                    dpkg.print(("dpkg: error processing archive %s:\n could not open destination file %s.dpkg-new for writing"):format(self.path, k))
                    return unpack_rollback()
                end
                if file.seek then file.write(v.data)
                else for c in string.gmatch(v.data, ".") do file.write(string.byte(c)) end end
                file.close()
                if self.conffiles and self.md5sums and dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" and v.mode == 0 then for _,w in ipairs(self.conffiles) do if w == k and self.md5sums[k] ~= dpkg.package(self.name).md5sums[k] and ((fs.exists(k) and v.data ~= readFile(k)) or not fs.exists(k)) then
                    local mode = fs.exists(k) and dpkg.force.confmode or (dpkg.force.confmiss and 0 or nil)
                    dpkg.print("Configuration file `" .. k .. [['
 ==> Modified (by you or by a script) since installation.
 ==> Package distributor has shipped an updated version.
   What would you like to do about it? Your options are:
    Y or I  : install the package maintainer's version
    N or O  : keep your currently-installed version
      D     : show the differences between the versions
      Z     : start a shell to examine the situation
 The default action is to keep your current version.]])
                    while mode == nil do
                        dpkg.write("*** " .. fs.getName(k) .. " (Y/I/N/O/D/Z) [default=N] ? ")
                        local answer = dpkg.read()
                        if answer == "Y" or answer == "y" or answer == "I" or answer == "i" then mode = 0
                        elseif answer == "N" or answer == "n" or answer == "O" or answer == "o" then mode = 1
                        elseif answer == "D" or answer == "d" then
                            local lines = {}
                            local d = diff.diff(readFile(k), v.data, "\n")
                            for _,x in ipairs(d) do
                                if x[2] == "in" then table.insert(lines, "+++ " .. x[1])
                                elseif x[2] == "out" then table.insert(lines, "--- " .. x[1])
                                else table.insert(lines, "    " .. x[1]) end
                            end
                            if dpkg.options.pager then require("pager")(table.concat(lines, "\n"))
                            else dpkg.print(table.concat(lines, "\n")) end
                        elseif answer == "Z" or answer == "z" then shell.run(shell.environment and "cash" or "shell")
                        elseif answer == "" then mode = 2 end
                    end
                    if mode == 0 then movedConfFiles[k] = true else
                        fs.move(k .. ".dpkg-old", k)
                        fs.move(k .. ".dpkg-new", k .. ".dpkg-dist")
                    end
                end end end
            else dpkg.debug("Unknown type " .. v.type .. " for path " .. k) end
            table.insert(self.filelist, k)
            dpkg_trigger.activate(k, self.name, false, dpkg.package.triggerdb, dpkg.package.packagedb)
        end
        -- Run postrm
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" then
            if not self.callMaintainerScript(".postrm!", "upgrade", self.control.Version) and not self.callMaintainerScript("postrm", "failed-upgrade", dpkg.package.packagedb[self.name].Version) then
                dpkg.debug("postrm upgrade failed")
                if self.callMaintainerScript(".preinst", "abort-upgrade", self.control.Version) then
                    dpkg.debug("Reverting changes")
                    for _,v in ipairs(self.filelist) do if not fs.isDir(v) then
                        fs.delete(v .. ".dpkg-new")
                        if fs.exists(v .. ".dpkg-old") then fs.move(v .. ".dpkg-old", v) end
                    end end
                    self.filelist = nil
                    if not self.callMaintainerScript("postrm", "abort-upgrade", dpkg.package.packagedb[self.name].Version) or not self.callMaintainerScript(".postinst", "abort-upgrade", self.control.Version) then
                        dpkg.debug("postrm/.postinst abort-upgrade failed")
                        dpkg.error("package postrm script failed to finish upgrade, and upgrade failed to abort")
                        updateStatus(self.name, 3, "half-installed")
                        dpkg.package.unwindScriptErrors()
                        return false
                    end
                    dpkg.error("package upgrade failed to finish")
                    updateStatus(self.name, 3, "unpacked")
                    dpkg.package.unwindScriptErrors()
                    return false
                else
                    dpkg.debug("preinst abort-upgrade failed")
                    dpkg.error("package postrm script failed to finish upgrade, and preinst script failed to abort upgrade")
                    updateStatus(self.name, 3, "half-installed")
                    dpkg.package.unwindScriptErrors()
                    return false
                end
            end
            -- Remove files deleted in the new version
            local oldfiles = readLines(dir("info/" .. self.name .. ".list"))
            for _,v in pairs(oldfiles) do 
                local found = false
                for _,w in ipairs(self.filelist) do if v == w then
                    found = true
                    break
                end end
                if not found then 
                    dpkg.debug("Deleting removed file " .. v)
                    fs.delete(v) 
                end
            end
        end
        -- Replace old file lists and maintainer scripts
        writeLines(dir("info/" .. self.name .. ".list"), self.filelist)
        if self.conffiles then writeLines(dir("info/" .. self.name .. ".conffiles"), self.conffiles) end
        if self.md5sums then
            local file = fs.open(dir("info/" .. self.name .. ".md5sums"), "w")
            for k,v in pairs(self.md5sums) do file.writeLine(v .. "  " .. k) end
            file.close()
        end
        -- Add triggers
        if self.triggers then
            local lines = split(self.triggers, '\n')
            for _,v in ipairs(lines) do
                v = trim(v:gsub("#.+$", ""))
                if string.find(v, "interest") == 1 then
                    local tokens = split(v)
                    if tokens[1] == "interest" or tokens[1] == "interest-await" then
                        dpkg_trigger.register(tokens[2], self.name, true)
                    elseif tokens[1] == "interest-noawait" then
                        dpkg_trigger.register(tokens[2], self.name, false)
                    end
                end
            end
            dpkg.package.setTriggerDB()
        end
        for _,v in ipairs {"postinst", "postrm", "preinst", "prerm", "triggers"} do if self[v] then writeFile(dir("info/" .. self.name .. "." .. v), self[v]) end end
        -- Fix file lists & move files into place
        for k,v in pairs(replaced) do
            local list = readLines(dir("info/" .. k .. ".list"))
            for _,w in ipairs(v) do for i,x in ipairs(list) do if w == x then table.remove(list, i); break end end end
            if #list == 0 then
                dpkg.package(k).callMaintainerScript("postrm", "disappear", self.name, self.control.Version)
                for _,w in ipairs {"conffiles", "md5sums", "postinst", "postrm", "preinst", "prerm", "triggers"} do fs.delete(dir("info/" .. k .. "." .. w)) end
                dpkg.package.packagedb[k].Status = "purge ok not-installed"
            else writeLines(dir("info/" .. k .. ".list"), list) end
        end
        for _,v in ipairs(self.filelist) do
            dpkg.package.filedb[v] = self.name
            if fs.exists(v .. ".dpkg-old") and not movedConfFiles[v] then fs.delete(v .. ".dpkg-old") end
            if fs.exists(v .. ".dpkg-new") then fs.move(v .. ".dpkg-new", v) end
        end
        fs.delete(dir("tmp.ci"))
        -- Update status file
        dpkg.package.packagedb[self.name] = dpkg.package.packagedb[self.name] or {}
        for k,v in pairs(self.control) do dpkg.package.packagedb[self.name][k] = v end
        dpkg.package.packagedb[self.name].Status = "install ok unpacked"
        self.isUnpacked = true
        -- Remove conflicting packages
        for k,v in pairs(conflicts) do if v == 1 then dpkg.package(k).remove() end end
        dpkg.package.clearScriptErrors()
        return true
    end,
    configure = function()
        if not self.isUnpacked then
            dpkg.error("internal error: package is not unpacked")
            return false
        end
        if getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
            if dpkg.force.hold then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is currently held")
            else
                dpkg.error("package is currently held")
                return false
            end
        end
        -- Check dependencies
        local depend_errors = {}
        if self.control.Depends ~= nil then
            for _,v in ipairs(split(self.control.Depends, ",")) do
                local ok, name = dpkg.checkDependency(v, function(state, package)
                    return dpkg_query.status.configured(state) or (package["Config-Version"] ~= nil and dpkg_query.status.present(state))
                end)
                if not ok then table.insert(depend_errors, {name, trim(v)}) end
            end
        end
        if #depend_errors > 0 then
            if dpkg.force.depends then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(depend_errors) do dpkg.print(" " .. self.name .. " depends on " .. v[2] .. "; however:\n  Package " .. v[1] .. " is not installed.\n") end
            else
                dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(depend_errors) do dpkg.print(" " .. self.name .. " depends on " .. v[2] .. "; however:\n  Package " .. v[1] .. " is not installed.\n") end
                return false
            end
        end
        -- Check if any packages break this one
        local breaks_errors = {}
        for k,v in pairs(dpkg.package.packagedb) do
            if v.Breaks and dpkg_query.status.get_number(getStatus(v, 3)) >= dpkg_query.status.unpacked and dpkg.findRelationship(self.name, self.control.Version, v.Breaks) then
                table.insert(breaks_errors, k)
            end
        end
        if #breaks_errors > 0 then
            if dpkg.force.breaks then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("conflicting packages prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(breaks_errors) do dpkg.print(" " .. v .. " breaks " .. self.name .. ", however:\n  Package " .. self.name .. " (" .. self.control.Version .. ") is being configured.\n") end
            else
                dpkg.error("conflicting packages prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(breaks_errors) do dpkg.print(" " .. v .. " breaks " .. self.name .. ", however:\n  Package " .. self.name .. " (" .. self.control.Version .. ") is being configured.\n") end
                return false
            end
        end
        dpkg.print("Setting up " .. self.name .. " (" .. self.control.Version .. ") ...")
        -- Configure package
        if not self.callMaintainerScript("postinst!", "configure", self.control["Config-Version"]) then
            dpkg.print("dpkg: an error occurred while configuring " .. self.name)
            updateStatus(dpkg.package.packagedb[self.name], 3, "half-configured")
            return false
        end
        -- Activate any required triggers
        if self.triggers then
            local lines = split(self.triggers, '\n')
            for _,v in ipairs(lines) do
                v = trim(v:gsub("#.+$", ""))
                if string.find(v, "activate") == 1 then
                    local tokens = split(v)
                    if tokens[1] == "activate" or tokens[1] == "activate-await" then
                        dpkg_trigger.activate(tokens[2], self.name, true, dpkg.package.triggerdb, dpkg.package.packagedb)
                    elseif tokens[1] == "activate-noawait" then
                        dpkg_trigger.activate(tokens[2], self.name, false, dpkg.package.triggerdb, dpkg.package.packagedb)
                    end
                end
            end
        end
        -- Process any pending triggers
        if dpkg.package.packagedb[self.name]["Triggers-Pending"] and dpkg.options.triggers then
            dpkg.print("Processing triggers for " .. self.name .. " (" .. self.control.Version .. ") ...")
            dpkg_trigger.commit(self.name, dpkg.package.triggerdb, dpkg.package.packagedb)
        else updateStatus(dpkg.package.packagedb[self.name], 3, "installed") end
        dpkg.package.clearScriptErrors()
        return true
    end,
    remove = function(purge)
        if not self.isUnpacked then
            dpkg.error("internal error: package is not unpacked")
            return false
        end
        if getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
            if dpkg.force.hold then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is currently held")
            else
                dpkg.error("package is currently held")
                return false
            end
        end
        do
            local errors = {}
            for k,v in pairs(dpkg.package.packagedb) do if (v.Depends and dpkg.findRelationship(self.name, self.control.Version, v.Depends)) then table.insert(errors, k) end end
            if #errors > 0 then
                if dpkg.force.depends then dpkg.print("dpkg: " .. self.name .. ": dependency problems, but removing anyway as you requested:")
                else dpkg.error("dependency problems prevent removal of " .. self.name .. ":") end
                for _,v in ipairs(errors) do dpkg.print(" " .. v[1] .. " depends on " .. self.name .. ".") end
                if not dpkg.force.depends then return false end
            end
        end
        -- Call prerm
        if not self.callMaintainerScript("prerm", "remove") then
            dpkg.debug("Prerm failed")
            if dpkg.package.unwindScriptErrors() then
                dpkg.error("prerm failed, leaving installed")
                updateStatus(dpkg.package.packagedb[self.name], 3, "installed")
                return false
            else
                dpkg.error("prerm failed to run")
                updateStatus(dpkg.package.packagedb[self.name], 3, "half-configured")
                return false
            end
        end
        -- Delete non-config files
        local confkeys = {}
        for _,v in ipairs(self.conffiles) do confkeys[v] = true end
        local dirs = {}
        for _,v in ipairs(self.filelist) do
            dpkg.debug("Removing " .. v)
            if not confkeys[v] then if fs.isDir(v) then table.insert(dirs, v) else fs.delete(v) end end
        end
        table.sort(dirs, function(a, b) return #a > #b end)
        for _,v in ipairs(dirs) do if #fs.list(v) == 0 then fs.delete(v) end end
        -- Call postrm
        if not self.callMaintainerScript("postrm", "remove") then
            dpkg.error("postrm failed to run")
            dpkg.package.clearScriptErrors()
            updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
            return false
        end
        -- Remove triggers
        if self.triggers then
            local lines = split(self.triggers, '\n')
            for _,v in ipairs(lines) do
                v = trim(v:gsub("#.+$", ""))
                if string.find(v, "interest") == 1 then
                    local tokens = split(v)
                    dpkg_trigger.deregister(tokens[2])
                end
            end
            dpkg.package.setTriggerDB()
        end
        -- Remove maintainer scripts
        for _,v in ipairs(fs.find(dir("info/" .. self.name .. ".*"))) do 
            local ext = v:match("[^.]+$")
            if not (ext == "postrm" or ext == "conffiles" or ext == "list") then fs.delete(v) end
        end
        updateStatus(dpkg.package.packagedb[self.name], 3, "config-files")
        if not fs.exists(dir("info/" .. self.name .. ".postrm")) and not fs.exists(dir("info/" .. self.name .. ".conffiles")) then
            -- Treat this package as purged since it's pretty much the same
            fs.delete(dir("info/" .. self.name .. ".list"))
            updateStatus(dpkg.package.packagedb[self.name], 3, "not-installed")
            return true
        elseif purge then return self.purge()
        else return true end
    end,
    purge = function()
        if not self.isUnpacked then
            dpkg.error("internal error: package is not unpacked")
            return false
        end
        if getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
            if dpkg.force.hold then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is currently held")
            else
                dpkg.error("package is currently held")
                return false
            end
        end
        for _,v in ipairs(self.conffiles) do fs.delete(v) end
        if not self.callMaintainerScript("postrm", "purge") then
            dpkg.error("postrm failed to run")
            dpkg.package.clearScriptErrors()
            updateStatus(dpkg.package.packagedb[self.name], 3, "config-files")
            return false
        end
        fs.delete(dir("info/" .. self.name .. ".postrm"))
        fs.delete(dir("info/" .. self.name .. ".conffiles"))
        fs.delete(dir("info/" .. self.name .. ".list"))
        updateStatus(dpkg.package.packagedb[self.name], 3, "not-installed")
        return true
    end,
    verify = function()
        if not self.isUnpacked then
            dpkg.error("internal error: package is not unpacked")
            return false
        end
        if getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
            if dpkg.force.hold then
                dpkg.warn("overriding problem because --force enabled:")
                dpkg.warn("package is currently held")
            else
                dpkg.error("package is currently held")
                return false
            end
        end
        if not self.md5sums then
            dpkg.error("cannot verify package: no md5 sums are available")
            return false
        end
        local success = true
        for k,v in pairs(self.md5sums) do
            if md5.sumhexa(readFile(k)) ~= v then
                dpkg.print("dpkg: " .. self.name .. ": checksum failed for file " .. k)
                success = false
            end
        end
        return success
    end,
}
_G.package = package_old

local function compChar(ac, bc)
    if ac == '~' and bc ~= '~' then return 1
    elseif ac ~= '~' and bc == '~' then return -1
    elseif ac == '' and bc ~= '' then return 1
    elseif ac ~= '' and bc == '' then return -1
    elseif string.match(ac, "%a") and not string.match(bc, "%a") then return 1
    elseif not string.match(ac, "%a") and string.match(bc, "%a") then return -1
    elseif ac > bc then return 1
    elseif ac < bc then return -1
    else return 0 end
end

local function compareVersionStrings(a, b)
    if a == b then return 0 end
    while a ~= "" or b ~= "" do
        local a_sub, b_sub
        a_sub, a = string.match(a, "^(%D*)(.*)$")
        b_sub, b = string.match(b, "^(%D*)(.*)$")
        while a_sub ~= "" or b_sub ~= "" do
            local a_sub_sub, b_sub_sub
            a_sub_sub, a_sub = string.match(a_sub, "^(.?)(.*)$")
            b_sub_sub, b_sub = string.match(b_sub, "^(.?)(.*)$")
            local res = compChar(a_sub_sub, b_sub_sub)
            if res ~= 0 then return res end
        end
        if a == "" and b == "" then break end
        a_sub, a = string.match(a, "^(%d*)(.*)$")
        b_sub, b = string.match(b, "^(%d*)(.*)$")
        if tonumber(a_sub) > tonumber(b_sub) then return 1 elseif tonumber(a_sub) < tonumber(b_sub) then return -1 end
    end
    return 0
end

-- Returns -1 if a < b, 0 if a == b, 1 if a > b, nil if invalid
function dpkg.compareVersions(a, b)
    if string.match(a, "^%d+:") or string.match(b, "^%d+:") then
        local a_epoch = tonumber(string.match(a, "^(%d+):") or 0)
        local b_epoch = tonumber(string.match(b, "^(%d+):") or 0)
        a, b = (string.match(a, "^%d+:(.*)") or a), (string.match(b, "^%d+:(.*)") or b)
        if a_epoch < b_epoch then return -1 elseif a_epoch > b_epoch then return 1 end
    end
    local a_version = string.match(a, "^([%w.+-~]+)%-?[%w.+~]*$")
    local b_version = string.match(b, "^([%w.+-~]+)%-?[%w.+~]*$")
    if a_version == nil or b_version == nil then return nil end
    local res = compareVersionStrings(a_version, b_version)
    if res ~= 0 then return res end
    if string.match(a, "%-[^-]+$") or string.match(b, "%-[%w.+~]+$") then
        return compareVersionStrings(string.match(a, "%-([%w.+~]+)$") or "0", string.match(b, "%-([%w.+~]+)$") or "0")
    end
    return 0
end

-- Takes a package name, version, and a relationship string (Depends, Breaks, etc.) and returns whether the relationship applies to the package
function dpkg.findRelationship(package, pkgversion, relationship)
    local version, comparison
    relationship = string.match(trim(relationship), "^(" .. package .. "%s+%([<=>][<=>]?%s*[^ )]+%))") or 
                   string.match(trim(relationship), "[, ](" .. package .. "%s+%([<=>][<=>]?%s*[^ )]+%))") or 
                   string.match(trim(relationship), "^(" .. package .. ")%s*,") or 
                   string.match(trim(relationship), "[, ](" .. package .. ")%s*,") or 
                   string.match(trim(relationship), "^(" .. package .. ")$") or 
                   string.match(trim(relationship), "[, ](" .. package .. ")$")
    if relationship == nil then return false end
    if string.match(relationship, "%S+%s+%([<=>][<=>]?%s*[^ )]+%)") then
        relationship, comparison, version = string.match(relationship, "(%S+)%s+%(([<=>][<=>]?)%s*([^ )]+)%)")
        if not ({["<<"] = true, ["<="] = true, ["="] = true, [">="] = true, [">>"] = true})[comparison] then return nil end
    end
    if version and comparison then
        local res = dpkg.compareVersions(pkgversion, version)
        return (comparison == "<<" and res == -1) or
               (comparison == "<=" and res ~= 1) or
               (comparison == "=" and res == 0) or
               (comparison == ">=" and res ~= -1) or
               (comparison == ">>" and res == 1)
    else return true end
end

-- Takes a string in the form of "package-name[ ({<< | <= | = | >= | >>} version)]", returns whether the dependency can be satisfied
-- Set unpacked to true to return true if it's unpacked, returns configured otherwise
-- unpacked may also be a function that takes a state and the package and returns whether it is valid
-- Returns whether a dependency was found, and if so its name
function dpkg.checkDependency(dep, unpacked)
    local version, comparison
    dep = trim(dep)
    if string.match(dep, "%S+%s+%([<=>][<=>]?%s*[^ )]+%)") then
        dep, comparison, version = string.match(dep, "(%S+)%s+%(([<=>][<=>]?)%s*([^ )]+)%)")
        if not ({["<<"] = true, ["<="] = true, ["="] = true, [">="] = true, [">>"] = true})[comparison] then return nil end
    end
    local pkgs = {}
    if dpkg.package.packagedb[dep] ~= nil then table.insert(pkgs, {dpkg.package.packagedb[dep],  dpkg.package.packagedb[dep].Version}) end
    -- Check for virtual packages (oh god is there a better way to do this?)
    for _,v in pairs(dpkg.package.packagedb) do if v.Provides and string.find(v.Provides, "[, ]" .. dep .. "[(, ]") then
        -- If we're looking for versions, the provider must have a version as well
        if version and string.match(v.Provides, "[, ]" .. dep .. "%s+%(=%s*[^ )]+%)") then
            table.insert(pkgs, {v, string.match(v.Provides, "[, ]" .. dep .. "%s+%(=%s*([^ )]+)%)")})
        elseif not version then
            table.insert(pkgs, {v, v.Version})
        end
    end end
    for _,pkgt in ipairs(pkgs) do
        if dpkg_query.status.configured(getStatus(pkgt[1], 3)) or 
           (unpacked == true and dpkg_query.status.present(getStatus(pkgt[1], 3))) or
           (type(unpacked) == "function" and unpacked(getStatus(pkgt[1], 3), pkgt[1])) then
            if version and comparison and not dpkg.breaks.depends_version then
                local res = dpkg.compareVersions(pkgt[2], version)
                if (comparison == "<<" and res == -1) or
                (comparison == "<=" and res ~= 1) or
                (comparison == "=" and res == 0) or
                (comparison == ">=" and res ~= -1) or
                (comparison == ">>" and res == 1) then return true, pkgt[1].Package end
            else return true, pkgt[1].Package end
        end
    end
    return false, dep
end

-- Loads the databases.
function dpkg.readDatabase()
    dpkg.write("(Reading database ...")
    dpkg.package.setPackageDB()
    dpkg.package.setTriggerDB()
    dpkg.package.setFileDB()
    dpkg.print(" " .. dpkg.package.filecount .. " files and directories installed.)")
end

--[[
    Modes:
    * 0 = install
    * 1 = unpack
    * 2 = configure
    * 3 = triggers only
    * 4 = remove
    * 5 = purge
    * 6 = verify
    * 7 = audit
    * 8 = get selections
    * 9 = set selections
    * 10 = clear selections
    * 11 = validate
    * 12 = compare versions
    * 13 = dpkg-deb
    * 14 = dpkg-query
]]

if shell and pcall(require, "dpkg") then
    local args = {}
    local mode = nil
    local recursive = false
    local only_selected = false
    local validate_type = nil
    local pre_invoke, post_invoke
    local path_exclude, path_include
    for _,v in ipairs({...}) do
        if mode ~= nil then table.insert(args, v)
        elseif string.match(v, "^%-[^-]") then
            local c = string.sub(v, 2, 2)
            if c == 'i' then mode = 0
            elseif c == 'r' then mode = 4
            elseif c == 'P' then mode = 5
            elseif c == 'V' then mode = 6
            elseif c == 'C' then mode = 7
            elseif c == '?' then print([[Temporary help string]]); return
            elseif c == 'D' then -- TODO: add debug arguments
            elseif c == 'b' or c == 'c' or c == 'e' or c == 'x' or c == 'X' or c == 'f' or c == 'I' then mode = 13
            elseif c == 'l' or c == 's' or c == 'L' or c == 'S' or c == 'p' then mode = 14
            elseif c == 'B' then dpkg.options.auto_deconfigure = true
            elseif c == 'R' then recursive = true
            elseif c == 'G' then dpkg.force.downgrade = false
            elseif c == 'O' then only_selected = true
            elseif c == 'E' then dpkg.options.skip_same_version = true end
        else
            local option
            if string.find(v, "=") then v, option = string.match("^(.+)=(.+)$") end
            if v == "--install" then mode = 0
            elseif v == "--unpack" then mode = 1
            elseif v == "--configure" then mode = 2
            elseif v == "--triggers-only" then mode = 3
            elseif v == "--remove" then mode = 4
            elseif v == "--purge" then mode = 5
            elseif v == "--verify" then mode = 6
            elseif v == "--audit" then mode = 7
            -- TODO: maybe add avail?
            elseif v == "--get-selections" then mode = 8
            elseif v == "--set-selections" then mode = 9
            elseif v == "--clear-selections" then mode = 10
            elseif v == "--print-architecture" then print("craftos"); return
            elseif string.match(v, "^%-%-assert%-") then
                if v == "--assert-support-predepends" then return 0
                elseif v == "--assert-working-epoch" then return 0
                elseif v == "--assert-long-filenames" then return 0
                elseif v == "--assert-multi-conrep" then return 1
                elseif v == "--assert-multi-arch" then return 1
                elseif v == "--assert-versioned-provides" then return 0
                else return 2 end
            elseif string.match(v, "^%-%-validate%-") then mode = 11; validate_type = string.match("^%-%-validate%-(.+)")
            elseif v == "--compare-verisons" then mode = 12
            elseif v == "--help" then print([[Temporary help string]]); return
            elseif v == "--force-help" then print([[Temporary force help string]]); return
            elseif v == "--build" or v == "--contents" or v == "--control" or v == "--extract" or v == "--vextract" or v == "--field" or v == "--ctrl-tarfile" or v == "--fsys-tarfile" or v == "--info" then mode = 13
            elseif v == "--list" or v == "--status" or v == "--listfiles" or v == "--search" or v == "--print-avail" then mode = 14
            elseif v == "--auto-deconfigure" then dpkg.options.auto_deconfigure = true
            elseif v == "--debug" then -- TODO: debug
            elseif string.match(v, "^%-%-force%-") or string.match(v, "^%-%-no%-force%-") or string.match(v, "^%-%-refuse%-") then
                local val = string.match(v, "^%-%-force%-") ~= nil
                local thing = v:gsub("^%-%-force%-", ""):gsub("^%-%-no%-force%-", ""):gsub("^%-%-refuse%-", "")
                if thing == "downgrade" then dpkg.force.downgrade = val
                elseif thing == "configure-any" then dpkg.force.configure_any = val
                elseif thing == "hold" then dpkg.force.hold = val
                elseif thing == "remove-reinstreq" then dpkg.force.remove_reinstreq = val
                elseif thing == "remove-essential" then dpkg.force.remove_essential = val
                elseif thing == "depends" then dpkg.force.depends = val
                elseif thing == "depends-version" then dpkg.force.depends_version = val
                elseif thing == "breaks" then dpkg.force.breaks = val
                elseif thing == "conflicts" then dpkg.force.conflicts = val
                elseif thing == "confmiss" then dpkg.force.confmiss = val
                elseif thing == "confnew" and dpkg.force.confmode ~= 2 then dpkg.force.confmode = 0
                elseif thing == "confold" and dpkg.force.confmode ~= 2 then dpkg.force.confmode = 1
                elseif thing == "confdef" then dpkg.force.confmode = 2
                elseif thing == "confask" and dpkg.force.confmode == nil then dpkg.force.confmode = nil -- redundant
                elseif thing == "overwrite" then dpkg.force.overwrite = val
                elseif thing == "overwrite-dir" then dpkg.force.overwrite_dir = val
                elseif thing == "overwrite-diverted" then dpkg.force.overwrite_diverted = val
                elseif thing == "architecture" then dpkg.force.architecture = val
                elseif thing == "bad-version" then dpkg.force.bad_version = val
                elseif thing == "bad-verify" then dpkg.force.bad_verify = val end
            elseif v == "--ignore-depends" then dpkg.options.ignore_depends = split(option, ",")
            elseif v == "--no-act" or v == "--dry-run" or v == "--simulate" then dpkg.options.dry_run = true
            elseif v == "--recursive" then recursive = true
            elseif v == "--admindir" then dpkg.admindir, dpkg_divert.admindir, dpkg_query.admindir, dpkg_trigger.admindir = option, option, option, option
            -- TODO: add instdir
            elseif v == "--selected-only" then only_selected = true
            elseif v == "--skip-same-verison" then dpkg.options.skip_same_version = true
            elseif v == "--pre-invoke" then pre_invoke = option
            elseif v == "--post-invoke" then post_invoke = option
            elseif v == "--path-exclude" then path_exclude = option
            elseif v == "--path-include" then path_include = option
            elseif v == "--no-pager" then dpkg.options.pager = false
            elseif v == "--no-triggers" then dpkg.options.triggers = false
            elseif v == "--triggers" then dpkg.options.triggers = true end
        end
    end
    local function exit(text)
        dpkg.error(text)
        print([[

Type dpkg --help for help about installing and deinstalling packages [*];
Use 'apt' or 'aptitude' for user-friendly package management;
Type dpkg -Dhelp for a list of dpkg debug flag values;
Type dpkg --force-help for a list of forcing options;
Type dpkg-deb --help for help about manipulating *.deb files;

Options marked [*] produce a lot of output !]])
        return 2
    end
    if mode == nil then exit("need an action option") end
    if mode == 0 or mode == 1 then --install, --unpack (since --install == --unpack + --configure)
        if #args == 0 then exit((mode == 0 and "--install" or "--unpack") .. " needs at least one package archive file argument") end
        local pkgs = {}
        for _,v in ipairs(args) do
            v = shell and shell.resolve(v) or v
            if not fs.exists(v) then dpkg.error("cannot access archive '" .. v .. "': No such file or directory"); return 2 end
            if recursive then
                if not fs.isDir(v) then dpkg.error("cannot access directory '" .. v .. "': Not a directory"); return 2 end
                local function getPkgs(dir)
                    for _,w in ipairs(fs.list(dir)) do
                        if fs.isDir(fs.combine(dir, w)) then getPkgs(fs.combine(dir, w))
                        elseif w:match("^.*%.deb$") then
                            dpkg.print("Loading " .. v .. " (this may take a while) ...")
                            local ok, pkg = pcall(dpkg.package, w)
                            if not ok then dpkg.error("cannot access archive '" .. fs.combine(dir, w) .. "': " .. pkg); return 2 end
                            table.insert(pkgs, pkg)
                            os.queueEvent("nosleep")
                            os.pullEvent()
                        end
                    end
                end
                getPkgs(v)
            else
                dpkg.print("Loading " .. v .. " (this may take a while) ...")
                local ok, pkg = pcall(dpkg.package, v)
                if not ok then dpkg.error("cannot access archive '" .. v .. "': " .. pkg); return 2 end
                table.insert(pkgs, pkg)
                os.queueEvent("nosleep")
                os.pullEvent()
            end
        end
        if #pkgs == 0 then dpkg.error("searched, but found no packages (files matching *.deb)"); return 2 end
        local err = {}
        for _,v in ipairs(pkgs) do
            dpkg.print("Selecting previously unselected package " .. v.name .. ".")
            if dpkg.package.packagedb == nil then dpkg.readDatabase() end
            dpkg.package.packagedb[v.name] = dpkg.package.packagedb[v.name] or {Status = "unknown ok not-installed"}
            updateStatus(dpkg.package.packagedb[v.name], 1, "install")
            if not v.unpack() or (mode == 0 and not v.configure()) then table.insert(err, v.name) end
            os.queueEvent("nosleep")
            os.pullEvent()
        end
        if dpkg.options.triggers then for k,v in pairs(dpkg.package.packagedb) do if v["Triggers-Pending"] then
            dpkg.print("Processing triggers for " .. k .. " (" .. v.Version .. ") ...")
            dpkg_trigger.commit(k, dpkg.package.triggerdb, dpkg.package.packagedb)
        end end end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error processing " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 2 then --configure
        if recursive then dpkg.warn("--recursive specified, but this flag is ineffective with --configure") end
        if #args == 0 then exit("--configure needs at least one package name argument") end
        dpkg.readDatabase()
        local err = {}
        if args[1] == "--pending" or args[1] == "-a" then for k,v in pairs(dpkg.package.packagedb) do if dpkg_query.status.needs_configure(getStatus(v, 3)) then 
            local ok, pkg = pcall(dpkg.package, k)
            if not ok or not pkg.configure() then table.insert(err, k) end 
        end end
        else for _,k in ipairs(args) do if dpkg_query.status.needs_configure(getStatus(dpkg.package.packagedb[k], 3)) then 
            local ok, pkg = pcall(dpkg.package, k)
            if not ok or not pkg.configure() then table.insert(err, k) end 
        end end end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error processing " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 3 then --triggers-only
        if recursive then dpkg.warn("--recursive specified, but this flag is ineffective with --triggers-only") end
        if #args == 0 then exit("--triggers-only needs at least one package name argument") end
        dpkg.readDatabase()
        local err = {}
        if args[1] == "--pending" or args[1] == "-a" then
            if dpkg.options.triggers then for k,v in pairs(dpkg.package.packagedb) do if v["Triggers-Pending"] then
                dpkg.print("Processing triggers for " .. k .. " (" .. v.Version .. ") ...")
                dpkg_trigger.commit(k, dpkg.package.triggerdb, dpkg.package.packagedb)
            end end end
        else
            if dpkg.options.triggers then for _,k in ipairs(args) do if dpkg.package.packagedb[k]["Triggers-Pending"] then
                dpkg.print("Processing triggers for " .. k .. " (" .. dpkg.package.packagedb[k].Version .. ") ...")
                dpkg_trigger.commit(k, dpkg.package.triggerdb, dpkg.package.packagedb)
            end end end
        end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error processing " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 4 then --remove
        if recursive then dpkg.warn("--recursive specified, but this flag is ineffective with --remove") end
        if #args == 0 then exit("--remove needs at least one package name argument") end
        dpkg.readDatabase()
        local err = {}
        for _,k in ipairs(args) do
            local ok, pkg = pcall(dpkg.package, k)
            if ok then updateStatus(dpkg.package.packagedb[k], 1, "deinstall") end
            if not ok or not pkg.remove(false) then table.insert(err, k) end
        end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error processing " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 5 then --purge
        if recursive then dpkg.warn("--recursive specified, but this flag is ineffective with --purge") end
        if #args == 0 then exit("--purge needs at least one package name argument") end
        dpkg.readDatabase()
        local err = {}
        for _,k in ipairs(args) do
            local ok, pkg = pcall(dpkg.package, k)
            if ok then updateStatus(dpkg.package.packagedb[k], 1, "deinstall") end
            if not ok or not pkg.remove(true) then table.insert(err, k) end
        end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error processing " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 6 then --verify
        if recursive then dpkg.warn("--recursive specified, but this flag is ineffective with --verify") end
        dpkg.readDatabase()
        local err = {}
        if #args == 0 then for k in pairs(dpkg.package.packagedb) do
            local ok, pkg = pcall(dpkg.package, k)
            if not ok or not pkg.verify() then table.insert(err, k) end
        end else for _,k in ipairs(args) do
            local ok, pkg = pcall(dpkg.package, k)
            if not ok or not pkg.verify() then table.insert(err, k) end
        end end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
        if #err > 0 then
            dpkg.print("dpkg: error verifying " .. table.concat(err, ", "))
            return 2
        else return 0 end
    elseif mode == 7 then --audit
        -- checks for broken packages
    elseif mode == 8 then --get-selections
        dpkg.readDatabase()
        local lines = {}
        if #args == 0 then for k,v in pairs(dpkg.package.packagedb) do if getStatus(v, 3) ~= "not-installed" then table.insert(lines, {k, getStatus(v, 1)}) end end
        else for _,k in ipairs(args) do table.insert(lines, {k, getStatus(dpkg.package.packagedb[k], 1)}) end end
        textutils.tabulate(table.unpack(lines))
    elseif mode == 9 then --set-selections
        -- stdin?
    elseif mode == 10 then --clear-selections
        dpkg.readDatabase()
        for k,v in pairs(dpkg.package.packagedb) do if v.Priority ~= "essential" and v.Priority ~= "required" then updateStatus(v, 1, "deinstall") end end
        dpkg_query.writeDatabase(dpkg.package.packagedb)
    elseif mode == 11 then --validate
        if validate_type == "pkgname" then
        elseif validate_type == "trigname" then
        elseif validate_type == "archname" then
        elseif validate_type == "version" then
        else exit("unknown option --validate-" .. validate_type) end
    elseif mode == 12 then --compare-versions
        if #args < 3 then exit("--compare-versions takes three arguments: <version> <relation> <version>") end
        local res = dpkg.findRelationship("a", args[1], "a (" .. args[2] .. " " .. args[3] .. ")")
        if res == nil then return 2 elseif res == true then return 0 else return 1 end
    elseif mode == 13 then --dpkg-deb
        return shell.run("dpkg-deb", ...)
    elseif mode == 14 then --dpkg-query
        return shell.run("dpkg-query", ...)
    end
end

return dpkg