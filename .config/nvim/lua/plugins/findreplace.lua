-- Local plugin: VSCode/Cursor-style in-file find & replace widget. The module
-- lives in lua/findreplace and is loaded directly; this spec just runs setup so
-- the keymaps and highlights are registered at startup.
return {
	dir = vim.fn.stdpath("config") .. "/lua/findreplace",
	name = "findreplace",
	lazy = false,
	config = function()
		require("findreplace").setup({
			key = "<C-f>",
		})
	end,
}
