local Voice = require("lazyspeak.voice").Voice
local Core = require("lazyspeak.core").Core
local Float = require("lazyspeak.ui").Float
local ui = require("lazyspeak.ui")
local install = require("lazyspeak.install")

local M = {}

---@class lazyspeak.Config
---@field agent { adapter: string, cmd?: string[], auto_approve?: boolean }
---@field model { path: string, server_port: number, server_url?: string }
---@field audio { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number }
---@field ui { float_position: string, float_width: number, show_waveform: boolean, statusline: boolean }
---@field snapshot { enabled: boolean, max_stack: number, use_git: boolean }
---@field keys { push_to_talk: string, toggle_listen: string, cancel: string, history: string, undo: string, switch_agent: string }
---@field daemon_cmd? string

---@type lazyspeak.Config
M.defaults = {
	agent = {
		adapter = "claudecode",
	},
	model = {
		path = install.MODEL_PATH,
		server_port = install.DEFAULT_PORT,
		-- server_url = "http://127.0.0.1:8674",  -- override to use external server
	},
	audio = {
		sample_rate = 16000,
		channels = 1,
		vad_threshold = 0.5,
		silence_duration_ms = 1000,
		max_duration_ms = 30000,
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
		if M._listening then
			M._voice:stop_listening()
			M._listening = false
		else
			M._voice:start_listening()
			M._listening = true
		end
	end, { desc = "lazyspeak: push-to-talk" })

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
---@return table<string, string>
local function build_daemon_env(model)
	local url = model.server_url or ("http://127.0.0.1:" .. model.server_port)
	return { LAZYSPEAK_STT_URL = url }
end

--- Start voice + core + UI, auto-launching llama-server if needed.
function M.start()
	if M._voice and M._voice:is_running() then
		return
	end

	-- If using the built-in server (no custom server_url), auto-start llama-server
	if not M.config.model.server_url then
		install.start_llama_server({
			port = M.config.model.server_port,
			model_path = M.config.model.path,
		}, function()
			M._start_pipeline()
		end)
	else
		M._start_pipeline()
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
			if event.type == "message" then
				M._float:set_agent_text(event.text or "")
			elseif event.type == "done" then
				M._state = "idle"
				ui.set_state("idle")
				M._float:set_state("idle")
			elseif event.type == "error" then
				M._state = "idle"
				ui.set_state("idle")
				M._float:set_state("idle")
				vim.notify("[lazyspeak] error: " .. (event.error or "unknown"), vim.log.levels.ERROR)
			end
		end)
	end)
	M._core:start()

	-- Initialize voice daemon
	local daemon_env = build_daemon_env(M.config.model)
	M._voice = Voice:new({ daemon_cmd = M.config.daemon_cmd, env = daemon_env })

	M._voice:on_transcript(function(text, duration_ms)
		M._state = "dispatching"
		ui.set_state("dispatching")
		M._listening = false
		vim.schedule(function()
			M._float:set_transcript(text)
			M._float:set_state("dispatching")
		end)
		M._core:handle_transcript(text, duration_ms)
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
