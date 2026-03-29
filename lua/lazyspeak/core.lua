---@class lazyspeak.Request
---@field type "prompt" | "cancel"
---@field session_id string
---@field text string

---@class lazyspeak.Event
---@field type "message" | "tool_call" | "diff" | "permission" | "done" | "error"
---@field session_id string
---@field text? string
---@field tool_name? string
---@field diff? lazyspeak.Diff
---@field permission? lazyspeak.Permission
---@field error? string

---@class lazyspeak.Diff
---@field path string
---@field old_content string
---@field new_content string

---@class lazyspeak.Permission
---@field id string
---@field description string
---@field callback fun(approved: boolean)

---@class lazyspeak.Snapshot
---@field id string
---@field session_id string
---@field transcript string
---@field timestamp number
---@field files string[]
---@field stash_ref string
---@field undo_data table<string, string>

---@class lazyspeak.Adapter
---@field start fun(opts: table): nil
---@field stop fun(): nil
---@field send fun(req: lazyspeak.Request): nil
---@field on_event fun(callback: fun(event: lazyspeak.Event)): nil

local M = {}

--- Voice command patterns — intercepted before reaching the agent.
---@type table<string, string>
local VOICE_COMMANDS = {
	["^undo"] = "undo",
	["^revert"] = "undo",
	["^go back"] = "undo",
	["^undo that"] = "undo",
	["^undo all"] = "undo_all",
	["^revert everything"] = "undo_all",
	["^cancel"] = "cancel",
	["^stop"] = "cancel",
	["^never ?mind"] = "cancel",
}

---@class lazyspeak.Core
---@field adapter lazyspeak.Adapter?
---@field session_id string
---@field snapshots lazyspeak.SnapshotStack
---@field event_callback fun(event: lazyspeak.Event)?
local Core = {}
Core.__index = Core

---@param opts table
---@return lazyspeak.Core
function Core:new(opts)
	local adapter_name = opts.agent and opts.agent.adapter or "claudecode"
	local adapter = require("lazyspeak.adapters." .. adapter_name)
	local SnapshotStack = require("lazyspeak.snapshot").SnapshotStack

	local obj = setmetatable({
		opts = opts,
		adapter = adapter,
		session_id = tostring(os.time()),
		snapshots = SnapshotStack:new(opts.snapshot or {}),
		event_callback = nil,
	}, Core)

	adapter.on_event(function(event)
		obj:_on_adapter_event(event)
	end)

	return obj
end

--- Check if a transcript matches a voice command.
---@param text string
---@return string? action
local function match_voice_command(text)
	local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for pattern, action in pairs(VOICE_COMMANDS) do
		if lower:match(pattern) then
			return action
		end
	end
	return nil
end

--- Handle an incoming transcript from the voice daemon.
---@param text string
---@param duration_ms number
function Core:handle_transcript(text, duration_ms)
	local action = match_voice_command(text)

	if action == "undo" then
		local ok, msg = self.snapshots:pop()
		vim.schedule(function()
			vim.notify("[lazyspeak] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
		end)
		return
	elseif action == "undo_all" then
		local count = self.snapshots:pop_all()
		vim.schedule(function()
			vim.notify("[lazyspeak] reverted " .. count .. " snapshots")
		end)
		return
	elseif action == "cancel" then
		if self.adapter then
			self.adapter.send({
				type = "cancel",
				session_id = self.session_id,
				text = "",
			})
		end
		return
	end

	-- Create snapshot before dispatching
	self.snapshots:create(self.session_id, text)

	-- Dispatch to adapter
	if self.adapter then
		self.adapter.send({
			type = "prompt",
			session_id = self.session_id,
			text = text,
		})
	else
		vim.schedule(function()
			vim.notify(
				string.format("[lazyspeak] no adapter — (%dms) %s", duration_ms, text),
				vim.log.levels.WARN
			)
		end)
	end
end

---@param event lazyspeak.Event
function Core:_on_adapter_event(event)
	if self.event_callback then
		self.event_callback(event)
	end
end

---@param callback fun(event: lazyspeak.Event)
function Core:on_event(callback)
	self.event_callback = callback
end

function Core:start()
	if self.adapter then
		self.adapter.start(self.opts)
	end
end

function Core:stop()
	if self.adapter then
		self.adapter.stop()
	end
end

M.Core = Core
M.match_voice_command = match_voice_command
return M
