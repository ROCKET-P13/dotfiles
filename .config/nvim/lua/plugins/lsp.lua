local M = {
	"neovim/nvim-lspconfig",
	dependencies = {
		"stevearc/conform.nvim",
	},
	event = { "BufReadPre", "BufNewFile" },
	config = function()
		vim.lsp.config("lua_ls", {
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

		vim.lsp.config("omnisharp", {
			settings = {
				FormattingOptions = {
					OrganizeImports = true,
				},
			},
		})

		vim.lsp.config("ts_ls", {
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

		vim.lsp.enable("lua_ls")
		vim.lsp.enable("ts_ls")
		vim.lsp.enable("eslint")
		vim.lsp.enable("omnisharp")
		vim.lsp.enable("cssls")
		vim.lsp.enable("html")
		vim.lsp.enable("jsonls")
		vim.lsp.enable("lemminx")

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
