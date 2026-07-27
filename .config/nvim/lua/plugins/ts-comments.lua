-- Treesitter-aware commentstring resolution. Used by Comment.nvim's `pre_hook`
-- (see lua/plugins/comment.lua) to emit `{/* %s */}` inside JSX nodes instead of
-- the `//%s` that Comment.nvim's bundled ft table returns for typescriptreact /
-- javascriptreact. Loads on JS/TS-family filetypes so setup() runs before any
-- comment toggle in those buffers.
return {
	"folke/ts-comments.nvim",
	event = "VeryLazy",
	enabled = vim.fn.has("nvim-0.10.0") == 1,
	opts = {},
}
