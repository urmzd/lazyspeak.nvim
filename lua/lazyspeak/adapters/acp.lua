--- ACP (Agent Client Protocol) adapter.
--- Spawns an ACP-compatible agent as a subprocess and communicates via
--- JSON-RPC 2.0 over stdio (newline-delimited). Implements the *client* (host)
--- half of ACP v1: it sends `initialize`, `session/new`, `session/prompt`,
--- `session/cancel`, and handles agent→client `session/update`,
--- `session/request_permission`, and `fs/*` requests.
---
--- Works with any ACP v1 agent: @agentclientprotocol/claude-agent-acp,
--- `gemini --acp`, `goose acp`, Codex, etc.
---
--- Spec: https://agentclientprotocol.com (stable schema, protocolVersion 1).
---@class lazyspeak.AcpAdapter : lazyspeak.Adapter

local M = {}

--- ACP protocol version this client speaks (bare integer, per spec).
local PROTOCOL_VERSION = 1

---@type fun(event: lazyspeak.Event)?
local _event_callback = nil

---@type number?
local _job_id = nil

---@type string?
local _session_id = nil

---@type number
local _request_id = 0

---@type string
local _partial = ""

--- Callbacks awaiting a response to a request *we* sent, keyed by id.
---@type table<number, fun(result: any, err: any)>
local _pending = {}

--- In-flight agent→client permission requests, keyed by JSON-RPC id, holding
--- the responder fn. Used to resolve them with `cancelled` on session/cancel.
---@type table<number, fun(option_id: string?)>
local _pending_permissions = {}

--- Capabilities the agent advertised in its `initialize` response. Notably
--- `prompt.audio` — only `gemini --acp` sets this today; Claude does not, so we
--- always send text content blocks unless an agent opts into audio.
---@type table
local _agent_caps = {}

--- Recent stderr lines from the agent, kept for error reporting (agents route
--- their own logs to stderr and reserve stdout for protocol messages).
---@type string[]
local _stderr_ring = {}

--- Emit an IR event to the registered callback, if any.
---@param event lazyspeak.Event
local function emit(event)
	if _event_callback then
		_event_callback(event)
	end
end

--- Send a JSON-RPC request to the agent.
---@param method string
---@param params table
---@param callback? fun(result: any, err: any)
local function send_request(method, params, callback)
	if not _job_id then
		return
	end
	_request_id = _request_id + 1
	local id = _request_id

	if callback then
		_pending[id] = callback
	end

	local msg = vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		method = method,
		params = params,
	})
	vim.fn.chansend(_job_id, msg .. "\n")
end

--- Send a JSON-RPC notification (no id, no response expected).
---@param method string
---@param params table
local function send_notification(method, params)
	if not _job_id then
		return
	end
	local msg = vim.json.encode({
		jsonrpc = "2.0",
		method = method,
		params = params,
	})
	vim.fn.chansend(_job_id, msg .. "\n")
end

--- Send a JSON-RPC success response back to the agent (for agent→client calls).
---@param id number
---@param result any
local function send_response(id, result)
	if not _job_id then
		return
	end
	local msg = vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		result = result,
	})
	vim.fn.chansend(_job_id, msg .. "\n")
end

--- Send a JSON-RPC error response back to the agent.
---@param id number
---@param code number
---@param message string
local function send_error(id, code, message)
	if not _job_id then
		return
	end
	local msg = vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		error = { code = code, message = message },
	})
	vim.fn.chansend(_job_id, msg .. "\n")
end

--- Extract the text from a ContentBlock (the single object carried by
--- agent_message_chunk / agent_thought_chunk updates).
---@param content any
---@return string
local function content_text(content)
	if type(content) == "table" and content.type == "text" then
		return content.text or ""
	end
	return ""
end

--- Handle an agent→client `session/update` notification.
---@param params table
local function handle_session_update(params)
	local update = params.update or {}
	local kind = update.sessionUpdate
	local sid = _session_id or ""

	if kind == "agent_message_chunk" then
		emit({ type = "message", session_id = sid, text = content_text(update.content) })
	elseif kind == "agent_thought_chunk" then
		emit({ type = "thought", session_id = sid, text = content_text(update.content) })
	elseif kind == "tool_call" or kind == "tool_call_update" then
		local raw = update.rawInput
		emit({
			type = "tool_call",
			session_id = sid,
			tool_name = update.title or update.kind or "tool",
			tool_call_id = update.toolCallId,
			status = update.status,
			text = raw ~= nil and vim.json.encode(raw) or nil,
		})
	elseif kind == "plan" then
		emit({ type = "plan", session_id = sid, text = update.entries and vim.json.encode(update.entries) or nil })
	end
	-- user_message_chunk / available_commands_update / current_mode_update /
	-- config_option_update / session_info_update are ignored for now.
