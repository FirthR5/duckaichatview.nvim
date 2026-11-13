-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║  duckai — vista de chat para los exports .txt de Duck.ai sobre markview  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local api = vim.api
local M = {}

local function glyph(cp)
  return vim.fn.nr2char(cp, 1)
end

M.defaults = {
  header = true,
  counter = true,
  spacer = true,
  rule = true,
  model_badge = true,
  meta = true,
  reasoning = "fold", -- "fold" | "hide" | "show"
  fold_turns = false,
  filetype = "markdown",
  notes = vim.env.MD_NOTES or "~/Documents/MD_Notes",
  icons = {
    user = glyph(0xF007) .. " ", --  nf-fa-user
    model = glyph(0xF013) .. " ", --  nf-fa-cog
    brain = glyph(0xE9E0) .. " ", --  nf-mdi-brain
    clock = glyph(0xF017) .. " ", --  nf-fa-clock-o
    rule = glyph(0x2500) .. glyph(0x2500) .. glyph(0x2500),
    rail = glyph(0x2502) .. " ", --  riel para prompts multilinea
  },
}

M.opts = vim.deepcopy(M.defaults)
M.state = {}
M.attached = {}
M.pending = {}
M.ns = api.nvim_create_namespace("duckai")

local PROMPT_RE = "^User%s+prompt%s+(%d+)%s+of%s+(%d+)%s+%-%s+(.-):%s*$"
local MODEL_RE = "^[%w][%w%.%s%-']*:%s*$"
local WIN_DEFAULTS = nil

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                  HIGHLIGHTS                              ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function hl()
  local links = {
    DuckUser = "DiagnosticOk",
    DuckModel = "Title",
    DuckMeta = "Comment",
    DuckDim = "Comment",
    DuckRule = "Comment",
    DuckHidden = "Conceal",
  }
  for name, target in pairs(links) do
    api.nvim_set_hl(0, name, { default = true, link = target })
  end
  api.nvim_set_hl(0, "DuckPrompt", { default = true, link = "Normal" })
  api.nvim_set_hl(0, "DuckPromptRail", { default = true, link = "Comment" })
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                  PARSER                                  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function next_nonblank(lines, i, n)
  for j = i + 1, n or #lines do
    if lines[j]:match("%S") then
      return j
    end
  end
end

local function looks_like_model(s)
  s = s:gsub("%s+$", "")
  if #s < 4 or #s > 40 then
    return false
  end
  if not s:match(MODEL_RE) then
    return false
  end
  if s:match("^%d") or s:match("%d%.%s") or not s:match("%d") then
    return false
  end
  return #vim.split(s:gsub(":%s*$", ""), "%s+", { trimempty = true }) <= 4
end

function M.is_chat(buf)
  local ok, lines = pcall(api.nvim_buf_get_lines, buf, 0, 1, false)
  return ok and lines[1] ~= nil and lines[1]:match("^This conversation was generated with Duck%.ai") ~= nil
end

