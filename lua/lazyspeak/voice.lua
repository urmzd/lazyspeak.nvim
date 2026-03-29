local M = {}

---@class lazyspeak.Voice
---@field job_id number?
---@field partial string buffered partial line from stdout
---@field callbacks table<string, function>
---@field daemon_cmd string
local Voice = {}
Voice.__index = Voice

---@param opts? { daemon_cmd?: string }
function Voice:new(opts)
	opts = opts or {}
	return setmetatable({
		job_id = nil,
		partial = "",
		callbacks = {},
		daemon_cmd = opts.daemon_cmd or "lazyspeak",
	}, Voice)
end

---@param line string
function Voice:_handle_line(line)
	if line == "" then
		return
	end

	local ok, data = pcall(vim.json.decode, line)
	if not ok then
		return
	end

	local event_type = data.type
	if event_type == "transcript" and self.callbacks.transcript then
		self.callbacks.transcript(data.text, data.duration_ms)
	elseif event_type == "status" and self.callbacks.status then
		self.callbacks.status(data.state)
	elseif event_type == "vad" and self.callbacks.vad then
		self.callbacks.vad(data.speaking)
	elseif event_type == "error" and self.callbacks.error then
		self.callbacks.error(data.message)
	end
end

function Voice:start()
	if self.job_id then
		return
	end

	self.job_id = vim.fn.jobstart({ self.daemon_cmd }, {
		on_stdout = function(_, data, _)
			-- data is a list of strings split by newlines.
			-- Last element may be partial (empty string if line was complete).
			for i, chunk in ipairs(data) do
				if i == 1 then
					-- Prepend any buffered partial from last callback
					chunk = self.partial .. chunk
					self.partial = ""
				end

				if i == #data then
					-- Last chunk is either empty (complete line) or partial
					self.partial = chunk
				else
					self:_handle_line(chunk)
				end
			end
		end,
		on_exit = function(_, code, _)
			self.job_id = nil
			if self.callbacks.exit then
				self.callbacks.exit(code)
			end
		end,
		stdout_buffered = false,
	})

	if self.job_id <= 0 then
		vim.notify("[lazyspeak] failed to start daemon: " .. self.daemon_cmd, vim.log.levels.ERROR)
		self.job_id = nil
	end
end

function Voice:stop()
	if not self.job_id then
		return
	end
	self:_send({ cmd = "shutdown" })
	vim.fn.jobwait({ self.job_id }, 2000)
	self.job_id = nil
end

function Voice:start_listening()
	self:_send({ cmd = "start_listening" })
end

function Voice:stop_listening()
	self:_send({ cmd = "stop_listening" })
end

function Voice:cancel()
	self:_send({ cmd = "cancel" })
end

---@param cmd table
function Voice:_send(cmd)
	if not self.job_id then
		return
	end
	vim.fn.chansend(self.job_id, vim.json.encode(cmd) .. "\n")
end

---@param callback fun(text: string, duration_ms: number)
function Voice:on_transcript(callback)
	self.callbacks.transcript = callback
end

---@param callback fun(state: string)
function Voice:on_status(callback)
	self.callbacks.status = callback
end

---@param callback fun(speaking: boolean)
function Voice:on_vad(callback)
	self.callbacks.vad = callback
end

---@param callback fun(message: string)
function Voice:on_error(callback)
	self.callbacks.error = callback
end

---@return boolean
function Voice:is_running()
	return self.job_id ~= nil
end

M.Voice = Voice
return M
