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
dpkg.print = print

local function dir(p) return fs.combine(dpkg.admindir, p) end
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

local package_old = _G.package
dpkg.package = class "package" {
    static = {
        packagedb = nil,
        triggerdb = nil,
        setPackageDB = function(db) dpkg.package.packagedb = db end,
        setTriggerDB = function(db) dpkg.package.triggerdb = db end
    },
    __init = function(path)
        if fs.exists(path) then 
            local deb = dpkg_deb.load(path)
            self.isUnpacked = false
            self.name = deb.name
            self.files = deb.data
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
            self.files = nil
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
    unpack = function()

    end
}
_G.package = package_old

return dpkg