function M.build(lines)
  local n = #lines
  local blanks = {}
  for i = 1, n do
    blanks[i] = lines[i]:match("^%s*$") ~= nil
  end

  local st = {
    lines = lines,
    blanks = blanks,
    boiler = {},
    turns = {},
    turn_by_line = {},
    reason = {},
    provider = nil,
    model = nil,
    cfg = {
      header = M.opts.header,
      counter = M.opts.counter,
      spacer = M.opts.spacer,
      rule = M.opts.rule,
      model_badge = M.opts.model_badge,
      meta = M.opts.meta,
      reasoning = M.opts.reasoning,
      fold_turns = M.opts.fold_turns,
    },
  }

  if lines[1] and lines[1]:match("^This conversation was generated with Duck%.ai") then
    st.boiler[1] = true
    st.provider, st.model = lines[1]:match("using ([^']+)'s%s+(.-)%s*Model")
  end
  for i = 2, math.min(n, 6) do
    if lines[i]:match("^%s*=+%s*$") and #lines[i]:gsub("%s", "") >= 8 then
      st.boiler[i] = true
    end
  end

  local i = 1
  while i <= n do
    local idx, total, date = lines[i]:match(PROMPT_RE)
    if idx then
      local t = { idx = tonumber(idx), total = tonumber(total), date = date, lnum = i }

      local m
      for j = i + 1, math.min(n, i + 80) do
        if lines[j]:match("^%s*```") or lines[j]:match("^%s*#%s") then
          break
        end
        if lines[j]:match("%S") and lines[j - 1] and lines[j - 1]:match("^%s*$") and looks_like_model(lines[j]) then
          m = j
          break
        end
      end

      local p = next_nonblank(lines, i, n)
      if p and not lines[p]:match("^%s*#") then
        t.text_lnum = p
        t.title = (lines[p]:gsub("^%s+", ""):gsub("%s+$", ""))
      end
      if m then
        t.model_lnum = m
        t.model = (lines[m]:gsub(":%s*$", ""))
        t.body_lnum = next_nonblank(lines, m, n)
      end

      local j = m or (i + 1)
      while j <= n do
        if lines[j]:match("^%s*%-%-+%s*$") and #lines[j]:gsub("%s", "") >= 20 then
          local nx = next_nonblank(lines, j, n)
          if not nx or lines[nx]:match(PROMPT_RE) then
            t.rule_lnum = j
            break
          end
        end
        j = j + 1
      end
      t.end_lnum = (t.rule_lnum and t.rule_lnum - 1) or n

      if t.text_lnum then
        t.text_end_lnum = t.text_lnum
        for k = t.text_lnum + 1, (m and m - 1 or t.end_lnum) do
          if lines[k]:match("%S") then
            t.text_end_lnum = k
          end
        end
      end

      st.turns[#st.turns + 1] = t
      if t.text_lnum then
        st.turn_by_line[t.text_lnum] = t
      end
      i = (t.rule_lnum and t.rule_lnum + 1) or (n + 1)
    else
      i = i + 1
    end
  end

  local open_at
  for j = 1, n do
    if lines[j]:match("^%s*<!%-%-") then
      open_at = open_at or j
    elseif open_at and lines[j]:match("%-%->") then
      st.reason[#st.reason + 1] = { first = open_at, last = j }
      open_at = nil
    end
  end
  if open_at then
    st.reason[#st.reason + 1] = { first = open_at, last = n }
  end

  for _, t in ipairs(st.turns) do
    if t.body_lnum then
      local v = t.body_lnum
      for _, r in ipairs(st.reason) do
        if v >= r.first and v <= r.last then
          v = r.last + 1
        end
      end
      t.body_visual = math.min(v, n)
    end
  end

  return st
end

-- Hide structural lines and drag the surrounding blanks.
local function compute_hide(st)
  local hide = {}
  local blanks = st.blanks
  local n = #st.lines
  local function mark(i)
    if not i or i < 1 or i > n or hide[i] then
      return
    end
    hide[i] = true
    for j = i - 1, 1, -1 do
      if not blanks[j] then
        break
      end
      hide[j] = true
    end
    for j = i + 1, n do
      if not blanks[j] then
        break
      end
      hide[j] = true
    end
  end

  for i = 1, math.min(n, 6) do
    if st.boiler[i] then
      mark(i)
    end
  end
  for _, t in ipairs(st.turns) do
    mark(t.lnum)
    mark(t.model_lnum)
    mark(t.rule_lnum)
  end
  if st.cfg.reasoning == "hide" then
    for _, r in ipairs(st.reason) do
      for i = r.first, r.last do
        mark(i)
      end
    end
  end
  return hide
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                DECORACIÓN                                ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

function M.apply(buf)
  local st = M.state[buf]
  if not st or not api.nvim_buf_is_valid(buf) then
    return
  end

  local icons = M.opts.icons
  local hide = compute_hide(st)
  local above = {}
  local below = {}
  local function push_above(lnum, line)
    if not lnum then
      return
    end
    above[lnum] = above[lnum] or {}
    above[lnum][#above[lnum] + 1] = line
  end
  local function push_below(lnum, line)
    if not lnum then
      return
    end
    below[lnum] = below[lnum] or {}
    below[lnum][#below[lnum] + 1] = line
  end

  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  for lnum in pairs(hide) do
    api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
      conceal = "",
      conceal_lines = "",
      line_hl_group = "DuckHidden",
      hl_mode = "combine",
      priority = 200,
    })
  end

  local first = st.turns[1]
  if st.cfg.header and first and first.text_lnum then
    -- Chat Header
    local chunks = {}
    if st.provider then
      chunks[#chunks + 1] = { " " .. st.provider, "DuckDim" }
    end
    if #st.turns > 0 then
      chunks[#chunks + 1] = { ("  · %d turnos"):format(#st.turns), "DuckDim" }
    end
    if #chunks > 0 then
      push_above(first.text_lnum, chunks)
    end
  end

  for k, t in ipairs(st.turns) do
    if t.text_lnum and not hide[t.text_lnum] then
      local first_l, last_l = t.text_lnum, t.text_end_lnum or t.text_lnum
      local counter = t.total and ("%d/%d"):format(t.idx, t.total) or tostring(t.idx)

      if st.cfg.rule and k > 1 then
        push_above(first_l, { { (" %s %s %s "):format(icons.rule, counter, icons.rule), "DuckRule" } })
      end

      -- El prompt puede ocupar varias lineas:
      -- se marca el bloque entero con un riel para que se lea como una unidad, no como respuesta.
      for lnum = first_l, last_l do
        api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
          line_hl_group = "DuckPrompt",
          hl_mode = "combine",
          priority = 205,
        })
        if lnum > first_l and not st.blanks[lnum] then
          api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
            virt_text = { { icons.rail, "DuckPromptRail" } },
            virt_text_pos = "inline",
            priority = 210,
          })
        end
      end

      -- Quien responde: su propia linea, entre el prompt y el razonamiento.
      if t.model and st.cfg.model_badge then
        push_below(last_l, {
          { icons.model, "DuckModel" },
          { " " .. t.model, "DuckModel" },
        })
      end

      local right = {}
      if st.cfg.counter and t.total then
        right[#right + 1] = { counter, "DuckDim" }
      end

      -- Fecha junto al icono del usuario; el mensaje va en la linea de abajo.
      if st.cfg.meta and t.date then
        push_above(first_l, {
          { icons.user, "DuckUser" },
          { " " .. t.date, "DuckDim" },
        })
      else
        api.nvim_buf_set_extmark(buf, M.ns, first_l - 1, 0, {
          virt_text = { { icons.user, "DuckUser" } },
          virt_text_pos = "inline",
          priority = 210,
        })
      end
      if #right > 0 then
        api.nvim_buf_set_extmark(buf, M.ns, last_l - 1, 0, {
          virt_text = right,
          virt_text_pos = "right_align",
          priority = 210,
        })
      end
    end

    if st.cfg.spacer and t.body_visual and t.body_visual ~= t.text_lnum and not hide[t.body_visual] then
      push_above(t.body_visual, { { "", "DuckDim" } })
    end
  end

  for lnum, chunks in pairs(above) do
    api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
      virt_lines = chunks,
      virt_lines_above = true,
      priority = 210,
    })
  end

  for lnum, chunks in pairs(below) do
    api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
      virt_lines = chunks,
      priority = 210,
    })
  end
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                   FOLDS                                  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

