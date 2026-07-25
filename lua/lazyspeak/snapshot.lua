local M = {}

--- Pre-turn snapshots, stored outside the repository.
---
--- Snapshots used to be `git stash create` + `git stash store`, which put plugin
--- bookkeeping into the user's own stash list: entries showed up in
--- `git stash list`, survived the session, and collided with the user's real
--- stashes. Snapshots now live under Neovim's state directory instead, so the
--- repository is never written to except when an undo actually restores files.
---
--- `stdpath("state")` rather than config or data: this is regenerable session
--- state, not user-authored settings, and it is where Neovim already keeps
--- undo files, swap, and shada.
---
---@class lazyspeak.SnapshotStack
---@field stack lazyspeak.Snapshot[]
---@field max_stack number
---@field root string
local SnapshotStack = {}
SnapshotStack.__index = SnapshotStack

--- Root of the snapshot store: `$XDG_STATE_HOME/nvim/lazyspeak/snapshots`.
---@return string
local function store_root()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "lazyspeak", "snapshots")
end

M.store_root = store_root

---@param root string repository root
---@param cmd string
---@return string
local function git_at(root, cmd)
	return vim.fn.system("git -C " .. vim.fn.shellescape(root) .. " " .. cmd)
end

--- Repository root, or nil when not inside a work tree.
---@return string?
local function repo_root()
	local root = vim.trim(vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"))
	if vim.v.shell_error ~= 0 or root == "" then
		return nil
	end
	return root
end

--- Tracked paths that differ from HEAD, staged or not. This is the set a
--- snapshot has to capture, and it matches what an undo has to put back.
---@param root string
---@return string[]
local function dirty_paths(root)
	local out = {}
	for _, line in ipairs(vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " diff --name-only HEAD")) do
		local p = vim.trim(line)
		if p ~= "" then
			out[#out + 1] = p
		end
	end
	return out
end

--- Content fingerprint of the working tree, so `discard` can prove a turn
--- changed nothing before throwing its snapshot away.
---
--- Hashes `git diff HEAD` rather than `git status --porcelain`: porcelain names
--- which files differ but not how, so an edit to an already-modified file left
--- the fingerprint unchanged.
---@param root string
---@return string
local function worktree_digest(root)
	local diff = git_at(root, "diff HEAD")
	if vim.v.shell_error ~= 0 then
		-- Unborn branch: no HEAD to diff against yet.
		diff = git_at(root, "status --porcelain")
	end
	return vim.fn.sha256(diff)
end

---@param opts { max_stack?: number, enabled?: boolean }
---@return lazyspeak.SnapshotStack
function SnapshotStack:new(opts)
	opts = opts or {}
	return setmetatable({
		stack = {},
		max_stack = opts.max_stack or 20,
		enabled = opts.enabled ~= false,
		root = store_root(),
	}, SnapshotStack)
end

--- Delete a snapshot's stored contents.
---@param snapshot lazyspeak.Snapshot
function SnapshotStack:_remove(snapshot)
	if snapshot and snapshot.dir then
		vim.fn.delete(snapshot.dir, "rf")
	end
end

--- Capture the working tree before a turn is dispatched.
---
--- Only tracked files that differ from HEAD are copied; a clean file is already
--- recoverable from HEAD, and untracked files are left alone (as the stash
--- implementation also did).
---@param session_id string
---@param transcript string
---@return lazyspeak.Snapshot?
function SnapshotStack:create(session_id, transcript)
	if not self.enabled then
		return nil
	end

	local root = repo_root()
	if not root then
		-- Without git there is no cheap way to know which files a turn might
		-- touch, so there is nothing sound to snapshot.
		return nil
	end

	local id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
	local dir = vim.fs.joinpath(self.root, session_id, id)
	local tree = vim.fs.joinpath(dir, "tree")

	local snapshot = {
		id = id,
		session_id = session_id,
		transcript = transcript,
		timestamp = os.time(),
		dir = dir,
		repo_root = root,
		files = {},
		digest = worktree_digest(root),
	}

	if vim.fn.mkdir(tree, "p") == 0 then
		vim.notify("[lazyspeak] could not create snapshot dir: " .. tree, vim.log.levels.WARN)
		return nil
	end

	for _, rel in ipairs(dirty_paths(root)) do
		local src = vim.fs.joinpath(root, rel)
		if vim.fn.filereadable(src) == 1 then
			local dest = vim.fs.joinpath(tree, rel)
			vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
			-- fs_copyfile is byte-exact; readfile/writefile would mangle
			-- trailing newlines and corrupt binary files.
			if vim.uv.fs_copyfile(src, dest) then
				snapshot.files[#snapshot.files + 1] = rel
			end
		end
	end

	-- Written so a crashed session's leftovers are identifiable when pruning.
	pcall(vim.fn.writefile, {
		vim.json.encode({
			id = id,
			session_id = session_id,
			transcript = transcript,
			timestamp = snapshot.timestamp,
			repo_root = root,
			files = snapshot.files,
		}),
	}, vim.fs.joinpath(dir, "meta.json"))

	table.insert(self.stack, snapshot)

	-- Evicting past the cap must delete the stored copy too, or the store grows
	-- without bound while `max_stack` appears to bound it.
	while #self.stack > self.max_stack do
		self:_remove(table.remove(self.stack, 1))
	end

	return snapshot
end

--- Revert the last snapshot.
---
--- Restores the contents of files captured at snapshot time, and returns to HEAD
--- any file the agent dirtied that was clean when the snapshot was taken. Files
--- the agent created are left in place, since deleting them is not recoverable
--- from here.
---@return boolean success
---@return string message
function SnapshotStack:pop()
	if #self.stack == 0 then
		return false, "nothing to undo"
	end

	local snapshot = table.remove(self.stack)
	local root = snapshot.repo_root or repo_root()
	if not root then
		self:_remove(snapshot)
		return false, "not in a git repository"
	end

	local captured = {}
	for _, rel in ipairs(snapshot.files) do
		captured[rel] = true
	end

	local restored = 0
	for _, rel in ipairs(snapshot.files) do
		local src = vim.fs.joinpath(snapshot.dir, "tree", rel)
		local dest = vim.fs.joinpath(root, rel)
		if vim.fn.filereadable(src) == 1 then
			vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
			if vim.uv.fs_copyfile(src, dest) then
				restored = restored + 1
			end
		end
	end

	local reset = 0
	for _, rel in ipairs(dirty_paths(root)) do
		if not captured[rel] then
			git_at(root, "restore --source=HEAD --worktree -- " .. vim.fn.shellescape(rel))
			if vim.v.shell_error == 0 then
				reset = reset + 1
			end
		end
	end

	self:_remove(snapshot)
	-- Reload buffers whose files changed underneath us.
	vim.cmd("silent! checktime")

	return true, ("reverted %d file(s), reset %d: %s"):format(restored, reset, (snapshot.transcript or ""):sub(1, 50))
end

--- Revert all snapshots for the current session.
---@return number count
function SnapshotStack:pop_all()
	local count = 0
	while #self.stack > 0 do
		local ok = self:pop()
		if ok then
			count = count + 1
		else
			break
		end
	end
	return count
end

--- Give back a snapshot the turn never needed, so it does not linger on disk.
--- Refuses unless the working tree is byte-identical to snapshot time, because
--- otherwise this is the only way back.
---@param snapshot lazyspeak.Snapshot
---@return boolean discarded
function SnapshotStack:discard(snapshot)
	if not snapshot then
		return false
	end
	local root = snapshot.repo_root or repo_root()
	if root and snapshot.digest and worktree_digest(root) ~= snapshot.digest then
		return false
	end
	for i, s in ipairs(self.stack) do
		if s.id == snapshot.id then
			table.remove(self.stack, i)
			break
		end
	end
	self:_remove(snapshot)
	return true
end

--- Drop this session's stored snapshots. Called on shutdown: an undo point is
--- only meaningful while the session that created it is alive.
---@param session_id string
function SnapshotStack:cleanup_session(session_id)
	self.stack = {}
	if session_id then
		vim.fn.delete(vim.fs.joinpath(self.root, session_id), "rf")
	end
end

---@return lazyspeak.Snapshot[]
function SnapshotStack:list()
	return self.stack
end

--- Session directories left behind by crashed or killed sessions.
---@param max_age_days? number default 7
---@return string[] directories
function SnapshotStack:stale_sessions(max_age_days)
	local cutoff = os.time() - (max_age_days or 7) * 86400
	local out = {}
	local handle = vim.uv.fs_scandir(self.root)
	if not handle then
		return out
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "directory" then
			local path = vim.fs.joinpath(self.root, name)
			local stat = vim.uv.fs_stat(path)
			if stat and stat.mtime and stat.mtime.sec < cutoff then
				out[#out + 1] = path
			end
		end
	end
	return out
end

--- Delete session directories older than `max_age_days`.
---@param max_age_days? number
---@return number removed
function SnapshotStack:prune_stale(max_age_days)
	local removed = 0
	for _, dir in ipairs(self:stale_sessions(max_age_days)) do
		if vim.fn.delete(dir, "rf") == 0 then
			removed = removed + 1
		end
	end
	return removed
end

-- Migration from the git-stash implementation -------------------------------

--- Drop a stored stash entry, located by its commit SHA.
---
--- `git stash list` prints `stash@{n}: <message>` with no SHA, so the original
--- lookup (matching a SHA prefix against those lines) could never succeed and
--- silently dropped nothing. `--format=%H` is what actually exposes it.
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

--- `lazyspeak:` stash entries written by the previous implementation. Nothing
--- refers to these any more, so they are pure residue.
---@return { sha: string, message: string }[]
function SnapshotStack:orphans()
	local out = {}
	for _, line in ipairs(vim.fn.systemlist("git stash list --format=%H%x09%gs")) do
		local sha, message = line:match("^(%x+)\t(.*)$")
		if sha and message and message:match("^lazyspeak: ") then
			out[#out + 1] = { sha = sha, message = message }
		end
	end
	return out
end

--- Drop every legacy `lazyspeak:` stash entry.
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

M.SnapshotStack = SnapshotStack
return M
