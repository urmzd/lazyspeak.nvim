local Voice = require("lazyspeak.voice").Voice
local Core = require("lazyspeak.core").Core
local Float = require("lazyspeak.ui").Float
local ui = require("lazyspeak.ui")
local install = require("lazyspeak.install")

local M = {}

---@class lazyspeak.Config
---@field agent { adapter: string, cmd?: string[], auto_approve?: boolean }
---@field model { path: string, server_port: number, server_url?: string }
---@field audio { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number, partial_interval_ms: number }
---@field ui { float_position: string, float_width: number, show_waveform: boolean, statusline: boolean }
---@field snapshot { enabled: boolean, max_stack: number, use_git: boolean }
---@field keys { push_to_talk: string, toggle_listen: string, cancel: string, history: string, undo: string, switch_agent: string }
---@field daemon_cmd? string

---@type lazyspeak.Config
M.defaults = {
	agent = {
		adapter = "claudecode",
		-- auto_approve: false = prompt on every agent permission request (safest
		-- for hands-free voice); true = auto-select the "allow" option.
		auto_approve = false,
	},
	model = {
		hf_repo = install.HF_REPO,
		server_port = install.DEFAULT_PORT,
		-- server_url = "http://127.0.0.1:8674",  -- override to use external server
	},
	audio = {
		sample_rate = 16000,
		channels = 1,
		-- Energy-based VAD threshold (RMS of normalized f32 samples). Speech is
		-- typically well under 0.1, so 0.01 is a sensible floor.
		vad_threshold = 0.01,
		-- How long to wait for trailing silence before finalizing an utterance.
		-- This is the single biggest perceived-latency knob — keep it low.
		silence_duration_ms = 400,
		max_duration_ms = 30000,
		-- How often to emit an interim (partial) transcript while still speaking.
		partial_interval_ms = 700,
	},
	ui = {
		float_position = "bottom-right",
		float_width = 40,
		show_waveform = true,
		statusline = true,
	},
	snapshot = {
		enabled = true,
		max_stack = 20,
		use_git = true,
	},
	keys = {
		push_to_talk = "<leader>ls",
		toggle_listen = "<leader>lS",
		cancel = "<leader>lc",
		history = "<leader>lh",
		undo = "<leader>lu",
		switch_agent = "<leader>la",
	},
}

---@type lazyspeak.Config
M.config = {}

---@type lazyspeak.Voice?
M._voice = nil

---@type lazyspeak.Core?
M._core = nil

---@type lazyspeak.Float?
M._float = nil

---@type string
M._state = "inactive"

---@type boolean
M._listening = false

---@param opts? table
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	local keys = M.config.keys

	vim.keymap.set("n", keys.push_to_talk, function()
		if not M._voice or not M._voice:is_running() then
			M.start()
		end

		-- Create float immediately if it doesn't exist yet
		if not M._float then
			M._float = Float:new({
				width = M.config.ui.float_width,
				position = M.config.ui.float_position,
			})
		end
		M._float:show()
		M._float:set_state("ready")

		local buf = vim.api.nvim_get_current_buf()

		local function cleanup()
			M._listening = false
			-- Don't hide the float here — let it linger so streamed agent output
			-- stays visible; it auto-hides once state settles to idle.
			pcall(vim.keymap.del, "n", "<Space>", { buffer = buf })
			pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
		end

		-- <Space> toggles recording on/off
		vim.keymap.set("n", "<Space>", function()
			if not M._voice or not M._voice:is_running() then
				vim.notify("[lazyspeak] waiting for daemon to start...", vim.log.levels.INFO)
				return
			end
			if M._listening then
				M._voice:stop_listening()
				M._listening = false
			else
				M._voice:start_listening()
				M._listening = true
			end
		end, { buffer = buf, desc = "lazyspeak: toggle recording" })

		-- <Esc> cancels and closes
		vim.keymap.set("n", "<Esc>", function()
			if M._listening and M._voice then
				M._voice:cancel()
			end
			cleanup()
		end, { buffer = buf, desc = "lazyspeak: close" })

		-- Auto-cleanup after dispatch completes
		M._session_cleanup = cleanup
	end, { desc = "lazyspeak: open" })

	vim.keymap.set("n", keys.cancel, function()
		if M._voice and M._voice:is_running() then
			M._voice:cancel()
			M._listening = false
		end
		if M._core then
			M._core:handle_transcript("cancel", 0)
		end
	end, { desc = "lazyspeak: cancel" })

	vim.keymap.set("n", keys.undo, function()
		if M._core then
			M._core:handle_transcript("undo", 0)
		end
	end, { desc = "lazyspeak: undo last edit" })
end

--- Build the environment variable table for the daemon process.
---@param model table the model config table
---@param audio table the audio config table
---@return table<string, string>
local function build_daemon_env(model, audio)
	local url = model.server_url or ("http://127.0.0.1:" .. model.server_port)
	return {
		LAZYSPEAK_STT_URL = url,
		LAZYSPEAK_VAD_THRESHOLD = tostring(audio.vad_threshold),
		LAZYSPEAK_SILENCE_MS = tostring(audio.silence_duration_ms),
		LAZYSPEAK_MAX_MS = tostring(audio.max_duration_ms),
		LAZYSPEAK_PARTIAL_MS = tostring(audio.partial_interval_ms),
	}
end

