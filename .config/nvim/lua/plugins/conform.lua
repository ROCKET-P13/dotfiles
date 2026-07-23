local M = {
	"stevearc/conform.nvim",
	dependencies = {
		"nvim-lua/plenary.nvim",
		{
			"mason-org/mason.nvim",
			opts = {},
		},
	},
	config = function()
		local conform = require("conform")

		conform.setup({
			formatters_by_ft = {
				lua = { "stylua" },
				-- cs = { "omnisharp" },
			},
			format_on_save = function(bufnr)
				local disabled = { html = true, xml = true, cs = true, json = true, jsonc = true }
				if disabled[vim.bo[bufnr].filetype] then
					return nil
				end
				return { lsp_fallback = true, async = false }
			end,
		})
	end,
}

return M
