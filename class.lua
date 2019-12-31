local metamethods = {__add=true, __sub=true, __mul=true, __div=true, __mod=true, __pow=true, __unm=true, __concat=true, __len=true, __eq=true, __lt=true, __le=true, __newindex=true, __call=true, __metatable=true}
local function _wrap_method(obj, func, ...)
    local env = getfenv(func)
    env.self = obj
    env.super = setmetatable({}, {__index = getmetatable(obj).__index})
    setfenv(func, env)
    return func(...)
end
local function defineClass(name, meta, def)
    local c, cmt = {__class = name}, {}
    if def.static then for k,v in pairs(def.static) do if metamethods[k] then cmt[k] = v else c[k] = v end end end
    def.static = nil
    if meta.extends then if meta.extends[1] then cmt.__index = function(self, name) for i,v in ipairs(meta.extends) do if v[name] then return v[name] end end end else cmt.__index = meta.extends end end
    local __init = def.__init
    def.__init = nil
    cmt.__call = function(self, ...)
        local omt, supers = {}, {}
        local obj = setmetatable({__class = name}, omt)
        if meta.extends and not __init then if meta.extends[1] then for i,v in ipairs(meta.extends) do supers[i] = v() end omt.__index = function(self, name) for i,v in ipairs(supers) do if v[name] then return v[name] end end end else omt.__index = meta.extends(...) end end
        for k,v in pairs(def) do if type(v) == "function" then obj[k] = function(...) _wrap_method(obj, v, ...) end elseif k ~= "__class" then obj[k] = v end if metamethods[k] then omt[k] = obj[k]; obj[k] = nil end end
        if __init then 
            local env = getfenv(__init)
            env.self = obj
            env.super = setmetatable({}, {__index = omt.__index})
            if meta.extends then if meta.extends[1] then omt.__index = function(self, name) if #supers < #meta.extends then for i,v in ipairs(meta.extends) do supers[i] = v() end end for i,v in ipairs(supers) do if v[name] then return v[name] end end end for i,v in ipairs(meta.extends) do env[v.__class] = function(...) supers[i] = v(...) end end else omt.__index = function(self, name) omt.__index = meta.extends(); return omt.__index[name] end env[meta.extends.__class] = function(...) omt.__index = meta.extends(...) end end end
            setfenv(__init, env)
            __init(...)
            if meta.extends and meta.extends[1] then omt.__index = function(self, name) for i,v in ipairs(supers) do if v[name] then return v[name] end end end end
        end
        return obj
    end
    _G[name] = setmetatable(c, cmt)
    return c
end
return setmetatable({}, {__call = function(self, name) return function(tab) if tab.extends or tab.implements then return function(impl) return defineClass(name, tab, impl) end else return defineClass(name, {}, tab) end end end})