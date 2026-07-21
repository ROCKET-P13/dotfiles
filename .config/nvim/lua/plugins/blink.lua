local M = {
	"saghen/blink.cmp",
	version = "1.*",
	dependencies = {
		{
			"L3MON4D3/LuaSnip",
			version = "v2.*",
			build = "make install_jsregexp",
		},
	},
	config = function()
		require("luasnip.loaders.from_vscode").lazy_load({
			paths = { vim.fn.stdpath("config") .. "/snippets" },
		})

		require("blink.cmp").setup({
		-- Enter accepts the selected suggestion (falls back to a newline
		-- when no menu is visible). Esc dismisses the menu and leaves insert
		-- mode in a single press.
		keymap = {
			preset = "none",
			["<Tab>"] = { "accept", "snippet_forward", "fallback" },
			["<S-Tab>"] = { "snippet_backward", "fallback" },
			["<Up>"] = { "select_prev", "fallback" },
			["<Down>"] = { "select_next", "fallback" },
			["<C-p>"] = { "select_prev", "fallback" },
			["<C-n>"] = { "select_next", "fallback" },
			["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
			["<C-e>"] = { "hide" },
			["<Esc>"] = {
				function(blink)
					blink.hide()
					return "\27"
				end,
			},
			["<CR>"] = { "accept", "fallback" },
				["<C-b>"] = { "scroll_documentation_up" },
				["<C-f>"] = { "scroll_documentation_down" },
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
				default = { "lsp", "path", "snippets", "buffer" },
				providers = {
					buffer = {
						opts = {
							min_keyword_length = 3,
						},
					},
				},
			},
			appearance = {
				nerd_font = "mono",
			},
		-- Fuzzy matching + ranking tuned to feel like VSCode: typo-tolerant,
		-- frecency-weighted, scored before label text.
		fuzzy = {
			use_typo_resistance = true,
			frecency = {
				enabled = true,
			},
			sorts = { "score", "sort_text", "label" },
			prebuilt_binaries = {
				enable = true,
				auto_download = true,
			},
		},
			completion = {
				keyword = {
					range = "full",
				},
				trigger = {
					show_on_blocked_trigger_characters = { " ", "\n", "\t" },
					show_on_x_blocked_trigger_characters = { "'", '"', "(" },
					show_in_snippet = true,
				},
				accept = {
					auto_brackets = {
						enabled = true,
					},
				},
			list = {
				max_items = 30,
				selection = {
					preselect = function(ctx)
						return ctx.mode ~= "cmdline"
					end,
					auto_insert = false,
				},
				cycle = {
					from_bottom = true,
					from_top = true,
				},
			},
			-- Documentation is fetched on demand only (no auto-show) to keep
			-- completions responsive and avoid LSP doc round-trips per selection.
			documentation = {
				auto_show = false,
				window = {
					border = "rounded",
					min_width = 30,
					max_width = 60,
					max_height = 20,
				},
			},
			-- VSCode-style inline ghost text preview of the accepted item.
			ghost_text = {
				enabled = true,
			},
			menu = {
				border = "rounded",
				draw = {
					columns = { { "kind_icon" }, { "label", gap = 1 }, { "source_name" } },
				},
			},
			},
		-- VSCode-style parameter hints while typing function arguments.
		signature = {
			enabled = true,
			trigger = {
				enabled = true,
				show_on_insert_on_trigger_character = false,
			},
			window = {
				border = "rounded",
			},
		},
		-- cmdline keymap lives at the top level (not under `keymap`).
		cmdline = {
			sources = function()
				local type = vim.fn.getcmdtype()
				if type == ":" then
					return { "cmdline", "path" }
				elseif type == "/" or type == "?" then
					return { "buffer" }
				end
				return {}
			end,
			keymap = {
				["<Tab>"] = { "accept", "fallback" },
				["<CR>"] = { "accept", "fallback" },
				["<Up>"] = { "fallback" },
				["<Down>"] = { "fallback" },
			},
		},
		})
	end,
}

return M
