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

self = {} -- to silence IDE warnings

dpkg.options = {

}

dpkg.force = {
    hold = false,
}

local package_old = _G.package
dpkg.package = class "package" {
    static = {
        packagedb = nil,
        triggerdb = nil,
        filedb = nil,
        filecount = 0,
        setPackageDB = function(db) dpkg.package.packagedb = db or dpkg_query.readDatabase() end,
        setTriggerDB = function(db) dpkg.package.triggerdb = db or dpkg_trigger.readDatabase() end,
        setFileDB = function(db, count) if db then dpkg.package.filedb, dpkg.package.filecount = db, count else dpkg.package.filedb, dpkg.package.filecount = dpkg_query.readFileLists() end end,
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
        else error("Could not find package " .. path) end
    end,
    callMaintainerScript = function(script, ...)
        -- TODO: Add unwind scripts to track actions
        if self.isUnpacked or string.sub(script, 1, 1) == "." then
            if not fs.exists(dir("info/" .. self.name .. "." .. string.gsub(script, "^%.", ""))) then return true end
            return shell.run(dir("info/" .. self.name .. "." .. string.gsub(script, "^%.", "")), ...)
        else
            if not fs.exists(dir("tmp.ci/" .. script)) then return true end
            return shell.run(dir("tmp.ci/" .. script), ...)
        end
    end,
    unpack = function()
        if self.isUnpacked then 
            dpkg.error("internal error: attempted to unpack package without archive")
            return false
        end
        -- Write maintainer scripts to temp folder
        if fs.isDir(dir("tmp.ci")) then fs.delete(dir("tmp.ci")) end
        tar.extract(self.controlArchive, dir("tmp.ci"))
        dpkg.print("Preparing to unpack " .. self.path .. " ...")
        -- Check pre-dependencies
        local predepend_errors = {}
        if self.control["Pre-Depends"] ~= nil then
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
                for _,v in ipairs(predepend_errors) do dpkg.print(" " .. self.name .. " pre-depends on " .. v[1] .. "; however:\n  Package " .. v[2] .. " is not installed.\n") end
            else
                dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(predepend_errors) do dpkg.print(" " .. self.name .. " pre-depends on " .. v[1] .. "; however:\n  Package " .. v[2] .. " is not installed.\n") end
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
            if getStatus(dpkg.package.packagedb[self.name], 1) == "hold" then
                if dpkg.force.hold then
                    dpkg.warn("overriding problem because --force enabled:")
                    dpkg.warn("package is currently held")
                else
                    dpkg.error("package is currently held")
                    return false
                end
            end
            dpkg.debug("Upgrading pre-existing package (" .. dpkg.package.packagedb[self.name].Version .. " => " .. self.control.Version .. ")")
            -- Call old prerm with `upgrade <new version>`
            if not self.callMaintainerScript(".prerm", "upgrade", self.control.Version) then
                dpkg.debug("Old package's prerm upgrade failed")
                -- Call new prerm with `failed-upgrade <old version>`
                if not self.callMaintainerScript("prerm", "failed-upgrade", dpkg.package.packagedb[self.name].Version) then
                    dpkg.debug("New package's prerm failed-upgrade failed")
                    -- Call old postinst with `abort-upgrade <new version>`
                    if self.callMaintainerScript(".postinst", "abort-upgrade", self.control.Version) then
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
                                dpkg.debug("Deconfigure failed, aborting.")
                                if deconf.callMaintainerScript("postinst", "abort-deconfigure", "in-favour", self.name, self.control.Version, "removing", l, dpkg.package.packagedb[l].Version) then
                                    updateStatus(v, 3, "installed")
                                else
                                    updateStatus(v, 3, "half-configured")
                                end
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
                dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":")
                for _,v in ipairs(errors) do
                    dpkg.print(" " .. v[1] .. " depends on " .. v[2] .. " which conflicts with " .. self.name .. ", however:")
                    dpkg.print("  deconfiguring " .. v[1] .. " failed")
                end
                fs.delete(dir("tmp.ci"))
                return false
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
                        if deconf.callMaintainerScript("postinst", "abort-remove", "in-favour", self.name, self.control.Version) then
                            updateStatus(dpkg.package.packagedb[k], 3, "unpacked")
                        end
                        table.insert(conflict_errors, k)
                    end
                end
            else
                dpkg.debug("Deconfigure failed, aborting.")
                if deconf.callMaintainerScript("postinst", "abort-deconfigure", "in-favour", self.name, self.control.Version) then
                    updateStatus(dpkg.package.packagedb[k], 3, "installed")
                else
                    updateStatus(dpkg.package.packagedb[k], 3, "half-configured")
                end
                table.insert(conflict_errors, k)
            end
        end end
        if #conflict_errors > 0 then
            dpkg.error("dependency problems prevent unpacking of " .. self.name .. ":")
            for _,v in ipairs(conflict_errors) do
                dpkg.print(" " .. v[1] .. " depends on " .. v[2] .. " which conflicts with " .. self.name .. ", however:")
                dpkg.print("  deconfiguring " .. v[1] .. " failed")
            end
            fs.delete(dir("tmp.ci"))
            return false
        end
        -- Call new preinst
        -- Is this an upgrade?
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" then
            -- Are there config files still installed?
            if getStatus(dpkg.package.packagedb[self.name], 3) ~= "config-files" then
                -- Upgrade
                dpkg.debug("Upgrading from " .. dpkg.package.packagedb[self.name].Version .. " to " .. self.control.Version)
                if not self.callMaintainerScript("preinst", "upgrade", dpkg.package.packagedb[self.name].Version) then
                    dpkg.debug("New preinst upgrade failed")
                    if self.callMaintainerScript("postrm", "abort-upgrade", dpkg.package.packagedb[self.name].Version) then
                        if self.callMaintainerScript(".postinst", "abort-upgrade", self.control.Version) then
                            dpkg.debug("Leaving package as-is")
                            dpkg.error("package pre-install script failed to upgrade, leaving old version installed")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "installed")
                            return false
                        else
                            dpkg.debug("Old postinst abort-upgrade failed")
                            dpkg.error("package pre-install script failed to upgrade, and previous version failed to revert changes")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "unpacked")
                            return false
                        end
                    else
                        dpkg.debug("New postrm abort-upgrade failed")
                        dpkg.error("package pre-install script failed to run")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        return false
                    end
                end
            else
                -- Install with config files
                dpkg.debug("Installing with config files")
                if not self.callMaintainerScript("preinst", "install", dpkg.package.packagedb[self.name]["Config-Version"]) then
                    dpkg.debug("Preinst install failed")
                    if self.callMaintainerScript("postrm", "abort-install", dpkg.package.packagedb[self.name]["Config-Version"]) then
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
                if self.callMaintainerScript("postrm", "abort-install") then
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
        -- Unpack files
        dpkg.print("Unpacking " .. self.name .. " (" .. self.control.Version .. ") ...")
        self.filelist = {}
        local replaced = {}
        local installed_size = 0
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
                            return false
                        else
                            dpkg.error("previous version failed to revert changes")
                            updateStatus(dpkg.package.packagedb[self.name], 3, "unpacked")
                            return false
                        end
                    else
                        dpkg.error("package post-removal script failed to run")
                        updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                        return false
                    end
                else
                    if self.callMaintainerScript("postrm", "abort-install", dpkg.package.packagedb[self.name]["Config-Version"]) then
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
                if self.callMaintainerScript("postrm", "abort-install") then
                    updateStatus(dpkg.package.packagedb[self.name], 3, "config-files")
                    return false
                else
                    dpkg.error("package post-removal script failed to run, reinstallation required")
                    updateStatus(dpkg.package.packagedb[self.name], 2, "reinstreq")
                    updateStatus(dpkg.package.packagedb[self.name], 3, "half-installed")
                    return false
                end
            end
        end
        for _,v in ipairs(self.files) do
            local k = v.name:gsub("^./+", "/"):gsub("^[^/]", "/%1")
            dpkg.debug("Writing " .. k)
            if (dpkg.package.filedb[k] ~= nil and dpkg.package.filedb[k] ~= self.name) and not fs.isDir(k) then
                if not (self.control.Replaces and dpkg.findRelationship(dpkg.package.filedb[k], dpkg.package.packagedb[dpkg.package.filedb[k]].Version, self.control.Replaces)) then
                    dpkg.print(("dpkg: error processing archive %s:\n trying to overwrite '%s', which is also in package %s %s"):format(self.path, k, dpkg.package.filedb[k], dpkg.package.packagedb[dpkg.package.filedb[k]].Version))
                    return unpack_rollback()
                else
                    replaced[dpkg.package.filedb[k]] = replaced[dpkg.package.filedb[k]] or {}
                    table.insert(replaced[dpkg.package.filedb[k]], k)
                end
            end
            if v.type == 5 then fs.makeDir(k)
            elseif v.type == 0 then
                if self.md5sums and self.md5sums[k:gsub("^/+", "")] and md5.sumhexa(v.data) ~= self.md5sums[k:gsub("^/+", "")] then
                    dpkg.debug(("Invalid checksum for file %s (expected %s, got %s)"):format(k, self.md5sums[k:gsub("^/+", "")], md5.sumhexa(v.data)))
                    dpkg.warn("invalid checksum for file " .. k) -- maybe error?
                end
                installed_size = installed_size + #v.data
                if fs.exists(k) then fs.move(k, k .. ".dpkg-old") end
                local file = fs.open(k .. ".dpkg-new", "wb")
                if not file then
                    dpkg.print(("dpkg: error processing archive %s:\n could not open destination file %s.dpkg-new for writing"):format(self.path, k))
                    return unpack_rollback()
                end
                if file.seek then file.write(v.data)
                else for c in string.gmatch(v.data, ".") do file.write(string.byte(c)) end end
                file.close()
            else dpkg.debug("Unknown type " .. v.type .. " for path " .. k) end
            table.insert(self.filelist, k)
            dpkg_trigger.activate(k, self.name, false, dpkg.package.triggerdb, dpkg.package.packagedb)
        end
        -- Run postrm
        if dpkg.package.packagedb[self.name] ~= nil and getStatus(dpkg.package.packagedb[self.name], 3) ~= "not-installed" then
            if not self.callMaintainerScript(".postrm", "upgrade", self.control.Version) and not self.callMaintainerScript("postrm", "failed-upgrade", dpkg.package.packagedb[self.name].Version) then
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
                        return false
                    end
                    dpkg.error("package upgrade failed to finish")
                    updateStatus(self.name, 3, "unpacked")
                    return false
                else
                    dpkg.debug("preinst abort-upgrade failed")
                    dpkg.error("package postrm script failed to finish upgrade, and preinst script failed to abort upgrade")
                    updateStatus(self.name, 3, "half-installed")
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
            if fs.exists(v .. ".dpkg-old") then fs.delete(v .. ".dpkg-old") end
            if fs.exists(v .. ".dpkg-new") then fs.move(v .. ".dpkg-new", v) end
        end
        fs.delete(dir("tmp.ci"))
        -- Update status file
        dpkg.package.packagedb[self.name] = dpkg.package.packagedb[self.name] or {}
        for k,v in pairs(self.control) do dpkg.package.packagedb[self.name][k] = v end
        dpkg.package.packagedb[self.name]["Installed-Size"] = installed_size
        dpkg.package.packagedb[self.name].Status = "install ok unpacked"
        self.isUnpacked = true
        -- Remove conflicting packages
        for k,v in pairs(conflicts) do
            -- deconfigure(k)
            if v == 1 then 
                -- remove(k)
            end
        end
        return true
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
            if version and comparison then
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

return dpkg