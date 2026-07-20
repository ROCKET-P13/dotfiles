-- Project-wide find & replace, modeled on nvim-spectre but self-contained.
--
-- A dedicated editable panel: the top rows are Search / Replace / Files inputs
-- (with inline virtual-text labels so the whole line is the raw value), a status
-- line with the active toggles and counts, and below a live, grouped list of
-- ripgrep matches with an inline replacement preview. Applying edits files on
-- disk with ripgrep's own engine (so regex backreferences match the preview),
-- then reloads any unmodified open buffers.

local M = {}

local NS_HL = vim.api.nvim_create_namespace("globalreplace_hl")
local NS_LABEL = vim.api.nvim_create_namespace("globalreplace_label")

local config = {
	key = "<leader>sg",
	width = 0.35,
	debounce_ms = 120,
}

-- Fixed buffer layout. The three input rows carry the raw values; everything
-- from ROW_STATUS down is re-rendered on every search and must never be treated
-- as user input.
-- ROW_PAD is a blank top line so the inputs aren't flush against the top of
-- the window; the statuscolumn gutter handles the left margin.
local ROW_PAD = 1
local ROW_SEARCH = ROW_PAD
local ROW_REPLACE = ROW_PAD + 1
local ROW_INCLUDE = ROW_PAD + 2
local ROW_EXCLUDE = ROW_PAD + 3
local ROW_STATUS = ROW_PAD + 4

local LABELS = {
	[ROW_SEARCH] = "Search  ",
	[ROW_REPLACE] = "Replace ",
	[ROW_INCLUDE] = "Include ",
	[ROW_EXCLUDE] = "Exclude ",
}

-- Single active session; the panel is a singleton like the in-file widget.
local state = nil

-- Inputs and toggles from the last session, restored on reopen.
local last = nil

local function new_session()
	return {
		main_win = nil,
		panel_win = nil,
		buf = nil,
		opts = { case = false, word = false, regex = false },
		cwd = vim.fn.getcwd(),
		data = { files = {}, flat = {}, nfiles = 0, nmatches = 0 },
		row_to_line = {},
		gen = 0,
		last_processed = nil,
		status = "",
		timer = nil,
		augroup = nil,
	}
end

