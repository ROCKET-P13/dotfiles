-- Finder for the filepicker plugin.
--
-- Builds a one-time candidate list for the current cwd (MRU entries first,
-- then on-disk files from `fd`/`rg`/a Lua fallback, with configurable
-- extension exclusions), then wraps it in a Telescope dynamic finder whose
-- `fn` does a cheap subsequence pre-filter per keystroke so the expensive
-- VSCode scorer only runs on plausible matches.

local sorter_mod = require("filepicker.sorter")

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

-- Leading pad + icon + gap shown before each path. Kept in sync with the
-- segments assembled in make_display so left-truncation stays accurate.
local LEFT_PAD = "  "
local ICON_GAP = " "

local M = {}

local function list_cmd(cwd)
	if vim.fn.executable("fd") == 1 then
		return { "fd", "--type", "f", "--hidden", "--follow", "--exclude", ".git", "--exclude", "node_modules", ".", cwd }
	elseif vim.fn.executable("rg") == 1 then
		return { "rg", "--files", "--hidden", "--glob", "!.git/*", "--glob", "!**/node_modules/**", cwd }
	end
	return nil
end

-- Lists files that live *inside* a node_modules directory (at any depth),
-- ignoring .gitignore so vendored deps are reachable. Only used lazily when the
-- prompt opts in via a literal "node_modules/" substring.
local function list_node_modules_cmd(cwd)
	if vim.fn.executable("fd") == 1 then
		return { "fd", "--type", "f", "--hidden", "--follow", "--no-ignore", "--full-path", "node_modules", cwd }
	elseif vim.fn.executable("rg") == 1 then
		return { "rg", "--files", "--hidden", "--no-ignore", "--glob", "**/node_modules/**", cwd }
	end
	return nil
end

-- Walk the filesystem by hand when neither fd nor rg is available. When
-- `include_node_modules` is true the walk instead descends *only* into
-- node_modules trees, mirroring list_node_modules_cmd for the fallback path.
local function fallback_walk(cwd, include_node_modules)
	local res = {}
	local function walk(dir, inside_node_modules)
		local handle = vim.uv.fs_scandir(dir)
		if not handle then
			return
		end
		while true do
			local name, ftype = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local is_node_modules = name == "node_modules"
			if name == ".git" then
				-- skip vcs metadata
			elseif not include_node_modules and is_node_modules then
				-- skip noisy dirs for the default listing
			elseif ftype == "directory" then
				walk(dir .. "/" .. name, inside_node_modules or is_node_modules)
			elseif ftype == "file" then
				-- when opted in, only surface files that live under node_modules
				if not include_node_modules or inside_node_modules then
					table.insert(res, dir .. "/" .. name)
				end
			end
		end
	end
	walk(cwd, false)
	return res
end

local function ext_of(path)
	return path:match("%.([%w]+)$") or ""
end

-- Extensions / filenames treated as binary or otherwise non-text junk. These
-- are never useful in a file picker and are excluded from candidates. The set
-- is conservative; extend via opts.exclude_ext for project-specific cases.
local BINARY_EXT = {
	-- archives
	zip = true, gz = true, tar = true, tgz = true, bz2 = true, ["7z"] = true, rar = true, xz = true,
	-- images
	png = true, jpg = true, jpeg = true, gif = true, bmp = true, tiff = true, tif = true, ico = true,
	webp = true, heic = true, psd = true, ai = true,
	-- audio
	mp3 = true, wav = true, ogg = true, flac = true, aac = true, m4a = true,
	-- video
	mp4 = true, mkv = true, avi = true, mov = true, webm = true,
	-- office / pdf
	pdf = true, doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true, odt = true,
	-- compiled / bytecode
	o = true, so = true, dll = true, a = true, dylib = true, exe = true, class = true, jar = true,
	pyc = true, pyo = true, wasm = true,
	-- fonts
	ttf = true, otf = true, woff = true, woff2 = true, eot = true,
	-- databases / blobs
	db = true, sqlite = true, sqlite3 = true, bin = true, dat = true, iso = true, dmg = true,
}

local JUNK_NAMES = {
	[".DS_Store"] = true,
	["Thumbs.db"] = true,
}

