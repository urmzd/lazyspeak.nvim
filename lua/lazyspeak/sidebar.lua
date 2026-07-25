local M = {}

--- The single lazyspeak surface: a right-hand sidebar rendering the session as
--- a structured conversation, with a fixed status header on top.
---
--- Content is held as a list of typed entries (turn, message, thought, tool,
--- diff, permission, error) and rendered to lines, rather than being appended
--- as raw text. That buys three things: each entry can draw its own frame,
--- streaming re-renders only the entry it touches, and a window resize can
--- re-flow everything from the model.
---
--- Text is hard-wrapped to the window width and `wrap` is off, so box borders
--- and gutters stay aligned instead of being broken up by soft wrapping.
---@class lazyspeak.Sidebar
---@field buf number?
---@field win number?
---@field opts { width: number, position: string }
---@field state string
---@field status table<string, string>
---@field entries table[]
---@field open_kind string?
---@field tool_index table<string, number>
---@field turns number
---@field _timer userdata?
---@field _tick number
local Sidebar = {}
Sidebar.__index = Sidebar

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Header occupies these rows; kept constant so entry offsets stay stable.
--- Rows are: process signals, current phase, contextual hints, rule.
local HEADER_H = 4

--- Highlight groups, linked to standard groups so the sidebar inherits the
--- user's colorscheme. `default = true` means an explicit user override wins.
local HL_LINKS = {
	LazySpeakSignalUp = "DiagnosticOk",
	LazySpeakSignalStarting = "DiagnosticWarn",
	LazySpeakSignalDown = "Comment",
	LazySpeakSignalError = "DiagnosticError",
	LazySpeakPhase = "Identifier",
	LazySpeakHint = "Comment",
	LazySpeakRule = "WinSeparator",
	LazySpeakTurn = "Title",
	LazySpeakMarker = "Special",
	LazySpeakTool = "Function",
	LazySpeakOk = "DiagnosticOk",
	LazySpeakPending = "DiagnosticWarn",
	LazySpeakFail = "DiagnosticError",
	LazySpeakAsk = "WarningMsg",
	LazySpeakHelpTitle = "Title",
	LazySpeakHelpKey = "Constant",
}

local function define_highlights()
	for name, link in pairs(HL_LINKS) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("lazyspeak_highlights", { clear = true }),
	desc = "lazyspeak: re-link sidebar highlights",
	callback = define_highlights,
})

local NS = vim.api.nvim_create_namespace("lazyspeak_sidebar")

--- Signal glyph highlight per state.
local SIGNAL_HL = {
	down = "LazySpeakSignalDown",
	starting = "LazySpeakSignalStarting",
	up = "LazySpeakSignalUp",
	error = "LazySpeakSignalError",
}

local BUSY = {
	starting_server = true,
	downloading_model = true,
	loading_model = true,
	starting_daemon = true,
	transcribing = true,
	dispatching = true,
	streaming = true,
}

local STATE_LABEL = {
	starting_server = "starting STT server...",
	downloading_model = "downloading model",
	loading_model = "loading model...",
	starting_daemon = "starting daemon...",
	ready = "press <Space> to record",
	listening = "recording... <Space> to send",
	transcribing = "transcribing...",
	dispatching = "sending to agent...",
	streaming = "agent working...",
	permission = "awaiting permission",
	idle = "idle",
	inactive = "stopped",
}

--- Signal glyphs for the three background processes.
local SIGNAL = { down = "○", starting = "◐", up = "●", error = "✗" }

--- Result glyphs for tool-call status.
local TOOL_GLYPH = {
	pending = "◐",
	in_progress = "◐",
	completed = "✓",
	failed = "✗",
	error = "✗",
}

---@param s string
---@return number
local function dw(s)
	return vim.fn.strdisplaywidth(s)
end

--- Pad or truncate to an exact display width.
---@param s string
---@param w number
---@return string
local function fit(s, w)
	local d = dw(s)
	if d == w then
		return s
	elseif d < w then
		return s .. string.rep(" ", w - d)
	end
	-- Truncate by display cells, leaving room for an ellipsis.
	local out = ""
	for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
		if dw(out .. ch) > w - 1 then
			break
		end
		out = out .. ch
	end
	return fit(out .. "…", w)
end

