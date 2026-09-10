local M = {
	"neovim/nvim-lspconfig",
	dependencies = {
		"stevearc/conform.nvim",
	},
	event = { "BufReadPre", "BufNewFile" },
	config = function()
		-- Set up capabilities for completion resolve (auto-imports)
		local capabilities = vim.lsp.protocol.make_client_capabilities()
		capabilities.textDocument = capabilities.textDocument or {}
		capabilities.textDocument.completion = capabilities.textDocument.completion or {}
		capabilities.textDocument.completion.completionItem = capabilities.textDocument.completion.completionItem or {}
		capabilities.textDocument.completion.completionItem.resolveSupport = {
			properties = { "documentation", "detail", "additionalTextEdits" },
		}

		vim.lsp.config("lua_ls", {
			capabilities = capabilities,
			root_markers = { ".luarc.json", ".luarc.jsonc", ".luarc", ".git" },
			root_dir = function(bufnr, on_dir)
				local path = vim.api.nvim_buf_get_name(bufnr)
				if path == "" then
					path = vim.fn.getcwd()
				end
				local config = vim.fn.stdpath("config")
				if vim.startswith(path, config .. "/") then
					on_dir(config)
					return
				end
				local root = vim.fs.root(path, { ".luarc.json", ".luarc.jsonc", ".luarc", ".git" })
				on_dir(root or vim.fn.stdpath("config"))
			end,
			settings = {
				Lua = {
					workspace = { checkThirdParty = false },
					diagnostics = {
						globals = { "vim" },
					},
				},
			},
		})

		vim.lsp.config("csharp_ls", {
			capabilities = capabilities,
		})

		vim.lsp.config("ts_ls", {
			capabilities = capabilities,
			settings = {
				filetypes = {
					"javascript",
					"typescript",
					"javascriptreact",
					"typescriptreact",
					"tsx",
				},
			},
		})

		vim.lsp.config("tailwindcss", {
			capabilities = capabilities,
			-- Spawn the language server directly. lspconfig's default ships
			-- `cmd` as a function (to prefer a local `node_modules/.bin`
			-- copy), which the native `vim.lsp.enable` path does not invoke,
			-- so the server never started. A plain list spawns the global
			-- binary on $PATH directly.
			cmd = { "tailwindcss-language-server", "--stdio" },
			filetypes = {
				"html",
				"css",
				"scss",
				"less",
				"javascript",
				"javascriptreact",
				"typescript",
				"typescriptreact",
				"tsx",
				"jsx",
			},
			root_markers = {
				"tailwind.config.js",
				"tailwind.config.cjs",
				"tailwind.config.mjs",
				"tailwind.config.ts",
				"package.json",
			},
			root_dir = function(bufnr, on_dir)
				local path = vim.api.nvim_buf_get_name(bufnr)
				if path == "" then
					path = vim.fn.getcwd()
				end
				local root = vim.fs.root(path, { "package.json" })
				if not root then
					return
				end

				for _, f in ipairs({
					"tailwind.config.js",
					"tailwind.config.cjs",
					"tailwind.config.mjs",
					"tailwind.config.ts",
				}) do
					if vim.uv.fs_stat(root .. "/" .. f) then
						on_dir(root)
						return
					end
				end

				local fd = io.open(root .. "/package.json", "r")
				if not fd then
					return
				end
				local content = fd:read("*a")
				fd:close()
				local ok, pkg = pcall(vim.json.decode, content)
				if not ok or not pkg then
					return
				end
				if
					(pkg.dependencies and pkg.dependencies.tailwindcss)
					or (pkg.devDependencies and pkg.devDependencies.tailwindcss)
				then
					on_dir(root)
				end
			end,
		})

		vim.lsp.enable("lua_ls")
		vim.lsp.enable("ts_ls")
		vim.lsp.enable("eslint")
		vim.lsp.enable("csharp_ls")
		vim.lsp.enable("csharpier")
		vim.lsp.enable("cssls")
		vim.lsp.enable("html")
		vim.lsp.enable("jsonls")
		vim.lsp.enable("lemminx")
		vim.lsp.enable("tailwindcss")

		vim.api.nvim_create_autocmd("BufRead", {
			pattern = "*.html",
			callback = function()
				if vim.bo.filetype == "xhtml" then
					vim.bo.filetype = "html"
				end
			end,
		})

		vim.api.nvim_create_autocmd("LspAttach", {
			callback = function(args)
				local client = vim.lsp.get_client_by_id(args.data.client_id)
				if client.server_capabilities.semanticTokensProvider then
					client.server_capabilities.semanticTokensProvider = nil
				end

				vim.keymap.set(
					"n",
					"K",
					vim.lsp.buf.hover,
					vim.tbl_extend("force", { buffer = args.buf, silent = true }, { desc = "Hover documentation" })
				)

				if client.name == "lemminx" then
					client.server_capabilities.documentFormattingProvider = false
					client.server_capabilities.documentRangeFormattingProvider = false
				end

				if client.name == "html" then
					client.server_capabilities.documentFormattingProvider = false
					client.server_capabilities.documentRangeFormattingProvider = false
				end

				if client.name == "ts_ls" then
					client.server_capabilities.documentFormattingProvider = false
					client.server_capabilities.documentRangeFormattingProvider = false
				end

				if client.name == "eslint" then
					client.server_capabilities.documentFormattingProvider = true
					client.server_capabilities.documentRangeFormattingProvider = true
				end
			end,
		})

		local icons = require("config.icons")
		local severity = vim.diagnostic.severity

		vim.diagnostic.config({
			signs = {
				active = true,
				values = {
					{ name = "DiagnosticSignError", text = icons.diagnostics.Error },
					{ name = "DiagnosticSignWarn", text = icons.diagnostics.Warning },
					{ name = "DiagnosticSignHint", text = icons.diagnostics.Hint },
					{ name = "DiagnosticSignInfo", text = icons.diagnostics.Information },
				},
				text = {
					[severity.ERROR] = icons.diagnostics.Error,
					[severity.WARN] = icons.diagnostics.Warning,
					[severity.HINT] = icons.diagnostics.Hint,
					[severity.INFO] = icons.diagnostics.Information,
				},
				texthl = {
					[severity.ERROR] = "DiagnosticSignError",
					[severity.WARN] = "DiagnosticSignWarn",
					[severity.HINT] = "DiagnosticSignHint",
					[severity.INFO] = "DiagnosticSignInfo",
				},
				numhl = {
					[severity.ERROR] = "DiagnosticSignError",
					[severity.WARN] = "DiagnosticSignWarn",
					[severity.HINT] = "DiagnosticSignHint",
					[severity.INFO] = "DiagnosticSignInfo",
				},
			},
			virtual_text = false,
			update_in_insert = false,
			underline = true,
			severity_sort = true,
			float = {
				focusable = false,
				style = "minimal",
				border = "rounded",
				header = "",
				prefix = "",
			},
		})

		vim.keymap.set("n", "<C-k>", function()
			vim.diagnostic.open_float({
				scope = "line",
				focusable = false,
			})
		end, { desc = "Show line diagnostics" })

		vim.keymap.set("n", "]d", function()
			vim.diagnostic.jump({ count = 1, float = true })
		end, { desc = "Next diagnostic" })

		vim.keymap.set("n", "[d", function()
			vim.diagnostic.jump({ count = -1, float = true })
		end, { desc = "Previous diagnostic" })

		vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action (apply fix)" })
	end,
}

return M
