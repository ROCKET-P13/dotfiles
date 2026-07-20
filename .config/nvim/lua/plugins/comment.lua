local M = {
	"numToStr/Comment.nvim",
}

function M.config()
	require("Comment").setup({
		toggler = {
			line = "<C-_>",
		},
		opleader = {
			line = "<C-_>",
		},
	})

	-- Ghostty transmits Ctrl-/ as <C-_>; alias <C-/> in case the terminal sends it literally.
	vim.keymap.set({ "n", "x" }, "<C-/>", "<C-_>", { remap = true, silent = true, desc = "Comment toggle" })
end

return M
