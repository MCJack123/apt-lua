-- dpkg-deb.lua
-- apt-lua
--
-- This file provides functions to interact with deb packages.
-- This file can be run from the shell.
--
-- Copyright (c) 2019 JackMacWindows.

local ar = require "ar"
local tar = require "tar"
local dpkg_control = require "dpkg-control"
local LibDeflate = require "LibDeflate"

local function trim(s) return string.match(s, '^()[%s%z]*$') and '' or string.match(s, '^[%s%z]*(.*[^%s%z])') end
local function pad(str, len, c) return string.len(str) < len and string.sub(str, 1, len) .. string.rep(c or " ", len - string.len(str)) or str end
local function lpad(str, len, c) return string.len(str) < len and string.rep(c or " ", len - string.len(str)) .. string.sub(str, 1, len) or str end
local function u2cc(p) return bit.band(p, 0x1) * 8 + bit.band(p, 0x2) + bit.band(p, 0x4) / 4 + 4 end
local function cc2u(p) return bit.band(p, 0x8) / 8 + bit.band(p, 0x2) + bit.band(p, 0x1) * 4 end
local verbose = false

local dpkg_deb = {}

function dpkg_deb.load(path, noser, gettar)
    if verbose then print("Loading package...") end
    local arch = ar.load(path)
    if arch == nil then error("Invalid deb file", 2) end
    os.queueEvent("nosleep")
    os.queueEvent(os.pullEvent())
    if #arch < 3 or arch[1].name ~= "debian-binary" or arch[1].data ~= "2.0\n" then error("Invalid deb file", 2) end
    if arch[2].name ~= "control.tar.gz" or arch[3].name ~= "data.tar.gz" then error("Unsupported compression format: " .. arch[2].name .. ", " .. arch[3].name .. ".", 2) end
    if verbose then print("Extracting control...") end
    local control_tar = LibDeflate:DecompressGzip(arch[2].data)
    os.queueEvent(os.pullEvent())
    local control = tar.load(control_tar, false, true)
    if control["."] ~= nil then control = control["."] end
    os.queueEvent(os.pullEvent())
    if verbose then print("Extracting data...") end
    local data_tar = LibDeflate:DecompressGzip(arch[3].data)
    os.queueEvent(os.pullEvent())
    if gettar then return {control_tar, data_tar} end
    local data = tar.load(data_tar, noser, true)
    if data["."] ~= nil and not noser then data = data["."] end
    os.queueEvent(os.pullEvent())
    local retval = {}
    retval.control_size = string.len(arch[2].data)
    retval.data_size = string.len(arch[3].data)
    retval.control_archive = control
    retval.control = dpkg_control.parseControl(control.control.data)
    retval.name = retval.control.Package
    retval.version = retval.control.Version
    retval.section = retval.control.Section
    retval.priority = retval.control.Priority
    if retval.control["Pre-Depends"] ~= nil then retval.predepends = dpkg_control.parseDependencies(retval.control["Pre-Depends"]) end
    if retval.control.Depends ~= nil then retval.depends = dpkg_control.parseDependencies(retval.control.Depends) end
    if retval.control.Recommends ~= nil then retval.recommends = dpkg_control.parseDependencies(retval.control.Recommends) end
    if retval.control.Suggests ~= nil then retval.suggests = dpkg_control.parseDependencies(retval.control.Suggests) end
    if retval.control.Enhances ~= nil then retval.enhances = dpkg_control.parseDependencies(retval.control.Enhances) end
    if retval.control.Breaks ~= nil then retval.breaks = dpkg_control.parseDependencies(retval.control.Breaks) end
    if retval.control.Conflicts ~= nil then retval.conflicts = dpkg_control.parseDependencies(retval.control.Conflicts) end
    if retval.control.Provides ~= nil then retval.provides = dpkg_control.parseDependencies(retval.control.Provides) end
    if retval.control.Replaces ~= nil then retval.replaces = dpkg_control.parseDependencies(retval.control.Replaces) end
    retval.conffiles = {}
    if control.conffiles ~= nil then for line in string.gmatch(control.conffiles.data, "[^\n]+") do table.insert(retval.conffiles, line) end end
    retval.md5sums = {}
    if control.md5sums ~= nil then for line in string.gmatch(control.md5sums.data, "[^\n]+") do if string.find(line, "  ") ~= nil then retval.md5sums[string.sub(line, string.find(line, "  ") + 2)] = string.sub(line, 1, string.find(line, "  ") - 1) end end end
    if control.preinst ~= nil then retval.preinst = control.preinst.data end
    if control.prerm ~= nil then retval.prerm = control.prerm.data end
    if control.postinst ~= nil then retval.postinst = control.postinst.data end
    if control.postrm ~= nil then retval.postrm = control.postrm.data end
    if control.config ~= nil then retval.config = control.config.data end
    if control.triggers ~= nil then retval.triggers = control.triggers.data end
    if control.templates ~= nil then 
        retval.templates = dpkg_control.parseControlList(control.templates.data)
        for k,v in pairs(retval.templates) do 
            local remove = {}
            for l,w in pairs(v) do if string.match(l, "%a+%-[%a@_]+%.UTF%-8") then table.insert(remove, l) end end
            for l,w in pairs(remove) do v[w] = nil end 
        end
    end
    retval.data = data
    return retval
