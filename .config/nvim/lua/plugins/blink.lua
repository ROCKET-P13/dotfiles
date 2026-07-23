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

		-- Returns true when the LSP has signature-help data for the call at the
		-- current cursor. Relies on blink's signature module, which clears its
		-- trigger context when the LSP responds with no signatures, so a non-nil
		-- context means the LSP knows the parameter shape for this call. In
		-- buffers with no LSP attached we never suppress (no signature help is
		-- possible, so the check is meaningless).
		local function in_call_with_signature()
			if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
				return true
			end
			local ok, sig_trigger = pcall(require, "blink.cmp.signature.trigger")
			return ok and sig_trigger.context ~= nil
		end

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
			local disabled = false
			disabled = disabled or (vim.tbl_contains({ "markdown", "json", "jsonc" }, vim.bo.filetype))
			disabled = disabled or (vim.bo.buftype == "prompt")
			-- Treesitter parsers aren't installed here, so node-based detection
			-- can't see string contexts. Scan the current line up to the cursor with
			-- a small stack parser: it tracks quoted strings, template-literal
			-- interpolations, and bracket contexts (both array literals and
			-- indexing). Completions are suppressed inside string text, inside
			-- `${...}` is still code, and inside `[...]` when the current element
			-- (text since the last comma or opening `[`) is empty or purely
			-- numeric (`arr[`, `arr[0`, `[1, 2, 3, 4`), while quoted keys
			-- (`obj["key"]`) and non-numeric elements (`[foo, bar`) stay enabled.
			if not disabled then
				local col = vim.api.nvim_win_get_cursor(0)[2]
				local before = vim.api.nvim_get_current_line():sub(1, col)
				local stack, i = {}, 1
			while i <= #before do
				local ch = before:sub(i, i)
				local top = stack[#stack]
				if top and top.delim then
					if ch == "\\" then
						i = i + 2
					elseif ch == top.delim then
						stack[#stack] = nil
						i = i + 1
					elseif top.delim == "`" and ch == "$" and before:sub(i + 1, i + 1) == "{" then
						stack[#stack + 1] = { interp = true, depth = 1 }
						i = i + 2
					else
						i = i + 1
					end
				elseif top and top.interp then
					if ch == "{" then
						top.depth = top.depth + 1
						i = i + 1
					elseif ch == "}" then
						top.depth = top.depth - 1
						if top.depth == 0 then
							stack[#stack] = nil
						end
						i = i + 1
					elseif ch == "'" or ch == '"' or ch == "`" then
						stack[#stack + 1] = { delim = ch }
						i = i + 1
					else
						i = i + 1
					end
				elseif top and top.bracket then
					-- Bracket context covers both array literals (`[1, 2, 3]`) and
					-- indexing (`arr[0]`, `obj["key"]`). Quoted keys hand control
					-- to the delim state, so bracket content only accumulates bare
					-- element text. Track only the current element (reset on comma)
					-- and suppress when it is empty or purely numeric, so typing
					-- numbers never triggers LSP suggestions.
					if ch == "]" then
						stack[#stack] = nil
						i = i + 1
					elseif ch == "'" or ch == '"' or ch == "`" then
						stack[#stack + 1] = { delim = ch }
						i = i + 1
					elseif ch == "[" then
						stack[#stack + 1] = { bracket = true, content = "" }
						i = i + 1
					elseif ch == "," then
						top.content = ""
						i = i + 1
					else
						top.content = top.content .. ch
						i = i + 1
					end
				elseif top and top.paren then
					-- Argument-list context `(...)`. Only `call` parens (preceded
					-- by an identifier / `)` / `]`, i.e. a real function call) are
					-- candidates for the no-signature suppression below; grouping
					-- and control-flow parens (`if (`, `(a + b)`) stay enabled.
					if ch == ")" then
						stack[#stack] = nil
						i = i + 1
					elseif ch == "'" or ch == '"' or ch == "`" then
						stack[#stack + 1] = { delim = ch }
						i = i + 1
					else
						i = i + 1
					end
				elseif ch == "'" or ch == '"' or ch == "`" then
					stack[#stack + 1] = { delim = ch }
					i = i + 1
				elseif ch == "[" then
					stack[#stack + 1] = { bracket = true, content = "" }
					i = i + 1
				elseif ch == "(" then
					-- Decide call vs. grouping by the token immediately before
					-- `(` (skipping whitespace). A preceding identifier that is
					-- not a control-flow keyword, or a preceding `)` / `]`,
					-- marks a function-call argument list.
					local j = i - 1
					while j >= 1 and (before:sub(j, j) == " " or before:sub(j, j) == "\t") do
						j = j - 1
					end
					local prev = before:sub(j, j)
					local is_call = prev == ")" or prev == "]"
						or prev:match("[%w_$]")
					if is_call and j >= 1 and prev:match("[%w_$]") then
						local wj = j
						while wj >= 1 and before:sub(wj, wj):match("[%w_$]") do
							wj = wj - 1
						end
						local word = before:sub(wj + 1, j)
						if vim.tbl_contains({
							"if", "elseif", "for", "while", "switch", "catch",
							"return", "typeof", "void", "delete", "instanceof",
							"in", "of", "await", "yield", "do", "with", "throw",
							"repeat", "until", "and", "or", "not", "function",
							"using", "lock", "foreach", "sizeof", "is", "as",
						}, word) then
							is_call = false
						end
					end
					stack[#stack + 1] = { paren = true, call = is_call }
					i = i + 1
				else
					i = i + 1
				end
			end
			local top = stack[#stack]
			disabled = top ~= nil
				and (top.delim ~= nil
					or (top.bracket ~= nil and top.content:match("^%s*%d*$") ~= nil)
					or (top.paren ~= nil and top.call and not in_call_with_signature()))
			end
			return not disabled
		end,
			snippets = { preset = "luasnip" },
			sources = {
				default = { "lsp", "path", "snippets" },
				providers = {
					buffer = {
						opts = {
							min_keyword_length = 3,
						},
					},
				},
			},
		appearance = {
			nerd_font_variant = "mono",
		},
		-- Fuzzy matching + ranking tuned to feel like VSCode: typo-tolerant,
		-- frecency-weighted, scored before label text.
		fuzzy = {
			frecency = {
				enabled = true,
			},
			sorts = { "score", "sort_text", "label" },
			prebuilt_binaries = {
				download = true,
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
	-- Enabled so blink tracks signature-help state (used by the `enabled`
	-- function to suppress completions in argument lists with no LSP
	-- signature data), but the popup window is hidden below.
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

		-- Keep signature tracking active as a signal for `enabled`, but never
		-- show the parameter-hints popup. Overriding the open entrypoint (set
		-- up lazily inside `blink.cmp.setup`) prevents the window from opening
		-- while `trigger.context` still gets populated.
		require("blink.cmp.signature.window").open_with_signature_help = function() end
	end,
}

return M
