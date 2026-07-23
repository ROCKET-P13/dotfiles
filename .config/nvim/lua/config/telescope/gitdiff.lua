local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

-- Run a git command synchronously and return its stdout.
local function run_git(args, cwd)
	local obj = vim.system(args, { cwd = cwd, text = true }):wait()
	if obj.code ~= 0 then
		return ""
	end
	return obj.stdout or ""
end

-- Parse a unified diff into one entry per hunk.
-- Each hunk: { file, lnum, added, removed, status, text }
local function parse_hunks(output, status)
	local hunks = {}
	local file = nil
	local hunk = nil
	local new_line = 0
	local first_added = nil

	local function finish()
		if hunk and hunk.file then
			table.insert(hunks, {
				file = hunk.file,
				lnum = first_added or hunk.start_line,
				added = hunk.added,
				removed = hunk.removed,
				status = hunk.status,
				text = table.concat(hunk.text, "\n"),
			})
		end
		hunk = nil
		first_added = nil
	end

	for _, line in ipairs(vim.split(output, "\n")) do
		local prefix = line:sub(1, 1)
		if line:sub(1, 11) == "diff --git " then
			finish()
			file = nil
		elseif line:sub(1, 3) == "+++" then
			local p = line:sub(4):gsub("^%s+", "")
			if p == "/dev/null" then
				file = nil
			else
				file = p:gsub("^b/", "")
			end
		elseif line:sub(1, 2) == "@@" then
			finish()
			local c = tonumber(line:match("%+(%d+)")) or 1
			hunk = { file = file, start_line = c, added = 0, removed = 0, text = {}, status = status }
			new_line = c
			first_added = nil
			table.insert(hunk.text, line)
		elseif hunk then
			table.insert(hunk.text, line)
			if prefix == "+" then
				hunk.added = hunk.added + 1
				if not first_added then
					first_added = new_line
				end
				new_line = new_line + 1
			elseif prefix == "-" then
				hunk.removed = hunk.removed + 1
			elseif prefix == " " then
				new_line = new_line + 1
			end
		end
	end
	finish()
	return hunks
end

-- Collect every uncommitted hunk: staged, unstaged, and untracked files.
local function collect_hunks(cwd)
	local hunks = {}
	vim.list_extend(hunks, parse_hunks(run_git({ "git", "diff", "--unified=3", "--no-color" }, cwd), "S"))
	vim.list_extend(hunks, parse_hunks(run_git({ "git", "diff", "--cached", "--unified=3", "--no-color" }, cwd), "U"))

	local untracked = run_git({ "git", "ls-files", "--others", "--exclude-standard" }, cwd)
	for _, f in ipairs(vim.split(untracked, "\n")) do
		if f ~= "" then
			table.insert(hunks, {
				file = f,
				lnum = 1,
				added = 0,
				removed = 0,
				status = "?",
				text = "new file: " .. f,
			})
		end
	end
	return hunks
end

local function make_entry_maker()
	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 1 },
			{ remaining = true },
			{ width = 9 },
		},
	})
	return function(hunk)
		return {
			value = { filename = hunk.file, lnum = hunk.lnum },
			display = function(entry)
				return displayer({
					{ hunk.status, "TelescopeResultsComment" },
					{ entry.value.filename .. ":" .. entry.value.lnum, "TelescopeResultsIdentifier" },
					{ string.format("+%d -%d", hunk.added, hunk.removed), "TelescopeResultsDiffChange" },
				})
			end,
			ordinal = hunk.file .. " " .. hunk.text,
			lnum = hunk.lnum,
			filename = hunk.file,
			hunk_text = hunk.text,
		}
	end
end

local function jump_to_change(prompt_bufnr)
	local entry = action_state.get_selected_entry()
	actions.close(prompt_bufnr)
	if not entry then
		return
	end
	vim.cmd("edit " .. vim.fn.fnameescape(entry.value.filename))
	pcall(vim.api.nvim_win_set_cursor, 0, { entry.value.lnum, 0 })
	vim.cmd("normal! zvzz")
end

local function git_diff(opts)
	opts = opts or {}
	opts.cwd = opts.cwd or vim.uv.cwd()

	local hunks = collect_hunks(opts.cwd)
	pickers
		.new(opts, {
			prompt_title = "Uncommitted Changes",
			finder = finders.new_table({
				results = hunks,
				entry_maker = make_entry_maker(),
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Hunk Preview",
				define_preview = function(self, entry)
					local lines = vim.split(entry.hunk_text, "\n")
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "diff"
				end,
			}),
			attach_mappings = function()
				actions.select_default:replace(jump_to_change)
				return true
			end,
		})
		:find()
end

M.setup = function()
	git_diff()
end

M.git_diff = git_diff

return M
