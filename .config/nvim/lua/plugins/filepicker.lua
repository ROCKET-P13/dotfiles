-- Local plugin: VSCode-style file picker built on a custom Telescope picker.
-- The module lives in lua/filepicker and is loaded directly; this spec just
-- runs setup so the MRU autocmd and <C-p> keymap are registered at startup.
return {
	dir = vim.fn.stdpath("config") .. "/lua/filepicker",
	name = "filepicker",
	lazy = false,
	dependencies = {
		"nvim-telescope/telescope.nvim",
		"nvim-lua/plenary.nvim",
		"nvim-tree/nvim-web-devicons",
	},
	config = function()
		require("filepicker").setup({
			key = "<C-p>",
			debounce_ms = 30,
			recency_weight = 12,
			mru_cap = 200,
			exclude_ext = { csv = true },
		})
	end,
}
