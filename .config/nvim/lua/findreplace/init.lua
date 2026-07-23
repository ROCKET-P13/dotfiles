-- In-file find & replace widget modeled on the VSCode/Cursor find box.
--
-- A floating Find input (and an optional Replace input) anchored to the top
-- right of the current window. Matches in the underlying buffer are highlighted
-- live as you type, the active match is emphasized and centered, and the title
-- shows the active-toggle state and a "current of total" count. All interaction
-- happens in insert mode, like the VSCode widget, so the inputs are modeless.

local M = {}

local NS = vim.api.nvim_create_namespace("findreplace")

local config = {
	key = "<leader>sr",
	width = 48,
	debounce_ms = 60,
}

-- Single active session; the widget is modal in the sense that only one is open.
local state = nil

-- Find/replace terms and toggle state from the last session, restored on reopen
-- so toggling the widget away and back does not lose what you were searching for.
local last = nil

local function new_session(target_win)
	return {
		target_win = target_win,
		target_buf = vim.api.nvim_win_get_buf(target_win),
		container_win = nil,
		container_buf = nil,
		find_win = nil,
		find_buf = nil,
		replace_win = nil,
		replace_buf = nil,
		box_w = nil,
		matches = {},
		current = 0,
		pattern = nil,
		opts = { case = false, word = false, regex = false },
		timer = nil,
		augroup = nil,
	}
end

--- Build a Vim regex from the find term honoring the toggle state. Case is an
--- explicit toggle (VSCode-style) rather than 'smartcase', so we pin it with
--- \c / \C. Literal mode uses very-nomagic (\V) so only backslashes need
--- escaping; whole-word wraps the term in word boundaries.
local function build_pattern(term, opts)
	if not term or term == "" then
		return nil
	end
	local flag = opts.case and "\\C" or "\\c"
	if opts.regex then
		local body = opts.word and ("\\<\\%(" .. term .. "\\)\\>") or term
		return flag .. body
	end
	local literal = term:gsub("\\", "\\\\")
	if opts.word then
		return flag .. "\\V\\<" .. literal .. "\\>"
	end
	return flag .. "\\V" .. literal
end