local function input(s, row)
	if not (s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(s.buf, row, row + 1, false)[1] or ""
end

local function flags_label(opts)
	local function tok(on, label)
		return on and ("[" .. label .. "]") or (" " .. label .. " ")
	end
	return tok(opts.case, "Aa") .. tok(opts.word, "\\b") .. tok(opts.regex, ".*")
end

-- VSCode-style include/exclude fields hold comma-separated glob patterns.
-- Whitespace around each pattern is trimmed; empties are dropped.
local function split_globs(s)
	local out = {}
	for part in (s or ""):gmatch("[^,]+") do
		local trimmed = part:match("^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			out[#out + 1] = trimmed
		end
	end
	return out
end

--- ripgrep flags common to every pass, derived from the toggle state. Case is
--- an explicit toggle (VSCode-style), not smartcase; non-regex uses fixed
--- strings so the term is matched verbatim. Include globs are passed through;
--- each exclude glob is negated with `!` so ripgrep prunes it from traversal.
local function common_args(s, include, exclude)
	local args = { "rg", "--color=never", "--sort=path" }
	if not s.opts.regex then
		table.insert(args, "--fixed-strings")
	end
	if s.opts.word then
		table.insert(args, "--word-regexp")
	end
	table.insert(args, s.opts.case and "--case-sensitive" or "--ignore-case")
	for _, g in ipairs(split_globs(include)) do
		table.insert(args, "--glob")
		table.insert(args, g)
	end
	for _, g in ipairs(split_globs(exclude)) do
		table.insert(args, "--glob")
		table.insert(args, "!" .. g)
	end
	return args
end

local function resolve(rel, cwd)
	if rel:sub(1, 1) == "/" then
		return rel
	end
	return cwd .. "/" .. rel
end

-- ripgrep prefixes results with "./" when handed a directory root; strip it so
-- both the displayed path and the resolved absolute path stay clean.
local function strip_dot(rel)
	return (rel:gsub("^%./", ""))
end

--- Parse ripgrep --json stdout into a grouped file/line structure plus a flat,
--- left-to-right match list whose order matches a paired `rg -o` pass.
local function parse_json(stdout, cwd)
	local files_order, files_index, flat = {}, {}, {}
	for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
		if line ~= "" then
			local ok, obj = pcall(vim.json.decode, line)
			if ok and obj.type == "match" then
				local d = obj.data
				local rel = strip_dot(d.path.text)
				local abs = resolve(rel, cwd)
				local frec = files_index[abs]
				if not frec then
					frec = { abs = abs, rel = rel, lines = {} }
					files_index[abs] = frec
					files_order[#files_order + 1] = frec
				end
				local text = (d.lines.text or ""):gsub("[\r\n]+$", "")
				local lrec = { lnum = d.line_number, text = text, spans = {} }
				for _, sm in ipairs(d.submatches or {}) do
					local mi = #flat + 1
					flat[mi] = { abs = abs, lnum = lrec.lnum, col = sm.start, end_col = sm["end"], repl = nil }
					lrec.spans[#lrec.spans + 1] = { col = sm.start, end_col = sm["end"], mi = mi }
				end
				frec.lines[#frec.lines + 1] = lrec
			end
		end
	end
	return { files = files_order, flat = flat, nfiles = #files_order, nmatches = #flat }
end

-- Pair the exact replacement substrings from `rg -o -r` with the flat match
-- list by position. Both passes use --sort=path so their traversal order is
-- identical. On any count mismatch (e.g. a replacement containing a newline)
-- leave repl nil so the caller falls back to the raw replacement text.
local function assign_repls(flat, stdout)
	local parts = vim.split(stdout or "", "\n", { plain = true })
	if #parts > 0 and parts[#parts] == "" then
		table.remove(parts)
	end
	if #parts ~= #flat then
		return
	end
	for i, f in ipairs(flat) do
		f.repl = parts[i]
	end
end

local function status_line(s)
	local search = input(s, ROW_SEARCH)
	if search == "" then
		return flags_label(s.opts) .. "   type to search"
	end
	if s.status ~= "" then
		return flags_label(s.opts) .. "   " .. s.status
	end
	local d = s.data
	if d.nmatches == 0 then
		return flags_label(s.opts) .. "   no results"
	end
	return string.format("%s   %d matches in %d files", flags_label(s.opts), d.nmatches, d.nfiles)
end

local HELP = "<CR> open  M-y replace  C-a all  M-c/M-w/M-r case/word/regex  q quit"
local SEP = string.rep("─", 60)

local function render(s)
	if not (s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
		return
	end
	local out = { status_line(s), HELP, SEP }
	local map = {}
	local marks = {}
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")
	for _, frec in ipairs(s.data.files) do
		local icon, icon_hl = has_devicons and devicons.get_icon(frec.rel, nil, { default = true }) or nil
		local icon_prefix = icon and (icon .. " ") or ""
		out[#out + 1] = icon_prefix .. frec.rel
		marks[#marks + 1] = { row = ROW_STATUS + #out - 1, kind = "file", icon_hl = icon_hl, icon_len = #icon_prefix }
		for _, lrec in ipairs(frec.lines) do
			local prefix = string.format(" %5d  ", lrec.lnum)
			out[#out + 1] = prefix .. lrec.text
			local row = ROW_STATUS + #out - 1
			map[row] = { abs = frec.abs, lrec = lrec, prefix_len = #prefix }
			for _, span in ipairs(lrec.spans) do
				marks[#marks + 1] = {
					row = row,
					kind = "match",
					col = #prefix + span.col,
					end_col = #prefix + span.end_col,
					repl = s.data.flat[span.mi].repl,
				}
			end
		end
	end

	vim.api.nvim_buf_set_lines(s.buf, ROW_STATUS, -1, false, out)
	vim.api.nvim_buf_clear_namespace(s.buf, NS_HL, 0, -1)
	s.row_to_line = map

	local replace_raw = input(s, ROW_REPLACE)
	local has_replace = replace_raw ~= ""
	pcall(vim.api.nvim_buf_set_extmark, s.buf, NS_HL, ROW_STATUS, 0, {
		end_row = ROW_STATUS + 1,
		hl_group = "GlobalReplaceStatus",
		hl_eol = true,
	})
	for _, mk in ipairs(marks) do
		if mk.kind == "file" then
			pcall(vim.api.nvim_buf_set_extmark, s.buf, NS_HL, mk.row, 0, {
				end_row = mk.row + 1,
				hl_group = "GlobalReplaceFile",
			})
			if mk.icon_hl and mk.icon_len > 0 then
				pcall(vim.api.nvim_buf_set_extmark, s.buf, NS_HL, mk.row, 0, {
					end_col = mk.icon_len,
					hl_group = mk.icon_hl,
					priority = 220,
				})
			end
		else
			pcall(vim.api.nvim_buf_set_extmark, s.buf, NS_HL, mk.row, mk.col, {
				end_col = mk.end_col,
				hl_group = has_replace and "GlobalReplaceMatchOld" or "Visual",
				priority = 200,
			})
			if has_replace then
				local repl = mk.repl or replace_raw
				pcall(vim.api.nvim_buf_set_extmark, s.buf, NS_HL, mk.row, mk.end_col, {
					virt_text = { { repl, "GlobalReplaceMatchNew" } },
					virt_text_pos = "inline",
					priority = 210,
				})
			end
		end
	end
end

local function build_key(s)
	return table.concat({
		input(s, ROW_SEARCH),
		input(s, ROW_INCLUDE),
		input(s, ROW_EXCLUDE),
		input(s, ROW_REPLACE),
		tostring(s.opts.case),
		tostring(s.opts.word),
		tostring(s.opts.regex),
	}, "\0")
end

local function run_search(s, force)
	local key = build_key(s)
	if not force and key == s.last_processed then
		return
	end
	s.last_processed = key
	s.status = ""
	s.gen = s.gen + 1
	local gen = s.gen

	local search = input(s, ROW_SEARCH)
	local include = input(s, ROW_INCLUDE)
	local exclude = input(s, ROW_EXCLUDE)
	local replace = input(s, ROW_REPLACE)

	if search == "" then
		s.data = { files = {}, flat = {}, nfiles = 0, nmatches = 0 }
		render(s)
		return
	end

	local json_args = common_args(s, include, exclude)
	vim.list_extend(json_args, { "--json", "--", search, "." })

	local function finish(data)
		vim.schedule(function()
			if gen == s.gen and s.buf and vim.api.nvim_buf_is_valid(s.buf) then
				s.data = data
				render(s)
			end
		end)
	end

	vim.system(json_args, { text = true, cwd = s.cwd }, function(res)
		if gen ~= s.gen then
			return
		end
		local data = parse_json(res.stdout, s.cwd)
		if replace == "" or data.nmatches == 0 then
			finish(data)
			return
		end
		local o_args = common_args(s, include, exclude)
		vim.list_extend(
			o_args,
			{ "--only-matching", "--no-line-number", "--no-filename", "--replace", replace, "--", search, "." }
		)
		vim.system(o_args, { text = true, cwd = s.cwd }, function(res2)
			if gen ~= s.gen then
				return
			end
			assign_repls(data.flat, res2.stdout)
			finish(data)
		end)
	end)
end

local function schedule_search(s)
	if s.timer then
		s.timer:stop()
		s.timer:close()
		s.timer = nil
	end
	local timer = vim.uv.new_timer()
	s.timer = timer
	timer:start(config.debounce_ms, 0, function()
		timer:stop()
		timer:close()
		if state == s then
			s.timer = nil
		end
		vim.schedule(function()
			if state == s and s.buf and vim.api.nvim_buf_is_valid(s.buf) then
				run_search(s)
			end
		end)
	end)
end

local function toggle(s, name)
	s.opts[name] = not s.opts[name]
	run_search(s)
end

-- Reload an already-open buffer for a file we just rewrote, unless it has
-- unsaved changes (in which case we must not clobber the user's edits).
local function reload_buffer(abs)
	local bufnr = vim.fn.bufnr(abs)
	if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	if vim.bo[bufnr].modified then
		vim.notify("globalreplace: skipped reload of modified buffer " .. abs, vim.log.levels.WARN)
		return
	end
	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("silent! edit!")
	end)
end

local function line_under_cursor(s)
	local row = vim.api.nvim_win_get_cursor(s.panel_win)[1] - 1
	return s.row_to_line[row]
end

local function span_nearest(rec, col)
	local best = rec.lrec.spans[1]
	for _, span in ipairs(rec.lrec.spans) do
		if col >= rec.prefix_len + span.col then
			best = span
		end
	end
	return best
end

local function open_match(s)
	local rec = line_under_cursor(s)
	if not rec then
		return
	end
	local span = rec.lrec.spans[1]
	if not (s.main_win and vim.api.nvim_win_is_valid(s.main_win)) then
		vim.cmd("wincmd l")
		s.main_win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(s.main_win)
	vim.cmd("edit " .. vim.fn.fnameescape(rec.abs))
	pcall(vim.api.nvim_win_set_cursor, s.main_win, { rec.lrec.lnum, span.col })
	vim.cmd("normal! zz")
end

local function replace_one(s)
	local rec = line_under_cursor(s)
	if not rec then
		return
	end
	local col = vim.api.nvim_win_get_cursor(s.panel_win)[2]
	local span = span_nearest(rec, col)
	local repl = s.data.flat[span.mi].repl or input(s, ROW_REPLACE)
	local lines = vim.fn.readfile(rec.abs)
	local target = lines[rec.lrec.lnum]
	if not target then
		return
	end
	lines[rec.lrec.lnum] = target:sub(1, span.col) .. repl .. target:sub(span.end_col + 1)
	vim.fn.writefile(lines, rec.abs)
	reload_buffer(rec.abs)
	run_search(s, true)
end

local function replace_all(s)
	if s.data.nmatches == 0 then
		return
	end
	local search = input(s, ROW_SEARCH)
	local replace = input(s, ROW_REPLACE)
	local include = input(s, ROW_INCLUDE)
	local exclude = input(s, ROW_EXCLUDE)
	local choice = vim.fn.confirm(
		string.format("Replace %d matches in %d files?", s.data.nmatches, s.data.nfiles),
		"&Yes\n&No",
		2
	)
	if choice ~= 1 then
		return
	end
	local failed = 0
	for _, frec in ipairs(s.data.files) do
		local args = common_args(s, include, exclude)
		vim.list_extend(args, { "--passthru", "--no-line-number", "--replace", replace, "--", search, frec.abs })
		local res = vim.system(args, { text = true, cwd = s.cwd }):wait()
		if res.code == 0 and res.stdout and res.stdout ~= "" then
			local fh = io.open(frec.abs, "wb")
			if fh then
				fh:write(res.stdout)
				fh:close()
				reload_buffer(frec.abs)
			else
				failed = failed + 1
			end
		else
			failed = failed + 1
		end
	end
	if failed > 0 then
		vim.notify(string.format("globalreplace: %d file(s) could not be written", failed), vim.log.levels.ERROR)
	end
	run_search(s, true)
end

local function set_input(s, row, value)
	vim.api.nvim_buf_set_lines(s.buf, row, row + 1, false, { value or "" })
end

local function apply_labels(s)
	for row, label in pairs(LABELS) do
		vim.api.nvim_buf_set_extmark(s.buf, NS_LABEL, row, 0, {
			virt_text = { { label, "GlobalReplaceLabel" } },
			virt_text_pos = "inline",
			right_gravity = false,
		})
	end
end

local function map(s, mode, lhs, fn)
	vim.keymap.set(mode, lhs, fn, { buffer = s.buf, nowait = true, silent = true })
end

local function wire_keys(s)
	map(s, "n", "<CR>", function()
		open_match(s)
	end)
	map(s, { "n", "i" }, "<M-y>", function()
		replace_one(s)
	end)
	map(s, { "n", "i" }, "<C-a>", function()
		replace_all(s)
	end)
	map(s, { "n", "i" }, "<M-c>", function()
		toggle(s, "case")
	end)
	map(s, { "n", "i" }, "<M-w>", function()
		toggle(s, "word")
	end)
	map(s, { "n", "i" }, "<M-r>", function()
		toggle(s, "regex")
	end)
	map(s, "n", "q", function()
		M.close()
	end)
	map(s, "i", "<Esc>", function()
		vim.cmd("stopinsert")
	end)
end

local function open_panel(s, seed)
	local width = math.max(50, math.floor(vim.o.columns * config.width))
	s.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[s.buf].buftype = "nofile"
	vim.bo[s.buf].bufhidden = "wipe"
	vim.bo[s.buf].swapfile = false
	vim.bo[s.buf].filetype = "globalreplace"
	vim.b[s.buf].completion = false

	vim.cmd("topleft vsplit")
	s.panel_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.panel_win, s.buf)
	vim.api.nvim_win_set_width(s.panel_win, width)
	local wo = vim.wo[s.panel_win]
	wo.number = false
	wo.relativenumber = false
	wo.wrap = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.list = false
	wo.cursorline = true
	wo.statuscolumn = "  "
	wo.winhighlight = "Normal:GlobalReplaceNormal,CursorLine:GlobalReplaceCursorLine,SignColumn:GlobalReplaceNormal"

	local search_seed = seed or (last and last.search) or ""
	vim.api.nvim_buf_set_lines(
		s.buf,
		0,
		-1,
		false,
		{ "", search_seed, (last and last.replace) or "", (last and last.include) or "", (last and last.exclude) or "" }
	)
	apply_labels(s)
end

local function attach_autocmds(s)
	s.augroup = vim.api.nvim_create_augroup("globalreplace_session", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = s.augroup,
		buffer = s.buf,
		callback = function()
			schedule_search(s)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = s.augroup,
		callback = function(args)
			if tonumber(args.match) == s.panel_win then
				vim.schedule(function()
					if state == s then
						M.close()
					end
				end)
			end
		end,
	})
end

--- Open the panel. `opts.seed` pre-fills the search field.
function M.open(opts)
	opts = opts or {}
	if vim.fn.executable("rg") ~= 1 then
		vim.notify("globalreplace: ripgrep (rg) is required", vim.log.levels.ERROR)
		return
	end
	if state then
		if opts.seed and opts.seed ~= "" then
			set_input(state, ROW_SEARCH, (opts.seed:gsub("\n.*$", "")))
		end
		if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
			vim.api.nvim_set_current_win(state.panel_win)
		end
		run_search(state, true)
		return
	end

	local main_win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_config(main_win).relative ~= "" then
		return
	end

	local s = new_session()
	s.main_win = main_win
	if last then
		s.opts = vim.deepcopy(last.opts)
	end
	state = s

	local seed = opts.seed and opts.seed ~= "" and (opts.seed:gsub("\n.*$", "")) or nil
	open_panel(s, seed)
	wire_keys(s)
	attach_autocmds(s)

	run_search(s, true)
	vim.api.nvim_set_current_win(s.panel_win)
	vim.api.nvim_win_set_cursor(s.panel_win, { ROW_SEARCH + 1, #input(s, ROW_SEARCH) })
	vim.cmd("startinsert!")
end

function M.close()
	local s = state
	if not s then
		return
	end
	last = {
		search = input(s, ROW_SEARCH),
		replace = input(s, ROW_REPLACE),
		include = input(s, ROW_INCLUDE),
		exclude = input(s, ROW_EXCLUDE),
		opts = vim.deepcopy(s.opts),
	}
	state = nil
	if s.timer then
		s.timer:stop()
		s.timer:close()
		s.timer = nil
	end
	if s.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
	end
	if s.panel_win and vim.api.nvim_win_is_valid(s.panel_win) then
		pcall(vim.api.nvim_win_close, s.panel_win, true)
	end
	if s.main_win and vim.api.nvim_win_is_valid(s.main_win) then
		pcall(vim.api.nvim_set_current_win, s.main_win)
	end
end

--- Toggle the panel: open/focus when away, close when focused inside it.
function M.toggle()
	if state then
		if vim.api.nvim_get_current_win() == state.panel_win then
			M.close()
		elseif state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
			vim.api.nvim_set_current_win(state.panel_win)
		end
	else
		M.open()
	end
end

local function hl_fg(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok and hl then
		return hl.fg
	end
	return nil
end

local function set_highlights()
	vim.api.nvim_set_hl(0, "Visual", { link = "CurSearch", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceMatchOld", { link = "DiffDelete", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceMatchNew", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceFile", { link = "Directory", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceStatus", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceLabel", { fg = hl_fg("Title") or hl_fg("Function"), bold = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceNormal", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "GlobalReplaceCursorLine", { link = "CursorLine", default = true })
end

--- @param opts table|nil { key?: string, width?: number, debounce_ms?: number }
function M.setup(opts)
	opts = opts or {}
	config.key = opts.key or config.key
	config.width = opts.width or config.width
	config.debounce_ms = opts.debounce_ms or config.debounce_ms

	set_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("globalreplace_hl", { clear = true }),
		callback = set_highlights,
	})

	vim.keymap.set("n", config.key, function()
		M.toggle()
	end, { desc = "Global find & replace" })

	vim.keymap.set("x", config.key, function()
		local save, savet = vim.fn.getreg("z"), vim.fn.getregtype("z")
		vim.cmd('normal! "zy')
		local sel = vim.fn.getreg("z")
		vim.fn.setreg("z", save, savet)
		M.open({ seed = sel })
	end, { desc = "Global find & replace (selection)" })
end

-- Exposed for headless testing.
M._parse_json = parse_json
M._assign_repls = assign_repls

return M
