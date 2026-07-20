-- VSCode-style fuzzy sorter for the filepicker plugin.
--
-- The scorer is a faithful-enough port of VSCode's Quick Open ranking:
--   * subsequence matching with bonuses for consecutive matches, word
--     boundaries (separators / start), and camelCase transitions
--   * filename (label) matches weighted higher than path matches
--   * a recency boost for recently-opened files, applied as a tiebreaker
--     so a strong fuzzy match still beats a weak match on a recent file
--
-- Telescope wants lower scores == better, and exactly -1 means "filter out".

local sorters = require("telescope.sorters")

local M = {}

local function is_upper(b)
	return b >= 65 and b <= 90
end
local function is_lower(b)
	return b >= 97 and b <= 122
end
local function to_lower(b)
	return is_upper(b) and (b + 32) or b
end

local SEP = {}
for _, c in ipairs({ "/", "\\", "_", "-", ".", " ", ":", "@" }) do
	SEP[string.byte(c)] = true
end

-- Heuristic for "test" files: anything under a test/tests/__tests__ directory
-- or with a .spec./.test. suffix. These get pushed to the bottom of results.
local function is_test_path(rel)
	if rel:find("/test[s]?/") or rel:find("^test[s]?/") or rel:find("/__tests__/") or rel:find("^__tests__/") then
		return true
	end
	local low = rel:lower()
	if low:match("%.spec%.[%w]+$") or low:match("%.test%.[%w]+$") then
		return true
	end
	return false
end

-- VSCode-ish bonus weights.
local BOUNDARY = 8 -- preceded by separator or at start of target
local CAMEL = 7 -- lower -> upper transition (camelCase boundary)
local CONSEC = 9 -- matched char immediately follows the previous match
local MATCH = 1 -- base score for any matched character
local GAP = -1 -- penalty per skipped character between matches

local function boundary_bonus(target, ti)
	if ti == 1 then
		return BOUNDARY
	end
	local prev = string.byte(target, ti - 1)
	local cur = string.byte(target, ti)
	if SEP[prev] then
		return BOUNDARY
	end
	if is_lower(prev) and is_upper(cur) then
		return CAMEL
	end
	return 0
end

-- Quick case-insensitive subsequence check. Used both to short-circuit the
-- expensive DP (no subsequence => no match) and by the finder as a pre-filter.
function M.has_match(query, target)
	if query == "" then
		return true
	end
	local ti = 1
	local tl = #target
	for qi = 1, #query do
		local c = to_lower(string.byte(query, qi))
		while ti <= tl and to_lower(string.byte(target, ti)) ~= c do
			ti = ti + 1
		end
		if ti > tl then
			return false
		end
		ti = ti + 1
	end
	return true
end

-- DP fuzzy score. Returns (score, positions) where positions is a list of
-- 1-indexed byte columns into `target`, or (nil, nil) if no match.
-- Higher score == better match.
function M.score(query, target)
	if query == "" then
		return 0, {}
	end
	local ql = #query
	local tl = #target
	if ql > tl then
		return nil, nil
	end

	-- D[qi] maps target position ti -> best score matching query[1..qi] ending
	-- with query[qi] at target[ti]. Position 0 means "before the target" and
	-- only D[0][0] = 0 is valid there (empty prefix).
	local D = {}
	local Prev = {}
	D[0] = { [0] = 0 }
	Prev[0] = {}

	for qi = 1, ql do
		local prevD = D[qi - 1]
		local curD = {}
		local curPrev = {}
		-- running max over already-seen tp of (prevD[tp] - GAP * tp), so the
		-- best gap-penalized predecessor of ti can be computed in O(1).
		local running = nil
		local running_tp = nil
		local last = tl - (ql - qi) -- rightmost target position qi can occupy
		for ti = qi, last do
			local tp = ti - 1
			if prevD[tp] ~= nil then
				local v = prevD[tp] - GAP * tp
				if running == nil or v > running then
					running = v
					running_tp = tp
				end
			end
			if to_lower(string.byte(query, qi)) == to_lower(string.byte(target, ti)) and running ~= nil then
				local base = MATCH + boundary_bonus(target, ti)
				local consec = prevD[tp] ~= nil and (prevD[tp] + base + CONSEC) or nil
				local gapv = running + GAP * (ti - 1) + base
				if consec and (gapv == nil or consec >= gapv) then
					curD[ti] = consec
					curPrev[ti] = tp
				else
					curD[ti] = gapv
					curPrev[ti] = running_tp
				end
			end
		end
		D[qi] = curD
		Prev[qi] = curPrev
	end

	-- pick the best ending position for the last query char
	local finalD = D[ql]
	local best_ti, best = nil, nil
	for ti, s in pairs(finalD) do
		if best == nil or s > best then
			best = s
			best_ti = ti
		end
	end
	if best == nil then
		return nil, nil
	end

	-- reconstruct matched positions
	local positions = {}
	local qi, ti = ql, best_ti
	while qi >= 1 do
		table.insert(positions, ti)
		ti = Prev[qi][ti]
		qi = qi - 1
	end
	-- positions were collected end-to-start; reverse them
	for i = 1, math.floor(#positions / 2) do
		local j = #positions - i + 1
		positions[i], positions[j] = positions[j], positions[i]
	end
	return best, positions
end

-- Composite ranking goodness for an entry: higher == better, `nil` == no match.
-- Shared by the sorter (which inverts it for Telescope's lower-is-better
-- convention) and the finder (which ranks the top-N candidates before handing
-- them to Telescope), so the two never drift apart.
function M.goodness(prompt, line, entry, opts)
	opts = opts or {}
	local recency_weight = opts.recency_weight or 12
	local test_penalty = opts.test_penalty or 1000
	local penalty = is_test_path(line) and test_penalty or 0
	local boost = entry.is_mru and (recency_weight / (entry.recency_rank + 1)) or 0
	if prompt == nil or prompt == "" then
		-- empty prompt: pure recency order, MRU first, test files last
		return boost - penalty
	end
	local label = entry.filename_part or line
	local raw_path = M.score(prompt, line)
	if not raw_path then
		return nil
	end
	local raw_label = M.score(prompt, label) or 0
	-- label matches count double so a filename hit outweighs a path hit;
	-- a mild path-length penalty nudges shorter paths up on ties, the way
	-- VSCode prefers files closer to the workspace root.
	local raw = raw_label * 2 + raw_path - (#line * 0.05)
	return raw + boost - penalty
end

-- Build a Telescope sorter. `recency_weight` controls how strongly MRU rank
-- biases results; higher = recents dominate more aggressively.
function M.new(opts)
	opts = opts or {}
	local recency_weight = opts.recency_weight or 12
	local test_penalty = opts.test_penalty or 1000
	local BIG = 1e9
	local scorer_opts = { recency_weight = recency_weight, test_penalty = test_penalty }

	return sorters.Sorter:new({
		discard = false,
		scoring_function = function(_, prompt, line, entry)
			local g = M.goodness(prompt, line, entry, scorer_opts)
			if g == nil then
				return -1
			end
			return BIG - g
		end,
		highlighter = function(_, prompt, display)
			if prompt == nil or prompt == "" then
				return {}
			end
			local _, positions = M.score(prompt, display)
			return positions or {}
		end,
	})
end

return M