-- True if `fname` (a basename) should be excluded: user-specified exts,
-- known binary extensions, or OS junk files.
local function should_exclude(fname, exclude_ext)
	if JUNK_NAMES[fname] then
		return true
	end
	local ext = ext_of(fname):lower()
	return exclude_ext[ext] or BINARY_EXT[ext] or false
end

-- Normalize a raw line (relative or absolute) into { abs, rel } for `cwd`.
local function normalize(cwd, line)
	local abs = line:sub(1, 1) == "/" and line or vim.fs.abspath(vim.fs.joinpath(cwd, line))
	local rel = vim.fs.relpath(cwd, abs) or line
	return abs, rel
end

-- Run a listing command (or the fallback walk) and return its raw line list.
local function run_listing(cmd, fallback)
	if cmd then
		local raw = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 then
			return {}
		end
		return raw
	end
	return fallback()
end

-- Convert a raw fd/rg/fallback line list into candidate tables, appending to
-- `candidates` and skipping paths already in `seen` or excluded by extension.
local function append_disk_candidates(raw, cwd, candidates, seen, exclude_ext, cap)
	table.sort(raw, function(a, b)
		return a < b
	end)
	for _, line in ipairs(raw) do
		if line ~= "" and #candidates < cap then
			local abs, rel = normalize(cwd, line)
			if not seen[abs] then
				seen[abs] = true
				local fname = rel:match("([^/\\]+)$") or rel
				if not should_exclude(fname, exclude_ext) then
					table.insert(candidates, {
						path = abs,
						rel = rel,
						is_mru = false,
						recency_rank = 0,
						filename_part = fname,
					})
				end
			end
		end
	end
end

