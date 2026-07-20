-- Public entry point: starts the tokenizer, wires filetype -> grammar scope
-- attachment, manages treesitter coexistence, and exposes user commands.

local client_mod = require("textmate.client")
local highlighter = require("textmate.highlighter")
local theme = require("textmate.theme")

local M = {}

local DEFAULT_FILETYPES = {
	javascript = "source.js",
	javascriptreact = "source.js.jsx",
	typescript = "source.ts",
	typescriptreact = "source.tsx",
	json = "source.json",
	jsonc = "source.json.comments",
	c = "source.c",
	rust = "source.rust",
	cs = "source.cs",
	html = "text.html.basic",
	xml = "text.xml",
}

local state = {
	client = nil,
	config = nil,
}

local function plugin_root()
	local src = debug.getinfo(1, "S").source:sub(2)
	-- src: <root>/lua/textmate/init.lua  ->  <root>
	return vim.fn.fnamemodify(src, ":h:h:h")
end

local function resolve_node(configured)
	if configured and configured ~= "" then
		return configured
	end
	local exe = vim.fn.exepath("node")
	if exe == "" then
		return nil
	end
	return exe
end

local function deps_installed(root)
	return vim.fn.isdirectory(root .. "/tokenizer/node_modules") == 1
		and vim.fn.isdirectory(root .. "/tokenizer/grammars") == 1
end

local function theme_path(root, name)
	return root .. "/tokenizer/themes/" .. name .. ".json"
end

-- Stops treesitter highlighting on a buffer so it does not paint over us.
-- nvim-treesitter also attaches on FileType; if its autocmd runs after ours it
-- would re-start highlighting, so we additionally stop on the next tick to win
-- the race regardless of autocmd ordering.
local function stop_treesitter(buf)
	pcall(vim.treesitter.stop, buf)
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.treesitter.stop, buf)
		end
	end)
end

local function start_treesitter(buf)
	pcall(vim.treesitter.start, buf)
end

-- Legacy Vim :syntax highlighting runs independently of treesitter, so it keeps
-- matching underneath our extmarks (visible in :Inspect) unless we also turn it
-- off. Setting 'syntax' to "OFF" clears it for the buffer; "ON" reloads it from
-- the filetype. Re-apply on the next tick for the same FileType-autocmd race
-- reason as stop_treesitter.
local function stop_syntax(buf)
	local function off()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].syntax = "OFF"
		end
	end
	off()
	vim.schedule(off)
end

local function start_syntax(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].syntax = "ON"
	end
end

local function scope_for_buf(buf)
	local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
	return state.config.filetypes[ft]
end

function M.attach_buf(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local scope_name = scope_for_buf(buf)
	if not scope_name then
		return false
	end
	if state.config.replace_treesitter then
		stop_treesitter(buf)
		stop_syntax(buf)
	end
	highlighter.attach(buf, scope_name)
	return true
end

function M.detach_buf(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	highlighter.detach(buf)
	if state.config.replace_treesitter then
		start_treesitter(buf)
		start_syntax(buf)
	end
end

function M.toggle_buf(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if highlighter.is_attached(buf) then
		M.detach_buf(buf)
	else
		if not M.attach_buf(buf) then
			vim.notify("[textmate] no grammar mapped for this filetype", vim.log.levels.WARN)
		end
	end
end

local function create_commands()
	vim.api.nvim_create_user_command("TextmateEnable", function()
		if not M.attach_buf() then
			vim.notify("[textmate] no grammar mapped for this filetype", vim.log.levels.WARN)
		end
	end, { desc = "Enable TextMate highlighting for the current buffer" })

	vim.api.nvim_create_user_command("TextmateDisable", function()
		M.detach_buf()
	end, { desc = "Disable TextMate highlighting for the current buffer" })

	vim.api.nvim_create_user_command("TextmateToggle", function()
		M.toggle_buf()
	end, { desc = "Toggle TextMate highlighting for the current buffer" })
end

--- @param opts table|nil
function M.setup(opts)
	opts = opts or {}
	local root = plugin_root()

	local config = {
		node = resolve_node(opts.node),
		tokenizer = root .. "/tokenizer/tokenizer.js",
		theme = opts.theme or "gruvbox-dark-hard",
		filetypes = vim.tbl_extend("force", DEFAULT_FILETYPES, opts.filetypes or {}),
		replace_treesitter = opts.replace_treesitter ~= false,
		auto_attach = opts.auto_attach ~= false,
		throttle_ms = opts.throttle_ms or opts.debounce_ms or 40,
		max_lines = opts.max_lines or 5000,
	}
	state.config = config

	create_commands()

	if not config.node then
		vim.notify("[textmate] node executable not found; set opts.node", vim.log.levels.ERROR)
		return
	end
	if not deps_installed(root) then
		vim.notify(
			"[textmate] dependencies missing; run :Lazy build textmate.nvim",
			vim.log.levels.ERROR
		)
		return
	end
	local theme_file = theme_path(root, config.theme)
	if vim.fn.filereadable(theme_file) ~= 1 then
		vim.notify("[textmate] theme not found: " .. theme_file, vim.log.levels.ERROR)
		return
	end

	local client = client_mod.new()
	state.client = client
	client:start({ node = config.node, tokenizer = config.tokenizer, theme = theme_file })

	-- Must run before any tokenize pass so highlight groups can be built.
	client:when_ready(function()
		theme.set_colormap(client.color_map)
	end)

	highlighter.setup({
		client = client,
		throttle_ms = config.throttle_ms,
		max_lines = config.max_lines,
	})

	if config.auto_attach then
		local group = vim.api.nvim_create_augroup("textmate_auto_attach", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = vim.tbl_keys(config.filetypes),
			callback = function(args)
				M.attach_buf(args.buf)
			end,
		})
		-- Attach to already-open buffers (e.g. the file opened before setup ran).
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				M.attach_buf(buf)
			end
		end
	end
end

return M
