local Voice = require("lazyspeak.voice").Voice
local Core = require("lazyspeak.core").Core
local Sidebar = require("lazyspeak.sidebar").Sidebar
local ui = require("lazyspeak.ui")
local install = require("lazyspeak.install")

local M = {}

---@class lazyspeak.Config
---@field agent { adapter: string, cmd?: string[], auto_approve?: boolean }
---@field model { path: string, server_port: number, server_url?: string }
---@field audio { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number, partial_interval_ms: number }
---@field ui { sidebar_position: string, sidebar_width: number, sidebar_auto_open: boolean, statusline: boolean }
---@field snapshot { enabled: boolean, max_stack: number, max_age_days: number }
---@field keys { push_to_talk: string, cancel: string, undo: string, sidebar: string, toggle_listen: string, history: string, switch_agent: string }
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
		-- Which side the session sidebar opens on: "right" | "left".
		sidebar_position = "right",
		sidebar_width = 48,
		-- Open the sidebar automatically when a session starts.
		sidebar_auto_open = true,
		statusline = true,
	},
	snapshot = {
		enabled = true,
		max_stack = 20,
		-- Session dirs left by a crashed Neovim are swept after this many days.
		max_age_days = 7,
	},
	keys = {
		push_to_talk = "<leader>ls",
		cancel = "<leader>lc",
		undo = "<leader>lu",
		sidebar = "<leader>ll",
		-- Reserved, not yet bound: see docs/roadmap.md.
		toggle_listen = "<leader>lS",
		history = "<leader>lh",
		switch_agent = "<leader>la",
	},
}

---@type lazyspeak.Config
M.config = {}

---@type lazyspeak.Voice?
M._voice = nil

---@type lazyspeak.Core?
M._core = nil

---@type lazyspeak.Sidebar?
M._sidebar = nil

---@type string
M._state = "inactive"

---@type boolean
M._listening = false

--- The sidebar is created lazily and shared: the keymap, the pipeline start-up
--- path, and the event router all reach for it, and creating a second one
--- would orphan the first window on screen.
---@return lazyspeak.Sidebar
function M._ensure_sidebar()
	if not M._sidebar then
		local cfg = M.config.ui or M.defaults.ui
		M._sidebar = Sidebar:new({
			width = cfg.sidebar_width,
			position = cfg.sidebar_position,
			keys = M.config.keys or M.defaults.keys,
		})
	end
	return M._sidebar
end

---@return lazyspeak.SnapshotStack
local function snapshot_stack()
	if M._core and M._core.snapshots then
		return M._core.snapshots
	end
	local SnapshotStack = require("lazyspeak.snapshot").SnapshotStack
	return SnapshotStack:new(M.config.snapshot or M.defaults.snapshot)
end

--- Dismiss the sidebar without stopping the daemon. The conversation buffer
--- survives, so reopening restores the full session.
function M.dismiss()
	if M._sidebar then
		M._sidebar:close()
	end
end