--- Start voice + core + UI, auto-launching llama-server if needed.
function M.start()
	if M._voice and M._voice:is_running() then
		return
	end

	local function update_float(state)
		vim.schedule(function()
			if M._float then
				M._float:set_state(state)
			end
		end)
	end

	-- If using the built-in server (no custom server_url), auto-start llama-server
	if not M.config.model.server_url then
		update_float("starting_server")
		install.start_llama_server({
			port = M.config.model.server_port,
			hf_repo = M.config.model.hf_repo,
		}, function()
			update_float("starting_daemon")
			M._start_pipeline()
			update_float("ready")
		end)
	else
		update_float("starting_daemon")
		M._start_pipeline()
		update_float("ready")
	end
end

--- Internal: start the voice daemon, core, and UI (called after server is ready).
function M._start_pipeline()
	if M._voice and M._voice:is_running() then
		return
	end

	-- Initialize UI
	M._float = Float:new({
		width = M.config.ui.float_width,
		position = M.config.ui.float_position,
	})

	-- Initialize core (adapter dispatch)
	M._core = Core:new(M.config)
	M._core:on_event(function(event)
		vim.schedule(function()
			M._on_agent_event(event)
		end)
	end)
	M._core:start()

	-- Initialize voice daemon
	local daemon_env = build_daemon_env(M.config.model, M.config.audio)
	M._voice = Voice:new({ daemon_cmd = M.config.daemon_cmd, env = daemon_env })

	M._voice:on_transcript(function(text, duration_ms)
		M._state = "dispatching"
		ui.set_state("dispatching")
		M._listening = false
		vim.schedule(function()
			M._float:reset_turn()
			M._float:set_transcript(text)
			M._float:set_state("dispatching")
		end)
		M._core:handle_transcript(text, duration_ms)
	end)

	M._voice:on_partial(function(text)
		vim.schedule(function()
			if M._float and text ~= "" then
				M._float:set_partial(text)
			end
		end)
	end)

	M._voice:on_status(function(state)
		M._state = state
		ui.set_state(state)
		vim.schedule(function()
			if state == "listening" then
				M._float:show()
				M._float:set_state("listening")
			elseif state == "transcribing" then
				M._float:set_state("transcribing")
			end
		end)
	end)

	M._voice:on_error(function(message)
		vim.schedule(function()
			vim.notify("[lazyspeak] daemon error: " .. message, vim.log.levels.ERROR)
		end)
	end)

	M._voice:start()
end

--- End the current agent turn: settle UI state and tear down session keymaps.
---@param stop_reason? string
local function finish_turn(stop_reason)
	M._state = "idle"
	ui.set_state("idle")
	if M._float then
		M._float:set_state("idle")
	end
	if stop_reason == "cancelled" then
		vim.notify("[lazyspeak] turn cancelled", vim.log.levels.INFO)
	end
	if M._session_cleanup then
		M._session_cleanup()
		M._session_cleanup = nil
	end
end

--- Route an IR event from the agent (via core) to the UI. Runs on the main loop.
---@param event lazyspeak.Event
function M._on_agent_event(event)
	if not M._float then
		return
	end
	local t = event.type

	if t == "message" then
		if M._state ~= "streaming" then
			M._state = "streaming"
			ui.set_state("streaming")
			M._float:set_state("streaming")
		end
		M._float:append_agent_text(event.text or "")
	elseif t == "thought" then
		M._float:append_thought(event.text or "")
	elseif t == "tool_call" then
		M._float:add_tool_call(event)
	elseif t == "diff" then
		if event.diff then
			M._float:add_diff(event.diff)
		end
	-- "plan" events are accepted but not rendered in the float yet.
	elseif t == "permission" then
		M._handle_permission(event.permission)
	elseif t == "done" then
		finish_turn(event.stop_reason)
	elseif t == "error" then
		vim.notify("[lazyspeak] error: " .. (event.error or "unknown"), vim.log.levels.ERROR)
		finish_turn()
	end
end

--- Present an agent permission request. Honors `agent.auto_approve`.
---@param perm lazyspeak.Permission
function M._handle_permission(perm)
	if not perm then
		return
	end
	local options = perm.options or {}

	--- Find the first option whose kind allows the action.
	local function first_allow()
		for _, o in ipairs(options) do
			if o.kind == "allow_once" or o.kind == "allow_always" then
				return o.optionId
			end
		end
		return options[1] and options[1].optionId
	end

	if M.config.agent and M.config.agent.auto_approve == true then
		perm.respond(first_allow())
		return
	end

	M._state = "permission"
	ui.set_state("permission")
	M._float:set_state("permission")
	M._float:set_permission(perm)

	vim.ui.select(options, {
		prompt = perm.title or "Allow agent action?",
		format_item = function(o)
			return o.name or o.optionId
		end,
	}, function(choice)
		M._float:clear_permission()
		perm.respond(choice and choice.optionId or nil)
		-- Resume the streaming state so the float keeps showing the turn.
		M._state = "streaming"
		ui.set_state("streaming")
		M._float:set_state("streaming")
	end)
end

function M.stop()
	if M._voice then
		M._voice:stop()
		M._voice = nil
	end
	if M._core then
		M._core:stop()
		M._core = nil
	end
	install.stop_llama_server()
	M._state = "inactive"
	M._listening = false
end

---@return string
function M.status()
	return ui.statusline()
end

return M
