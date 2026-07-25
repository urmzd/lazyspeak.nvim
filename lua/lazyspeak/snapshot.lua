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

--- Content fingerprint of the working tree, used to tell whether a turn changed
--- anything at all. More truthful than trusting the agent to report every write
--- it made.
---
--- Hashes `git diff HEAD` rather than `git status --porcelain`: porcelain names
--- which files differ but not how, so an edit to an already-modified file left
--- the fingerprint unchanged. `git diff HEAD` also covers exactly what
--- `git stash create` captures — tracked changes, staged or not — so the
--- fingerprint and the snapshot agree on scope.
---@return string
local function worktree_digest()
	local diff = vim.fn.system("git diff HEAD 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		-- Unborn branch: no HEAD to diff against yet.
		diff = vim.fn.system("git status --porcelain 2>/dev/null")
	end
	return vim.fn.sha256(diff)
end

--- Drop a stored stash entry, located by its commit SHA.
---
--- `git stash list` prints `stash@{n}: <message>` with no SHA, so the previous
--- lookup (matching a SHA prefix against those lines) could never succeed and
--- silently dropped nothing. `--format=%H` is what actually exposes the SHA.
---@param ref string
---@return boolean dropped
local function drop_stash(ref)
	if not ref or ref == "" or ref == "clean" then
		return false
	end
	local shas = vim.fn.systemlist("git stash list --format=%H")
	for i, sha in ipairs(shas) do
		if vim.trim(sha) == ref then
			vim.fn.system("git stash drop stash@{" .. (i - 1) .. "}")
			return vim.v.shell_error == 0
		end
	end
	return false
end

M.drop_stash = drop_stash

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
		digest = nil,
	}

	if self.use_git and is_git_repo() then
		-- Recorded so `discard` can prove nothing changed before removing this.
		snapshot.digest = worktree_digest()
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

	-- Trim stack if over limit. The evicted entry's stash has to go with it:
	-- dropping only the Lua record left the git stash alive forever, so
	-- `max_stack` bounded the undo stack while bounding nothing in git.
	while #self.stack > self.max_stack do
		local evicted = table.remove(self.stack, 1)
		drop_stash(evicted.stash_ref)
	end

	return snapshot
end

--- Discard a snapshot the turn never needed, so it does not linger as an
--- unreachable stash entry. Refuses unless the working tree is byte-identical
--- to when the snapshot was taken, because otherwise it is the only way back.
---@param snapshot lazyspeak.Snapshot
---@return boolean discarded
function SnapshotStack:discard(snapshot)
	if not snapshot then
		return false
	end
	if snapshot.digest and worktree_digest() ~= snapshot.digest then
		return false
	end
	for i, s in ipairs(self.stack) do
		if s.id == snapshot.id then
			table.remove(self.stack, i)
			break
		end
	end
	if snapshot.stash_ref == "" or snapshot.stash_ref == "clean" then
		return true
	end
	return drop_stash(snapshot.stash_ref)
end

--- `lazyspeak:` stash entries that no live snapshot refers to. Residue of turns
--- that failed or changed nothing; the plugin can never pop them.
---@return { sha: string, message: string }[]
function SnapshotStack:orphans()
	local live = {}
	for _, s in ipairs(self.stack) do
		if s.stash_ref and s.stash_ref ~= "" then
			live[s.stash_ref] = true
		end
	end

	local out = {}
	for _, line in ipairs(vim.fn.systemlist("git stash list --format=%H%x09%gs")) do
		local sha, message = line:match("^(%x+)\t(.*)$")
		if sha and message and message:match("^lazyspeak: ") and not live[sha] then
			out[#out + 1] = { sha = sha, message = message }
		end
	end
	return out
end

--- Drop every orphaned `lazyspeak:` stash entry.
---@return number dropped
---@return number found
function SnapshotStack:prune_orphans()
	local orphans = self:orphans()
	local dropped = 0
	for _, o in ipairs(orphans) do
		-- Re-resolves the index each time, so shifting entries are handled.
		if drop_stash(o.sha) then
			dropped = dropped + 1
		end
	end
	return dropped, #orphans
end

--- Revert the last snapshot.
---
--- Restores the contents of files that existed when the snapshot was taken.
--- Files the agent created afterwards are left in place rather than deleted,
--- since removing files is not recoverable from here.
---@return boolean success
---@return string message
function SnapshotStack:pop()
	if #self.stack == 0 then
		return false, "nothing to undo"
	end

	local snapshot = table.remove(self.stack)

	if snapshot.stash_ref ~= "" and snapshot.stash_ref ~= "clean" then
		-- `git stash apply` merges, so it aborts with "local changes would be
		-- overwritten" exactly when the agent has edited the snapshotted files —
		-- the only situation undo exists for. Restore the paths outright instead.
		local result = vim.fn.system("git restore --source=" .. snapshot.stash_ref .. " --worktree -- . 2>&1")
		if vim.v.shell_error ~= 0 then
			return false, "git restore failed: " .. result
		end
		drop_stash(snapshot.stash_ref)
		-- Reload any buffer whose file changed underneath us.
		vim.cmd("silent! checktime")
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
