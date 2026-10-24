-- edit-anywhere.lua: the nvim side of SUPER+CTRL+E (scripts/edit-anywhere.sh). Loaded with `nvim -c 'luafile ...'`, so it
-- changes nothing in the owner's nvim config: everything here is local to this one scratch buffer and does nothing unless
-- the script set EDIT_ANYWHERE_DIR. K3 (layout auto-switch) and every other setting of the config stay as they are.
--
--   Ctrl+S (insert, normal, visual) and ZZ   write the buffer and quit: the script copies it and pastes it
--   :wq / :x                                  the same (any write of the buffer marks the text as final)
--   :q! / ZQ / closing the window             nothing was written: cancel, nothing is pasted
--   Esc                                       stays Esc
-- The text is written exactly as it is in the buffer (no end-of-line is added), so a one-line text has no trailing newline.
local dir = vim.env.EDIT_ANYWHERE_DIR
if not dir or dir == "" then
  return
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    -- markdown first: its ftplugin sets formatoptions, overridden below; render-markdown (ft markdown) shows **bold**, lists,
    -- code in NORMAL mode, the raw text in INSERT
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undofile = false
    vim.bo[buf].fixendofline = false
    vim.bo[buf].endofline = false
    vim.bo[buf].formatoptions = ""
    vim.bo[buf].textwidth = 0
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].spell = false
    vim.wo[win].colorcolumn = ""

    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = buf,
      callback = function()
        vim.fn.writefile({}, dir .. "/saved")
      end,
    })

    local function finish()
      vim.cmd "silent! write!"
      vim.cmd "qall!"
    end
    -- Ctrl+S on the physical S key of the ua (і) and ru (ы) layouts too: langmapper twins the normal-mode mappings but not
    -- the insert-mode ones, and finishing must work with any layout active
    local opts = { buffer = buf, silent = true, nowait = true, desc = "Edit anywhere: finish and paste" }
    for _, mode in ipairs { "n", "i", "x" } do
      for _, lhs in ipairs { "<C-s>", "<C-ы>", "<C-і>" } do
        vim.keymap.set(mode, lhs, finish, opts)
      end
    end
    vim.keymap.set("n", "ZZ", finish, opts)

    -- start in INSERT at the end of the text (a preloaded selection is continued, not overwritten)
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      vim.cmd "normal! G"
      vim.cmd "startinsert!"
    end)
  end,
})