--- All matches of `pattern` in `buf` as 0-indexed { row, col_start, col_end }
--- with end-exclusive columns. Returns nil on an invalid pattern (e.g. a
--- half-typed regex) so the caller can surface it instead of erroring.
local function compute_matches(buf, pattern)
	if not pattern then
		return {}
	end
	local ok, res = pcall(vim.fn.matchbufline, buf, pattern, 1, "$")
	if not ok then
		return nil
	end
	local out = {}
	for _, m in ipairs(res) do
		if #m.text > 0 then
			out[#out + 1] = { row = m.lnum - 1, col_start = m.byteidx, col_end = m.byteidx + #m.text }
		end
	end
	return out
end

local function input_line(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
end

local function flags_label(opts)
	local function tok(key, on, label)
		return on and (key .. ":[" .. label .. "]") or (key .. ":" .. label)
	end
	return tok("M-c", opts.case, "Aa") .. " " .. tok("M-w", opts.word, "\\b") .. " " .. tok("M-r", opts.regex, ".*")
end

local function find_title(s)
	local count
	if not s.matches then
		count = "bad pattern"
	elseif #s.matches == 0 then
		count = (s.pattern and "no results" or "0/0")
	else
		count = string.format("%d/%d", s.current, #s.matches)
	end
	return string.format(" Find %s  %s ", flags_label(s.opts), count)
end

local function repaint(s)
	if not vim.api.nvim_buf_is_valid(s.target_buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(s.target_buf, NS, 0, -1)
	if not s.matches then
		return
	end
	for i, m in ipairs(s.matches) do
		local hl = (i == s.current) and "FindReplaceCurrent" or "FindReplaceMatch"
		pcall(vim.api.nvim_buf_set_extmark, s.target_buf, NS, m.row, m.col_start, {
			end_col = m.col_end,
			hl_group = hl,
			priority = 300,
		})
	end
end

local function update_title(s)
	if s.find_win and vim.api.nvim_win_is_valid(s.find_win) then
		pcall(vim.api.nvim_win_set_config, s.find_win, { title = find_title(s), title_pos = "left" })
	end
end

local function goto_current(s)
	if not s.matches or s.current == 0 then
		return
	end
	local m = s.matches[s.current]
	if not vim.api.nvim_win_is_valid(s.target_win) then
		return
	end
	pcall(vim.api.nvim_win_set_cursor, s.target_win, { m.row + 1, m.col_start })
	vim.api.nvim_win_call(s.target_win, function()
		vim.cmd("normal! zz")
	end)
end

-- Pick the match at or after the target window's cursor, so typing keeps the
-- selection near where the user is rather than jumping to the top of the file.
local function nearest_to_cursor(s)
	if not s.matches or #s.matches == 0 then
		return 0
	end
	local cur = vim.api.nvim_win_get_cursor(s.target_win)
	local row, col = cur[1] - 1, cur[2]
	for i, m in ipairs(s.matches) do
		if m.row > row or (m.row == row and m.col_start >= col) then
			return i
		end
	end
	return 1
end

local function recompute(s, opts)
	opts = opts or {}
	local term = input_line(s.find_buf)
	s.pattern = build_pattern(term, s.opts)
	s.matches = compute_matches(s.target_buf, s.pattern)
	if not s.matches or #s.matches == 0 then
		s.current = 0
	else
		s.current = nearest_to_cursor(s)
	end
	repaint(s)
	update_title(s)
	if opts.jump ~= false then
		goto_current(s)
	end
end

local function schedule_recompute(s, jump)
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
			if state == s and s.find_buf and vim.api.nvim_buf_is_valid(s.find_buf) then
				recompute(s, { jump = jump ~= false })
			end
		end)
	end)
end

local function step(s, delta)
	if not s.matches or #s.matches == 0 then
		return
	end
	s.current = ((s.current - 1 + delta) % #s.matches) + 1
	repaint(s)
	update_title(s)
	goto_current(s)
end

local function toggle(s, name)
	s.opts[name] = not s.opts[name]
	recompute(s, { jump = false })
end

local function focus(s, which, insert)
	local win = which == "replace" and s.replace_win or s.find_win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		if insert ~= false then
			vim.cmd("startinsert!")
		end
	end
end

local function defocus(s)
	if vim.api.nvim_win_is_valid(s.target_win) then
		vim.api.nvim_set_current_win(s.target_win)
	end
	vim.cmd("stopinsert")
end

-- Vim's :substitute replacement metacharacters (\, &, ~) must be neutralized so
-- a non-regex replacement is inserted verbatim.
local function escape_literal_replacement(repl)
	return (repl:gsub("\\", "\\\\"):gsub("&", "\\&"):gsub("~", "\\~"))
end

local function replace_current(s)
	if not s.matches or s.current == 0 then
		return
	end
	local m = s.matches[s.current]
	local repl = input_line(s.replace_buf)
	local line = vim.api.nvim_buf_get_lines(s.target_buf, m.row, m.row + 1, false)[1] or ""
	local matched = line:sub(m.col_start + 1, m.col_end)
	local newtext
	if s.opts.regex then
		newtext = vim.fn.substitute(matched, s.pattern, repl, "")
	else
		newtext = repl
	end
	pcall(
		vim.api.nvim_buf_set_text,
		s.target_buf,
		m.row,
		m.col_start,
		m.row,
		m.col_end,
		vim.split(newtext, "\n", { plain = true })
	)
	-- Resume from the replaced position so the next match becomes current.
	pcall(vim.api.nvim_win_set_cursor, s.target_win, { m.row + 1, m.col_start })
	recompute(s)
end

local function replace_all(s)
	if not s.pattern then
		return
	end
	local repl = input_line(s.replace_buf)
	local repl_sub = s.opts.regex and repl or escape_literal_replacement(repl)
	-- Edit only the matched regions via :substitute. Rewriting whole lines (or
	-- the whole buffer) would delete other plugins' highlight extmarks on
	-- untouched lines, which an incremental highlighter then never repaints. A
	-- control-character delimiter avoids having to escape "/" in the pattern or
	-- replacement; source text never contains it. keeppatterns leaves the search
	-- register untouched.
	local d = "\031"
	local cmd = string.format("silent! keeppatterns %%s%s%s%s%s%sge", d, s.pattern, d, repl_sub, d)
	vim.api.nvim_buf_call(s.target_buf, function()
		vim.cmd(cmd)
	end)
	recompute(s, { jump = false })
end

local function close(s)
	last = {
		find = input_line(s.find_buf),
		replace = input_line(s.replace_buf),
		opts = vim.deepcopy(s.opts),
	}
	if state == s then
		state = nil
	end
	if s.timer then
		s.timer:stop()
		s.timer:close()
		s.timer = nil
	end
	if s.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
	end
	if vim.api.nvim_buf_is_valid(s.target_buf) then
		vim.api.nvim_buf_clear_namespace(s.target_buf, NS, 0, -1)
	end
	-- Close the inner boxes before the container they are anchored to.
	for _, win in ipairs({ s.find_win, s.replace_win, s.container_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	if vim.api.nvim_win_is_valid(s.target_win) then
		pcall(vim.api.nvim_set_current_win, s.target_win)
	end
end

local function map(buf, lhs, fn)
	for _, mode in ipairs({ "i", "n" }) do
		vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
	end
end

local function wire_keys(s)
	local function find_enter()
		step(s, 1)
	end
	for _, buf in ipairs({ s.find_buf, s.replace_buf }) do
		map(buf, "<Down>", function()
			step(s, 1)
		end)
		map(buf, "<Up>", function()
			step(s, -1)
		end)
		map(buf, "<S-CR>", function()
			step(s, -1)
		end)
		map(buf, "<Tab>", function()
			focus(s, buf == s.find_buf and "replace" or "find")
		end)
		map(buf, "<S-Tab>", function()
			focus(s, buf == s.find_buf and "replace" or "find")
		end)
		map(buf, "<M-c>", function()
			toggle(s, "case")
		end)
		map(buf, "<M-w>", function()
			toggle(s, "word")
		end)
		map(buf, "<M-r>", function()
			toggle(s, "regex")
		end)
		-- Interactive stepping: replace the current match and advance, skip to the
		-- next without replacing, step back, or replace everything remaining.
		map(buf, "<M-y>", function()
			replace_current(s)
		end)
		map(buf, "<M-n>", function()
			step(s, 1)
		end)
		map(buf, "<M-p>", function()
			step(s, -1)
		end)
		map(buf, "<C-a>", function()
			replace_all(s)
		end)
		-- Insert-mode Esc just leaves insert mode, staying in the box so the
		-- inputs can be navigated with normal-mode motions.
		vim.keymap.set("i", "<Esc>", function()
			vim.cmd("stopinsert")
		end, { buffer = buf, nowait = true, silent = true })
		-- Normal-mode Esc drops focus back to the file; the widget stays open and
		-- closing remains an explicit toggle.
		vim.keymap.set("n", "<Esc>", function()
			defocus(s)
		end, { buffer = buf, nowait = true, silent = true })
	end
	map(s.find_buf, "<CR>", find_enter)
	map(s.replace_buf, "<CR>", function()
		replace_current(s)
	end)
	-- Normal-mode line motions move between the stacked inputs, like moving down
	-- from the Find line to the Replace line.
	vim.keymap.set("n", "j", function()
		focus(s, "replace", false)
	end, { buffer = s.find_buf, nowait = true, silent = true })
	vim.keymap.set("n", "k", function()
		focus(s, "find", false)
	end, { buffer = s.replace_buf, nowait = true, silent = true })
end

local function make_input_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	-- blink.cmp checks this buffer-local flag; keep its completion menu out of
	-- the find/replace inputs without touching the global blink config.
	vim.b[buf].completion = false
	return buf
end

-- Outer container that draws the rounded outline around the whole widget. It is
-- a non-focusable backdrop; the input boxes sit inside it.
local function container_config(s)
	local win_w = vim.api.nvim_win_get_width(s.target_win)
	return {
		relative = "win",
		win = s.target_win,
		anchor = "NE",
		row = 1,
		col = win_w - 2,
		width = s.box_w + 4,
		height = 7,
		style = "minimal",
		border = "rounded",
		zindex = 100,
		focusable = false,
	}
end

-- An inner box (find / replace) positioned inside the container at the given
-- interior row, leaving a one-cell pad to the container border.
local function inner_config(s, row, focusable, title)
	local cfg = {
		relative = "win",
		win = s.container_win,
		anchor = "NW",
		row = row,
		col = 2,
		width = s.box_w - 2,
		height = 1,
		style = "minimal",
		border = "rounded",
		zindex = 220,
		focusable = focusable,
	}
	if title then
		cfg.title = title
		cfg.title_pos = "left"
	end
	return cfg
end

local function open_windows(s)
	local win_w = vim.api.nvim_win_get_width(s.target_win)
	s.box_w = math.max(16, math.min(config.width, win_w - 10))

	s.container_buf = make_input_buf()
	s.container_win = vim.api.nvim_open_win(s.container_buf, false, container_config(s))

	s.find_buf = make_input_buf()
	s.find_win = vim.api.nvim_open_win(s.find_buf, true, inner_config(s, 1, true, find_title(s)))

	s.replace_buf = make_input_buf()
	s.replace_win = vim.api.nvim_open_win(
		s.replace_buf,
		false,
		inner_config(s, 4, true, " Replace  M-y:do M-n:skip M-p:prev C-a:all ")
	)

	for _, win in ipairs({ s.container_win, s.find_win, s.replace_win }) do
		vim.wo[win].winhighlight =
			"Normal:FindReplaceNormal,FloatBorder:FindReplaceBorder,FloatTitle:FindReplaceTitle"
		vim.wo[win].cursorline = false
	end
end

local function attach_autocmds(s)
	s.augroup = vim.api.nvim_create_augroup("findreplace_session", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = s.augroup,
		buffer = s.find_buf,
		callback = function()
			schedule_recompute(s, true)
		end,
	})
	-- The widget stays open over the file, so refresh highlights as the file is
	-- edited, but without moving the cursor out from under the user.
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = s.augroup,
		buffer = s.target_buf,
		callback = function()
			schedule_recompute(s, false)
		end,
	})
	-- If any of the widget windows is closed by other means, tear the session down.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = s.augroup,
		callback = function(args)
			local closed = tonumber(args.match)
			if closed == s.find_win or closed == s.replace_win or closed == s.container_win then
				vim.schedule(function()
					if state == s then
						close(s)
					end
				end)
			end
		end,
	})
