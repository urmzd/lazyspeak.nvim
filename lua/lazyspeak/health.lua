local M = {}

function M.check()
	vim.health.start("lazyspeak")

	-- Daemon binary
	if vim.fn.executable("lazyspeak") == 1 then
		vim.health.ok("daemon binary found in PATH")
	else
		vim.health.warn("daemon binary not in PATH", {
			"Run: cargo install --path crates/lazyspeak",
			"Or: just install",
		})
	end

	-- Claude CLI (for claudecode adapter)
	if vim.fn.executable("claude") == 1 then
		vim.health.ok("claude CLI found")
	else
		vim.health.info("claude CLI not found (needed for claudecode adapter)")
	end

	-- ONNX model
	local install = require("lazyspeak.install")
	if vim.fn.isdirectory(install.ONNX_DIR) == 1 then
		vim.health.ok("ONNX model found at " .. install.ONNX_DIR)
	else
		vim.health.info("ONNX model not found", {
			"Run: :LazySpeakInstall",
			"Or: just convert-model",
		})
	end

	-- Python (for model conversion)
	if vim.fn.executable("python3") == 1 then
		vim.health.ok("python3 found")
	else
		vim.health.warn("python3 not found (needed for ONNX model conversion)")
	end

	-- Plugin state
	local ok, ls = pcall(require, "lazyspeak")
	if ok and ls.config and ls.config.agent then
		vim.health.ok("plugin loaded (adapter: " .. ls.config.agent.adapter .. ", backend: " .. ls.config.model.backend .. ")")
	elseif ok then
		vim.health.warn("plugin loaded but not configured — call require('lazyspeak').setup()")
	else
		vim.health.error("plugin failed to load")
	end
end

return M