end

local function extract(data, path, link)
    fs.makeDir(path)
    local links = {}
    for k,v in pairs(data) do if k ~= "//" and type(k) == "string" then
        local p = fs.combine(path, k)
        if v["//"] ~= nil then 
            local l = extract(v, p, kernel ~= nil) 
            if kernel then for l,w in pairs(l) do table.insert(links, w) end end
        elseif (v.type == 1 or v.type == 2) and kernel then table.insert(links, v)
        elseif v.type == 0 or v.type == 7 then
            local file = fs.open(p, "wb")
            for s in string.gmatch(v.data, ".") do file.write(string.byte(s)) end
            file.close()
            if kernel and v.owner ~= nil then
                fs.setPermissions(p, "*", u2cc(bit.brshift(v.mode, 6)) + bit.band(v.mode, 0x800) / 0x80)
                if v.ownerName ~= nil and v.ownerName ~= "" then
                    fs.setPermissions(p, users.getUIDFromName(v.ownerName), u2cc(v.mode) + bit.band(v.mode, 0x800) / 0x80)
                    fs.setOwner(p, users.getUIDFromName(v.ownerName))
                else
                    fs.setPermissions(p, v.owner, u2cc(v.mode) + bit.band(v.mode, 0x800) / 0x80)
                    fs.setOwner(p, v.owner)
                end
            end
        elseif v.type ~= nil then print("Unimplemented type " .. v.type) end
        if verbose then print(((v["//"] and v["//"].name or v.name) or "?") .. " => " .. (p or "?")) end
        os.queueEvent(os.pullEvent())
    end end
    if link then return links
    elseif kernel then for k,v in pairs(links) do
        -- soon(tm)
    end end
end

local function strmap(num, str, c)
    local retval = ""
    for i = 1, string.len(str) do retval = retval .. (bit.band(num, bit.blshift(1, string.len(str)-i)) == 0 and c or string.sub(str, i, i)) end
    return retval
end

