-- Translates the VSCode theme color map + per-token font-style bits into real
-- Neovim highlight groups. Groups are created lazily and cached, named by
-- (color index, style bits), so each distinct (color, style) pair maps to one
-- highlight group with the theme's exact hex foreground.

local bit = require("bit")

local M = {}

-- colormap[i] mirrors the JS color map: Lua index i == JS index (i - 1).
-- JS index 0 is the "no color" sentinel, so a token color index c maps to
-- colormap[c + 1].
local colormap = {}
local group_cache = {}

local STYLE_ITALIC = 1
local STYLE_BOLD = 2
local STYLE_UNDERLINE = 4
local STYLE_STRIKE = 8

local function hex_for(color_index)
	local v = colormap[color_index + 1]
	if v == nil or v == vim.NIL or v == "" then
		return nil
	end
	return v
end

--- Store the color map sent by the tokenizer and reset cached groups.
--- @param cm string[]
function M.set_colormap(cm)
	colormap = cm or {}
	group_cache = {}
end

--- Resolve a (color index, style bits) pair to a highlight group name.
--- Returns nil when there is nothing to paint (no color and no style).
--- @param color_index integer
--- @param style integer
--- @return string|nil
function M.group(color_index, style)
	style = style or 0
	local fg = hex_for(color_index)
	if not fg and style == 0 then
		return nil
	end

	local key = color_index .. ":" .. style
	local cached = group_cache[key]
	if cached then
		return cached
	end

	local name = string.format("TextMateTM_%d_%d", color_index, style)
	local opts = {}
	if fg then
		opts.fg = fg
	end
	if bit.band(style, STYLE_ITALIC) ~= 0 then
		opts.italic = true
	end
	if bit.band(style, STYLE_BOLD) ~= 0 then
		opts.bold = true
	end
	if bit.band(style, STYLE_UNDERLINE) ~= 0 then
		opts.underline = true
	end
	if bit.band(style, STYLE_STRIKE) ~= 0 then
		opts.strikethrough = true
	end
	vim.api.nvim_set_hl(0, name, opts)
	group_cache[key] = name
	return name
end

return M