function M.fold(lnum)
  local st = M.state[api.nvim_get_current_buf()]
  if not st then
    if vim.treesitter and vim.treesitter.foldexpr then
      local ok, lvl = pcall(vim.treesitter.foldexpr, lnum)
      if ok and type(lvl) == "number" then
        return lvl
      end
    end
    return 0
  end

  if st.cfg.reasoning == "fold" then
    for _, r in ipairs(st.reason) do
      if lnum >= r.first and lnum <= r.last then
        return 2
      end
    end
  end

  if st.cfg.fold_turns then
    for _, t in ipairs(st.turns) do
      if lnum >= t.text_lnum and lnum <= t.end_lnum then
        return 1
      end
    end
  end

  return 0
end

function M.foldtext()
  local st = M.state[api.nvim_get_current_buf()]
  if not st then
    return ""
  end
  local lnum = vim.v.foldstart
  if vim.fn.foldlevel(lnum) >= 2 then
    local for_turn
    for _, r in ipairs(st.reason) do
      if lnum >= r.first and lnum <= r.last then
        for_turn = r
        break
      end
    end
    local lines = for_turn and (for_turn.last - for_turn.first + 1) or 0
    return ("%srazonamiento · %d líneas"):format(M.opts.icons.brain, lines)
  end
  local t = st.turn_by_line[lnum]
  if not t then
    return ""
  end
  local title = t.title or ""
  if #title > 60 then
    title = title:sub(1, 57) .. "..."
  end
  local counter = t.total and ("%d/%d"):format(t.idx, t.total) or tostring(t.idx)
  return (" %s%s  %s"):format(M.opts.icons.user, counter, title)
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                             Window Options                               ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

