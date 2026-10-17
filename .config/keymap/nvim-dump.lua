-- keymap generator helper: print every mapping that has a `desc` as JSON (one line) on stdout.
-- Run headless after the plugin manager finished its lazy start (VeryLazy mappings, plugin `keys` stubs).
local out, seen = {}, {}
for _, mode in ipairs({ "n", "x", "i", "t", "o", "c" }) do
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.desc then
      local id = mode .. "\0" .. m.lhs
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = { mode = mode, lhs = m.lhs, desc = m.desc }
      end
    end
  end
end
io.stdout:write(vim.json.encode({ leader = vim.g.mapleader or "\\", keys = out }), "\n")
