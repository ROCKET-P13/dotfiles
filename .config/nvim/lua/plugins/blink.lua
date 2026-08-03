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

		-- Decides whether a `{` at `end_col` (1-based, the index of the `{`
		-- itself) opens an object literal or a code block. Object literals sit
		-- in expression position: preceded by `=`, `(`, `,`, `[`, `:`, `?`, or
		-- an expression-yielding keyword (`return`, `await`, `new`, ...).
		-- Everything else (`)`, `else`, `try`, `do`, `=>`, statement starts) is
		-- a block and stays enabled. Used to suppress completions only on
		-- object-key typing, not inside function bodies.
		local function is_object_brace(line, end_col)
			local j = end_col
			while j >= 1 and (line:sub(j, j) == " " or line:sub(j, j) == "\t") do
				j = j - 1
			end
			local prev = line:sub(j, j)
			if j == 0 or prev == "=" or prev == "(" or prev == "," or prev == "[" or prev == ":" or prev == "?" then
				return true
			end
			if prev:match("[%w_$]") then
				local wj = j
				while wj >= 1 and line:sub(wj, wj):match("[%w_$]") do
					wj = wj - 1
				end
				local word = line:sub(wj + 1, j)
				return vim.tbl_contains({
					"return",
					"typeof",
					"void",
					"delete",
					"in",
					"of",
					"await",
					"yield",
					"throw",
					"new",
					"and",
					"or",
					"not",
					"is",
					"as",
				}, word)
			end
			return false
		end

		-- Parses the line text before the cursor and returns the top of the
		-- context stack, or nil when the stack is empty (cursor in plain code).
		-- Stack entries carry one of: `delim` (inside a quoted string), `interp`
		-- (inside a `${}` template interpolation), `bracket`, `paren`, or
		-- `brace`. Shared by `enabled()`, `sources.default`, and the lsp
		-- `transform_items` filter so they agree on "inside a string".
		local function context_top(before)
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
					if ch == ")" then
						stack[#stack] = nil
						i = i + 1
					elseif ch == "'" or ch == '"' or ch == "`" then
						stack[#stack + 1] = { delim = ch }
						i = i + 1
					else
						i = i + 1
					end
				elseif top and top.brace then
					if ch == "}" then
						stack[#stack] = nil
						i = i + 1
					elseif ch == "'" or ch == '"' or ch == "`" then
						stack[#stack + 1] = { delim = ch }
						i = i + 1
					elseif ch == "{" then
						stack[#stack + 1] =
							{ brace = true, object = is_object_brace(before, i - 1), content = "", colon = false }
						i = i + 1
					elseif top.object then
						if ch == "," then
							top.content = ""
							top.colon = false
							i = i + 1
						elseif ch == ":" then
							top.colon = true
							i = i + 1
						else
							top.content = top.content .. ch
							i = i + 1
						end
					else
						i = i + 1
					end
				elseif ch == "'" or ch == '"' or ch == "`" then
					stack[#stack + 1] = { delim = ch }
					i = i + 1
				elseif ch == "[" then
					stack[#stack + 1] = { bracket = true, content = "" }
					i = i + 1
				elseif ch == "{" then
					stack[#stack + 1] =
						{ brace = true, object = is_object_brace(before, i - 1), content = "", colon = false }
					i = i + 1
				elseif ch == "(" then
					local j = i - 1
					while j >= 1 and (before:sub(j, j) == " " or before:sub(j, j) == "\t") do
						j = j - 1
					end
					local prev = before:sub(j, j)
					local is_call = prev == ")" or prev == "]" or prev:match("[%w_$]")
					if is_call and j >= 1 and prev:match("[%w_$]") then
						local wj = j
						while wj >= 1 and before:sub(wj, wj):match("[%w_$]") do
							wj = wj - 1
						end
						local word = before:sub(wj + 1, j)
						if
							vim.tbl_contains({
								"if",
								"elseif",
								"for",
								"while",
								"switch",
								"catch",
								"return",
								"typeof",
								"void",
								"delete",
								"instanceof",
								"in",
								"of",
								"await",
								"yield",
								"do",
								"with",
								"throw",
								"repeat",
								"until",
								"and",
								"or",
								"not",
								"function",
								"using",
								"lock",
								"foreach",
								"sizeof",
								"is",
								"as",
							}, word)
						then
							is_call = false
						end
					end
					stack[#stack + 1] = { paren = true, call = is_call }
					i = i + 1
				else
					i = i + 1
				end
			end
			return stack[#stack]
		end

		-- True when a tailwindcss language server is attached to the buffer.
		-- Tailwind class names live inside string literals, so the string
		-- suppression in `enabled()` is relaxed only when this is true.
		local function tailwind_attached()
			return #vim.lsp.get_clients({ bufnr = 0, name = "tailwindcss" }) > 0
		end

		-- Top of the context stack at the cursor, for the shared string check.
		local function current_top()
			local col = vim.api.nvim_win_get_cursor(0)[2]
			local before = vim.api.nvim_get_current_line():sub(1, col)
			return context_top(before)
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
				-- disabled = disabled or (vim.tbl_contains({ "markdown", "json", "jsonc" }, vim.bo.filetype))
				-- disabled = disabled or (vim.bo.buftype == "prompt")
				local top = current_top()
				if top ~= nil and top.delim ~= nil then
					-- Inside a quoted string. Tailwind class names are typed
					-- inside string literals (e.g. `className="flex p-4"`), so
					-- keep the menu enabled when a tailwindcss server is
					-- attached; otherwise preserve the existing suppression.
					if not tailwind_attached() then
						disabled = true
					end
				else
					disabled = top ~= nil
						and (
							top.delim ~= nil
							or (top.bracket ~= nil and top.content:match("^%s*%d*$") ~= nil)
							or (top.brace ~= nil and top.object and not top.colon)
						)
				end
				return not disabled
			end,
			snippets = { preset = "luasnip" },
			sources = {
				-- Drop duplicate items that share the same label and LSP kind
				-- (e.g. `console` returned by both `lsp` and `buffer`). Keeps the
				-- first occurrence, which — after blink sorts — is the
				-- highest-ranked one. Runs after per-provider transform_items,
				-- so the lsp tailwind filter still applies.
				transform_items = function(_, items)
					local seen = {}
					return vim.tbl_filter(function(item)
						local key = (item.label or "") .. "\0" .. tostring(item.kind or 0)
						if seen[key] then
							return false
						end
						seen[key] = true
						return true
					end, items)
				end,
				default = function()
					local top = current_top()
					if top ~= nil and top.delim ~= nil and tailwind_attached() then
						-- Inside a string with tailwindcss attached: only the lsp
						-- source can produce tailwind class items, so drop path and
						-- snippets to avoid noise inside the class literal.
						return { "lsp" }
					end
					return { "lsp", "path", "snippets" }
				end,
				-- Require 3+ characters before auto-suggesting, so typing short
				-- fragments doesn't pop the menu. Trigger characters (e.g. `.`
				-- member access) and manual shows (`<C-Space>`) bypass the limit.
				min_keyword_length = function(ctx)
					if ctx.trigger.kind == "trigger_character" or ctx.trigger.kind == "manual" then
						return 0
					end
					return 2
				end,
				providers = {
					lsp = {
						-- In string context, keep only items coming from the
						-- tailwindcss client so other attached servers (ts_ls,
						-- cssls, ...) don't leak completions into class literals.
						transform_items = function(_, items)
							local top = current_top()
							if top == nil or top.delim == nil then
								return items
							end
							return vim.tbl_filter(function(item)
								return item.client_name == "tailwindcss"
							end, items)
						end,
					},
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
			-- VSCode-style ranking: pure match score, then LSP sortText, then
			-- label as a tiebreaker. Frecency and proximity boosting are off
			-- because VSCode's IntelliSense does not recency-weight or
			-- distance-weight suggestions.
			fuzzy = {
				frecency = {
					enabled = false,
				},
				use_proximity = false,
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
					enabled = false,
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