function M.apply_win(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  local st = M.state[buf]
  if not st then
    M.restore_win(win)
    return
  end
  local wo = vim.wo[win]
  wo.conceallevel = 2
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'duckai'.fold(v:lnum)"
  wo.foldtext = "v:lua.require'duckai'.foldtext()"
  wo.foldlevel = st.cfg.fold_turns and 0 or 1
  wo.foldenable = true
  -- La columna de folds (icono de flecha) estorba: el fold ya se identifica
  -- por su propio texto, asi que se oculta mientras dura la vista de chat.
  wo.foldcolumn = "0"
end

function M.restore_win(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) or not WIN_DEFAULTS then
    return
  end
  local wo = vim.wo[win]
  wo.conceallevel = WIN_DEFAULTS.conceallevel
  wo.foldmethod = WIN_DEFAULTS.foldmethod
  wo.foldexpr = WIN_DEFAULTS.foldexpr
  wo.foldtext = WIN_DEFAULTS.foldtext
  wo.foldlevel = WIN_DEFAULTS.foldlevel
  wo.foldenable = WIN_DEFAULTS.foldenable
  wo.foldcolumn = WIN_DEFAULTS.foldcolumn
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                 BUFER HOOK                               ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function refresh(buf)
  if M.pending[buf] then
    return
  end
  M.pending[buf] = true
  vim.schedule(function()
    M.pending[buf] = nil
    if api.nvim_buf_is_valid(buf) and M.state[buf] then
      M.state[buf] = M.build(api.nvim_buf_get_lines(buf, 0, -1, false))
      M.apply(buf)
    end
  end)
end

function M.attach(buf)
  if M.attached[buf] then
    return
  end
  M.attached[buf] = true
  api.nvim_buf_attach(buf, false, {
    on_lines = function()
      refresh(buf)
    end,
  })
end

local function maps(buf)
  local ok, keys = pcall(require, "config.keys")
  local p = (ok and keys.Duck) or "<leader>Md"
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = "duckai: " .. desc })
  end
  map(p .. "o", "<cmd>DuckOpen<cr>", "abrir chats")
  map(p .. "r", "<cmd>DuckToggleReasoning<cr>", "razonamiento")
  map(p .. "m", "<cmd>DuckToggleMeta<cr>", "metadata")
  map(p .. "f", "<cmd>DuckToggleFold<cr>", "plegar turnos")
  map(p .. "u", "<cmd>DuckToggleUI<cr>", "toggle interfaz")
end

