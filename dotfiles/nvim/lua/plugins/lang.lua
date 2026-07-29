return {
  -- Ada language server (no LazyVim extra exists for Ada).
  -- Adding "ada_ls" to the servers table causes mason-lspconfig to auto-install
  -- ada-language-server via Mason.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ada_ls = {
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            local root = vim.fs.root(fname, { ".als.json", "alire.toml" })
            if root then
              on_dir(root)
            end
          end,
        },
        asm_lsp = {},

        -- Bazel repos compile with a hermetic cross-GCC whose builtin include
        -- paths (its own libstdc++) only the driver itself knows; clangd must
        -- be allowed to interrogate it or every std header comes up missing.
        -- --query-driver is only accepted on the command line, and LazyVim's
        -- opts merge REPLACES list values, so this restates the clangd
        -- extra's default cmd rather than just appending one flag.
        clangd = {
          cmd = {
            "clangd",
            "--background-index",
            "--clang-tidy",
            "--header-insertion=iwyu",
            "--completion-style=detailed",
            "--function-arg-placeholders",
            "--fallback-style=llvm",
            "--query-driver=/home/pdietl/.cache/bazel/**/aarch64-linux-g++",
          },
        },
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

  -- Use gnatpp (from libadalang-tools) for Ada formatting instead of LSP.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        ada = { "gnatpp" },
      },
      formatters = {
        gnatpp = {
          command = "gnatpp",
          args = { "--syntax-only", "$FILENAME" },
          stdin = false,
        },
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
