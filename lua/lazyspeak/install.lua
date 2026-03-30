local M = {}

local DATA_DIR = vim.fn.expand("~/.local/share/lazyspeak")
local ONNX_DIR = DATA_DIR .. "/onnx"

function M.run()
	vim.fn.mkdir(DATA_DIR, "p")

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

	-- Convert ONNX model if not present
	if vim.fn.isdirectory(ONNX_DIR) == 1 then
		vim.notify("[lazyspeak] ONNX model already exists at " .. ONNX_DIR)
	else
		vim.notify("[lazyspeak] converting Voxtral model to ONNX (requires Python deps)...")
		local plugin_dir = debug.getinfo(1, "S").source:match("@(.*/)")
		if plugin_dir then
			plugin_dir = plugin_dir:gsub("/lua/lazyspeak/$", "")
		end

		local script = plugin_dir and (plugin_dir .. "/scripts/convert_model.py") or nil
		if script and vim.fn.filereadable(script) == 1 then
			vim.fn.jobstart({ "python3", script, "--output", DATA_DIR, "--quantize", "q4" }, {
				on_exit = function(_, code, _)
					vim.schedule(function()
						if code == 0 then
							vim.notify("[lazyspeak] ONNX model ready at " .. ONNX_DIR)
						else
							vim.notify("[lazyspeak] ONNX conversion failed — run `just convert-model` manually", vim.log.levels.ERROR)
						end
					end)
				end,
			})
		else
			vim.notify("[lazyspeak] convert script not found — run `just convert-model` manually", vim.log.levels.WARN)
		end
	end
end

M.ONNX_DIR = ONNX_DIR
M.DATA_DIR = DATA_DIR

return M
