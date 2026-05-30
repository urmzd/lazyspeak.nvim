local M = {}

---@class lazyspeak.Float
---@field win number?
---@field buf number?
---@field opts { width: number, position: string, max_height: number }
---@field state string
---@field transcript string
---@field partial string
---@field agent_text string
---@field thought_text string
---@field tool_calls { id: string?, name: string, status: string? }[]
---@field tool_index table<string, number>
---@field diffs string[]
---@field permission lazyspeak.Permission?
local Float = {}
Float.__index = Float

---@param opts? { width?: number, position?: string, max_height?: number }
---@return lazyspeak.Float
function Float:new(opts)
	opts = opts or {}
	return setmetatable({
		win = nil,
		buf = nil,
		opts = {
			width = opts.width or 40,
			position = opts.position or "bottom-right",
			max_height = opts.max_height or 16,
		},
		state = "idle",
		transcript = "",
		partial = "",
		agent_text = "",
		thought_text = "",
		tool_calls = {},
		tool_index = {},
		diffs = {},
		permission = nil,
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

--- True while the agent turn is active (streaming output or awaiting
--- permission) — used to suppress the idle auto-hide mid-turn.
---@return boolean
function Float:_is_busy()
	return self.state == "dispatching"
		or self.state == "streaming"
		or self.state == "permission"
		or self.permission ~= nil
end

---@param state string
function Float:set_state(state)
	self.state = state
	if (state == "idle" or state == "inactive") and not self:_is_busy() then
		vim.defer_fn(function()
			if (self.state == "idle" or self.state == "inactive") and not self:_is_busy() then
				self:hide()
			end
		end, 3000)
	end
	self:_render()
end

---@param text string
function Float:set_transcript(text)
	self.transcript = text
	self.partial = ""
	self:_render()
end

--- Set the provisional (interim) transcript line shown while still speaking.
---@param text string
function Float:set_partial(text)
	self.partial = text
	self:_render()
end

--- Clear all per-turn agent output. Call when dispatching a new prompt.
function Float:reset_turn()
	self.agent_text = ""
	self.thought_text = ""
	self.tool_calls = {}
	self.tool_index = {}
	self.diffs = {}
	self.permission = nil
	self:_render()
end

--- Append a streamed agent message chunk.
---@param chunk string
function Float:append_agent_text(chunk)
	self.agent_text = self.agent_text .. (chunk or "")
	self:_render()
end

--- Replace the agent text wholesale (kept for backward compatibility).
---@param text string
function Float:set_agent_text(text)
	self.agent_text = text or ""
	self:_render()
end

--- Append a streamed agent thought chunk.
---@param chunk string
function Float:append_thought(chunk)
	self.thought_text = self.thought_text .. (chunk or "")
	self:_render()
end

--- Record or update a tool call (keyed by ACP toolCallId).
---@param ev lazyspeak.Event
function Float:add_tool_call(ev)
	local id = ev.tool_call_id
	local entry = { id = id, name = ev.tool_name or "tool", status = ev.status }
	if id and self.tool_index[id] then
		self.tool_calls[self.tool_index[id]] = entry
	else
		self.tool_calls[#self.tool_calls + 1] = entry
		if id then
			self.tool_index[id] = #self.tool_calls
		end
	end
	self:_render()
end

---@param diff lazyspeak.Diff
function Float:add_diff(diff)
	self.diffs[#self.diffs + 1] = diff.path
	self:_render()
end

---@param perm lazyspeak.Permission
function Float:set_permission(perm)
	self.permission = perm
	self:_render()
end

function Float:clear_permission()
	self.permission = nil
	self:_render()
end

--- Wrap a (possibly multi-line) string to `width` columns.
---@param text string
---@param width number
---@return string[]
local function wrap(text, width)
	local out = {}
	for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
		if para == "" then
			out[#out + 1] = ""
		else
			local line = ""
			for word in para:gmatch("%S+") do
				if #line == 0 then
					line = word
				elseif #line + 1 + #word <= width then
					line = line .. " " .. word
				else
					out[#out + 1] = line
					line = word
				end
			end
			if #line > 0 then
				out[#out + 1] = line
			end
		end
	end
	return out
end

function Float:_render()
	if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
		return
	end

	local w = self.opts.width - 2
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end
	local function add_wrapped(prefix, text)
		for _, l in ipairs(wrap(text, w - #prefix)) do
			add("  " .. prefix .. l)
		end
	end

	-- State indicator.
	local indicators = {
		starting_server = "  starting STT server...",
		starting_daemon = "  starting daemon...",
		ready = "  press <Space> to record",
		listening = "  recording... <Space> to send",
		transcribing = "  transcribing...",
		dispatching = "  sending to agent...",
		streaming = "  agent working...",
		permission = "  awaiting permission",
		idle = "  idle",
	}
	add(indicators[self.state] or ("  " .. self.state))

	-- Provisional partial transcript (shown while still speaking).
	if self.partial ~= "" and self.transcript == "" then
		add("")
		add_wrapped("~ ", self.partial)
	end

	-- Final transcript (the user's words).
	if self.transcript ~= "" then
		add("")
		add_wrapped('" ', self.transcript)
	end

	-- Agent thinking (dimmed via prefix).
	if self.thought_text ~= "" then
		add("")
		add("  thinking:")
		add_wrapped("  ", self.thought_text)
	end

	-- Agent response.
	if self.agent_text ~= "" then
		add("")
		add_wrapped("", self.agent_text)
	end

	-- Tool calls.
	if #self.tool_calls > 0 then
		add("")
		for _, tc in ipairs(self.tool_calls) do
			local status = tc.status and (" [" .. tc.status .. "]") or ""
			add("  • " .. tc.name .. status)
		end
	end

	-- File edits.
	for _, path in ipairs(self.diffs) do
		add("  ~ " .. vim.fn.fnamemodify(path, ":."))
	end

	-- Permission prompt.
	if self.permission then
		add("")
		add_wrapped("? ", self.permission.title)
		for i, opt in ipairs(self.permission.options or {}) do
			add(("  [%d] %s"):format(i, opt.name or opt.optionId))
		end
	end

	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)

	-- Resize and follow the bottom.
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		local height = math.min(math.max(#lines, 3), self.opts.max_height)
		vim.api.nvim_win_set_height(self.win, height)
		pcall(vim.api.nvim_win_set_cursor, self.win, { #lines, 0 })
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
