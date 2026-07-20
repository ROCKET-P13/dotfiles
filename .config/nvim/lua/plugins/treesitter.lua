local M = {
	"nvim-treesitter/nvim-treesitter",
	dependencies = {
		"nvim-treesitter/playground",
		"windwp/nvim-ts-autotag",
	},
	build = ":TSUpdate",
	lazy = false,
	config = function()
		require("nvim-treesitter.configs").setup({
			ensure_installed = {
				"vimdoc",
				"jsonc",
				"javascript",
				"typescript",
				"c",
				"c_sharp",
				"lua",
				"rust",
				"jsdoc",
				"bash",
				"query",
			},
			sync_install = true,
			auto_install = false,
			indent = {
				enable = false,
			},
			autotag = {
				enable = true,
			},
			highlight = {
				enable = false,
				additional_vim_regex_highlighting = false,
			},
			incremental_selection = {
				enable = true,
				keymaps = {
					init_selection = "<C-space>",
					node_incremental = "<C-space>",
					scope_incremental = false,
					node_decremental = "<bs>",
				},
			},
		})
	end,
}

return M