function M.on_buffer(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  if not M.state[buf] then
    if not M.is_chat(buf) then
      M.restore_win(0)
      return
    end
    if vim.bo[buf].filetype ~= M.opts.filetype then
      vim.bo[buf].filetype = M.opts.filetype
    end
    M.state[buf] = M.build(api.nvim_buf_get_lines(buf, 0, -1, false))
    maps(buf)
  end

  M.attach(buf)
  M.apply(buf)
  M.apply_win(0)
  require("duckai.outline").attach(buf)
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                COMANDOS                                  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function buf_state()
  local buf = api.nvim_get_current_buf()
  if not M.state[buf] then
    vim.notify("duckai: este buffer no es un chat de Duck.ai", vim.log.levels.WARN)
  end
  return M.state[buf]
end

local function commands()
  local cmd = api.nvim_create_user_command

  cmd("DuckOpen", function(opts)
    M.open(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "duckai: abrir un chat de Duck.ai" })

  cmd("DuckToggleReasoning", function()
    local st = buf_state()
    if not st then
      return
    end
    local order = { "fold", "hide", "show" }
    local cur = 1
    for i, v in ipairs(order) do
      if v == st.cfg.reasoning then
        cur = i
      end
    end
    st.cfg.reasoning = order[cur % #order + 1]
    M.apply(api.nvim_get_current_buf())
    M.apply_win(0)
    vim.notify("duckai: razonamiento = " .. st.cfg.reasoning, vim.log.levels.INFO)
  end, { desc = "duckai: ciclar razonamiento (fold/hide/show)" })

  cmd("DuckToggleMeta", function()
    local st = buf_state()
    if not st then
      return
    end
    st.cfg.meta = not st.cfg.meta
    M.apply(api.nvim_get_current_buf())
  end, { desc = "duckai: mostrar/ocultar metadata" })

  cmd("DuckToggleFold", function()
    local st = buf_state()
    if not st then
      return
    end
    st.cfg.fold_turns = not st.cfg.fold_turns
    M.apply(api.nvim_get_current_buf())
    M.apply_win(0)
  end, { desc = "duckai: plegar por turno" })

  cmd("DuckToggleUI", function()
    local win = api.nvim_get_current_win()
    vim.wo[win].conceallevel = vim.wo[win].conceallevel == 2 and 0 or 2
  end, { desc = "duckai: mostrar/ocultar la vista de chat" })
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                  PICKER                                  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function title_of(path)
  local lines = vim.fn.readfile(path, "", 12)
  for i, l in ipairs(lines) do
    if l:match(PROMPT_RE) then
      local j = next_nonblank(lines, i, #lines)
      return j and (lines[j]:gsub("^%s+", ""):gsub("%s+$", "")) or vim.fn.fnamemodify(path, ":t")
    end
  end
  return vim.fn.fnamemodify(path, ":t")
end

function M.open(path)
  if path then
    vim.cmd.edit(vim.fn.fnameescape(path))
    return
  end

  local dir = vim.fn.expand(M.opts.notes) .. "/ChatBot"
  local files = vim.fn.glob(dir .. "/duck.ai*.txt", false, true)
  if #files == 0 then
    vim.notify("duckai: no hay chats en " .. dir, vim.log.levels.WARN)
    return
  end
  table.sort(files, function(a, b)
    return vim.fn.getftime(a) > vim.fn.getftime(b)
  end)

  local titles = {}
  for i, f in ipairs(files) do
    titles[i] = title_of(f)
  end

  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")

  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
    vim.ui.select(titles, { prompt = "Duck.ai" }, function(_, i)
      if i then
        vim.cmd.edit(vim.fn.fnameescape(files[i]))
      end
    end)
    return
  end

  pickers
    .new({}, {
      prompt_title = "Chats de Duck.ai",
      finder = finders.new_table({
        results = files,
        entry_maker = function(f)
          local name = vim.fn.fnamemodify(f, ":t")
          local title = title_of(f)
          return {
            value = f,
            display = name,
            path = f,
            comment = title,
            ordinal = name .. " " .. title,
          }
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            vim.cmd.edit(vim.fn.fnameescape(entry.value))
          end
        end)
        return true
      end,
    })
    :find()
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                  SETUP                                   ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  WIN_DEFAULTS = {
    conceallevel = vim.o.conceallevel,
    foldmethod = vim.o.foldmethod,
    foldexpr = vim.o.foldexpr,
    foldtext = vim.o.foldtext,
    foldlevel = vim.o.foldlevel,
    foldenable = vim.o.foldenable,
    foldcolumn = vim.o.foldcolumn,
  }

  hl()
  commands()

  local group = api.nvim_create_augroup("duckai", { clear = true })
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter" }, {
    group = group,
    desc = "duckai: detectar chats de Duck.ai",
    callback = function(ev)
      M.on_buffer(ev.buf)
    end,
  })
  api.nvim_create_autocmd("WinNew", {
    group = group,
    desc = "duckai: opciones de ventana",
    callback = function(ev)
      M.apply_win(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    desc = "duckai: restaurar opciones de ventana",
    callback = function(ev)
      if M.state[ev.buf] then
        M.restore_win(0)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      M.state[ev.buf] = nil
      M.attached[ev.buf] = nil
      M.pending[ev.buf] = nil
      pcall(function()
        require("duckai.outline").detach(ev.buf)
      end)
    end,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = hl,
  })

  M.on_buffer(0)
  return M
end

return M
