local M = {}

local DEFAULT_PORT = 8674
local HEALTH_PATH = "/health"
local HF_REPO = "ggml-org/Voxtral-Mini-3B-2507-GGUF"

--- Install daemon binary (model is auto-downloaded by llama-server via -hf).
function M.run()
	-- Build daemon binary
	if vim.fn.executable("lazyspeak") == 0 then
		vim.notify("[lazyspeak] building daemon binary...")
		local plugin_dir = debug.getinfo(1, "S").source:match("@(.*/)")
		if plugin_dir then
			plugin_dir = plugin_dir:gsub("/lua/lazyspeak/$", "")
		end

		if plugin_dir and vim.fn.isdirectory(plugin_dir .. "/crates") == 1 then
			vim.fn.jobstart({ "cargo", "install", "--path", plugin_dir .. "/crates/lazyspeak" }, {
				on_exit = function(_, code, _)
					vim.schedule(function()
						if code == 0 then
							vim.notify("[lazyspeak] daemon binary installed")
						else
							vim.notify(
								"[lazyspeak] daemon build failed — run `cargo install --path crates/lazyspeak` manually",
								vim.log.levels.ERROR
							)
						end
					end)
				end,
			})
		else
			vim.notify(
				"[lazyspeak] could not find crates/ dir — run `cargo install --path crates/lazyspeak` manually",
				vim.log.levels.WARN
			)
		end
	else
		vim.notify("[lazyspeak] daemon binary already installed")
	end

	vim.notify("[lazyspeak] model will be auto-downloaded on first :LazySpeakStart via llama-server -hf " .. HF_REPO)
end

-- llama-server process management

---@type number?
M._llama_job_id = nil

--- How long the server may make no observable progress before we give up.
--- This is an *idle* timeout, not a total one: a multi-gigabyte first-run
--- download may legitimately take far longer than any fixed deadline, so what
--- matters is whether bytes are still moving.
local DEFAULT_STALL_MS = 120000

--- Probe the server's health endpoint without blocking the editor.
---
--- The old implementation used `io.popen("curl ...")`, which blocks Neovim's
--- main loop for as long as curl runs. A loading `llama-server` accepts the
--- connection before it can answer, and curl without `--max-time` waits
--- indefinitely on that, freezing the whole session. This is async and doubly
--- bounded by curl's own timeouts.
---@param port number
---@param cb fun(ok: boolean)
function M.probe_server(port, cb)
	local url = string.format("http://127.0.0.1:%d%s", port, HEALTH_PATH)
	local ok, err = pcall(vim.system, {
		"curl",
		"-sf",
		"--connect-timeout",
		"1",
		"--max-time",
		"2",
		url,
	}, { text = true }, function(res)
		vim.schedule(function()
			cb(res.code == 0)
		end)
	end)
	if not ok then
		vim.schedule(function()
			vim.notify("[lazyspeak] health probe failed to spawn: " .. tostring(err), vim.log.levels.WARN)
			cb(false)
		end)
	end
end

--- Start llama-server with the Voxtral model if not already running.
--- Uses -hf to auto-download model + mmproj from HuggingFace on first run.
---
--- Fully asynchronous: nothing here blocks the main loop, and readiness is
--- reported through `on_ready`. Progress is reported through `on_phase` so the
--- UI can distinguish a long download from a stuck server.
---@param opts? { port?: number, hf_repo?: string, on_phase?: fun(phase: string, detail?: string), stall_timeout_ms?: number }
---@param on_ready? fun() called once the server is healthy
function M.start_llama_server(opts, on_ready)
	opts = opts or {}
	local port = opts.port or DEFAULT_PORT
	local hf_repo = opts.hf_repo or HF_REPO
	local on_phase = opts.on_phase or function() end
	local stall_ms = opts.stall_timeout_ms or DEFAULT_STALL_MS

	-- Already managed by us
	if M._llama_job_id then
		if on_ready then
			on_ready()
		end
		return
	end

	-- Something else may already be listening on the port.
	M.probe_server(port, function(alive)
		if alive then
			vim.notify("[lazyspeak] llama-server already running on port " .. port)
			on_phase("ready")
			if on_ready then
				on_ready()
			end
			return
		end
		M._spawn_llama_server(port, hf_repo, on_phase, stall_ms, on_ready)
	end)
