local M = {
	"saghen/blink.cmp",
	version = "1.*",
	dependencies = {
		{
			"L3MON4D3/LuaSnip",
			version = "v2.*", -- Replace <CurrentMajor> by the latest released major (first number of latest release)
			build = "make install_jsregexp",
		},
	},
	config = function()
		require("luasnip.loaders.from_vscode").lazy_load({
			paths = { vim.fn.stdpath("config") .. "/snippets" },
		})

		require("blink.cmp").setup({
			keymap = {
				["<CR>"] = { "select_and_accept", "fallback" },
				["<Tab>"] = {
					"select_next",
					"snippet_forward",
					"fallback",
				},
				["<S-Tab>"] = {
					"select_prev",
					"snippet_backward",
					"fallback",
				},
			},
			enabled = function()
				local node = vim.treesitter.get_node()
				local disabled = false
				disabled = disabled or (vim.tbl_contains({ "markdown" }, vim.bo.filetype))
				disabled = disabled or (vim.bo.buftype == "prompt")
				disabled = disabled or (node and string.find(node:type(), "comment"))
				disabled = disabled or (node and string.find(node:type(), "string"))

				return not disabled
			end,
			snippets = { preset = "luasnip" },
			sources = {
				default = { "lsp", "snippets", "buffer" },
			},
			completion = {
				accept = {
					auto_brackets = {
						enabled = false,
					},
				},
				trigger = {
					show_on_blocked_trigger_characters = { " ", "\n", "\t" },
					show_on_x_blocked_trigger_characters = { "'", '"', "(" },
				},
				list = {
					max_items = 15,
					selection = {
						preselect = true,
						auto_insert = false,
					},
				},
			},
		})
	end,
}

return M
