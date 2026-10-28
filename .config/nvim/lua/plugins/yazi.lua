local ROOT_MARKERS = { ".git", "Makefile", "go.mod", "package.json", "pyproject.toml", "Cargo.toml" }

local function shell_quote(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function project_root()
	return vim.fs.root(0, ROOT_MARKERS) or vim.uv.cwd() or vim.fn.getcwd()
end

local function current_directory()
	local name = vim.api.nvim_buf_get_name(0)
	local oil_dir = name:match("^oil://(.*)")
	if oil_dir and vim.fn.isdirectory(oil_dir) == 1 then
		return oil_dir, nil
	end

	if name ~= "" and vim.fn.filereadable(name) == 1 then
		return vim.fn.fnamemodify(name, ":h"), name
	end

	local parent = vim.fn.fnamemodify(name, ":h")
	if name ~= "" and parent ~= "" and vim.fn.isdirectory(parent) == 1 then
		return parent, nil
	end

	return vim.uv.cwd() or vim.fn.getcwd(), nil
end

local function visual_selection_path()
	local lines = require("yazi.utils").get_visual_selection_lines()
	local line = lines[1]
	if line == nil then
		return nil
	end

	line = line:gsub("^%s*(.-)%s*$", "%1")
	line = vim.fn.expand(line) or line
	local absolute_path = vim.fn.fnamemodify(vim.fn.expand("%:p:h") .. "/" .. line, ":p")
	if vim.fn.filereadable(absolute_path) == 1 or vim.fn.isdirectory(absolute_path) == 1 then
		return absolute_path
	end
	if vim.fn.filereadable(line) == 1 or vim.fn.isdirectory(line) == 1 then
		return line
	end
	return nil
end

local function chooser_path(line)
	if not line:find("://", 1, true) then
		return line
	end

	local path = require("yazi.url").to_path(line)
	if path:find("%%", 1, true) then
		path = vim.uri_decode(path)
	end

	-- search://query:1:1/Users/... drops the leading slash. The // form keeps it.
	if path ~= "" and path:sub(1, 1) ~= "/" then
		local absolute = "/" .. path
		if vim.fn.filereadable(absolute) == 1 or vim.fn.isdirectory(absolute) == 1 then
			return absolute
		end
	end

	return path
end

local function popup_config_home()
	local dir = vim.fn.stdpath("cache") .. "/yazi-tmux-popup"
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile({
		"[mgr]",
		"prepend_keymap = [",
		'	{ on = "<C-b>", run = "quit", desc = "Close" },',
		"]",
	}, dir .. "/keymap.toml")
	return dir
end

local function open_yazi_popup(directory, use_visual, reveal_path)
	if vim.env.TMUX == nil or vim.env.TMUX == "" then
		vim.notify("Yazi popup requires a tmux session", vim.log.levels.ERROR)
		return
	end

	local yazi_bin = vim.fn.exepath("yazi")
	if yazi_bin == "" then
		vim.notify("yazi is not on PATH", vim.log.levels.ERROR)
		return
	end

	local cwd = directory
	local reveal = reveal_path
	if cwd == nil or cwd == "" then
		local start = ""
		if use_visual then
			start = visual_selection_path() or ""
		end
		if start == "" then
			start = require("yazi.utils").selected_file_path().filename or ""
		end
		if vim.fn.isdirectory(start) == 1 then
			cwd = start
		elseif vim.fn.filereadable(start) == 1 then
			cwd = vim.fn.fnamemodify(start, ":h")
			reveal = start
		else
			cwd = vim.uv.cwd() or vim.fn.getcwd()
		end
	end

	if vim.fn.isdirectory(cwd) ~= 1 then
		vim.notify("Yazi popup directory does not exist: " .. cwd, vim.log.levels.ERROR)
		return
	end

	local chooser = vim.fn.tempname()
	local channel = "yazi-popup-" .. vim.uv.hrtime()
	local reveal_arg = reveal and (" " .. shell_quote(reveal)) or ""
	local script = string.format(
		"trap 'tmux wait-for -S %s' EXIT; YAZI_CONFIG_HOME=%s %s --chooser-file %s%s",
		channel,
		shell_quote(popup_config_home()),
		shell_quote(yazi_bin),
		shell_quote(chooser),
		reveal_arg
	)

	local waiter = vim.system({ "tmux", "wait-for", channel })
	local popup = vim.system({
		"tmux",
		"display-popup",
		"-E",
		"-d",
		cwd,
		"-w",
		"80%",
		"-h",
		"80%",
		"--",
		"sh",
		"-c",
		script,
	}):wait()

	if popup.code ~= 0 then
		vim.system({ "tmux", "wait-for", "-S", channel }):wait()
		waiter:wait()
		local detail = (popup.stderr or popup.stdout or ""):gsub("%s+$", "")
		vim.notify(detail ~= "" and detail or "tmux display-popup failed", vim.log.levels.ERROR)
		return
	end

	waiter:wait()

	local lines = {}
	if vim.fn.filereadable(chooser) == 1 then
		lines = vim.fn.readfile(chooser)
		os.remove(chooser)
	end

	local files = {}
	local chosen_directory
	for _, line in ipairs(lines) do
		local path = chooser_path(line)
		if path ~= "" then
			if vim.fn.isdirectory(path) == 1 then
				chosen_directory = path
			else
				files[#files + 1] = path
			end
		end
	end

	if #files == 0 and chosen_directory ~= nil then
		vim.schedule(function()
			open_yazi_popup(chosen_directory)
		end)
		return
	end

	if #files == 0 then
		return
	end

	vim.schedule(function()
		vim.cmd.edit(vim.fn.fnameescape(files[1]))
		for index = 2, #files do
			vim.cmd.badd(vim.fn.fnameescape(files[index]))
		end
	end)
end

return {
	"mikavilpas/yazi.nvim",
	version = "*",
	event = "VeryLazy",
	dependencies = {
		{ "nvim-lua/plenary.nvim", lazy = true },
	},
	keys = {
		{
			"<leader>-",
			function()
				local directory, file = current_directory()
				open_yazi_popup(directory, false, file)
			end,
			mode = "n",
			desc = "Open yazi in the current directory",
		},
		{
			"<leader>-",
			function()
				open_yazi_popup(nil, true)
			end,
			mode = "v",
			desc = "Open yazi at the selected path",
		},
		{
			"<C-b>",
			function()
				open_yazi_popup(project_root())
			end,
			mode = "n",
			desc = "Toggle yazi at the project root",
		},
		{
			"<C-Up>",
			"<cmd>Yazi toggle<cr>",
			desc = "Resume the last yazi session",
		},
	},
	opts = {
		open_for_directories = false,
		open_file_function = function(chosen_file)
			if vim.fn.isdirectory(chosen_file) == 1 then
				vim.schedule(function()
					require("yazi").yazi(nil, chosen_file)
				end)
				return
			end

			require("yazi.openers").open_file(chosen_file)
		end,
		keymaps = {
			show_help = "<f1>",
		},
		hooks = {
			yazi_opened = function(_, buffer)
				vim.keymap.set("t", "<C-b>", function()
					local current = require("yazi").active_contexts:current()
					if current then
						current.api:emit_to_yazi({ "quit" })
					end
				end, { buffer = buffer, desc = "Close yazi" })
			end,
		},
	},
}