--- Hard-wrap text to `width` display cells, honoring explicit newlines and
--- breaking words that are longer than the line.
---@param text string
---@param width number
---@return string[]
local function wrap(text, width)
	if width < 4 then
		width = 4
	end
	local out = {}
	for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
		if para == "" then
			out[#out + 1] = ""
		else
			local line = ""
			for word in para:gmatch("%S+") do
				while dw(word) > width do
					-- A single word longer than the line: split it.
					if line ~= "" then
						out[#out + 1] = line
						line = ""
					end
					local head = ""
					for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
						if dw(head .. ch) > width then
							break
						end
						head = head .. ch
					end
					out[#out + 1] = head
					word = word:sub(#head + 1)
				end
				if line == "" then
					line = word
				elseif dw(line) + 1 + dw(word) <= width then
					line = line .. " " .. word
				else
					out[#out + 1] = line
					line = word
				end
			end
			if line ~= "" then
				out[#out + 1] = line
			end
		end
	end
	if #out == 0 then
		out[1] = ""
	end
	return out
end

---@param opts? { width?: number, position?: string, keys?: table }
---@return lazyspeak.Sidebar
function Sidebar:new(opts)
	opts = opts or {}
	return setmetatable({
		buf = nil,
		win = nil,
		opts = {
			width = opts.width or 48,
			position = opts.position or "right",
		},
		-- Configured keymaps, so hints show what the user actually bound.
		keys = opts.keys or {},
		show_help = false,
		state = "inactive",
		detail = nil,
		status = { stt = "down", daemon = "down", agent = "down" },
		entries = {},
		-- Which entry kind is currently accepting streamed chunks.
		open_kind = nil,
		tool_index = {},
		turns = 0,
		_timer = nil,
		_tick = 0,
	}, Sidebar)
end

function Sidebar:_ensure_buf()
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	self.buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, self.buf, "lazyspeak://session")
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = self.buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = self.buf })
	vim.api.nvim_set_option_value("filetype", "lazyspeak", { buf = self.buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })

	-- Local affordances, advertised in the hint row and the help block.
	vim.keymap.set("n", "?", function()
		self:toggle_help()
	end, { buffer = self.buf, desc = "lazyspeak: toggle help" })
	vim.keymap.set("n", "q", function()
		self:close()
	end, { buffer = self.buf, desc = "lazyspeak: close sidebar" })

	local blank = {}
	for _ = 1, HEADER_H do
		blank[#blank + 1] = ""
	end
	self:_write(0, -1, blank)
	self:_render_header()
	self:_render_all()
end

---@return number
function Sidebar:_width()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		return vim.api.nvim_win_get_width(self.win)
	end
	return self.opts.width
end

---@return boolean
function Sidebar:_at_bottom()
	if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
		return true
	end
	local cur = vim.api.nvim_win_get_cursor(self.win)[1]
	local total = vim.api.nvim_buf_line_count(self.buf)
	return cur >= total - 1
end

---@param start_row number
---@param end_row number
---@param lines string[]
function Sidebar:_write(start_row, end_row, lines)
	if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
		return
	end
	local follow = self:_at_bottom()
	vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf })
	vim.api.nvim_buf_set_lines(self.buf, start_row, end_row, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })
	if follow and self.win and vim.api.nvim_win_is_valid(self.win) then
		local n = vim.api.nvim_buf_line_count(self.buf)
		pcall(vim.api.nvim_win_set_cursor, self.win, { n, 0 })
	end
end

-- Header ---------------------------------------------------------------

--- Keys that are relevant right now. Only globally-bound maps are listed, so a
--- hint is never shown for something that would not work from where the cursor
--- currently is; `?` is the one local affordance and is labelled as such in the
--- help block.
---@return string
function Sidebar:_hint_line()
	local k = self.keys or {}
	local s = self.state
	local parts

	if s == "listening" then
		parts = { "<Space> send", "<Esc> cancel" }
	elseif s == "ready" then
		parts = { "<Space> record", "<Esc> close" }
	elseif s == "permission" then
		parts = { "answer the prompt" }
	elseif s == "streaming" or s == "dispatching" then
		parts = { (k.cancel or "<leader>lc") .. " interrupt" }
	elseif BUSY[s] then
		parts = { "working" }
	else
		parts = { (k.push_to_talk or "<leader>ls") .. " talk", (k.undo or "<leader>lu") .. " undo" }
	end

	parts[#parts + 1] = "? help"
	return table.concat(parts, "   ")
end

--- Rewrite the fixed header rows in place. Never touches the conversation.
function Sidebar:_render_header()
	if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
		return
	end
	local w = self:_width()

	local mark
	if BUSY[self.state] then
		mark = SPINNER[(self._tick % #SPINNER) + 1]
	elseif self.state == "listening" then
		mark = "●"
	else
		mark = "○"
	end

	-- Build the signals row while recording byte ranges, so each glyph can be
	-- coloured by its own state rather than the row sharing one highlight.
	local signal_line = " "
	local spans = {}
	for _, item in ipairs({
		{ "stt", self.status.stt },
		{ "daemon", self.status.daemon },
		{ "agent", self.status.agent },
	}) do
		local glyph = SIGNAL[item[2]] or "○"
		spans[#spans + 1] = {
			from = #signal_line,
			to = #signal_line + #glyph,
			hl = SIGNAL_HL[item[2]] or "LazySpeakSignalDown",
		}
		signal_line = signal_line .. glyph .. " " .. item[1] .. "  "
	end

	local label = STATE_LABEL[self.state] or self.state
	if self.detail and self.detail ~= "" then
		label = label .. " " .. self.detail
	end
	local phase_line = (" %s %s"):format(mark, label)

	self:_write(0, HEADER_H, {
		fit(signal_line, w),
		fit(phase_line, w),
		fit(" " .. self:_hint_line(), w),
		string.rep("─", math.max(4, w)),
	})

	vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, HEADER_H)
	for _, s in ipairs(spans) do
		pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, 0, s.from, {
			end_col = s.to,
			hl_group = s.hl,
		})
	end
	pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, 1, 0, {
		end_row = 2,
		end_col = 0,
		hl_group = "LazySpeakPhase",
	})
	pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, 2, 0, {
		end_row = 3,
		end_col = 0,
		hl_group = "LazySpeakHint",
	})
	pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, 3, 0, {
		end_row = 4,
		end_col = 0,
		hl_group = "LazySpeakRule",
	})
