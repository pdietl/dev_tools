-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.wrap = true

-- LazyVim sets clipboard="" whenever SSH_CONNECTION is set, expecting
-- Neovim's OSC 52 auto-provider to take over — but that keys off SSH_TTY,
-- which tmux does not carry into its sessions, so inside tmux nothing takes
-- over. Re-enable sync with an explicit provider.
--
-- Yanks go out both channels at once; no environment sniffing can tell which
-- machine is in front of the keyboard, because inside tmux the environment
-- is frozen at pane creation and lies after roaming between local and SSH
-- attaches.
--   * wl-copy sets this machine's Wayland clipboard, for when it is the one
--     being sat at.
--   * OSC 52 reaches whichever terminal tmux has attached right now, plus
--     (set-clipboard on) tmux's own paste buffer. VTE terminals (Ptyxis,
--     GNOME Terminal) discard OSC 52, so over SSH from one of those the
--     tmux buffer is the part that works.
-- Terminals refuse OSC 52 reads (a real read would hang), so paste returns
-- the unnamed register; paste from other applications with the terminal's
-- own paste.
local osc52 = require("vim.ui.clipboard.osc52")
local function copy(reg, cmd)
  local via_osc52 = osc52.copy(reg)
  return function(lines)
    via_osc52(lines)
    pcall(vim.system, cmd, { stdin = table.concat(lines, "\n") })
  end
end
local function paste_unnamed()
  return { vim.fn.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') }
end
vim.g.clipboard = {
  name = "wl-copy + OSC 52",
  copy = { ["+"] = copy("+", { "wl-copy" }), ["*"] = copy("*", { "wl-copy", "--primary" }) },
  paste = { ["+"] = paste_unnamed, ["*"] = paste_unnamed },
}
vim.opt.clipboard = "unnamedplus"