---@param opts? table
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	local keys = M.config.keys

	-- Sweep snapshot directories from sessions that never shut down cleanly, so
	-- a crash cannot leave residue accumulating indefinitely. Deferred so it
	-- never sits in front of startup.
	vim.schedule(function()
		local ok, removed = pcall(function()
			return snapshot_stack():prune_stale(M.config.snapshot.max_age_days)
		end)
		if ok and removed and removed > 0 then
			vim.notify(("[lazyspeak] cleaned %d stale snapshot session(s)"):format(removed))
		end
	end)

	-- Never leave a daemon, llama-server, or agent process behind on exit.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("lazyspeak_shutdown", { clear = true }),
		desc = "lazyspeak: shut down daemon and agent",
		callback = function()
			M.stop()
		end,
	})

	vim.keymap.set("n", keys.push_to_talk, function()
		if not M._voice or not M._voice:is_running() then
			M.start()
		end

		local sidebar = M._ensure_sidebar()
		if M.config.ui.sidebar_auto_open then
			sidebar:open(false)
		end
		sidebar:set_state("ready")

		local buf = vim.api.nvim_get_current_buf()

		local function cleanup()
			M._listening = false
			-- The sidebar stays up: it is the reminder that a daemon is running.
			-- <Esc> dismisses it explicitly, as does :LazySpeakStop.
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

		-- <Esc> cancels and dismisses the UI
		vim.keymap.set("n", "<Esc>", function()
			if M._listening and M._voice then
				M._voice:cancel()
			end
			cleanup()
			M.dismiss()
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

	vim.keymap.set("n", keys.sidebar, function()
		M._ensure_sidebar():toggle()
	end, { desc = "lazyspeak: toggle session sidebar" })
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

	local function ui_state(state, detail)
		vim.schedule(function()
			M._ensure_sidebar():set_state(state, detail)
		end)
	end

	local function signal(key, value)
		vim.schedule(function()
			M._ensure_sidebar():set_status(key, value)
		end)
	end

	-- If using the built-in server (no custom server_url), auto-start llama-server
	if not M.config.model.server_url then
		signal("stt", "starting")
		ui_state("starting_server")
		install.start_llama_server({
			port = M.config.model.server_port,
			hf_repo = M.config.model.hf_repo,
			-- Surface the distinction between a slow first-run download and a
			-- server that is genuinely stuck.
			on_phase = function(phase, detail)
				if phase == "downloading" then
					ui_state("downloading_model", detail)
				elseif phase == "loading" then
					ui_state("loading_model")
				elseif phase == "ready" then
					signal("stt", "up")
				elseif phase == "error" then
					signal("stt", "error")
					ui_state("inactive", detail)
				end
			end,
		}, function()
			signal("stt", "up")
			ui_state("starting_daemon")
			M._start_pipeline()
			ui_state("ready")
		end)
	else
		-- An external server is assumed reachable; the first transcription will
		-- surface a failure if it is not.
		signal("stt", "up")
		ui_state("starting_daemon")
		M._start_pipeline()
		ui_state("ready")
	end
end

--- Internal: start the voice daemon, core, and UI (called after server is ready).
function M._start_pipeline()
	if M._voice and M._voice:is_running() then
		return
	end

	-- Initialize UI
	local sidebar = M._ensure_sidebar()
	if M.config.ui.sidebar_auto_open then
		sidebar:open(false)
	end

	-- Initialize core (adapter dispatch)
	sidebar:set_status("agent", "starting")
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
			local sb = M._ensure_sidebar()
			sb:begin_turn(text)
			sb:set_state("dispatching")
		end)
		M._core:handle_transcript(text, duration_ms)
	end)

	M._voice:on_partial(function(text)
		vim.schedule(function()
			if text ~= "" then
				M._ensure_sidebar():set_partial(text)
			end
		end)
	end)

	M._voice:on_status(function(state)
		M._state = state
		ui.set_state(state)
		vim.schedule(function()
			if state == "listening" then
				M._ensure_sidebar():set_state("listening")
			elseif state == "transcribing" then
				M._ensure_sidebar():set_state("transcribing")
			end
		end)
	end)

	M._voice:on_error(function(message)
		vim.schedule(function()
			vim.notify("[lazyspeak] daemon error: " .. message, vim.log.levels.ERROR)
			local sb = M._ensure_sidebar()
			sb:set_status("daemon", "error")
			sb:add_error("daemon: " .. message)
		end)
	end)

	M._voice:start()
	sidebar:set_status("daemon", M._voice:is_running() and "up" or "error")
end