end

--- Internal: spawn llama-server and watch it until healthy or stalled.
---@param port number
---@param hf_repo string
---@param on_phase fun(phase: string, detail?: string)
---@param stall_ms number
---@param on_ready? fun()
function M._spawn_llama_server(port, hf_repo, on_phase, stall_ms, on_ready)
	if vim.fn.executable("llama-server") ~= 1 then
		vim.notify(
			"[lazyspeak] llama-server not found — install llama.cpp (brew install llama.cpp)",
			vim.log.levels.ERROR
		)
		on_phase("error", "llama-server not installed")
		return
	end

	vim.notify("[lazyspeak] starting llama-server on port " .. port .. " (model: " .. hf_repo .. ")...")

	local phase = "starting"
	local last_progress = vim.uv.now()

	--- Classify a line of server output and reset the stall watchdog. Any
	--- output at all counts as progress, which is what lets a slow download
	--- run as long as it needs without tripping the timeout.
	---@param line string
	local function observe(line)
		last_progress = vim.uv.now()
		local pct = line:match("(%d?%d?%d)%%")
		if phase ~= "loading" and pct then
			phase = "downloading"
			on_phase("downloading", pct .. "%")
		elseif line:match("loading model") or line:match("llama_model_loader") or line:match("load_tensors") then
			if phase ~= "loading" then
				phase = "loading"
				on_phase("loading")
			end
		end
	end

	local function drain(data)
		for _, line in ipairs(data or {}) do
			if line ~= "" then
				observe(line)
			end
		end
	end

	M._llama_job_id = vim.fn.jobstart({
		"llama-server",
		"-hf",
		hf_repo,
		"--port",
		tostring(port),
	}, {
		on_stdout = function(_, data, _)
			drain(data)
		end,
		on_stderr = function(_, data, _)
			drain(data)
		end,
		on_exit = function(_, code, _)
			M._llama_job_id = nil
			if code ~= 0 then
				vim.schedule(function()
					vim.notify("[lazyspeak] llama-server exited with code " .. code, vim.log.levels.WARN)
				end)
			end
		end,
	})

	if M._llama_job_id <= 0 then
		vim.notify("[lazyspeak] failed to start llama-server", vim.log.levels.ERROR)
		M._llama_job_id = nil
		on_phase("error", "failed to spawn llama-server")
		return
	end

	local timer = vim.uv.new_timer()
	local finished = false
	local in_flight = false

	---@param ok boolean
	---@param message? string
	local function finish(ok, message)
		if finished then
			return
		end
		finished = true
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		if ok then
			vim.notify("[lazyspeak] llama-server ready")
			on_phase("ready")
			if on_ready then
				on_ready()
			end
		else
			vim.notify("[lazyspeak] " .. (message or "llama-server failed"), vim.log.levels.ERROR)
			on_phase("error", message)
		end
	end

	timer:start(
		500,
		1000,
		vim.schedule_wrap(function()
			if finished then
				return
			end
			if M._llama_job_id == nil then
				return finish(false, "llama-server exited before becoming ready")
			end
			if vim.uv.now() - last_progress > stall_ms then
				return finish(
					false,
					("llama-server made no progress for %ds — check memory pressure"):format(
						math.floor(stall_ms / 1000)
					)
				)
			end
			-- One probe at a time; a slow probe must not queue up behind itself.
			if in_flight then
				return
			end
			in_flight = true
			M.probe_server(port, function(alive)
				in_flight = false
				if alive then
					last_progress = vim.uv.now()
					finish(true)
				end
			end)
		end)
	)
end

--- Stop the managed llama-server process.
function M.stop_llama_server()
	if M._llama_job_id then
		vim.fn.jobstop(M._llama_job_id)
		M._llama_job_id = nil
	end
end

M.HF_REPO = HF_REPO
M.DEFAULT_PORT = DEFAULT_PORT

return M
