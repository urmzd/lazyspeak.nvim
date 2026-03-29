local M = {}

---@class lazyspeak.Float
---@field win number?
---@field buf number?
---@field opts { width: number, position: string }
---@field state string
---@field transcript string
---@field agent_text string
local Float = {}
Float.__index = Float

---@param opts? { width?: number, position?: string }
---@return lazyspeak.Float
function Float:new(opts)
	opts = opts or {}
	return setmetatable({
		win = nil,
		buf = nil,
		opts = {
			width = opts.width or 40,
			position = opts.position or "bottom-right",
		},
		state = "idle",
		transcript = "",
		agent_text = "",
	}, Float)
end

function Float:_create_buf()
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	self.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.buf })
	vim.api.nvim_set_option_value("filetype", "lazyspeak", { buf = self.buf })
end

function Float:show()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		return
	end

	self:_create_buf()

	local width = self.opts.width
	local height = 6
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	local col = editor_width - width - 2
	local row = editor_height - height - 4

	self.win = vim.api.nvim_open_win(self.buf, false, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " lazyspeak ",
		title_pos = "left",
		noautocmd = true,
	})

	vim.api.nvim_set_option_value("wrap", true, { win = self.win })
	self:_render()
end

function Float:hide()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		vim.api.nvim_win_close(self.win, true)
	end
	self.win = nil
end

---@param state string
function Float:set_state(state)
	self.state = state
	if state == "idle" or state == "inactive" then
		vim.defer_fn(function()
			if self.state == "idle" or self.state == "inactive" then
				self:hide()
			end
		end, 3000)
	end
	self:_render()
end

---@param text string
function Float:set_transcript(text)
	self.transcript = text
	self:_render()
end

---@param text string
function Float:set_agent_text(text)
	self.agent_text = text
	self:_render()
end

function Float:_render()
	if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
		return
	end

	local lines = {}

	-- State indicator
	local indicators = {
		listening = "  listening...",
		transcribing = "  transcribing...",
		dispatching = "  sending to agent...",
		idle = "  idle",
	}
	table.insert(lines, indicators[self.state] or ("  " .. self.state))
	table.insert(lines, "")

	-- Transcript
	if self.transcript ~= "" then
		table.insert(lines, '  "' .. self.transcript .. '"')
		table.insert(lines, "")
	end

	-- Agent response (truncated)
	if self.agent_text ~= "" then
		local truncated = self.agent_text:sub(1, self.opts.width - 4)
		table.insert(lines, "  " .. truncated)
	end

	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)

	-- Resize window to fit content
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		local height = math.max(#lines, 3)
		vim.api.nvim_win_set_height(self.win, height)
	end
end

M.Float = Float

--- Global state for statusline.
---@type string
M._state = ""

---@param state string
function M.set_state(state)
	M._state = state
end

---@return string
function M.statusline()
	if M._state == "" or M._state == "inactive" then
		return ""
	elseif M._state == "listening" then
		return "ls:mic"
	elseif M._state == "transcribing" then
		return "ls:..."
	elseif M._state == "dispatching" then
		return "ls:>>>"
	else
		return ""
	end
end

return M