end

--- Handle an agent→client `session/request_permission` request.
---@param id number
---@param params table
local function handle_request_permission(id, params)
	local tool_call = params.toolCall or {}
	local options = params.options or {}

	local function respond(option_id)
		_pending_permissions[id] = nil
		if option_id then
			send_response(id, { outcome = { outcome = "selected", optionId = option_id } })
		else
			send_response(id, { outcome = { outcome = "cancelled" } })
		end
	end
	_pending_permissions[id] = respond

	if _event_callback then
		emit({
			type = "permission",
			session_id = _session_id or "",
			permission = {
				id = tostring(id),
				title = tool_call.title or "agent action",
				kind = tool_call.kind,
				options = options,
				respond = respond,
			},
		})
	else
		-- No UI bound — auto-select the first allow option, else cancel.
		local pick
		for _, o in ipairs(options) do
			if o.kind == "allow_once" or o.kind == "allow_always" then
				pick = o.optionId
				break
			end
		end
		respond(pick or (options[1] and options[1].optionId))
	end
end

--- Handle an agent→client `fs/read_text_file` request.
---@param id number
---@param params table
local function handle_fs_read(id, params)
	local path = params.path
	if not path or vim.fn.filereadable(path) ~= 1 then
		send_error(id, -32602, "file not readable: " .. tostring(path))
		return
	end
	local lines = vim.fn.readfile(path)
	-- Optional line/limit windowing per spec.
	if params.line or params.limit then
		local start_line = math.max((params.line or 1), 1)
		local limit = params.limit
		local windowed = {}
		for i = start_line, (limit and (start_line + limit - 1) or #lines) do
			if lines[i] == nil then
				break
			end
			windowed[#windowed + 1] = lines[i]
		end
		lines = windowed
	end
	send_response(id, { content = table.concat(lines, "\n") })
end

--- Handle an agent→client `fs/write_text_file` request.
---@param id number
---@param params table
local function handle_fs_write(id, params)
	local path = params.path
	local content = params.content
	if not path or content == nil then
		send_error(id, -32602, "fs/write_text_file requires path and content")
		return
	end

	local old_content = ""
	if vim.fn.filereadable(path) == 1 then
		old_content = table.concat(vim.fn.readfile(path), "\n")
	end

	local dir = vim.fn.fnamemodify(path, ":h")
	if dir ~= "" and vim.fn.isdirectory(dir) ~= 1 then
		vim.fn.mkdir(dir, "p")
	end
	vim.fn.writefile(vim.split(content, "\n"), path)
	send_response(id, vim.empty_dict())

	-- Reload the buffer if it is open.
	vim.schedule(function()
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("checktime")
			end)
		end
	end)

	emit({
		type = "diff",
		session_id = _session_id or "",
		diff = { path = path, old_content = old_content, new_content = content },
	})
end

--- Dispatch a single decoded JSON-RPC message from the agent.
---@param data table
local function handle_message(data)
	-- A response to a request we sent.
	if data.id ~= nil and (data.result ~= nil or data.error ~= nil) then
		local cb = _pending[data.id]
		if cb then
			_pending[data.id] = nil
			cb(data.result, data.error)
		end
		return
	end

	local method = data.method
	if not method then
		return
	end

	local params = data.params or {}

	-- Notifications (no id): agent → client.
	if method == "session/update" then
		handle_session_update(params)
		return
	end

	-- Requests (have id): agent → client, expect a response.
	local id = data.id
	if method == "session/request_permission" then
		handle_request_permission(id, params)
	elseif method == "fs/read_text_file" then
		handle_fs_read(id, params)
	elseif method == "fs/write_text_file" then
		handle_fs_write(id, params)
	elseif id ~= nil then
		-- Unknown agent→client request (e.g. terminal/* we didn't advertise):
		-- reply with an error so the agent doesn't hang.
		send_error(id, -32601, "method not supported by lazyspeak: " .. method)
	end
end

---@param line string
local function handle_line(line)
	if line == "" then
		return
	end
	local ok, data = pcall(vim.json.decode, line)
	if ok and type(data) == "table" then
		handle_message(data)
	end
end

--- Run the ACP handshake: initialize → session/new.
local function handshake()
	send_request("initialize", {
		protocolVersion = PROTOCOL_VERSION,
		clientCapabilities = {
			fs = { readTextFile = true, writeTextFile = true },
			terminal = false,
		},
	}, function(result, err)
		if err then
			vim.schedule(function()
				vim.notify("[lazyspeak] ACP initialize failed: " .. vim.inspect(err), vim.log.levels.ERROR)
			end)
			return
		end

		_agent_caps = (result and result.agentCapabilities) or {}

		send_request("session/new", {
			cwd = vim.fn.getcwd(),
			mcpServers = {}, -- encodes to [] in Neovim
		}, function(sess_result, sess_err)
			if sess_err then
				vim.schedule(function()
					vim.notify("[lazyspeak] ACP session/new failed: " .. vim.inspect(sess_err), vim.log.levels.ERROR)
				end)
				return
			end
			_session_id = sess_result and sess_result.sessionId
		end)
	end)
end

---@param opts table
function M.start(opts)
	if _job_id then
		return
	end

	local cmd = opts.agent and opts.agent.cmd
	if not cmd then
		vim.notify("[lazyspeak] ACP adapter requires agent.cmd", vim.log.levels.ERROR)
		return
	end

	_partial = ""
	_pending = {}
	_pending_permissions = {}
	_request_id = 0
	_agent_caps = {}
	_stderr_ring = {}

	_job_id = vim.fn.jobstart(cmd, {
		on_stdout = function(_, data, _)
			for i, chunk in ipairs(data) do
				if i == 1 then
					chunk = _partial .. chunk
					_partial = ""
				end
				if i == #data then
					_partial = chunk
				else
					handle_line(chunk)
				end
			end
		end,
		on_stderr = function(_, data, _)
			for _, chunk in ipairs(data) do
				if chunk ~= "" then
					_stderr_ring[#_stderr_ring + 1] = chunk
					if #_stderr_ring > 50 then
						table.remove(_stderr_ring, 1)
					end
				end
			end
		end,
		on_exit = function(_, code, _)
			_job_id = nil
			_session_id = nil
			if code ~= 0 then
				local tail = table.concat(vim.list_slice(_stderr_ring, math.max(1, #_stderr_ring - 5)), "\n")
				vim.schedule(function()
					emit({
						type = "error",
						session_id = _session_id or "",
						error = ("ACP agent exited with code %d%s"):format(code, tail ~= "" and ("\n" .. tail) or ""),
					})
				end)
			end
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	if _job_id <= 0 then
		vim.notify("[lazyspeak] failed to spawn ACP agent: " .. vim.inspect(cmd), vim.log.levels.ERROR)
		_job_id = nil
		return
	end

	handshake()
end

function M.stop()
	if _job_id then
		vim.fn.jobstop(_job_id)
		_job_id = nil
	end
	_session_id = nil
	_pending = {}
	_pending_permissions = {}
end

---@param req lazyspeak.Request
function M.send(req)
	if req.type == "cancel" then
		-- Resolve any pending permission prompts with the cancelled outcome,
		-- then notify the agent.
		for _, respond in pairs(_pending_permissions) do
			respond(nil)
		end
		_pending_permissions = {}
		if _job_id and _session_id then
			send_notification("session/cancel", { sessionId = _session_id })
		end
		return
	end

	if req.type ~= "prompt" or not _session_id then
		return
	end

	send_request("session/prompt", {
		sessionId = _session_id,
		prompt = {
			{ type = "text", text = req.text },
		},
	}, function(result, err)
		if err then
			emit({ type = "error", session_id = _session_id or "", error = vim.inspect(err) })
		else
			emit({
				type = "done",
				session_id = _session_id or "",
				stop_reason = result and result.stopReason,
			})
		end
	end)
end

---@param callback fun(event: lazyspeak.Event)
function M.on_event(callback)
	_event_callback = callback
end

--- Capabilities the agent advertised (e.g. `.promptCapabilities.audio`).
---@return table
function M.agent_capabilities()
	return _agent_caps
end

return M
