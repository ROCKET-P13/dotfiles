-- Local plugin: Spectre-style project-wide find & replace. The module lives in
-- lua/globalreplace and is loaded directly; this spec just runs setup so the
-- keymaps and highlights are registered at startup.
return {
	dir = vim.fn.stdpath("config") .. "/lua/globalreplace",
	name = "globalreplace",
	lazy = false,
	config = function()
		require("globalreplace").setup({
			key = "<leader>sg",
		})
	end,
}
