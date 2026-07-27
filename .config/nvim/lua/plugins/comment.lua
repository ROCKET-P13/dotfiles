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
		-- Comment.nvim resolves the commentstring as pre_hook -> ft.calculate() ->
		-- vim.bo.commentstring. Its bundled ft table maps typescriptreact /
		-- javascriptreact to `//%s`, which wins over vim.bo.commentstring, so
		-- JSX lines get `//` instead of `{/* */}`. Defer to ts-comments.nvim for
		-- the React filetypes so the treesitter node under the cursor decides;
		-- return nil for everything else to keep Comment.nvim's behavior intact.
		pre_hook = function(ctx)
			local ft = vim.bo.filetype
			if ft == "typescriptreact" or ft == "javascriptreact" then
				return require("ts-comments.comments").get(ft)
			end
		end,
	})

	-- Ghostty transmits Ctrl-/ as <C-_>; alias <C-/> in case the terminal sends it literally.
	vim.keymap.set({ "n", "x" }, "<C-/>", "<C-_>", { remap = true, silent = true, desc = "Comment toggle" })
end

return M
