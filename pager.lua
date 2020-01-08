return function(contents)

local foldLines = true

local lines = {}
local pos, hpos = 1, 1
local w, h = term.getSize()
local message = nil
h=h-1

local function readFile()
    lines = {}
    for line in string.gmatch(contents, "[^\n\r]+") do table.insert(lines, ({string.gsub(line, "\t", "    ")})[1]) end
    if foldLines and hpos == 1 then for i = 1, #lines do if #lines[i] > w then
        table.insert(lines, i+1, string.sub(lines[i], w) or "")
        lines[i] = string.sub(lines[i], 1, w - 1)
    end end end
end

local function redrawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    for i = pos, pos + h - 1 do 
        if lines[i] ~= nil then term.write(string.sub(lines[i], hpos)) end 
        term.setCursorPos(1, i - pos + 2)
    end
    term.setCursorPos(1, h+1)
    if message then term.blit(message, string.rep("f", #message), string.rep("0", #message))
    elseif pos >= #lines - h then term.blit("(END)", "fffff", "00000")
    else term.write(":") end
    term.setCursorBlink(true)
end

local function readCommand(prompt, fg, bg)
    term.setCursorPos(1, h+1)
    term.clearLine()
    term.blit(prompt, fg or string.rep("0", #prompt), bg or string.rep("f", #prompt))
    local str = ""
    local c = 1
    while true do
        term.setCursorPos(#prompt + 1, h + 1)
        term.write(str .. string.rep(" ", w - #str - #prompt - 2))
        term.setCursorPos(#prompt + c, h + 1)
        term.setCursorBlink(true)
        local ev, p1 = os.pullEvent()
        if ev == "key" then
            if p1 == keys.backspace then if str == "" then return nil elseif c > 1 then 
                str = string.sub(str, 1, c-2) .. string.sub(str, c)
                c=c-1 
            end
            elseif p1 == keys.left and c > 1 then c = c - 1
            elseif p1 == keys.right and c < #str + 1 then c = c + 1
            elseif p1 == keys.enter or p1 == keys["return"] then return str
            end
        elseif ev == "char" then 
            str = string.sub(str, 1, c-1) .. p1 .. string.sub(str, c) 
            c=c+1
        end
    end
end

local function flashScreen()
    local br, bg, bb = term.getPaletteColor(colors.black)
    term.setPaletteColor(colors.black, term.getPaletteColor(colors.lightGray))
    sleep(0.1)
    term.setPaletteColor(colors.black, term.getPaletteColor(colors.gray))
    sleep(0.05)
    term.setPaletteColor(colors.black, br, bg, bb)
    sleep(0.05)
end

readFile()

local lastQuery = nil

while true do
    redrawScreen()
    local ev, p1, p2, p3 = os.pullEvent()
    local oldMessage = message
    message = nil
    if ev == "key" then
        if p1 == keys.left and hpos > w / 2 then hpos = hpos - w / 2
        elseif p1 == keys.right then hpos = hpos + w / 2
        elseif p1 == keys.up then if pos > 1 then pos = pos - 1 else flashScreen() end
        elseif (p1 == keys.down or p1 == keys.enter or p1 == keys["return"]) then if pos < #lines - h then pos = pos + 1 else flashScreen() end
        elseif p1 == keys.space then if pos < #lines - h then pos = pos + (pos < #lines - 2*h + 1 and h or (#lines - h) - pos) else flashScreen() end
        end
    elseif ev == "char" then
        if p1 == "q" then break 
        elseif p1 == "f" then if pos < #lines - h then pos = pos + (pos < #lines - 2*h + 1 and h or (#lines - h) - pos) else flashScreen() end
        elseif p1 == "b" then if pos > 1 then pos = pos - (pos > h + 1 and h or pos - 1) else flashScreen() end
        elseif p1 == "d" then if pos < #lines - h then pos = pos + (pos < #lines - (1.5*h) + 1 and h / 2 or (#lines - h) - pos) else flashScreen() end
        elseif p1 == "u" then if pos > 1 then pos = pos - (pos > (h / 2) + 1 and (h / 2) or pos - 1) else flashScreen() end
        elseif p1 == "g" or p1 == "<" then pos = 1
        elseif p1 == "G" or p1 == ">" then pos = #lines - h
        elseif p1 == "e" or p1 == "j" then if pos < #lines - h then pos = pos + 1 else flashScreen() end
        elseif p1 == "y" or p1 == "k" then if pos > 1 then pos = pos - 1 else flashScreen() end
        elseif p1 == "K" or p1 == "Y" then pos = pos - 1
        elseif p1 == "J" then pos = pos + 1
        elseif p1 == "/" then
            local query = readCommand("/")
            if query == "" then query = lastQuery end
            if query ~= nil then
                lastQuery = query
                local found = false
                for i = pos + 1, #lines do if string.match(lines[i], query) then
                    pos = i
                    found = true
                    break
                end end
                if pos > #lines - h then pos = #lines - h end
                if not found then message = "Pattern not found" end
            end
        elseif p1 == "?" then
            local query = readCommand("?")
            if query == "" then query = lastQuery end
            if query ~= nil then
                lastQuery = query
                local found = false
                for i = pos - 1, 1, -1 do if string.match(lines[i], query) then
                    pos = i
                    found = true
                    break
                end end
                if pos > #lines - h then pos = #lines - h end
                if not found then message = "Pattern not found" end
            end
        elseif p1 == "n" then
            local found = false
            for i = pos + 1, #lines do if string.match(lines[i], lastQuery) then
                pos = i
                found = true
                break
            end end
            if pos > #lines - h then pos = #lines - h end
            if not found then message = "Pattern not found" end
        elseif p1 == "N" then
            local found = false
            for i = pos - 1, 1, -1 do if string.match(lines[i], lastQuery) then
                pos = i
                found = true
                break
            end end
            if pos > #lines - h then pos = #lines - h end
            if not found then message = "Pattern not found" end
        end
    elseif ev == "term_resize" then
        w, h = term.getSize()
        h=h-1
        readFile()
    elseif ev == "mouse_scroll" then
        if p1 == 1 and pos < #lines - h then pos = pos + 1
        elseif p1 == -1 and pos > 1 then pos = pos - 1 end
    else
        message = oldMessage
    end
end
term.clear()
term.setCursorPos(1, 1)

end