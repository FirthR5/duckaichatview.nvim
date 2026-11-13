-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║  Outline:                                                                ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local M = {}

local api = vim.api
local Kind = vim.lsp.protocol.SymbolKind

-- Escalera de iconos: conversacion > turno > # > ## > ### ...
local KIND_TURN = Kind.Class
local KIND_BY_LEVEL = {
  [1] = Kind.Method,
  [2] = Kind.Property,
}

local function pos(line, character)
  return { line = line, character = character or 0 }
end

local function clamp(text, max)
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > max then
    return text:sub(1, max - 1) .. "…"
  end
  return text
end

-- Headers del buffer dentro de un rango, anidados por nivel.
-- Cada seccion termina justo antes del proximo header de su mismo nivel.
local function headings_in_range(lines, from, to)
  local flat, fence = {}, false
  for i = math.max(from, 1), math.min(to, #lines) do
    local line = lines[i]
    if line:match("^%s*```") then
      fence = not fence
    elseif not fence then
      local hashes, text = line:match("^(#+)%s+(.+)$")
      if hashes and #hashes <= 6 and text:match("%S") then
        flat[#flat + 1] = {
          name = text:gsub("%s+$", ""),
          level = #hashes,
          kind = KIND_BY_LEVEL[#hashes] or Kind.Field,
          lnum = i,
          children = {},
        }
      end
    end
  end

  local last = math.min(to, #lines) - 1
  local roots, stack = {}, {}
  for idx, node in ipairs(flat) do
    while #stack > 0 and stack[#stack].level >= node.level do
      table.remove(stack)
    end
    if #stack == 0 then
      roots[#roots + 1] = node
    else
      local parent = stack[#stack].node
      parent.children[#parent.children + 1] = node
    end
    stack[#stack + 1] = { level = node.level, node = node }

    local close = math.max(last, node.lnum - 1)
    for j = idx + 1, #flat do
      if flat[j].level <= node.level then
        close = math.max(flat[j].lnum - 2, node.lnum - 1)
        break
      end
    end
    node.range = { start = pos(node.lnum - 1), ["end"] = pos(close) }
    node.selectionRange = { start = pos(node.lnum - 1), ["end"] = pos(node.lnum - 1, #lines[node.lnum]) }
  end

  return roots
end

--- Symbolos del buffer: la conversacion arriba, los headers debajo.
---@param bufnr integer
---@return table[]|nil
function M.symbols(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or #lines == 0 then
    return nil
  end

  local st = require("duckai").state[bufnr]
  local name = (st and st.turns[1] and st.turns[1].title)
    or vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
  if not name or name == "" then
    name = "conversación"
  end

  local detail
  if st then
    local model = st.model or (st.turns[1] and st.turns[1].model)
    detail = table.concat(vim.tbl_filter(function(x)
      return x
    end, { model, st.provider }), " · ")
  end

  -- Un nodo por turno: asi ningun prompt se pierde aunque su respuesta no
  -- tenga ningun # header.
  local children = {}
  if st and #st.turns > 0 then
    for _, t in ipairs(st.turns) do
      if t.text_lnum then
        local from = t.text_lnum
        local to = t.end_lnum or #lines
        local counter = t.total and ("%d/%d"):format(t.idx, t.total) or tostring(t.idx)
        children[#children + 1] = {
          name = ("%s  %s"):format(counter, clamp(t.title or "", 60)),
          detail = t.model,
          kind = KIND_TURN,
          range = { start = pos(from - 1), ["end"] = pos(math.max(math.min(to, #lines) - 1, from - 1)) },
          selectionRange = { start = pos(from - 1), ["end"] = pos(from - 1, #(lines[from] or "")) },
          children = headings_in_range(lines, from + 1, to),
        }
      end
    end
  else
    children = headings_in_range(lines, 1, #lines)
  end

  return {
    {
      name = name,
      detail = detail,
      kind = Kind.Namespace,
      range = { start = pos(0), ["end"] = pos(#lines - 1) },
      selectionRange = { start = pos(0), ["end"] = pos(0, #(lines[1] or "")) },
      children = children,
    },
  }
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                             SERVIDOR EN PROCESO                          ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

local function new_server()
  local closing = false
  local next_id = 0
  local server = {}

  function server.request(method, params, callback)
    next_id = next_id + 1
    local id = next_id

    if method == "initialize" then
      callback(nil, {
        capabilities = {
          documentSymbolProvider = true,
          textDocumentSync = { openClose = true, change = 1, save = false },
        },
        serverInfo = { name = "duckai" },
      })
    elseif method == "textDocument/documentSymbol" then
      local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
      -- Respuesta asincrona, como manda el protocolo.
      vim.schedule(function()
        if closing then
          callback(nil, nil)
          return
        end
        local result = M.symbols(bufnr)
        if result then
          callback(nil, result)
        else
          callback({ code = -32603, message = "duckai: sin simbolos" }, nil)
        end
      end)
    else
      callback(nil, nil)
    end

    return true, id
  end

  function server.notify(method)
    if method == "exit" then
      closing = true
    end
    return true
  end

  function server.is_closing()
    return closing
  end

  function server.terminate()
    closing = true
  end

  return server
end

-- ╔══════════════════════════════════════════════════════════════════════════╗ --
-- ║                                  ATTACH                                  ║ --
-- ╚══════════════════════════════════════════════════════════════════════════╝ --

M.client = nil

local function refresh_outline()
  -- Solo si el usuario ya tiene el outline abierto: refresca sin esperar.
  if package.loaded["outline"] then
    vim.defer_fn(function()
      pcall(require("outline").refresh_outline)
    end, 100)
  end
end

---@param bufnr integer
function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  if M.client then
    if M.client:is_stopped() then
      M.client = nil
    elseif not vim.lsp.buf_is_attached(bufnr, M.client.id) then
      vim.lsp.buf_attach_client(bufnr, M.client.id)
      refresh_outline()
    end
    return
  end

  -- Si otro cliente ya da documentSymbol, no competir.
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name ~= "duckai" and client.server_capabilities.documentSymbolProvider then
      return
    end
  end

  local dir = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":p:h")
  if dir == "" then
    dir = vim.fn.getcwd()
  end

  local id = vim.lsp.start({
    name = "duckai",
    cmd = new_server,
    root_dir = dir,
    reuse_client = function()
      return M.client
    end,
  }, { bufnr = bufnr })

  M.client = id and vim.lsp.get_client_by_id(id) or nil

  if M.client then
    refresh_outline()
  end
end

---@param bufnr integer
function M.detach(bufnr)
  if M.client and not M.client:is_stopped() and vim.lsp.buf_is_attached(bufnr, M.client.id) then
    pcall(vim.lsp.buf_detach_client, bufnr, M.client.id)
  end
end

return M
