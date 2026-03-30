local M = {}

local DATA_DIR = vim.fn.expand("~/.local/share/lazyspeak")
local MODEL_NAME = "voxtral-mini-3b-q4_k_m.gguf"
local MODEL_PATH = DATA_DIR .. "/" .. MODEL_NAME

function M.run()
	vim.fn.mkdir(DATA_DIR, "p")

	-- Check if model already exists
	if vim.fn.filereadable(MODEL_PATH) == 1 then
		vim.notify("[lazyspeak] model already exists at " .. MODEL_PATH)
	else
		vim.notify("[lazyspeak] downloading model (~2.5 GB)... this may take a while")
		local url = "https://huggingface.co/mistralai/Voxtral-Mini-3B-2507-GGUF/resolve/main/" .. MODEL_NAME

		vim.fn.jobstart({ "curl", "-L", "-o", MODEL_PATH, "--progress-bar", url }, {
			on_exit = function(_, code, _)
				vim.schedule(function()
					if code == 0 then
						vim.notify("[lazyspeak] model downloaded to " .. MODEL_PATH)
					else
						vim.notify("[lazyspeak] model download failed (exit " .. code .. ")", vim.log.levels.ERROR)
					end
				end)
			end,
		})
	end

	-- Check if daemon binary is installed
	if vim.fn.executable("lazyspeak") == 0 then
		vim.notify("[lazyspeak] building daemon binary...")
		-- Find the plugin directory
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
							vim.notify("[lazyspeak] daemon build failed — run `cargo install --path crates/lazyspeak` manually", vim.log.levels.ERROR)
						end
					end)
				end,
			})
		else
			vim.notify("[lazyspeak] could not find crates/ dir — run `cargo install --path crates/lazyspeak` manually", vim.log.levels.WARN)
		end
	else
		vim.notify("[lazyspeak] daemon binary already installed")
	end
end

--- llama-server process management

---@type number?
M._llama_job_id = nil

local DEFAULT_PORT = 8674
local HEALTH_PATH = "/health"

--- Check if a server is already responding on the given port.
---@param port number
---@return boolean
function M.is_server_running(port)
	local url = string.format("http://127.0.0.1:%d%s", port, HEALTH_PATH)
	local handle = io.popen(string.format("curl -sf %s 2>/dev/null", url))
	if not handle then
		return false
	end
	local result = handle:read("*a")
	handle:close()
	return result ~= nil and result ~= ""
end

--- Start llama-server with the Voxtral model if not already running.
---@param opts? { port?: number, model_path?: string }
---@param on_ready? fun() called once the server is healthy
function M.start_llama_server(opts, on_ready)
	opts = opts or {}
	local port = opts.port or DEFAULT_PORT
	local model_path = vim.fn.expand(opts.model_path or MODEL_PATH)

	-- Already managed by us
	if M._llama_job_id then
		if on_ready then on_ready() end
		return
	end

	-- Something else is already listening on the port
	if M.is_server_running(port) then
		vim.notify("[lazyspeak] llama-server already running on port " .. port)
		if on_ready then on_ready() end
		return
	end

	-- Model must exist
	if vim.fn.filereadable(model_path) ~= 1 then
		vim.notify("[lazyspeak] model not found at " .. model_path .. " — run :LazySpeakInstall first", vim.log.levels.ERROR)
		return
	end

	-- llama-server must be installed
	if vim.fn.executable("llama-server") ~= 1 then
		vim.notify("[lazyspeak] llama-server not found — install llama.cpp (brew install llama.cpp)", vim.log.levels.ERROR)
		return
	end

	vim.notify("[lazyspeak] starting llama-server on port " .. port .. "...")

	M._llama_job_id = vim.fn.jobstart({
		"llama-server",
		"-m", model_path,
		"--port", tostring(port),
	}, {
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
		return
	end

	-- Poll until server is healthy (up to 30s)
	if on_ready then
		local attempts = 0
		local max_attempts = 60
		local timer = vim.uv.new_timer()
		timer:start(500, 500, vim.schedule_wrap(function()
			attempts = attempts + 1
			if M.is_server_running(port) then
				timer:stop()
				timer:close()
				vim.notify("[lazyspeak] llama-server ready")
				on_ready()
			elseif attempts >= max_attempts then
				timer:stop()
				timer:close()
				vim.notify("[lazyspeak] llama-server did not become ready in time", vim.log.levels.ERROR)
			end
		end))
	end
end

--- Stop the managed llama-server process.
function M.stop_llama_server()
	if M._llama_job_id then
		vim.fn.jobstop(M._llama_job_id)
		M._llama_job_id = nil
	end
end

M.MODEL_PATH = MODEL_PATH
M.DATA_DIR = DATA_DIR

return M
