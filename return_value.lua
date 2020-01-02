if tonumber(..., nil) then return tonumber(..., nil)
elseif ... == "true" then return true
elseif ... == "false" then return false
else return ({...})[1] end
