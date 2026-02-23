return {
  -- Ada language server (no LazyVim extra exists for Ada).
  -- Adding "als" to the servers table causes mason-lspconfig to auto-install
  -- ada-language-server via Mason.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        als = {},
        asm_lsp = {},
      },
    },
  },

  -- Ensure shellcheck is installed via Mason.
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = {
        "shellcheck",
      },
    },
  },

  -- Configure shellcheck as the linter for shell scripts.
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        sh = { "shellcheck" },
      },
    },
  },
}
