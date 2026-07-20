vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.cursorline = true
vim.opt.cursorlineopt = "number"
vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#ff9e64", bold = true })

vim.opt.startofline = true

vim.opt.timeout = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.numberwidth = 4
vim.opt.list = false
vim.opt.autoindent = true -- copy indent from current line when starting new one

vim.opt.swapfile = false

vim.opt.wrap = false
vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.termguicolors = true
vim.opt.background = "dark"
vim.opt.signcolumn = "yes"

vim.opt.backspace = "indent,eol,start"

vim.opt.clipboard:append("unnamedplus")

vim.opt.splitright = true
vim.opt.splitbelow = true

vim.opt.fixendofline = false

vim.g.mapleader = " "
-- force CRLF line endings for all new files
vim.opt.fileformats = "dos,unix"
vim.opt.fileformat = "dos"
vim.opt.cmdheight = 0

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
	callback = function()
		if vim.bo.buftype == "" then
			vim.cmd("checktime")
		end
	end,
})

vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Highlight when yanking (copying) text",
	group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
	callback = function()
		vim.highlight.on_yank({ higroup = "Visual" })
	end,
})

-- Automatically trigger buffer reload when underlying disk file has changed
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
	callback = function()
		if vim.bo.buftype == "" then -- Only reload normal file buffers
			vim.cmd("checktime")
		end
	end,
})

vim.keymap.set("n", "<C-l>", "<C-W>l")
vim.keymap.set("n", "<C-h>", "<C-W>h")
vim.keymap.set("n", "<C-j>", "<C-W>j")
vim.keymap.set("n", "<C-k>", "<C-W>k")

vim.opt.startofline = true

local keymap = vim.api.nvim_set_keymap

keymap("n", "<leader>p", ":MarkdownPreviewToggle<CR>", {})

keymap("n", "<leader>v", ":TodoLocList<CR>", {})

keymap("n", "<C-s>", ":w<CR>", {})

keymap("n", "<leader>z", ":delmarks a-zA-Z0-9", {})

keymap("n", "<leader>d", [[:lua require('goto-preview').goto_preview_definition()<CR>]], {})
keymap("n", "<leader>t", [[:lua require('goto-preview').goto_preview_type_definition()<CR>]], {})
keymap("n", "<leader>i", [[:lua require('goto-preview').goto_preview_implementation()<CR>]], {})
keymap("n", "<leader>D", [[:lua require('goto-preview').goto_preview_declaration()<CR>]], {})
keymap("n", "<Esc>", [[:lua require('goto-preview').close_all_win()<CR>]], {})
keymap("n", "<leader>r", [[:lua require('goto-preview').goto_preview_references()<CR>]], {})

local esc = vim.api.nvim_replace_termcodes("<Esc>", true, true, true)
vim.fn.setreg("t", "ywothrow new Error(JSON.stringify({ " .. esc .. "pa }));" .. esc)
vim.fn.setreg("l", "ywoconsole.log(JSON.stringify({ " .. esc .. "pa }));" .. esc)