end

--- Open the widget on the current window. `opts.seed` pre-fills the find field.
function M.open(opts)
	opts = opts or {}
	if state then
		if opts.seed and opts.seed ~= "" then
			vim.api.nvim_buf_set_lines(state.find_buf, 0, -1, false, { (opts.seed:gsub("\n.*$", "")) })
			recompute(state)
		end
		focus(state, "find")
		return
	end
	local target_win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_config(target_win).relative ~= "" then
		return -- refuse to anchor inside another floating window
	end
	local s = new_session(target_win)
	if last then
		s.opts = vim.deepcopy(last.opts)
	end
	state = s
	open_windows(s)
	wire_keys(s)
	attach_autocmds(s)

	local find_seed = (opts.seed and opts.seed ~= "" and opts.seed) or (last and last.find) or ""
	find_seed = find_seed:gsub("\n.*$", "")
	if find_seed ~= "" then
		vim.api.nvim_buf_set_lines(s.find_buf, 0, -1, false, { find_seed })
	end
	if last and last.replace and last.replace ~= "" then
		vim.api.nvim_buf_set_lines(s.replace_buf, 0, -1, false, { last.replace })
	end

	recompute(s)
	vim.api.nvim_set_current_win(s.find_win)
	vim.api.nvim_win_set_cursor(s.find_win, { 1, #input_line(s.find_buf) })
	vim.cmd("startinsert!")
end

--- Toggle the widget: open it (or focus it) when away, close it when focused
--- inside one of its inputs. The container otherwise stays open.
function M.toggle()
	if state then
		local cur = vim.api.nvim_get_current_win()
		if cur == state.find_win or cur == state.replace_win then
			close(state)
		else
			focus(state, "find")
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
	vim.api.nvim_set_hl(0, "FindReplaceMatch", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "FindReplaceCurrent", { link = "CurSearch", default = true })
	-- Transparent backgrounds so the widget matches the terminal background,
	-- keeping the theme's foreground colors. Scoped to this plugin's windows via
	-- winhighlight rather than overriding the global float groups.
	vim.api.nvim_set_hl(0, "FindReplaceNormal", { bg = "NONE" })
	vim.api.nvim_set_hl(0, "FindReplaceBorder", { fg = hl_fg("FloatBorder") or hl_fg("Normal"), bg = "NONE" })
	vim.api.nvim_set_hl(0, "FindReplaceTitle", { fg = hl_fg("FloatTitle") or hl_fg("Title"), bg = "NONE", bold = true })
end

--- @param opts table|nil { key?: string, width?: number, debounce_ms?: number }
function M.setup(opts)
	opts = opts or {}
	config.key = opts.key or config.key
	config.width = opts.width or config.width
	config.debounce_ms = opts.debounce_ms or config.debounce_ms

	set_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("findreplace_hl", { clear = true }),
		callback = set_highlights,
	})

	vim.keymap.set("n", config.key, function()
		M.toggle()
	end, { desc = "Find & replace (current file)" })

	vim.keymap.set("x", config.key, function()
		local save, savet = vim.fn.getreg("z"), vim.fn.getregtype("z")
		vim.cmd('normal! "zy')
		local sel = vim.fn.getreg("z")
		vim.fn.setreg("z", save, savet)
		M.open({ seed = sel })
	end, { desc = "Find & replace selection" })
end

-- Exposed for headless testing of the matching/replace logic.
M._build_pattern = build_pattern
M._compute_matches = compute_matches
M._escape_literal_replacement = escape_literal_replacement

return M
