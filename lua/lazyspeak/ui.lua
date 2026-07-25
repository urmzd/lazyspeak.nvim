--- Status line component. All in-editor rendering lives in
--- `lazyspeak.sidebar`; this only exposes the compact state string users embed
--- in lualine and friends.
local M = {}

---@type string
M._state = ""

---@param state string
function M.set_state(state)
	M._state = state
end

---@return string
function M.statusline()
	if M._state == "" or M._state == "inactive" or M._state == "idle" then
		return ""
	elseif M._state == "listening" then
		return "ls:mic"
	elseif M._state == "transcribing" then
		return "ls:..."
	elseif M._state == "dispatching" or M._state == "streaming" then
		return "ls:>>>"
	elseif M._state == "permission" then
		return "ls:???"
	else
		return ""
	end
end

return M
