-- Tape Archive (tar) archiver/unarchiver library (using UStar)
-- Use in the shell or with require

local function trim(s) return string.match(s, '^()[%s%z]*$') and '' or string.match(s, '^[%s%z]*(.*[^%s%z])') end
local function u2cc(p) return bit.band(p, 0x1) * 8 + bit.band(p, 0x2) + bit.band(p, 0x4) / 4 + 4 end
local function cc2u(p) return bit.band(p, 0x8) / 8 + bit.band(p, 0x2) + bit.band(p, 0x1) * 4 end
local function pad(str, len, c) return string.len(str) < len and string.sub(str, 1, len) .. string.rep(c or " ", len - string.len(str)) or str end
local function lpad(str, len, c) return string.len(str) < len and string.rep(c or " ", len - string.len(str)) .. string.sub(str, 1, len) or str end
local function tidx(t, i, ...)
    if i and t[i] == nil then t[i] = {} end
    return i ~= nil and tidx(t[i], ...) or t 
end
local function split(str, sep)
    local t={}
    for s in string.gmatch(str, "([^"..(sep or "%s").."]+)") do table.insert(t, s) end
    return t
end
local verbosity = 0
local ignore_zero = false

local tar = {}

-- Converts a serial list of tar entries into a hierarchy
function tar.unserialize(data)
    local retval = {}
    local links = {}
    for k,v in pairs(data) do
        local components = split(v.name, "/")
        local name = table.remove(components, table.maxn(components))
        local dir = tidx(retval, table.unpack(components))
        if v.type == 0 or v.type == 7 then dir[name] = v 
        elseif v.type == 1 or v.type == 2 then table.insert(links, v) 
        elseif v.type == 5 then dir[name] = {["//"] = v} end
    end
    for k,v in pairs(links) do
        local components = split(v.name, "/")
        local name = table.remove(components, table.maxn(components))
        tidx(retval, table.unpack(components))[name] = tidx(retval, table.unpack(split(v.link, "/")))
    end
    return retval
end

