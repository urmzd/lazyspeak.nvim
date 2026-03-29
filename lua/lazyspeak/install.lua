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
			vim.fn.jobstart({ "cargo", "install", "--path", plugin_dir .. "/crates/lazyspeak-cli" }, {
				on_exit = function(_, code, _)
					vim.schedule(function()
						if code == 0 then
							vim.notify("[lazyspeak] daemon binary installed")
						else
							vim.notify("[lazyspeak] daemon build failed — run `cargo install --path crates/lazyspeak-cli` manually", vim.log.levels.ERROR)
						end
					end)
				end,
			})
		else
			vim.notify("[lazyspeak] could not find crates/ dir — run `cargo install --path crates/lazyspeak-cli` manually", vim.log.levels.WARN)
		end
	else
		vim.notify("[lazyspeak] daemon binary already installed")
	end
end

M.MODEL_PATH = MODEL_PATH
M.DATA_DIR = DATA_DIR

return M
