local M = {}

---@class lazyspeak.SnapshotStack
---@field stack lazyspeak.Snapshot[]
---@field max_stack number
---@field use_git boolean
local SnapshotStack = {}
SnapshotStack.__index = SnapshotStack

---@param opts { max_stack?: number, use_git?: boolean }
---@return lazyspeak.SnapshotStack
function SnapshotStack:new(opts)
	return setmetatable({
		stack = {},
		max_stack = opts.max_stack or 20,
		use_git = opts.use_git ~= false,
	}, SnapshotStack)
end

---@return boolean
local function is_git_repo()
	return vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null"):match("true") ~= nil
end

--- Create a snapshot of the current state before an edit.
---@param session_id string
---@param transcript string
---@param files? string[]
---@return lazyspeak.Snapshot?
function SnapshotStack:create(session_id, transcript, files)
	local snapshot = {
		id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
		session_id = session_id,
		transcript = transcript,
		timestamp = os.time(),
		files = files or {},
		stash_ref = "",
		undo_data = {},
	}

	if self.use_git and is_git_repo() then
		-- git stash create makes a stash commit without modifying the working tree
		local ref = vim.fn.system("git stash create"):gsub("%s+", "")
		if ref ~= "" then
			-- Store the ref so we can apply it later
			vim.fn.system("git stash store -m 'lazyspeak: " .. transcript:sub(1, 50) .. "' " .. ref)
			snapshot.stash_ref = ref
		else
			-- No changes to stash — working tree is clean
			snapshot.stash_ref = "clean"
		end
	else
		-- Non-git fallback: cache file contents in memory
		for _, path in ipairs(files) do
			local content = vim.fn.readfile(path)
			if content then
				snapshot.undo_data[path] = table.concat(content, "\n")
			end
		end
	end

	table.insert(self.stack, snapshot)

	-- Trim stack if over limit
	while #self.stack > self.max_stack do
		table.remove(self.stack, 1)
	end

	return snapshot
end

--- Revert the last snapshot.
---@return boolean success
---@return string message
function SnapshotStack:pop()
	if #self.stack == 0 then
		return false, "nothing to undo"
	end

	local snapshot = table.remove(self.stack)

	if snapshot.stash_ref ~= "" and snapshot.stash_ref ~= "clean" then
		local result = vim.fn.system("git stash apply " .. snapshot.stash_ref .. " 2>&1")
		if vim.v.shell_error ~= 0 then
			return false, "git stash apply failed: " .. result
		end
		-- Drop the stash entry
		local stash_list = vim.fn.systemlist("git stash list")
		for i, line in ipairs(stash_list) do
			if line:match(snapshot.stash_ref:sub(1, 7)) then
				vim.fn.system("git stash drop stash@{" .. (i - 1) .. "}")
				break
			end
		end
		return true, "reverted via git stash: " .. snapshot.transcript:sub(1, 50)
	elseif next(snapshot.undo_data) then
		for path, content in pairs(snapshot.undo_data) do
			vim.fn.writefile(vim.split(content, "\n"), path)
			-- Reload buffer if open
			local bufnr = vim.fn.bufnr(path)
			if bufnr ~= -1 then
				vim.api.nvim_buf_call(bufnr, function()
					vim.cmd("edit!")
				end)
			end
		end
		return true, "reverted files: " .. snapshot.transcript:sub(1, 50)
	end

	return true, "reverted (was clean): " .. snapshot.transcript:sub(1, 50)
end

--- Revert all snapshots for the current session.
---@return number count
function SnapshotStack:pop_all()
	local count = 0
	while #self.stack > 0 do
		local ok, _ = self:pop()
		if ok then
			count = count + 1
		else
			break
		end
	end
	return count
end

---@return lazyspeak.Snapshot[]
function SnapshotStack:list()
	return self.stack
end

M.SnapshotStack = SnapshotStack
return M
