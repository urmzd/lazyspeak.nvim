--- Claude Code adapter.
---
--- A thin preset over the ACP adapter: it launches Anthropic's official ACP
--- bridge (`@agentclientprotocol/claude-agent-acp`, formerly
--- `@zed-industries/claude-code-acp`) and then speaks standard ACP. This gives
--- real session continuity, streamed responses, tool-call visibility,
--- permission prompts, and file-edit events — everything the old
--- `claude --print -p` pipe could not do.
---
--- Authentication: the spawned process inherits the environment, so set
--- `ANTHROPIC_API_KEY`, or rely on a prior `claude login` token. No in-editor
--- auth flow is required.
---
--- Override the launch command with `agent.cmd` if you have the bridge
--- installed globally (e.g. `{ "claude-agent-acp" }`).
---@class lazyspeak.ClaudeCodeAdapter : lazyspeak.Adapter

local acp = require("lazyspeak.adapters.acp")

--- Default command: run the published ACP bridge via npx.
local DEFAULT_CMD = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }

local M = {}

---@param opts table
function M.start(opts)
	opts = vim.deepcopy(opts or {})
	opts.agent = opts.agent or {}
	if not opts.agent.cmd then
		opts.agent.cmd = DEFAULT_CMD
	end
	return acp.start(opts)
end

M.stop = acp.stop
M.send = acp.send
M.on_event = acp.on_event
M.agent_capabilities = acp.agent_capabilities

return M
