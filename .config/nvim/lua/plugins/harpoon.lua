local M = {
	"ThePrimeagen/harpoon",
	dependencies = {
		"nvim-lua/plenary.nvim",
	},
	config = function()
		vim.keymap.set("n", "<leader>ha", function()
			require("harpoon.mark").add_file()
		end)

		vim.keymap.set("n", "<C-e>", function()
			require("harpoon.ui").toggle_quick_menu()
		end)

		vim.keymap.set("n", "<leader>1", function()
			require("harpoon.ui").nav_file(1)
		end)
		vim.keymap.set("n", "<leader>2", function()
			require("harpoon.ui").nav_file(2)
		end)
		vim.keymap.set("n", "<leader>3", function()
			require("harpoon.ui").nav_file(3)
		end)
		vim.keymap.set("n", "<leader>4", function()
			require("harpoon.ui").nav_file(4)
		end)
	end,
}

return M
