--- ACP (Agent Client Protocol) adapter.
--- Spawns an ACP-compatible agent as a subprocess, communicates via
--- JSON-RPC 2.0 over stdio. Supports Gemini CLI, Goose, Codex, etc.
---@class lazyspeak.AcpAdapter : lazyspeak.Adapter

local M = {}

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

---@type table<number, fun(result: any, err: any)>
local _pending = {}

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

--- Send a JSON-RPC response back to the agent (for agent→client calls).
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

--- Handle a JSON-RPC message from the agent.
---@param data table
local function handle_message(data)
	-- Response to a request we sent
	if data.id and (data.result ~= nil or data.error ~= nil) then
		local cb = _pending[data.id]
		if cb then
			_pending[data.id] = nil
			cb(data.result, data.error)
		end
		return
	end

	-- Notification from the agent (no id, or id with method = agent calling us)
	local method = data.method
	if not method then
		return
	end

	-- Agent → Client: session/update notifications
	if method == "session/update" then
		local params = data.params or {}
		local update_type = params.type

		if update_type == "agent_message_chunk" and _event_callback then
			_event_callback({
				type = "message",
				session_id = _session_id or "",
				text = params.text or "",
			})
		elseif update_type == "tool_call" and _event_callback then
			_event_callback({
				type = "tool_call",
				session_id = _session_id or "",
				tool_name = params.name,
				text = params.arguments,
			})
		end
		return
	end

	-- Agent → Client: fs/read_text_file
	if method == "fs/read_text_file" then
		local path = data.params and data.params.path
		if path then
			local lines = vim.fn.readfile(path)
			local content = table.concat(lines, "\n")
			send_response(data.id, { content = content })
		else
			send_response(data.id, vim.NIL)
		end
		return
	end

	-- Agent → Client: fs/write_text_file
	if method == "fs/write_text_file" then
		local path = data.params and data.params.path
		local content = data.params and data.params.content
		if path and content then
			vim.fn.writefile(vim.split(content, "\n"), path)
			send_response(data.id, {})

			-- Reload buffer if open
			vim.schedule(function()
				local bufnr = vim.fn.bufnr(path)
				if bufnr ~= -1 then
					vim.api.nvim_buf_call(bufnr, function()
						vim.cmd("edit!")
					end)
				end
			end)

			if _event_callback then
				_event_callback({
					type = "diff",
					session_id = _session_id or "",
					diff = { path = path, old_content = "", new_content = content },
				})
			end
		else
			send_response(data.id, vim.NIL)
		end
		return
	end

	-- Agent → Client: session/request_permission
	if method == "session/request_permission" then
		local desc = data.params and data.params.description or "unknown action"
		local req_id = data.id

		if _event_callback then
			_event_callback({
				type = "permission",
				session_id = _session_id or "",
				permission = {
					id = tostring(req_id),
					description = desc,
					callback = function(approved)
						send_response(req_id, { approved = approved })
					end,
				},
			})
		else
			-- Auto-approve if no callback
			send_response(req_id, { approved = true })
		end
		return
	end

	-- Agent → Client: terminal/create
	if method == "terminal/create" then
		local cmd_parts = data.params and data.params.command
		if cmd_parts then
			local term_job = vim.fn.jobstart(cmd_parts, {
				on_exit = function() end,
			})
			send_response(data.id, { terminalId = tostring(term_job) })
		else
			send_response(data.id, vim.NIL)
		end
		return
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
	_request_id = 0

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
		on_exit = function(_, code, _)
			_job_id = nil
			if _event_callback then
				vim.schedule(function()
					_event_callback({
						type = code == 0 and "done" or "error",
						session_id = _session_id or "",
						error = code ~= 0 and ("agent exited with code " .. code) or nil,
					})
				end)
			end
		end,
		stdout_buffered = false,
	})

	if _job_id <= 0 then
		vim.notify("[lazyspeak] failed to spawn ACP agent", vim.log.levels.ERROR)
		_job_id = nil
		return
	end

	-- ACP initialize handshake
	send_request("initialize", {
		protocolVersion = "0.11.4",
		clientInfo = { name = "lazyspeak.nvim", version = "0.1.0" },
		clientCapabilities = {
			fs = { readTextFile = true, writeTextFile = true },
			terminal = { create = true, output = true, waitForExit = true, kill = true },
		},
	}, function(result, err)
		if err then
			vim.schedule(function()
				vim.notify("[lazyspeak] ACP init failed: " .. vim.inspect(err), vim.log.levels.ERROR)
			end)
			return
		end

		-- Create session
		send_request("session/new", {
			cwd = vim.fn.getcwd(),
		}, function(sess_result, sess_err)
			if sess_err then
				vim.schedule(function()
					vim.notify("[lazyspeak] session/new failed: " .. vim.inspect(sess_err), vim.log.levels.ERROR)
				end)
				return
			end
			_session_id = sess_result and sess_result.sessionId
		end)
	end)
end

function M.stop()
	if _job_id then
		vim.fn.jobstop(_job_id)
		_job_id = nil
	end
	_session_id = nil
	_pending = {}
end

---@param req lazyspeak.Request
function M.send(req)
	if req.type == "cancel" then
		if _job_id and _session_id then
			local msg = vim.json.encode({
				jsonrpc = "2.0",
				method = "session/cancel",
				params = { sessionId = _session_id },
			})
			vim.fn.chansend(_job_id, msg .. "\n")
		end
		return
	end

	if req.type ~= "prompt" or not _session_id then
		return
	end

	send_request("session/prompt", {
		sessionId = _session_id,
		content = {
			{ type = "text", text = req.text },
		},
	}, function(result, err)
		if err and _event_callback then
			vim.schedule(function()
				_event_callback({
					type = "error",
					session_id = _session_id or "",
					error = vim.inspect(err),
				})
			end)
		elseif _event_callback then
			vim.schedule(function()
				_event_callback({
					type = "done",
					session_id = _session_id or "",
				})
			end)
		end
	end)
end

---@param callback fun(event: lazyspeak.Event)
function M.on_event(callback)
	_event_callback = callback
end

return M
