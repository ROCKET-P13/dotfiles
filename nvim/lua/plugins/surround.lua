local M = {
	"kylechui/nvim-surround",
	version = "^3.0.0",
	event = "VeryLazy",
	config = function()
		require("nvim-surround").setup({
			surrounds = {
				["("] = {
					add = { "(", ")" },
				},
				["{"] = {
					add = { "{ ", " }" },
				},
				["["] = {
					add = { "[", "]" },
				},
			},
			keymaps = {
				normal = "su",
			},
		})

		vim.keymap.set("v", '"', '<Plug>(nvim-surround-visual)"', {})
		vim.keymap.set("v", "'", "<Plug>(nvim-surround-visual)'", {})
		vim.keymap.set("v", "(", "<Plug>(nvim-surround-visual)(", {})
		vim.keymap.set("v", "[", "<Plug>(nvim-surround-visual)[", {})
		vim.keymap.set("v", "{", "<Plug>(nvim-surround-visual){", {})
		-- vim.keymap.set("v", "<", "<Plug>(nvim-surround-visual)<", {})
	end,
}

return M
