return {
	"NeogitOrg/neogit",
	lazy = true,
	dependencies = {
		"esmuellert/codediff.nvim",
	},
	cmd = "Neogit",
	keys = {
		{ "<leader>gg", "<cmd>Neogit<cr>", desc = "Show Neogit UI" },
	},
	config = function()
		require("neogit").setup({
			kind = "floating",
			disable_line_numbers = false,
			integrations = {
				codediff = true,
			},
			diff_viewer = "codediff",
		})
	end,
}