-- Converts a hierarchy into a serial list of tar entries
function tar.serialize(data)
    --if data["//"] == nil then error("Invalid directory " .. data.name) end
    local retval = (data["//"] ~= nil and #data["//"] > 0) and {data["//"]} or {}
    for k,v in pairs(data) do if k ~= "//" then
        if v["//"] ~= nil or v.name == nil then
            local t = table.maxn(retval)
            for l,w in ipairs(tar.serialize(v)) do retval[t+l] = w end
        else table.insert(retval, v) end
    end end
    return retval
end

-- Loads an archive into a table
function tar.load(path, noser, rawdata)
    if not fs.exists(path) and not rawdata then error("Path does not exist", 2) end
    local file 
    if rawdata then
        local s = 1
        file = {
            read = function(num)
                if num then
                    s=s+num
                    return string.sub(path, s-num, s-1)
                end
                s=s+1
                return string.byte(string.sub(path, s-1, s-1))
            end,
            close = function() end,
            seek = true,
        }
    else file = fs.open(path, "rb") end
    local oldread = file.read
    local sum = 0
    local seek = 0
    file.read = function(c) 
        c = c or 1
        if c < 1 then return end
        local retval = nil
        if file.seek then
            retval = oldread(c)
            if retval ~= nil then for ch in retval:gmatch(".") do sum = sum + ch:byte() end end
        else
            for i = 1, c do
                local n = oldread()
                if n == nil then return retval end
                retval = (retval or "") .. string.char(n)
                sum = sum + n
                if i % 1000000 == 0 then
                    os.queueEvent("nosleep")
                    os.pullEvent()
                end
            end
        end
        seek = seek + c
        return retval
    end
    local retval = {}
    local empty_blocks = 0
    while true do
        local data = {}
        sum = 0
        data.name = file.read(100)
        assert(seek % 512 == 100)
        if data.name == nil then break
        elseif data.name == string.rep("\0", 100) then
            file.read(412)
            assert(seek % 512 == 0)
            empty_blocks = empty_blocks + 1
            if empty_blocks == 2 and not ignore_zero then break end
        else
            data.name = trim(data.name)
            data.mode = tonumber(trim(file.read(8)), 8)
            data.owner = tonumber(trim(file.read(8)), 8)
            data.group = tonumber(trim(file.read(8)), 8)
            local size = tonumber(trim(file.read(12)), 8)
            data.timestamp = tonumber(trim(file.read(12)), 8)
            local o = sum
            local checksum = tonumber(trim(file.read(8)), 8)
            sum = o + 256
            local t = file.read()
            data.type = tonumber(t == "\0" and "0" or t) or t
            data.link = trim(file.read(100))
            if trim(file.read(6)) == "ustar" then
                file.read(2)
                data.ownerName = trim(file.read(32))
                data.groupName = trim(file.read(32))
                data.deviceNumber = {tonumber(trim(file.read(8))), tonumber(trim(file.read(8)))}
                if data.deviceNumber[1] == nil and data.deviceNumber[2] == nil then data.deviceNumber = nil end
                data.name = trim(file.read(155)) .. data.name
            end
            file.read(512 - (seek % 512))
            assert(seek % 512 == 0)
            if sum ~= checksum then print("Warning: checksum mismatch for " .. data.name) end
            if size ~= nil and size > 0 then
                data.data = file.read(size)
                if size % 512 ~= 0 then file.read(512 - (seek % 512)) end
            end
            assert(seek % 512 == 0)
            table.insert(retval, data)
        end
        os.queueEvent("nosleep")
        os.pullEvent()
    end
    file.close()
    return noser and retval or tar.unserialize(retval)
end

-- Extracts files from a table or file to a directory
function tar.extract(data, path, link)
    fs.makeDir(path)
    local links = {}
    for k,v in pairs(data) do if k ~= "//" then
        local p = fs.combine(path, k)
        if v["//"] ~= nil then 
            local l = tar.extract(v, p, kernel ~= nil) 
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
        if verbosity > 0 then print(((v["//"] and v["//"].name or v.name) or "?") .. " => " .. (p or "?")) end
        os.queueEvent("nosleep")
        os.pullEvent()
    end end
    if link then return links
    elseif kernel then for k,v in pairs(links) do
        -- soon(tm)
    end end
end

-- Reads a file into a table entry
function tar.read(base, p)
    local file = fs.open(fs.combine(base, p), "rb")
    local retval = {
        name = p,
        mode = fs.getPermissions and cc2u(fs.getPermissions(p, fs.getOwner(p) or 0)) * 0x40 + cc2u(fs.getPermissions(p, "*")) + bit.band(fs.getPermissions(p, "*"), 0x10) * 0x80 or 0x1FF, 
        owner = fs.getOwner and fs.getOwner(p) or 0, 
        group = 0,
        timestamp = os.epoch and math.floor(os.epoch("utc") / 1000) or 0,
        type = 0,
        link = "",
        ownerName = fs.getOwner and users.getShortName(fs.getOwner(p)) or "",
        groupName = "",
        deviceNumber = nil,
        data = ""
    }
    if file.seek then retval.data = file.read(fs.getSize(fs.combine(base, p))) else
        local c = file.read()
        while c ~= nil do 
            retval.data = retval.data .. string.char(c)
            c = file.read()
        end
    end
    file.close()
    return retval
end

-- Packs files in a directory into a table
function tar.pack(base, path)
    if not fs.isDir(base) then return tar.read(base, path) end
    local retval = {["//"] = {
        name = path .. "/",
        mode = fs.getPermissions and cc2u(fs.getPermissions(path, fs.getOwner(path) or 0)) * 0x40 + cc2u(fs.getPermissions(path, "*")) + bit.band(fs.getPermissions(path, "*"), 0x10) * 0x80 or 0x1FF,
        owner = fs.getOwner and fs.getOwner(path) or 0,
        group = 0,
        timestamp = os.epoch and math.floor(os.epoch("utc") / 1000) or 0,
        type = 5,
        link = "",
        ownerName = fs.getOwner and users.getShortName(fs.getOwner(path)) or "",
        groupName = "",
        deviceNumber = nil,
        data = nil
    }}
    if string.sub(base, -1) == "/" then base = string.sub(base, 1, -1) end
    if path and string.sub(path, 1, 1) == "/" then path = string.sub(path, 2) end
    if path and string.sub(path, -1) == "/" then path = string.sub(path, 1, -1) end
    local p = path and (base .. "/" .. path) or base
    for k,v in pairs(fs.list(p)) do
        if fs.isDir(fs.combine(p, v)) then retval[v] = tar.pack(base, path and (path .. "/" .. v) or v)
        else retval[v] = tar.read(base, path and (path .. "/" .. v) or v) end
        if verbosity > 0 then print(fs.combine(p, v) .. " => " .. (path and (path .. "/" .. v) or v)) end
    end
    return retval
end

-- Saves a table to an archive file
function tar.save(data, path, noser)
    if not noser then data = tar.serialize(data) end
    local nosave = path == nil
    local file 
    local seek = 0
    if not nosave then 
        file = fs.open(path, "wb")
        local oldwrite = file.write
        file.write = function(str) 
            for c in string.gmatch(str, ".") do oldwrite(string.byte(c)) end
            seek = seek + string.len(str)
        end
    else file = "" end
    for k,v in pairs(data) do
        local header = ""
        header = header .. pad(string.sub(v.name, -100), 100, "\0")
        header = header .. (v.mode and string.format("%07o\0", v.mode) or string.rep("\0", 8))
        header = header .. (v.owner and string.format("%07o\0", v.owner) or string.rep("\0", 8))
        header = header .. (v.group and string.format("%07o\0", v.group) or string.rep("\0", 8))
        header = header .. (v.data and string.format("%011o\0", string.len(v.data)) or (string.rep("0", 11) .. "\0"))
        header = header .. (v.timestamp and string.format("%011o\0", v.timestamp) or string.rep("\0", 12))
        header = header .. v.type
        header = header .. (v.link and pad(v.link, 100, "\0") or string.rep("\0", 100))
        header = header .. "ustar  \0"
        header = header .. (v.ownerName and pad(v.ownerName, 32, "\0") or string.rep("\0", 32))
        header = header .. (v.groupName and pad(v.groupName, 32, "\0") or string.rep("\0", 32))
        header = header .. (v.deviceNumber and v.deviceNumber[1] and string.format("%07o\0", v.deviceNumber[1]) or string.rep("\0", 8))
        header = header .. (v.deviceNumber and v.deviceNumber[2] and string.format("%07o\0", v.deviceNumber[2]) or string.rep("\0", 8))
        header = header .. (string.len(v.name) > 100 and pad(string.sub(v.name, 1, -101), 155, "\0") or string.rep("\0", 155))
        if string.len(header) < 504 then header = header .. string.rep("\0", 504 - string.len(header)) end
        local sum = 256
        for c in string.gmatch(header, ".") do sum = sum + string.byte(c) end
        header = string.sub(header, 1, 148) .. string.format("%06o\0 ", sum) .. string.sub(header, 149)
        if nosave then file = file .. header else file.write(header) end
        --assert(seek % 512 == 0)
        if v.data ~= nil and v.data ~= "" then 
            if nosave then file = file .. pad(v.data, math.ceil(string.len(v.data) / 512) * 512, "\0") 
            else file.write(pad(v.data, math.ceil(string.len(v.data) / 512) * 512, "\0")) end
        end
    end
    if nosave then file = file .. string.rep("\0", 1024) else file.write(string.rep("\0", 1024)) end
    if nosave then file = file .. string.rep("\0", 10240 - (string.len(file) % 10240)) else file.write(string.rep("\0", 10240 - (seek % 10240))) end
    if not nosave then file.close() end
    os.queueEvent("nosleep")
    os.pullEvent()
    if nosave then return file end
end

-- Actual installer
write("Enter the desired install path: ")
local install_path = read(nil, nil, nil, "/usr/apt-lua")

-- Install dpkg
local temp = false
if not fs.exists(shell.resolve("dpkg-lua.tar")) then
    temp = true
    print("Downloading dpkg-lua...")
    local handle = http.get("https://raw.githubusercontent.com/MCJack123/apt-lua/master/dpkg-lua.tar", nil, true)
    local first = handle.read(1)
    local file = fs.open(shell.resolve("dpkg-lua.tar"), "wb")
    if type(first) == "number" then
        while first ~= nil do
            file.write(first)
            first = handle.read()
        end
    else
        first = first .. handle.read(4095)
        while first ~= nil do
            file.write(first)
            first = handle.read(4096)
        end
    end
    file.close()
    handle.close()
end
print("Unpacking dpkg-lua.tar ...")
local pkg = tar.load(shell.resolve("dpkg-lua.tar"))
tar.extract(pkg, install_path)
if temp then fs.delete(shell.resolve("dpkg-lua.tar")) end
print("Setting up dpkg ...")
fs.makeDir("/var/lib/dpkg/info")
fs.makeDir("/var/lib/dpkg/triggers")
fs.open("/var/lib/dpkg/triggers/File", "w").close()
fs.open("/var/lib/dpkg/triggers/Unincorp", "w").close()
local file = fs.open("/var/lib/dpkg/status", "w")
file.write([[Package: dpkg
Version: 0.2
Architecture: craftos
Maintainer: JackMacWindows <jackmacwindowslinux@gmail.com>
Status: install ok installed
Installed-Size: 427432
Section: package-managers
Essential: yes
Priority: essential
Description: dpkg package manager for CraftOS
 dpkg-lua is a port of Debian's dpkg package manager for CraftOS.
 It supports most of the features available in dpkg.
]])
file.close()
file = fs.open("/var/lib/dpkg/info/dpkg.list", "w")
for k in pairs(pkg) do file.writeLine(install_path .. "/" .. k) end
--file.writeLine("/var\n/var/lib\n/var/lib/dpkg\n/var/lib/dpkg/info\n/var/lib/dpkg/triggers")
file.close()
local md5 = dofile(install_path .. "/md5.lua")
file = fs.open("/var/lib/dpkg/info/dpkg.md5sums", "w")
for k,v in pairs(pkg) do file.writeLine(md5.sumhexa(v.data) .. "  " .. install_path .. "/" .. k) end
file.close()

-- Install apt
temp = false
if not fs.exists(shell.resolve("apt-lua.deb")) then
    temp = true
    local handle = http.get("https://api.github.com/repos/MCJack123/apt-lua/contents/apt-lua.deb")
    if handle.readAll():find("Not Found") then
        temp = -1
        handle.close()
    else
        handle.close()
        print("Downloading apt-lua...")
        handle = http.get("https://raw.githubusercontent.com/MCJack123/apt-lua/master/apt-lua.deb", nil, true)
        local first = handle.read(1)
        file = fs.open(shell.resolve("apt-lua.deb"), "wb")
        if type(first) == "number" then
            while first ~= nil do
                file.write(first)
                first = handle.read()
            end
        else
            first = first .. handle.read(4095)
            while first ~= nil do
                file.write(first)
                first = handle.read(4096)
            end
        end
        file.close()
        handle.close()
    end
end
if temp ~= -1 then
    shell.run(install_path .. "/dpkg -i " .. shell.resolve("apt-lua.deb"))
    if temp then fs.delete(shell.resolve("apt-lua.deb")) end
end

-- Update PATH
write("Would you like apt-lua to be added to your PATH? (y/N) ")
local res = read()
if res == "y" or res == "Y" then
    file = fs.open("/startup.lua", fs.exists("/startup.lua") and "a" or "w")
    file.writeLine("")
    file.writeLine("shell.setPath(shell.path() .. ':" .. install_path .. "')")
    file.close()
    shell.setPath(shell.path() .. ':' .. install_path)
    print("apt-lua has been added to your PATH.")
end
print("Done.")