-- Build the full ordered candidate list for `cwd`, excluding node_modules.
-- `mru_list` is the output of mru.list_under(cwd). `opts.exclude_ext` is a set
-- like { csv = true }. `opts.max_files` caps the on-disk portion.
function M.build(cwd, mru_list, opts)
	opts = opts or {}
	local exclude_ext = opts.exclude_ext or { csv = true }
	local max_files = opts.max_files or 50000

	local raw = run_listing(list_cmd(cwd), function()
		return fallback_walk(cwd, false)
	end)

	local candidates = {}
	local seen = {}

	-- MRU entries first, preserving recency rank.
	for _, e in ipairs(mru_list) do
		local rel = vim.fs.relpath(cwd, e.path) or e.path
		local fname = e.path:match("([^/\\]+)$") or e.path
		if not should_exclude(fname, exclude_ext) then
			seen[e.path] = true
			table.insert(candidates, {
				path = e.path,
				rel = rel,
				is_mru = true,
				recency_rank = e.rank,
				filename_part = fname,
			})
		end
	end

	-- On-disk files, sorted alphabetically for a stable empty-prompt order.
	append_disk_candidates(raw, cwd, candidates, seen, exclude_ext, max_files + #mru_list)

	return candidates
end

-- Build the node_modules-only candidate list for `cwd`. Kept separate from
-- M.build so it can be produced lazily the first time a search opts into it.
function M.build_node_modules(cwd, opts)
	opts = opts or {}
	local exclude_ext = opts.exclude_ext or { csv = true }
	local max_files = opts.max_files or 50000

	local raw = run_listing(list_node_modules_cmd(cwd), function()
		return fallback_walk(cwd, true)
	end)

	local candidates = {}
	append_disk_candidates(raw, cwd, candidates, {}, exclude_ext, max_files)
	return candidates
end

-- Telescope entry maker. Memoizes on the candidate table so repeated `fn`
-- invocations don't rebuild entries every keystroke. The `display` function
-- left-truncates long paths so the filename/end of the path stays visible
-- instead of the leading directory structure.
function M.entry_maker()
	return function(item)
		if item._entry then
			return item._entry
		end
		local rel = item.rel

		-- Resolve the devicon once per candidate; cached on the entry so the
		-- highlight stays stable across re-renders. Falls back to no icon when
		-- nvim-web-devicons isn't available.
		local icon, icon_hl
		if has_devicons then
			local ext = ext_of(item.filename_part)
			icon, icon_hl = devicons.get_icon(item.filename_part, ext, { default = true })
		end

		-- Display width consumed by everything to the left of the path: the
		-- left pad, the icon glyph, and the gap between icon and path.
		local prefix_len = #LEFT_PAD + (icon and #icon or 0) + (icon and #ICON_GAP or 0)

		local function make_display(entry, picker)
			local win = picker and picker.layout and picker.layout.results and picker.layout.results.winid
			local width = win and (vim.api.nvim_win_get_width(win) - #(picker.selection_caret or "> ") - prefix_len)
			local path
			if not width or #rel <= width then
				path = rel
			else
				-- keep the tail (filename + deepest dirs); drop the leading portion
				path = "…" .. rel:sub(#rel - width + 2)
			end

			local display = LEFT_PAD
			if icon then
				display = display .. icon .. ICON_GAP .. path
			else
				display = display .. path
			end

			-- Telescope expects (string, highlights) where each highlight is
			-- { {byte_start, byte_end}, hl_group } (0-indexed, end-exclusive).
			-- Only the icon glyph gets a highlight; the path relies on the
			-- sorter/matcher highlights applied separately by Telescope.
			local highlights
			if icon and icon_hl then
				local icon_start = #LEFT_PAD
				local icon_end = icon_start + #icon
				highlights = { { { icon_start, icon_end }, icon_hl } }
			end
			return display, highlights
		end
		local entry = {
			value = item.path,
			filename = item.path,
			ordinal = rel,
			display = make_display,
			is_mru = item.is_mru,
			recency_rank = item.recency_rank,
			filename_part = item.filename_part,
		}
		item._entry = entry
		return entry
	end
end

-- Rank `list` by descending `goodness` (stable on candidate order for ties)
-- and return at most `max_results` entries. `nil` goodness drops the entry.
local function rank_and_cap(list, prompt, max_results, scorer_opts)
	if max_results == nil or max_results <= 0 then
		return list
	end
	local scored = {}
	for i, c in ipairs(list) do
		local g = sorter_mod.goodness(prompt, c.rel, c, scorer_opts)
		if g ~= nil then
			scored[#scored + 1] = { i = i, g = g, c = c }
		end
	end
	table.sort(scored, function(a, b)
		if a.g ~= b.g then
			return a.g > b.g
		end
		return a.i < b.i
	end)
	local out = {}
	for i = 1, math.min(#scored, max_results) do
		out[i] = scored[i].c
	end
	return out
end

-- Wrap the candidate list in a dynamic finder. The `fn` pre-filters by a
-- cheap subsequence match so the scorer only sees candidates that can match,
-- then ranks by `goodness` and caps to `opts.max_results` so only the top-N
-- reach Telescope.
-- Prompt substring that opts a search into node_modules results.
local NODE_MODULES_TRIGGER = "node_modules/"

function M.make_finder(candidates, opts)
	opts = opts or {}
	local cwd = opts.cwd
	local max_results = opts.max_results
	local scorer_opts = {
		recency_weight = opts.recency_weight,
		test_penalty = opts.test_penalty,
		xml_html_penalty = opts.xml_html_penalty,
	}

	-- node_modules candidates are expensive and rarely wanted, so build them at
	-- most once and only when a prompt first opts in.
	local nm_candidates
	local function node_modules_candidates()
		if nm_candidates == nil then
			nm_candidates = cwd
					and M.build_node_modules(cwd, {
						exclude_ext = opts.exclude_ext,
						max_files = opts.max_files,
					})
				or {}
		end
		return nm_candidates
	end

	local finders = require("telescope.finders")
	return finders.new_dynamic({
		fn = function(prompt)
			if prompt == nil or prompt == "" then
				return rank_and_cap(candidates, prompt, max_results, scorer_opts)
			end
			local pool = {}
			for _, c in ipairs(candidates) do
				if sorter_mod.has_match(prompt, c.rel) then
					pool[#pool + 1] = c
				end
			end
			if prompt:find(NODE_MODULES_TRIGGER, 1, true) then
				for _, c in ipairs(node_modules_candidates()) do
					if sorter_mod.has_match(prompt, c.rel) then
						pool[#pool + 1] = c
					end
				end
			end
			return rank_and_cap(pool, prompt, max_results, scorer_opts)
		end,
		entry_maker = M.entry_maker(),
	})
end

return M
