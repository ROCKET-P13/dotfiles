-- Persisted most-recently-used file store for the filepicker plugin.
-- Keeps an ordered list of absolute paths (newest first), capped at `cap`,
-- serialized to JSON in stdpath("data") so recents survive restarts.

local M = {}

local uv = vim.uv or vim.loop
local store_path = vim.fn.stdpath("data") .. "/filepicker_mru.json"

local cap = 200
local items = {} -- { { path = abs, ts = os.time() }, ... } newest first
local loaded = false

local function load()
	if loaded then
		return
	end
	loaded = true
	local f = io.open(store_path, "r")
	if not f then
		return
	end
	local body = f:read("*a")
	f:close()
	if not body or body == "" then
		return
	end
	local ok, data = pcall(vim.json.decode, body)
	if not ok or type(data) ~= "table" then
		return
	end
	for _, e in ipairs(data) do
		if type(e) == "table" and type(e.path) == "string" and not M._contains(e.path) then
			table.insert(items, e)
		end
	end
end

function M._contains(path)
	for _, e in ipairs(items) do
		if e.path == path then
			return true
		end
	end
	return false
end

local function save()
	local f = io.open(store_path, "w")
	if not f then
		return
	end
	local ok, body = pcall(vim.json.encode, items)
	if ok then
		f:write(body or "")
	end
	f:close()
end

function M.setup(opts)
	opts = opts or {}
	cap = opts.mru_cap or cap
	load()
end

-- Move `path` to the front of the MRU list, dropping it from its old position.
-- Persisted on every call; the list is small so this is cheap.
function M.record(path)
	if not path or path == "" then
		return
	end
	load()
	for i, e in ipairs(items) do
		if e.path == path then
			table.remove(items, i)
			break
		end
	end
	table.insert(items, 1, { path = path, ts = os.time() })
	while #items > cap do
		table.remove(items, #items)
	end
	save()
end

-- Return MRU entries that live under `cwd` and still exist on disk, newest first.
-- Each entry is { path = abs, ts = seconds, rank = 1-based position }.
function M.list_under(cwd)
	load()
	local out = {}
	for _, e in ipairs(items) do
		if vim.fs.relpath(cwd, e.path) and uv.fs_stat(e.path) then
			table.insert(out, { path = e.path, ts = e.ts, rank = #out + 1 })
		end
	end
	return out
end

return M
