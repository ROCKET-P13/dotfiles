local M = {
	"numToStr/Comment.nvim",
}

function M.config()
	require("Comment").setup({
		toggler = {
			line = "<C-/>",
		},
		opleader = {
			line = "<C-/>",
		},
	})
end

return M