--- End the current agent turn: settle UI state and tear down session keymaps.
---@param stop_reason? string
local function finish_turn(stop_reason)
	M._state = "idle"
	ui.set_state("idle")
	if M._sidebar then
		M._sidebar:end_turn(stop_reason)
		M._sidebar:set_state("idle")
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
	local t = event.type
	local sb = M._ensure_sidebar()

	if t == "message" then
		if M._state ~= "streaming" then
			M._state = "streaming"
			ui.set_state("streaming")
			sb:set_state("streaming")
		end
		sb:append_message(event.text or "")
	elseif t == "thought" then
		sb:append_thought(event.text or "")
	elseif t == "tool_call" then
		sb:add_tool_call(event)
	elseif t == "diff" then
		if event.diff then
			sb:add_diff(event.diff)
		end
	elseif t == "ready" then
		-- The agent only becomes usable once it has a session.
		sb:set_status("agent", "up")
	elseif t == "exit" then
		sb:set_status("agent", event.error and "error" or "down")
	-- "plan" events are accepted but not rendered yet.
	elseif t == "permission" then
		M._handle_permission(event.permission)
	elseif t == "done" then
		finish_turn(event.stop_reason)
	elseif t == "error" then
		vim.notify("[lazyspeak] error: " .. (event.error or "unknown"), vim.log.levels.ERROR)
		sb:add_error(event.error or "unknown")
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
	local sb = M._ensure_sidebar()
	sb:set_state("permission")
	sb:set_permission(perm)

	vim.ui.select(options, {
		prompt = perm.title or "Allow agent action?",
		format_item = function(o)
			return o.name or o.optionId
		end,
	}, function(choice)
		perm.respond(choice and choice.optionId or nil)
		sb:resolve_permission(choice and (choice.name or choice.optionId) or "denied")
		-- Resume the streaming state so the sidebar keeps showing the turn.
		M._state = "streaming"
		ui.set_state("streaming")
		sb:set_state("streaming")
	end)
end

--- Tear everything down: agent, daemon, STT server, and UI. Also runs on
--- VimLeavePre so quitting Neovim never strands a background process.
function M.stop()
	if M._voice then
		pcall(function()
			M._voice:stop()
		end)
		M._voice = nil
	end
	if M._core then
		pcall(function()
			M._core:stop()
		end)
		-- An undo point outlives its usefulness with the session that made it,
		-- so the stored copies go too rather than accumulating on disk.
		pcall(function()
			M._core.snapshots:cleanup_session(M._core.session_id)
		end)
		M._core = nil
	end
	install.stop_llama_server()

	if M._sidebar then
		M._sidebar:dispose()
		M._sidebar = nil
	end

	M._state = "inactive"
	ui.set_state("inactive")
	M._listening = false
end

---@return string
function M.status()
	return ui.statusline()
end

--- Clean up snapshot residue: session directories left by a crashed Neovim,
--- and `lazyspeak:` git stash entries written by the pre-XDG implementation.
---
--- Stale directories go without asking; they are the plugin's own regenerable
--- state. Stash entries live in the user's repository, so those are listed and
--- confirmed first.
function M.prune_snapshots()
	local stack = snapshot_stack()
	local cfg = M.config.snapshot or M.defaults.snapshot

	local removed = stack:prune_stale(cfg.max_age_days)
	if removed > 0 then
		vim.notify(("[lazyspeak] removed %d stale snapshot session(s)"):format(removed))
	end

	local orphans = stack:orphans()
	if #orphans == 0 then
		if removed == 0 then
			vim.notify("[lazyspeak] nothing to prune")
		end
		return
	end

	local preview = {}
	for i, o in ipairs(orphans) do
		if i > 5 then
			preview[#preview + 1] = ("  ...and %d more"):format(#orphans - 5)
			break
		end
		preview[#preview + 1] = "  " .. o.message
	end

	local prompt = ("Drop %d legacy lazyspeak stash entries from this repo?\n%s"):format(
		#orphans,
		table.concat(preview, "\n")
	)

	vim.ui.select({ "no", "yes" }, { prompt = prompt }, function(choice)
		if choice ~= "yes" then
			vim.notify("[lazyspeak] kept " .. #orphans .. " stash entries")
			return
		end
		local dropped, found = stack:prune_orphans()
		vim.notify(("[lazyspeak] dropped %d of %d stash entries"):format(dropped, found))
	end)
end

return M
