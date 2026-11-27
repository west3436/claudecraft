-- claudecraft.pricing - per-model Anthropic API prices for the in-game cost estimate.
--
-- Usage:
--   local pricing = require("claudecraft.pricing")
--   local cost, rates = pricing.requestCost(model, inputTokens, outputTokens, cacheWrite, cacheRead)
--
-- All prices are USD per million tokens (MTok), from
-- https://platform.claude.com/docs/en/about-claude/pricing (checked 2026-11-27).
--   input  = base (uncached) input
--   output = output
--   write  = 5-minute cache write (1.25x input; ClaudeCraft only writes 5-minute entries)
--   read   = cache hit / refresh (0.1x input on most models, lower on the newest ones)
-- Prices are first-party Claude API rates: no batch discount, no fast mode, and no
-- inference_geo multiplier.

local pricing = {}

local PRICES = {
    -- Fable / Mythos
    ["claude-fable-5-2"]   = {input=8,    output=40,   write=10,    read=0.20},
    ["claude-mythos-5-2"]  = {input=8,    output=40,   write=10,    read=0.20},
    ["claude-fable-5-1"]   = {input=10,   output=50,   write=12.5,  read=0.25},
    ["claude-mythos-5-1"]  = {input=10,   output=50,   write=12.5,  read=0.25},
    ["claude-fable-5"]     = {input=10,   output=50,   write=12.5,  read=1.00},
    ["claude-mythos-5"]    = {input=10,   output=50,   write=12.5,  read=1.00},
    -- Opus
    ["claude-opus-5-5"]    = {input=4,    output=20,   write=5,     read=0.20},
    ["claude-opus-5"]      = {input=5,    output=25,   write=6.25,  read=0.50},
    ["claude-opus-4-8"]    = {input=5,    output=25,   write=6.25,  read=0.50},
    ["claude-opus-4-7"]    = {input=5,    output=25,   write=6.25,  read=0.50},
    ["claude-opus-4-6"]    = {input=5,    output=25,   write=6.25,  read=0.50},
    ["claude-opus-4-5"]    = {input=5,    output=25,   write=6.25,  read=0.50},
    ["claude-opus-4-1"]    = {input=15,   output=75,   write=18.75, read=1.50},
    ["claude-opus-4"]      = {input=15,   output=75,   write=18.75, read=1.50},
    -- Sonnet
    ["claude-sonnet-5-5"]  = {input=2,    output=10,   write=2.5,   read=0.10},
    ["claude-sonnet-5"]    = {input=2,    output=10,   write=2.5,   read=0.20},
    ["claude-sonnet-4-6"]  = {input=3,    output=15,   write=3.75,  read=0.30},
    ["claude-sonnet-4-5"]  = {input=3,    output=15,   write=3.75,  read=0.30},
    ["claude-sonnet-4"]    = {input=3,    output=15,   write=3.75,  read=0.30},
    -- Haiku (Haiku 5.5 is tiered by prompt length, see LONG_PROMPT below)
    ["claude-haiku-5-5"]   = {input=0.10, output=0.50, write=0.125, read=0.01},
    ["claude-haiku-4-5"]   = {input=1,    output=5,    write=1.25,  read=0.10},
}

-- Requests whose whole prompt (input + cache write + cache read) is over the
-- threshold pay these prices instead. Each request is priced on its own.
local LONG_PROMPT = {
    ["claude-haiku-5-5"] = {threshold=100000,
        rates={input=0.50, output=2.50, write=0.625, read=0.05}},
}

-- Unknown model in a known family: use that family's newest model.
local FAMILY_FALLBACK = {
    {"fable",  "claude-fable-5-2"},
    {"mythos", "claude-mythos-5-2"},
    {"opus",   "claude-opus-5-5"},
    {"sonnet", "claude-sonnet-5-5"},
    {"haiku",  "claude-haiku-5-5"},
}

-- Nothing matches at all: price as the mod's default model.
local DEFAULT_MODEL = "claude-sonnet-4-6"

-- Known ids, longest first, so "claude-opus-4-5" wins over "claude-opus-4".
local KNOWN = {}
for id in pairs(PRICES) do KNOWN[#KNOWN+1] = id end
table.sort(KNOWN, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
end)

local cache = {}

--- Resolve a configured model string to a price entry.
-- Handles dated snapshots ("claude-sonnet-4-5-20250929") and provider prefixes
-- ("anthropic.claude-opus-4-6") by substring match.
-- Returns {id=, exact=bool, input=, output=, write=, read=}.
function pricing.lookup(model)
    model = tostring(model or "")
    if cache[model] then return cache[model] end
    local lower = model:lower()
    local id, exact

    for _, k in ipairs(KNOWN) do
        local s, e = lower:find(k, 1, true)
        if s then
            local rest = lower:sub(e + 1)
            -- The match must end at a version boundary (end, date snapshot,
            -- "@date", ":0", "-v1"), so "claude-opus-5" does not claim an
            -- unknown "claude-opus-5-7".
            if rest == "" or rest:match("^%-%d%d%d%d%d%d%d%d") or rest:match("^[@:]")
                    or rest:match("^%-v%d") then
                id, exact = k, true
                break
            end
        end
    end

    if not id then
        for _, fam in ipairs(FAMILY_FALLBACK) do
            if lower:find(fam[1], 1, true) then id = fam[2]; break end
        end
        id = id or DEFAULT_MODEL
        exact = false
    end

    local p = PRICES[id]
    local r = {id=id, exact=exact, input=p.input, output=p.output, write=p.write, read=p.read}
    cache[model] = r
    return r
end

--- Rates that apply to one request, accounting for prompt-length tiers.
function pricing.ratesFor(model, inputTokens, cacheWrite, cacheRead)
    local base = pricing.lookup(model)
    local tier = LONG_PROMPT[base.id]
    local prompt = (inputTokens or 0) + (cacheWrite or 0) + (cacheRead or 0)
    if tier and prompt > tier.threshold then
        local t = tier.rates
        return {id=base.id, exact=base.exact, long=true,
                input=t.input, output=t.output, write=t.write, read=t.read}
    end
    return base
end

--- Cost in USD of one request.
-- inputTokens is the API's input_tokens field, which is the uncached remainder.
-- Returns cost, uncachedCost (what the same prompt would cost with no caching), rates.
function pricing.requestCost(model, inputTokens, outputTokens, cacheWrite, cacheRead)
    local inp, out = inputTokens or 0, outputTokens or 0
    local cw, cr = cacheWrite or 0, cacheRead or 0
    local r = pricing.ratesFor(model, inp, cw, cr)
    local cost = (inp * r.input + out * r.output + cw * r.write + cr * r.read) / 1000000
    local uncached = ((inp + cw + cr) * r.input + out * r.output) / 1000000
    return cost, uncached, r
end

--- Compact token count: 812, 4.8k, 1.2M.
function pricing.fmtTokens(n)
    n = n or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

--- Format a price per MTok without trailing zeros: 3, 3.75, 0.3, 0.125.
function pricing.fmtRate(x)
    local s = string.format("%.3f", x):gsub("0+$", ""):gsub("%.$", "")
    return s
end

return pricing
