return {
  {
    "rcarriga/nvim-notify",
    config = function()
      vim.notify = require("notify")
      vim.notify.setup({
        stages = "fade_in_slide_out",
        timeout = 3000,
        render = "compact",
        max_width = 50,
        minimum_width = 30,
        top_down = false,  
      })
    end
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      local lspconfig = require("lspconfig")
      lspconfig.ts_ls.setup({
        cmd = { "typescript-language-server", "--stdio" },
        on_attach = function(client, bufnr)
          local function buf_map(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
          end

          buf_map("n", "K",         vim.lsp.buf.hover,          "Hover Documentation")
          buf_map("n", "gd",        vim.lsp.buf.definition,     "Go to Definition")
          buf_map("n", "gD",        vim.lsp.buf.declaration,    "Go to Declaration")
          buf_map("n", "gi",        vim.lsp.buf.implementation, "Go to Implementation")
          buf_map("n", "gr",        vim.lsp.buf.references,     "Find References")
          buf_map("n", "<leader>rn",vim.lsp.buf.rename,         "Rename Symbol")
          buf_map("n", "<leader>ca",vim.lsp.buf.code_action,    "Code Action")
        end,
        capabilities = lspconfig.util.default_config.capabilities,
      })

      lspconfig.bufls.setup({
        cmd = { "bufls", "serve" },
        filetypes = { "proto" },
        root_dir = lspconfig.util.root_pattern("buf.yaml", "buf.gen.yaml", ".git"),
        settings = {},
        on_attach = function(client, bufnr)
          local opts = { buffer = bufnr }
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
        end,
      })

      local capabilities = require("cmp_nvim_lsp").default_capabilities()
      capabilities.offsetEncoding = { "utf-16" }
            
      lspconfig.gopls.setup({
        cmd = { "gopls" },
        filetypes = { "go", "gomod", "gowork", "gotmpl" },
        root_dir = lspconfig.util.root_pattern("go.work", "go.mod", ".git"),
        settings = {
          gopls = {
            completeUnimported = true,
            usePlaceholders = true,
            analyses = {
              unusedparams = true,
            },
          },
        },
        on_attach = function(client, bufnr)
          local opts = { buffer = bufnr }
          vim.keymap.set("n", "<leader>ra", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<leader>rr", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>rf", function()
            vim.lsp.buf.format({ async = true })
          end, opts)
          vim.keymap.set("n", "<leader>rh", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rs", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "<leader>rd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<leader>ri", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>rR", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "<leader>rc", vim.lsp.codelens.run, opts)
          vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

          client.server_capabilities.documentFormattingProvider = false

          local augroup = vim.api.nvim_create_augroup("LspFormatting", { clear = true })
          vim.api.nvim_create_autocmd("BufWritePre", {
            group = augroup,
            buffer = bufnr,
            callback = function()
              vim.lsp.buf.format({
                bufnr = bufnr,
                async = false,
                filter = function(cl)
                  return cl.name == "null-ls"
                end,
              })
            end,
          })
        end,
      })

           
      lspconfig.pyright.setup({
        capabilities = require("cmp_nvim_lsp").default_capabilities(),
        on_attach = function(client, bufnr)
          local opts = { buffer = bufnr }
          vim.keymap.set("n", "<leader>ra", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<leader>rr", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>rf", function()
            vim.lsp.buf.format({ async = true })
          end, opts)
          vim.keymap.set("n", "<leader>rh", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rs", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "<leader>rd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<leader>ri", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>rR", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "<leader>rc", vim.lsp.codelens.run, opts)

          vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
        end,
      })

      lspconfig.html.setup({})
      lspconfig.cssls.setup({})
      lspconfig.clangd.setup({
        cmd = { "clangd", "--background-index", "--clang-tidy" },
        filetypes = { "c", "cpp", "objc", "objcpp" }, 
        capabilities = capabilities,
        on_attach = function(client, bufnr)
          client.offset_encoding = "utf-16"
          local opts = { buffer = bufnr }

          vim.keymap.set("n", "<leader>ra", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<leader>rr", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>rf", function()
            vim.lsp.buf.format({ async = true })
          end, opts)
          vim.keymap.set("n", "<leader>rh", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rs", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "<leader>rd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<leader>ri", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>rR", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "<leader>rc", vim.lsp.codelens.run, opts)

          vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

          if client.server_capabilities.documentFormattingProvider then
            vim.api.nvim_create_autocmd("BufWritePre", {
              buffer = bufnr,
              callback = function()
                vim.lsp.buf.format({ async = false })
              end,
            })
          end
        end,
      })

      lspconfig.rust_analyzer.setup({
        settings = {
        ["rust-analyzer"] = {
            procMacro = { enable = true },
            checkOnSave = {
              command = "clippy", 
            },
            diagnostics = {
              enable = true,     
              disabled = {},      
            },
            logLevel = "off",
          },
        },

        on_attach = function(client, bufnr)
          local opts = { buffer = bufnr }

          vim.keymap.set("n", "<leader>ra", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<leader>fe", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<leader>rr", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>rf", function()
            vim.lsp.buf.format({ async = true })
          end, opts)
          vim.keymap.set("n", "<leader>rh", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rs", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "<leader>rd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<leader>ri", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>rR", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "<leader>rc", vim.lsp.codelens.run, opts)
          

          vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

          if client.server_capabilities.documentFormattingProvider then
            vim.api.nvim_create_autocmd("BufWritePre", {
              buffer = bufnr,
              callback = function()
                vim.lsp.buf.format({ async = false })
              end,
            })
          end
        end,
      })

      
      vim.diagnostic.config({
        virtual_text = false,  
        signs = true,
        underline = true,
        update_in_insert = false,
        severity_sort = true,
        float = {
          source = "always",
          border = "rounded",
        },
      })

      vim.keymap.set("n", "<leader>d", function()
        vim.diagnostic.open_float(nil, { focus = false })
      end, { desc = "Open diagnostics float" })
    end,
  },

  {
    "tpope/vim-dadbod",
    cmd = { "DB", "DBUI", "DBUIToggle", "DBUIAddConnection" },
  },


  {
    "jose-elias-alvarez/null-ls.nvim",
    ft = "go",
    config = function()
      local null_ls = require("null-ls")

      null_ls.setup({
        sources = {
          null_ls.builtins.formatting.gofumpt,
          null_ls.builtins.formatting.goimports_reviser,
          null_ls.builtins.formatting.golines,
        },
      })
    end,
  },


  {
    "olexsmir/gopher.nvim",
    ft = "go",
    config = function(_, opts)
      require("gopher").setup(opts)
    end,
    build = function()
      vim.cmd [[silent! GoInstallDeps]]
    end,
  },

  {
    "dreamsofcode-io/nvim-dap-go",
    ft = "go",
    dependencies = "mfussenegger/nvim-dap",
    config = function(_, opts)
      require("dap-go").setup(opts)

      vim.keymap.set("n", "<leader>dt", ":DapToggleBreakpoint<CR>", { desc = "Toggle Breakpoint" })
      vim.keymap.set("n", "<leader>dc", ":DapContinue<CR>", { desc = "Continue Debugging" })
    end
  },

  {
    "kristijanhusak/vim-dadbod-ui",
    dependencies = { "tpope/vim-dadbod" },
    cmd = { "DBUI", "DBUIToggle" },
    config = function()
      vim.g.db_ui_save_location = "~/.config/nvim/db_connections"
    end,
  },

  {
    "kristijanhusak/vim-dadbod-completion",
    dependencies = { "kristijanhusak/vim-dadbod-ui", "tpope/vim-dadbod", "hrsh7th/nvim-cmp" },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        sources = cmp.config.sources({
          { name = "vim-dadbod-completion" }, 
        }),
      })
    end,
    ft = { "sql" }, 
  },

  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter",
    config = function()
      require("copilot").setup({
        suggestion = {
          enabled = true,
          auto_trigger = true,
          keymap = {
            accept = "<Tab>",
            next = "<C-n>",
            prev = "<C-p>",
            dismiss = "<C-e>",
          },
        },
        panel = {
          enabled = true,
          keymap = {
            jump_prev = "[[",
            jump_next = "]]",
            accept = "<CR>",
            refresh = "gr",
            open = "<C-o>",
          },
        },
      })
    end,
  },

   {
    "sainnhe/everforest",
    lazy = false,
    priority = 10000,
    config = function()
      vim.o.termguicolors = true

      vim.g.everforest_background = "medium"

      vim.cmd([[colorscheme everforest]])
    end,
  },

  {
    "simrat39/rust-tools.nvim",
    ft = { "rust", "toml" },
    dependencies = { "neovim/nvim-lspconfig" },
    config = function()
      local rt = require("rust-tools")
      rt.setup({
        tools = {
          inlay_hints = {
            auto = true,
            only_current_line = false,
            show_parameter_hints = true,
            parameter_hints_prefix = "<- ",
            other_hints_prefix = "=> ",
          },
        },
        server = {
          on_attach = function(client, bufnr)
            local opts = { buffer = bufnr }

            client.offset_encoding = "utf-16"

            vim.keymap.set("n", "<leader>ra", vim.lsp.buf.code_action, opts)
            vim.keymap.set("v", "<leader>fe", vim.lsp.buf.code_action, opts)

            vim.keymap.set("n", "<leader>rr", vim.lsp.buf.rename, opts)
            vim.keymap.set("n", "<leader>rf", function()
              vim.lsp.buf.format({ async = true })
            end, opts)
            vim.keymap.set("n", "<leader>rh", vim.lsp.buf.hover, opts)
            vim.keymap.set("n", "<leader>rs", vim.lsp.buf.signature_help, opts)
            vim.keymap.set("n", "<leader>rd", vim.lsp.buf.definition, opts)
            vim.keymap.set("n", "<leader>ri", vim.lsp.buf.implementation, opts)
            vim.keymap.set("n", "<leader>rR", vim.lsp.buf.references, opts)
            vim.keymap.set("n", "<leader>rc", vim.lsp.codelens.run, opts)

            vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, opts)
            vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
            vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
            vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
            vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

            if client.server_capabilities.documentFormattingProvider then
              vim.api.nvim_create_autocmd("BufWritePre", {
                buffer = bufnr,
                callback = function()
                  vim.lsp.buf.format({ async = false })
                end,
              })
            end
          end,
        },
      })
    end,
  },

  {
    "hrsh7th/nvim-cmp",
    dependencies = { "hrsh7th/cmp-nvim-lsp", "onsails/lspkind-nvim" },
    config = function()
      local cmp = require("cmp")
      local lspkind = require("lspkind")
      cmp.setup({
        mapping = {
          ["<C-j>"] = cmp.mapping.select_next_item(),
          ["<C-k>"] = cmp.mapping.select_prev_item(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
        },
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
        }),
        formatting = {
          format = lspkind.cmp_format({
            mode = "symbol_text",
            maxwidth = 50,
          }),
        },
      })
    end,
  },

  {
    "L3MON4D3/LuaSnip",
    config = function(plugin, opts)
      require("astronvim.plugins.configs.luasnip")(plugin, opts)

      local luasnip = require("luasnip")
      luasnip.filetype_extend("javascript", { "javascriptreact" })
    end,
  },

  {
    "windwp/nvim-autopairs",
    config = function()
      require("nvim-autopairs").setup()
    end,
  },

  {
    "goolord/alpha-nvim",
    opts = function(_, opts)
      opts.section.header.val = {
        "███████╗██╗  ██╗ █████╗ ██╗     ███████╗███████╗",
        "██╔════╝██║ ██╔╝██╔══██╗██║     ██╔════╝██╔════╝",
        "███████╗█████╔╝ ███████║██║     ███████╗█████╗  ",
        "╚════██║██╔═██╗ ██╔══██║██║     ╚════██║██╔══╝  ",
        "███████║██║  ██╗██║  ██║███████╗███████║███████╗",
        "╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝",
      }
      return opts
    end,
  },

  { "max397574/better-escape.nvim", enabled = true },

  {
    "ThePrimeagen/vim-be-good",
    cmd = "VimBeGood",
  },

  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v2.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    config = function()
      require("neo-tree").setup({
        filesystem = {
          follow_current_file = true,
          hijack_netrw = true,
          use_libuv_file_watcher = true,
        },
        buffers = {
          follow_current_file = true,
        },
        git_status = {
          window = {
            position = "float",
          },
        },
      })
    end,
  },

  {
    "phaazon/hop.nvim",
    branch = "v2",
    config = function()
      local hop = require("hop")
      hop.setup({ keys = "etovxqpdygfblzhckisuran" })

      vim.keymap.set("n", "<leader>fs", function()
        hop.hint_char1({ current_line_only = true })
      end, { desc = "Hop to symbol in current line" })

      vim.keymap.set("n", "<leader>fl", function()
        hop.hint_lines()
      end, { desc = "Hop to line in current window" })

      vim.keymap.set("n", "<leader>fw", function()
        hop.hint_words()
      end, { desc = "Hop to word in current window" })

      vim.keymap.set("n", "<leader>fp", function()
        hop.hint_patterns()
      end, { desc = "Hop to pattern in current window" })
    end,
  },

  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      { "nvim-lua/plenary.nvim" },
      { "nvim-telescope/telescope-file-browser.nvim" },
    },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        extensions = {
          file_browser = {
            hijack_netrw = true,
            mappings = {
              ["n"] = {
                ["m"] = require("telescope").extensions.file_browser.actions.move,
              },
            },
          },
        },
      })
      telescope.load_extension("file_browser")

      vim.keymap.set("n", "<leader>fb", ":Telescope file_browser<CR>", { desc = "Open File Browser" })
    end,
  },

  
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "rust", "lua", "c", "python", "javascript", "go" }, 
        highlight = { enable = true },
        indent = { enable = true },
      })
    end
  },
}

