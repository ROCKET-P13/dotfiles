return {
	"mikavilpas/yazi.nvim",
	version = "*",
	event = "VeryLazy",
	dependencies = {
		{ "nvim-lua/plenary.nvim", lazy = true },
	},
	keys = {
		{
			"<leader>-",
			mode = { "n", "v" },
			"<cmd>Yazi<cr>",
			desc = "Open yazi at the current file",
		},
		{
			"<C-b>",
			function()
				local yazi = require("yazi")
				local current = yazi.active_contexts:current()
				if current then
					current.api:emit_to_yazi({ "quit" })
					return
				end

				yazi.yazi(nil, vim.fn.getcwd())
			end,
			mode = "n",
			desc = "Toggle yazi",
		},
		{
			"<C-Up>",
			"<cmd>Yazi toggle<cr>",
			desc = "Resume the last yazi session",
		},
	},
	opts = {
		open_for_directories = false,
		open_file_function = function(chosen_file)
			if vim.fn.isdirectory(chosen_file) == 1 then
				vim.schedule(function()
					require("yazi").yazi(nil, chosen_file)
				end)
				return
			end

			require("yazi.openers").open_file(chosen_file)
		end,
		keymaps = {
			show_help = "<f1>",
		},
		hooks = {
			yazi_opened = function(_, buffer)
				vim.keymap.set("t", "<C-b>", function()
					local current = require("yazi").active_contexts:current()
					if current then
						current.api:emit_to_yazi({ "quit" })
					end
				end, { buffer = buffer, desc = "Close yazi" })
			end,
		},
	},
}
