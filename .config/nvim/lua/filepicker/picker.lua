-- Wires the filepicker finder + sorter into a Telescope picker.
-- Inherits the user's global Telescope defaults (layout, mappings, etc.) by
-- passing `require("telescope.config").values` as the defaults table.

local mru = require("filepicker.mru")
local finder_mod = require("filepicker.finder")
local sorter_mod = require("filepicker.sorter")

local M = {}

function M.open(opts)
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()

	local mru_list = mru.list_under(cwd)
	local candidates = finder_mod.build(cwd, mru_list, {
		exclude_ext = opts.exclude_ext,
		max_files = opts.max_files,
	})

	local finder = finder_mod.make_finder(candidates, {
		max_results = opts.max_results,
		recency_weight = opts.recency_weight,
		test_penalty = opts.test_penalty,
	})
	local sorter = sorter_mod.new({ recency_weight = opts.recency_weight })

	local pickers = require("telescope.pickers")
	local conf = require("telescope.config").values

	local picker_opts = {
		prompt_title = "Find Files",
		cwd = cwd,
		finder = finder,
		sorter = sorter,
		debounce = opts.debounce_ms or 30,
		-- keep Telescope's default file actions (<CR> edit, <C-x> split, ...)
		attach_mappings = function()
			return true
		end,
	}

	pickers.new(picker_opts, conf):find()
end

return M
