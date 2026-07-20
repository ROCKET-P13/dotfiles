local M = {
	"nvim-treesitter/nvim-treesitter",
	branch = "main",
	dependencies = {
		"windwp/nvim-ts-autotag",
	},
	build = ":TSUpdate",
	lazy = false,
	config = function()
		local ts = require("nvim-treesitter")

		local ensure_installed = {
			"vimdoc",
			"json",
			"javascript",
			"typescript",
			"c",
			"c_sharp",
			"lua",
			"rust",
			"jsdoc",
			"bash",
			"query",
		}

		-- Install missing parsers from ensure_installed on startup.
		local installed = {}
		for _, lang in ipairs(ts.get_installed("parsers")) do
			installed[lang] = true
		end
		local missing = {}
		for _, lang in ipairs(ensure_installed) do
			if not installed[lang] then
				missing[#missing + 1] = lang
			end
		end
		if #missing > 0 then
			ts.install(missing)
		end

		-- nvim-ts-autotag now exposes its own setup() and no longer relies on
		-- the removed nvim-treesitter.configs module.
		require("nvim-ts-autotag").setup({})

		-- Incremental selection (replaces the removed incremental_selection module).
		local current_node = {}

		local function set_visual_selection(bufnr, node)
			if not node then
				return
			end
			current_node[bufnr] = node
			local start_row, start_col, end_row, end_col = node:range()
			vim.fn.setpos("'<", { bufnr, start_row + 1, start_col + 1, 0 })
			vim.fn.setpos("'>", { bufnr, end_row + 1, end_col, 0 })
			vim.cmd("normal! gv")
		end

		local function init_selection()
			local bufnr = vim.api.nvim_get_current_buf()
			local node = vim.treesitter.get_node({ bufnr = bufnr })
			if not node then
				local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
				if ok and parser then
					node = parser:tree():root()
				end
			end
			set_visual_selection(bufnr, node)
		end

		local function node_incremental()
			local bufnr = vim.api.nvim_get_current_buf()
			local node = current_node[bufnr] or vim.treesitter.get_node({ bufnr = bufnr })
			if not node then
				return
			end
			local parent = node:parent()
			if parent then
				set_visual_selection(bufnr, parent)
			end
		end

		local function node_decremental()
			local bufnr = vim.api.nvim_get_current_buf()
			local node = current_node[bufnr]
			if not node then
				return
			end
			local row, col = unpack(vim.api.nvim_win_get_cursor(0))
			local cursor = { row - 1, col }
			for i = 0, node:named_child_count() - 1 do
				local child = node:named_child(i)
				if child and vim.treesitter.node_contains(child, cursor) then
					set_visual_selection(bufnr, child)
					return
				end
			end
		end

		vim.keymap.set("n", "<C-space>", init_selection, { desc = "TS: init selection" })
		vim.keymap.set("x", "<C-space>", node_incremental, { desc = "TS: node incremental" })
		vim.keymap.set("x", "<bs>", node_decremental, { desc = "TS: node decremental" })
	end,
}

return M