local function CurrentDate(z)
    local z = math.floor(z / 86400) + 719468
    local era = math.floor(z / 146097)
    local doe = math.floor(z - era * 146097)
    local yoe = math.floor((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365)
    local y = math.floor(yoe + era * 400)
    local doy = doe - math.floor((365 * yoe + yoe / 4 - yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = math.ceil(doy - (153 * mp + 2) / 5 + 1)
    local m = math.floor(mp + (mp < 10 and 3 or -9))
    return y + (m <= 2 and 1 or 0), m, d
end
    
local function CurrentTime(unixTime)
    local hours = math.floor(unixTime / 3600 % 24)
    local minutes = math.floor(unixTime / 60 % 60)
    local seconds = math.floor(unixTime % 60)
    local year, month, day = CurrentDate(unixTime)
    return {
        year = year,
        month = month,
        day = day,
        hours = hours,
        minutes = minutes < 10 and "0" .. minutes or minutes,
        seconds = seconds < 10 and "0" .. seconds or seconds
    }
end

if shell and pcall(require, "dpkg-deb") then
    local mode = nil
    local tarextract = false
    local compress_level = 5
    local showformat = "${Package}\t${Version}\n"
    local uniform_compression = true
    local check = true
    local args = {}
    for k,v in pairs({...}) do
        if v == "-b" or v == "--build" then mode = 0
        elseif v == "-I" or v == "--info" then mode = 1
        elseif v == "-W" or v == "--show" then mode = 2
        elseif v == "-f" or v == "--field" then mode = 3
        elseif v == "-c" or v == "--contents" then mode = 4
        elseif v == "-x" or v == "--extract" then mode = 5
        elseif v == "-X" or v == "--vextract" then mode = 5; verbose = true
        elseif v == '-R' or v == "--raw-extract" then mode = 7
        elseif v == "--ctrl-tarfile" then mode = 5; tarextract = true
        elseif v == "--fsys-tarfile" then mode = 6; tarextract = true
        elseif v == "-e" or v == "--control" then mode = 6
        elseif v == "-?" or v == "--help" then print([[Usage: dpkg-deb [<option> ...] <command>
Commands:
    -b|--build <directory> [<deb>]     Build an archive.
    -c|--contents <deb>                List contents.
    -I|--info <deb> [<cfile> ...]      Show info to stdout.
    -W|--show <deb>                    Show information on package(s)
    -f|--field <deb> [<cfield> ...]    Show field(s) to stdout.
    -e|--control <deb> [<directory>]   Extract control info.
    -x|--extract <deb> <directory>     Extract files.
    -X|--vextract <deb> <directory>    Extract & list files.
    -R|--raw-extract <deb> <directory> Extract control info and files.
    --ctrl-tarfile <deb>               Output control tarfile.
    --fsys-tarfile <deb>               Output filesystem tarfile.
    -?, --help                         Show this help message.
        --version                      Show the version.]]); return 2
        elseif v == "--version" then print("dpkg-deb v1.0\nPart of apt-lua for CraftOS\nCopyright (c) 2019 JackMacWindows."); return 2
        elseif string.find(v, "--showformat=") == 1 then showformat = string.sub(v, 14)
        elseif string.sub(v, 1, 2) == "-z" then compress_level = tonumber(string.sub(v, 3))
        elseif v == "--no-uniform-compression" then uniform_compression = false
        elseif v == "--uniform-compression" then uniform_compression = true
        elseif v == "--nocheck" then check = false
        elseif v == "-v" or v == "--verbose" then verbose = true 
        else table.insert(args, v) end
    end
    showformat = string.gsub(string.gsub(showformat, "\\n", "\n"), "\\t", "\t")
    if mode == 0 then
        if #args < 1 then error("Usage: dpkg-deb [options...] --build <binary-directory> [archive|directory]") end
        local binary_directory = shell.resolve(args[1])
        local output = args[2] and shell.resolve(args[2]) or shell.resolve(binary_directory .. ".deb")
        if not fs.isDir(binary_directory) then error(binary_directory .. " is not a directory")
        elseif not fs.isDir(fs.combine(binary_directory, "DEBIAN")) then error("A subdirectory named DEBIAN is required.") end
        if verbose and fs.isDir(output) then print("Output is a directory, forcing check") end
        if check or fs.isDir(output) then
            local file = fs.open(fs.combine(binary_directory, "DEBIAN/control"), "r")
            if not file then error("Control file not found.") end
            local retval = {}
            local last_key = nil
            local line = file.readLine()
            local i = 1
            while line ~= nil do
                if string.sub(line, 1, 1) == " " and last_key ~= nil then
                    if last_key == "Description" then
                        if type(retval[last_key]) == "string" then retval[last_key] = {Short = retval[last_key], Long = ""} end
                        retval[last_key].Long = retval[last_key].Long .. (string.sub(line, 2) == "." and "\n\n" or string.sub(line, 2))
                    else retval[last_key] = retval[last_key] .. (string.sub(line, 2) == "." and "\n" or string.sub(line, 2)) end
                else
                    if string.find(line, ":") == nil then 
                        file.close()
                        error("Error while checking control (line " .. i .. "): Missing separator\n    " .. line) 
                    end
                    last_key = string.sub(line, 1, (string.find(line, ":")) - 1)
                    retval[last_key] = trim(string.sub(line, (string.find(line, ":")) + 1))
                end
                line = file.readLine()
                i=i+1
            end
            file.close()
            if retval.Package == nil then error("Error while checking control: Missing \"Package\" field") end
            if retval.Version == nil then error("Error while checking control: Missing \"Version\" field") end
            if retval.Architecture == nil then error("Error while checking control: Missing \"Architecture\" field") end
            if retval.Maintainer == nil then error("Error while checking control: Missing \"Maintainer\" field") end
            if retval.Description == nil then error("Error while checking control: Missing \"Description\" field") end
            if fs.isDir(output) then output = fs.combine(output, retval.Package .. "_" .. retval.Version .. "_" .. retval.Architecture .. ".deb") end
            print("Successfully checked package \"" .. retval.Package .. "\".")
        end
        if verbose then print("Creating control archive...") end
        local control_tar = tar.save(tar.pack(fs.combine(binary_directory, "DEBIAN")))
        os.queueEvent("nosleep")
        os.queueEvent(os.pullEvent())
        if verbose then print("Creating data archive...") end
        local data = tar.pack(binary_directory)
        data.DEBIAN = nil
        local data_tar = tar.save(data)
        os.queueEvent(os.pullEvent())
        if verbose then print("Compressing archives...") end
        local control_tar_gz = LibDeflate:CompressGzip(control_tar, {level=uniform_compression and compress_level or 5})
        os.queueEvent(os.pullEvent())
        local data_tar_gz = LibDeflate:CompressGzip(data_tar, {level=compress_level})
        os.queueEvent(os.pullEvent())
        if verbose then print("Writing package...") end
        ar.save({
            {
                name = "debian-binary",
                timestamp = os.epoch and math.floor(os.epoch("utc") / 1000) or 0, 
                owner = 0, 
                group = 0,
                mode = 0x1FF,
                data = "2.0\n"
            },
            {
                name = "control.tar.gz",
                timestamp = os.epoch and math.floor(os.epoch("utc") / 1000) or 0, 
                owner = 0, 
                group = 0,
                mode = 0x1FF,
                data = control_tar_gz
            },
            {
                name = "data.tar.gz",
                timestamp = os.epoch and math.floor(os.epoch("utc") / 1000) or 0, 
                owner = 0, 
                group = 0,
                mode = 0x1FF,
                data = data_tar_gz
            }
        }, output)
    elseif mode == 1 then
        if #args < 1 then error("Usage: dpkg-deb [options...] --info <archive> [control-file-name...]") end
        local deb = load(shell.resolve(args[1]))
        print("new Debian package, version 2.0.")
        print("size " .. deb.data_size .. " bytes: control archive=" .. deb.control_size .. " bytes.")
        local control = {}
        local max = {0, 0, 0}
        for k,v in pairs(deb.control_archive) do if k ~= "//" then
            local lines = 0
            for l in string.gmatch(v.data or "", "[^\n]+") do lines = lines + 1 end
            local p = {tostring(string.len(v.data or "")), tostring(lines), k}
            for l,w in pairs(p) do if string.len(w) + 2 > max[l] then max[l] = string.len(w) + 2 end end
            table.insert(control, p)
        end end
        for k,v in pairs(control) do print(lpad(v[1], max[1]) .. " bytes," .. lpad(v[2], max[2]) .. " lines   " .. pad(v[3], max[3])) end
        print(deb.control_archive.control.data)
    elseif mode == 2 then
        if #args < 1 then error("Usage: dpkg-deb [options...] --show <archive>") end
        local deb = load(shell.resolve(args[1]))
        write(({string.gsub(showformat, "%${(.-)}", deb.control)})[1])
    elseif mode == 3 then
        if #args < 1 then error("Usage: dpkg-deb [options...] --field <archive> [control-field-name...]") end
        local deb = load(shell.resolve(args[1]))
        local function check(v) if type(v) == "table" then return v.Short .. "\n" .. v.Long else return v end end
        for k,v in pairs(deb.control) do
            if #args > 1 then for l,w in pairs(args) do if k == w then print(k .. ": " .. check(v)); break end end
            else print(k .. ": " .. check(v)) end
        end
    elseif mode == 4 then
        if #args < 1 then error("Usage: dpkg-deb [options...] --contents <archive>") end
        local deb = load(shell.resolve(args[1]), true)
        local tmp = {}
        local max = {0, 0, 0, 0, 0}
        for k,v in pairs(deb.data) do
            local date = CurrentTime(v.timestamp or 0)
            local d = string.format("%04d-%02d-%02d %02d:%02d", date.year, date.month, date.day, date.hours, date.minutes)
            local p = {strmap(v.mode + (v.type == 5 and 0x200 or 0), "drwxrwxrwx", "-"), (v.ownerName or v.owner or 0) .. "/" .. (v.groupName or v.group or 0), string.len(v.data or ""), d, v.name .. (v.link and v.link ~= "" and (" -> " .. v.link) or "")}
            for l,w in pairs(p) do if string.len(w) + 1 > max[l] then max[l] = string.len(w) + 1 end end
            table.insert(tmp, p)
        end
        for k,v in pairs(tmp) do
            for l,w in pairs(v) do write((l == 3 and lpad or pad)(w, max[l]) .. (l == 3 and " " or "")) end
            print("")   
        end
    elseif mode ~= nil and mode >= 5 and mode <= 7 then
        if #args < 1 or (not tarextract and mode ~= 6 and #args < 2) then error("Usage: dpkg-deb [options...] --extract <archive> <directory>") end
        local deb = load(shell.resolve(args[1]), false, tarextract)
        local out = args[2] and shell.resolve(args[2]) or (mode == 6 and shell.resolve("DEBIAN") or shell.dir())
        if not tarextract then fs.makeDir(out) end
        if mode ~= 6 then if tarextract then print(deb[2]) else extract(deb.data, out) end end
        if mode ~= 5 then if tarextract then print(deb[1]) else extract(deb.control_archive, mode == 7 and fs.combine(out, "DEBIAN") or out) end end
    else error("Usage: dpkg-deb [options...] <command>") end
end

return dpkg_deb