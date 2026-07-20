-- Custom local plugin: VSCode TextMate grammar highlighting via the real
-- vscode-textmate + vscode-oniguruma libraries. Token colors are resolved from
-- the bundled VSCode gruvbox theme (jdinhify/vscode-theme-gruvbox v1.29.1), so
-- highlighting matches VSCode rather than the Neovim colorscheme. Replaces
-- treesitter highlighting on the configured filetypes (treesitter stays active
-- for everything else, indentation, and incremental selection).
return {
	dir = vim.fn.stdpath("config") .. "/textmate.nvim",
	name = "textmate.nvim",
	lazy = false,
	-- Installs the Node tokenizer deps and downloads grammar files.
	-- Re-run manually with `:Lazy build textmate.nvim`.
	build = "cd tokenizer && npm install && node fetch-grammars.js",
	config = function()
		require("textmate").setup({
			-- Matches your gruvbox.nvim `contrast = "hard"` dark setup.
			theme = "gruvbox-dark-hard",
			-- Other bundled variants: gruvbox-dark-medium, gruvbox-dark-soft,
			-- gruvbox-light-hard, gruvbox-light-medium, gruvbox-light-soft.
			replace_treesitter = true, -- stop TS highlight on attached buffers
			auto_attach = true, -- attach on FileType for mapped filetypes
			-- node = "node",              -- override node binary path
			throttle_ms = 40, -- how often to re-highlight while typing
			-- Files above this line count are skipped (no highlighting). Raised
			-- from the 5000 default; each tokenize pass re-sends the whole buffer,
			-- so very large files cost more per edit.
			max_lines = 100000,
		})
	end,
}