end

-- Entry rendering ------------------------------------------------------

--- A framed block: rounded border with a left title and optional right label.
---@param title string
---@param right string
---@param body string
---@param w number
---@return string[]
local function box(title, right, body, w)
	local inner = math.max(4, w - 4)
	local left_cap = "╭─ " .. title .. " "
	local right_cap = right ~= "" and (" " .. right .. " ─╮") or "─╮"
	local fill = math.max(0, w - dw(left_cap) - dw(right_cap))
	local lines = { left_cap .. string.rep("─", fill) .. right_cap }
	for _, l in ipairs(wrap(body, inner)) do
		lines[#lines + 1] = "│ " .. fit(l, inner) .. " │"
	end
	lines[#lines + 1] = "╰" .. string.rep("─", math.max(0, w - 2)) .. "╯"
	return lines
end

--- A bulleted block: marker line plus an indented body.
---@param marker string
---@param body string
---@param w number
---@return string[]
local function bullet(marker, body, w)
	local lines = { fit(marker, w) }
	if body and body ~= "" then
		for _, l in ipairs(wrap(body, math.max(4, w - 2))) do
			lines[#lines + 1] = "  " .. l
		end
	end
	return lines
end

---@param e table
---@param w number
---@return string[]
function Sidebar:_entry_lines(e, w)
	local out

	if e.kind == "turn" then
		out = box("you", e.time or "", e.text or "", w)
	elseif e.kind == "partial" then
		out = box("you", "…", e.text or "", w)
	elseif e.kind == "message" then
		out = bullet("⏺ agent", e.text, w)
	elseif e.kind == "thought" then
		out = bullet("⏺ thinking", e.text, w)
	elseif e.kind == "tool" then
		local head = "⏺ " .. e.name .. (e.detail and ("(" .. e.detail .. ")") or "")
		out = { fit(head, w) }
		if e.status then
			local glyph = TOOL_GLYPH[e.status] or "·"
			out[#out + 1] = fit("  ⎿ " .. glyph .. " " .. e.status, w)
		end
	elseif e.kind == "permission" then
		out = { fit("⏺ ? " .. (e.title or "allow agent action?"), w) }
		if e.answer then
			out[#out + 1] = fit("  ⎿ " .. e.answer, w)
		end
	elseif e.kind == "error" then
		out = bullet("⏺ ! error", e.text, w)
	elseif e.kind == "note" then
		out = { fit("  " .. (e.text or ""), w) }
	else
		out = { fit(tostring(e.kind), w) }
	end

	out[#out + 1] = ""
	return out
end

--- The key reference. Shown until the first turn arrives, and on demand via
--- `?` or `:LazySpeakHelp`.
---@param w number
---@return string[]
function Sidebar:_help_lines(w)
	local k = self.keys or {}
	local rows = {
		{ k.push_to_talk or "<leader>ls", "talk (starts the daemon)" },
		{ "<Space>", "record, then send" },
		{ "<Esc>", "cancel and dismiss" },
		{ k.cancel or "<leader>lc", "interrupt the agent" },
		{ k.undo or "<leader>lu", "undo the last edit" },
		{ k.sidebar or "<leader>ll", "toggle this sidebar" },
	}

	local keyw = 0
	for _, r in ipairs(rows) do
		keyw = math.max(keyw, dw(r[1]))
	end

	local out = { " Getting started", "" }
	for _, r in ipairs(rows) do
		-- Fall back to two lines per entry when the window is too narrow for
		-- the aligned form.
		local one = "  " .. fit(r[1], keyw) .. "  " .. r[2]
		if dw(one) <= w then
			out[#out + 1] = one
		else
			out[#out + 1] = "  " .. r[1]
			for _, l in ipairs(wrap(r[2], math.max(4, w - 6))) do
				out[#out + 1] = "      " .. l
			end
		end
	end

	local prose = {
		'Say "undo", "cancel", or "revert" to do those hands-free.',
		"Name files explicitly — the agent is not told which buffer you have open or where your cursor is.",
	}
	for _, p in ipairs(prose) do
		out[#out + 1] = ""
		for _, l in ipairs(wrap(p, math.max(4, w - 2))) do
			out[#out + 1] = " " .. l
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = " In this window: ? help   q close"
	out[#out + 1] = ""
	return out
end

--- Whether the key reference is currently on screen.
---@return boolean
function Sidebar:_help_visible()
	return self.show_help or #self.entries == 0
end

function Sidebar:toggle_help()
	self.show_help = not self.show_help
	self:_render_all()
end

--- Rebuild the whole conversation from the entry model. Used on first render
--- and whenever the window width changes.
function Sidebar:_render_all()
	if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
		return
	end
	local w = self:_width()
	local lines = {}
	local help_len = 0
	if self:_help_visible() then
		local hl = self:_help_lines(w)
		help_len = #hl
		vim.list_extend(lines, hl)
	end
	for _, e in ipairs(self.entries) do
		e._start = HEADER_H + #lines
		local el = self:_entry_lines(e, w)
		e._len = #el
		vim.list_extend(lines, el)
	end
	self:_write(HEADER_H, -1, lines)
	self:_highlight(HEADER_H, lines, help_len)
end

--- Apply line-level highlights over a written range. Entry output is generated
--- by this module, so matching on the rendered prefix is deterministic.
---@param start_row number
---@param lines string[]
---@param help_len? number leading lines belonging to the help block
function Sidebar:_highlight(start_row, lines, help_len)
	if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
		return
	end
	vim.api.nvim_buf_clear_namespace(self.buf, NS, start_row, start_row + #lines)
	help_len = help_len or 0

	for i, line in ipairs(lines) do
		local row = start_row + i - 1
		local group

		if i <= help_len then
			group = (i == 1) and "LazySpeakHelpTitle" or "LazySpeakHint"
		elseif line:match("^[╭│╰]") then
			group = "LazySpeakTurn"
		elseif line:match("^⏺ %?") then
			group = "LazySpeakAsk"
		elseif line:match("^⏺ !") then
			group = "LazySpeakFail"
		elseif line:match("^⏺ agent") or line:match("^⏺ thinking") then
			group = "LazySpeakMarker"
		elseif line:match("^⏺ ") then
			group = "LazySpeakTool"
		elseif line:match("^%s+⎿ ✓") then
			group = "LazySpeakOk"
		elseif line:match("^%s+⎿ ✗") then
			group = "LazySpeakFail"
		elseif line:match("^%s+⎿") then
			group = "LazySpeakPending"
		end

		if group then
			pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, row, 0, {
				end_row = row + 1,
				end_col = 0,
				hl_group = group,
			})
		end
	end
end

--- Re-render a single entry in place, shifting the offsets of those below it.
---@param i number
function Sidebar:_render_entry(i)
	local e = self.entries[i]
	if not e then
		return
	end
	if not e._start then
		return self:_render_all()
	end
	local el = self:_entry_lines(e, self:_width())
	local old = e._len or 0
	self:_write(e._start, e._start + old, el)
	local delta = #el - old
	e._len = #el
	if delta ~= 0 then
		for j = i + 1, #self.entries do
			if self.entries[j]._start then
				self.entries[j]._start = self.entries[j]._start + delta
			end
		end
	end
	self:_highlight(e._start, el)
end

--- Append an entry and render it.
---@param e table
---@return number index
function Sidebar:_push(e)
	self:_ensure_buf()
	local was_empty = #self.entries == 0
	self.entries[#self.entries + 1] = e
	-- The empty-state help block occupies the conversation region until the
	-- first entry arrives, so that transition needs a full rebuild.
	if was_empty and not self.show_help then
		self:_render_all()
		return 1
	end
	local el = self:_entry_lines(e, self:_width())
	e._start = vim.api.nvim_buf_line_count(self.buf)
	e._len = #el
	self:_write(e._start, e._start, el)
	self:_highlight(e._start, el)
	return #self.entries
end

--- Drop the last entry (used to retract the provisional transcript).
function Sidebar:_pop()
	local i = #self.entries
	local e = self.entries[i]
	if not e then
		return
	end
	if e._start and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		self:_write(e._start, e._start + (e._len or 0), {})
	end
	self.entries[i] = nil
end

--- Route a streamed chunk into the open entry of `kind`, opening one if the
--- previous entry was something else.
---@param kind string
---@param chunk string
function Sidebar:_stream(kind, chunk)
	if chunk == nil or chunk == "" then
		return
	end
	self:_ensure_buf()
	local i = #self.entries
	if self.open_kind == kind and self.entries[i] and self.entries[i].kind == kind then
		self.entries[i].text = (self.entries[i].text or "") .. chunk
		self:_render_entry(i)
	else
		self.open_kind = kind
		self:_push({ kind = kind, text = chunk })
	end
end

-- Status ---------------------------------------------------------------

---@param key string one of "stt", "daemon", "agent"
---@param value string one of "down", "starting", "up", "error"
function Sidebar:set_status(key, value)
	self.status[key] = value
	self:_render_header()
end

---@param state string
---@param detail? string appended to the label, e.g. a download percentage
function Sidebar:set_state(state, detail)
	self.state = state
	self.detail = detail
	self:_sync_spinner()
	self:_render_header()
end

function Sidebar:_stop_spinner()
	if self._timer then
		self._timer:stop()
		self._timer:close()
		self._timer = nil
	end
end

function Sidebar:_sync_spinner()
	if BUSY[self.state] then
		if self._timer then
			return
		end
		self._timer = vim.uv.new_timer()
		self._timer:start(
			80,
			80,
			vim.schedule_wrap(function()
				if not BUSY[self.state] or not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
					self:_stop_spinner()
					return
				end
				self._tick = self._tick + 1
				self:_render_header()
			end)
		)
	else
		self:_stop_spinner()
	end
end

-- Conversation ---------------------------------------------------------

--- Show the interim transcript as a provisional box, replaced by `begin_turn`.
---@param text string
function Sidebar:set_partial(text)
	if text == nil or text == "" then
		return
	end
	self:_ensure_buf()
	local i = #self.entries
	if self.entries[i] and self.entries[i].kind == "partial" then
		self.entries[i].text = text
		self:_render_entry(i)
	else
		self.open_kind = nil
		self:_push({ kind = "partial", text = text })
	end
end

function Sidebar:clear_partial()
	local e = self.entries[#self.entries]
	if e and e.kind == "partial" then
		self:_pop()
	end
end

---@param transcript string
function Sidebar:begin_turn(transcript)
	self:_ensure_buf()
	self:clear_partial()
	self.open_kind = nil
	self.tool_index = {}
	self.turns = self.turns + 1
	self:_push({ kind = "turn", text = transcript or "", time = os.date("%H:%M") })
end

---@param chunk string
function Sidebar:append_message(chunk)
	self:_stream("message", chunk)
end

---@param chunk string
function Sidebar:append_thought(chunk)
	self:_stream("thought", chunk)
end

--- Record or update a tool call. Updates re-render the original entry so
--- status transitions do not duplicate it.
---@param ev lazyspeak.Event
function Sidebar:add_tool_call(ev)
	self:_ensure_buf()
	local id = ev.tool_call_id
	if id and self.tool_index[id] then
		local i = self.tool_index[id]
		local e = self.entries[i]
		if e then
			e.status = ev.status
			self:_render_entry(i)
			return
		end
	end
	self.open_kind = nil
	local i = self:_push({
		kind = "tool",
		name = ev.tool_name or "tool",
		detail = ev.tool_detail,
		status = ev.status,
	})
	if id then
		self.tool_index[id] = i
	end
end

---@param diff lazyspeak.Diff
function Sidebar:add_diff(diff)
	self.open_kind = nil
	self:_push({
		kind = "tool",
		name = "Edit",
		detail = vim.fn.fnamemodify(diff.path, ":."),
		status = "completed",
	})
end

---@param perm lazyspeak.Permission
function Sidebar:set_permission(perm)
	self.open_kind = nil
	self._perm_index = self:_push({ kind = "permission", title = perm.title })
end

--- Record how the pending permission request resolved.
---@param answer string
function Sidebar:resolve_permission(answer)
	local i = self._perm_index
	if i and self.entries[i] and self.entries[i].kind == "permission" then
		self.entries[i].answer = answer
		self:_render_entry(i)
		self._perm_index = nil
		return
	end
	self:_push({ kind = "note", text = "→ " .. answer })
end

---@param message string
function Sidebar:add_error(message)
	self.open_kind = nil
	self:_push({ kind = "error", text = message })
end

---@param stop_reason? string
function Sidebar:end_turn(stop_reason)
	self.open_kind = nil
	if stop_reason == "cancelled" then
		self:_push({ kind = "note", text = "(cancelled)" })
	end
end

-- Window ---------------------------------------------------------------

---@return boolean
function Sidebar:is_open()
	return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- Open the sidebar as a full-height vertical split.
---@param focus? boolean steal the cursor (manual open) or not (auto-open)
function Sidebar:open(focus)
	self:_ensure_buf()
	if self:is_open() then
		if focus then
			vim.api.nvim_set_current_win(self.win)
		end
		return
	end
	local prev = vim.api.nvim_get_current_win()
	local side = self.opts.position == "left" and "topleft" or "botright"
	vim.cmd(side .. " vsplit")
	self.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(self.win, self.buf)
	-- Set the width explicitly rather than via a count on :vsplit. The count is
	-- not reliably honored once other windows are open, and `equalalways`
	-- re-balances afterwards; winfixwidth then pins it against later splits.
	vim.api.nvim_set_option_value("winfixwidth", true, { win = self.win })
	vim.api.nvim_win_set_width(self.win, self.opts.width)
	-- Content is hard-wrapped to the window width, so soft wrapping would break
	-- the box borders and gutters.
	vim.api.nvim_set_option_value("wrap", false, { win = self.win })
	vim.api.nvim_set_option_value("number", false, { win = self.win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = self.win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = self.win })
	vim.api.nvim_set_option_value("cursorline", false, { win = self.win })

	-- Re-flow from the entry model when the window width changes.
	self._augroup = vim.api.nvim_create_augroup("lazyspeak_sidebar", { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = self._augroup,
		desc = "lazyspeak: re-flow sidebar on resize",
		callback = function()
			if self:is_open() then
				self:_render_header()
				self:_render_all()
			end
		end,
	})

	self:_render_header()
	self:_render_all()
	local n = vim.api.nvim_buf_line_count(self.buf)
	pcall(vim.api.nvim_win_set_cursor, self.win, { n, 0 })
	if not focus and vim.api.nvim_win_is_valid(prev) then
		vim.api.nvim_set_current_win(prev)
	end
end

function Sidebar:close()
	if self._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
		self._augroup = nil
	end
	if self:is_open() then
		vim.api.nvim_win_close(self.win, true)
	end
	self.win = nil
end

function Sidebar:toggle()
	if self:is_open() then
		self:close()
	else
		self:open(true)
	end
end

--- Close the window and drop the buffer. Called on shutdown.
function Sidebar:dispose()
	self:_stop_spinner()
	self:close()
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
	end
	self.buf = nil
	self.entries = {}
	self.tool_index = {}
	self.open_kind = nil
end

M.Sidebar = Sidebar
return M
