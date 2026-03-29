--- Claude Code CLI adapter.
--- Spawns `claude --print -p <transcript>` and streams the response back.
---@class lazyspeak.ClaudeCodeAdapter : lazyspeak.Adapter

local M = {}

---@type fun(event: lazyspeak.Event)?
local _event_callback = nil

---@type number?
local _job_id = nil

---@type string[]
local _response_lines = {}

function M.start(_opts)
	-- No persistent process needed — we spawn per-prompt.
end

function M.stop()
	if _job_id then
		vim.fn.jobstop(_job_id)
		_job_id = nil
	end
end

---@param req lazyspeak.Request
function M.send(req)
	if req.type == "cancel" then
		M.stop()
		if _event_callback then
			_event_callback({
				type = "done",
				session_id = req.session_id,
			})
		end
		return
	end

	if req.type ~= "prompt" then
		return
	end

	-- Kill any existing request
	M.stop()
	_response_lines = {}

	local partial = ""

	_job_id = vim.fn.jobstart({ "claude", "--print", "-p", req.text }, {
		on_stdout = function(_, data, _)
			for i, chunk in ipairs(data) do
				if i == 1 then
					chunk = partial .. chunk
					partial = ""
				end

				if i == #data then
					partial = chunk
				else
					table.insert(_response_lines, chunk)
					if _event_callback then
						vim.schedule(function()
							_event_callback({
								type = "message",
								session_id = req.session_id,
								text = chunk,
							})
						end)
					end
				end
			end
		end,
		on_exit = function(_, code, _)
			_job_id = nil
			-- Flush any remaining partial
			if partial ~= "" then
				table.insert(_response_lines, partial)
			end

			vim.schedule(function()
				if _event_callback then
					-- Send full response as final message
					local full = table.concat(_response_lines, "\n")
					if full ~= "" then
						_event_callback({
							type = "message",
							session_id = req.session_id,
							text = full,
						})
					end
					_event_callback({
						type = code == 0 and "done" or "error",
						session_id = req.session_id,
						error = code ~= 0 and ("claude exited with code " .. code) or nil,
					})
				end
			end)
		end,
		stdout_buffered = false,
	})

	if _job_id <= 0 then
		vim.notify("[lazyspeak] failed to spawn claude CLI", vim.log.levels.ERROR)
		_job_id = nil
	end
end

---@param callback fun(event: lazyspeak.Event)
function M.on_event(callback)
	_event_callback = callback
end

return M
