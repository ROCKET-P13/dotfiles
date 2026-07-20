local M = {
	"nvim-telescope/telescope.nvim",
	dependencies = {
		"nvim-lua/plenary.nvim",
		{
			"nvim-telescope/telescope-fzf-native.nvim",
			build = "make",
		},
		{
			"nvim-telescope/telescope-frecency.nvim",
			version = "*",
		},
		{
			"nvim-telescope/telescope-fzf-native.nvim",
			build = "cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release --target install",
		},
	},
	config = function()
		local actions = require("telescope.actions")

		require("telescope").setup({
			defaults = {
				path_display = { "smart" },
				layout_strategy = "horizontal",
				layout_config = {
					prompt_position = "top",
					horizontal = {
						preview_cutoff = 0,
						height = 30,
						width = 100,
					},
				},
				sorting_strategy = "ascending",
				shorter_path = true,
				initial_mode = "insert",
				selection_strategy = "reset",
				color_devicons = true,
				preview = false,
			},
			mappings = {
				n = {
					["<esc>"] = actions.close,
					["q"] = actions.close,
					["<C-q>"] = function(prompt_bufnr)
						actions.smart_send_to_qflist(prompt_bufnr)
						actions.open_qflist(prompt_bufnr)
					end,
				},
				i = {
					["<C-q>"] = function(prompt_bufnr)
						actions.smart_send_to_qflist(prompt_bufnr)
						actions.open_qflist(prompt_bufnr)
					end,
				},
			},
			pickers = {
				find_files = {},
				git_status = {
					preview = true,
				},
			},
			extensions = {
				fzf = {
					fuzzy = true, -- false will only do exact matching
					override_generic_sorter = false, -- override the generic sorter
					override_file_sorter = false, -- override the file sorter
					case_mode = "smart_case", -- or "ignore_case" or "respect_case"
					-- the default case_mode is "smart_case"
				},
				frecency = {
					auto_validate = false,
					path_display = { "filename_first" },
					ignore_patterns = { "*/.git", "*/.git/*", "*/.DS_Store", "*/node_modules/*" },
					workspace = "CWD",
				},
			},
		})

		require("telescope").load_extension("fzf")
		require("telescope").load_extension("frecency")

		local builtin = require("telescope.builtin")
		vim.keymap.set("n", "<C-g>", builtin.git_status, {})
		vim.keymap.set("n", "<leader><leader>", builtin.buffers, {})
		vim.keymap.set("n", "<leader>mg", require("config.telescope.multigrep").setup)
	end,
}

return M
