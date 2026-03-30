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

	-- llama-server (STT inference)
	if vim.fn.executable("llama-server") == 1 then
		vim.health.ok("llama-server found")
	else
		vim.health.warn("llama-server not found (needed for STT)", {
			"Install: brew install llama.cpp",
		})
	end

	-- Claude CLI (for claudecode adapter)
	if vim.fn.executable("claude") == 1 then
		vim.health.ok("claude CLI found")
	else
		vim.health.info("claude CLI not found (needed for claudecode adapter)")
	end

	-- Model file
	local install = require("lazyspeak.install")
	if vim.fn.filereadable(install.MODEL_PATH) == 1 then
		local size = vim.fn.getfsize(install.MODEL_PATH)
		if size > 1000000 then
			local size_gb = string.format("%.1f GB", size / (1024 * 1024 * 1024))
			vim.health.ok("Voxtral model found (" .. size_gb .. ")")
		else
			vim.health.warn("Voxtral model file is too small — may be corrupted", {
				"Run: :LazySpeakInstall",
				"Or: just convert-model",
			})
		end
	else
		vim.health.info("Voxtral model not found", {
			"Run: :LazySpeakInstall",
			"Or: just convert-model",
		})
	end

	-- Plugin state
	local ok, ls = pcall(require, "lazyspeak")
	if ok and ls.config and ls.config.agent then
		vim.health.ok("plugin loaded (adapter: " .. ls.config.agent.adapter .. ")")
	elseif ok then
		vim.health.warn("plugin loaded but not configured — call require('lazyspeak').setup()")
	else
		vim.health.error("plugin failed to load")
	end
end

return M
