-- Freesound Search for REAPER (starter)
-- Requires: ReaImGui (ReaPack) and curl on PATH (built into Win10+/macOS/Linux)
-- Freesound API token: https://freesound.org/apiv2/apply
-- Insert uses the HQ preview file (MP3), not the original download.

local SECTION = 'FreesoundSearch'
local API = 'https://freesound.org/apiv2/'
local CACHE = reaper.GetResourcePath() .. '/Data/FreesoundCache/'
reaper.RecursiveCreateDirectory(CACHE, 0)

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox('This script needs ReaImGui. Install it via ReaPack.', 'Freesound Search', 0)
  return
end

---------------------------------------------------------------- JSON (minimal)
local json = {}
do
  local escmap = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
  local function skip(s, i) return s:find('[^ \n\r\t]', i) or #s + 1 end
  local parse

  local function parse_string(s, i)
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == '' then error('unterminated string') end
      if c == '"' then return table.concat(out), j + 1 end
      if c == '\\' then
        local n = s:sub(j + 1, j + 1)
        if n == 'u' then
          out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16))
          j = j + 6
        else
          out[#out + 1] = escmap[n] or n
          j = j + 2
        end
      else
        out[#out + 1] = c
        j = j + 1
      end
    end
  end

  parse = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == '{' then
      local t = {}
      i = skip(s, i + 1)
      if s:sub(i, i) == '}' then return t, i + 1 end
      while true do
        local k
        k, i = parse_string(s, skip(s, i))
        i = skip(s, i)
        assert(s:sub(i, i) == ':', 'expected :')
        local v
        v, i = parse(s, i + 1)
        t[k] = v
        i = skip(s, i)
        local d = s:sub(i, i)
        i = i + 1
        if d == '}' then return t, i elseif d ~= ',' then error('expected , or }') end
      end
    elseif c == '[' then
      local t = {}
      i = skip(s, i + 1)
      if s:sub(i, i) == ']' then return t, i + 1 end
      while true do
        local v
        v, i = parse(s, i)
        t[#t + 1] = v
        i = skip(s, i)
        local d = s:sub(i, i)
        i = i + 1
        if d == ']' then return t, i elseif d ~= ',' then error('expected , or ]') end
      end
    elseif c == '"' then
      return parse_string(s, i)
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return nil, i + 4
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
      if not num then error('bad json at ' .. i) end
      return tonumber(num), i + #num
    end
  end

  function json.decode(s) return (parse(s, 1)) end
end

---------------------------------------------------------------- helpers
local function urlenc(s)
  return (s:gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end))
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('a')
  f:close()
  return d
end

local function file_exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() return true end
  return false
end

-- Runs curl; returns true on exit code 0
local function curl(args)
  local ret = reaper.ExecProcess('curl -s -L --max-time 30 ' .. args, 40000)
  if not ret then return false end
  local code = tonumber(ret:match('^(%-?%d+)'))
  return code == 0
end

local function short_license(url)
  url = url or ''
  if url:find('zero') then return 'CC0' end
  if url:find('by%-nc') then return 'CC-BY-NC' end
  if url:find('/by/') then return 'CC-BY' end
  if url:find('sampling') then return 'Sampling+' end
  return url
end

local function safe_name(s)
  return (s:gsub('[^%w%-_]', '_')):sub(1, 40)
end

---------------------------------------------------------------- state
local state = {
  token = reaper.GetExtState(SECTION, 'token'),
  query = '',
  lic = 0,   -- 0: CC0, 1: CC0 + CC-BY, 2: any
  dur = 1,   -- 0: any, 1: <=2s, 2: <=10s, 3: <=30s
  results = {},
  status = 'Enter a token and a search term.',
  src = nil,
  playing = nil,
}

local LICENSE_FILTERS = {
  [0] = 'license:"Creative Commons 0"',
  [1] = 'license:("Creative Commons 0" OR "Attribution")',
  [2] = nil,
}
local DURATION_FILTERS = {
  [0] = nil,
  [1] = 'duration:[0 TO 2]',
  [2] = 'duration:[0 TO 10]',
  [3] = 'duration:[0 TO 30]',
}

---------------------------------------------------------------- actions
local function search()
  if state.token == '' then state.status = 'Missing API token.' return end
  if state.query == '' then state.status = 'Type a search term.' return end
  reaper.SetExtState(SECTION, 'token', state.token, true)

  local filters = {}
  if LICENSE_FILTERS[state.lic] then filters[#filters + 1] = LICENSE_FILTERS[state.lic] end
  if DURATION_FILTERS[state.dur] then filters[#filters + 1] = DURATION_FILTERS[state.dur] end

  local url = API .. 'search/text/?query=' .. urlenc(state.query)
    .. '&fields=' .. urlenc('id,name,username,license,duration,previews,url')
    .. '&page_size=30'
  if #filters > 0 then url = url .. '&filter=' .. urlenc(table.concat(filters, ' ')) end

  local tmp = CACHE .. 'search.json'
  os.remove(tmp)
  state.status = 'Searching...'
  if not curl('-H "Authorization: Token ' .. state.token .. '" -o "' .. tmp .. '" "' .. url .. '"') then
    state.status = 'curl failed (is curl installed and online?)'
    return
  end

  local body = read_file(tmp)
  local ok, data = pcall(json.decode, body or '')
  if not ok or type(data) ~= 'table' then
    state.status = 'Could not parse response.'
    return
  end
  if data.detail then state.status = 'API error: ' .. tostring(data.detail) return end

  state.results = data.results or {}
  state.status = string.format('%d results (of %s total)', #state.results, tostring(data.count or '?'))
end

local function stop()
  -- The preview system owns and frees the source it was given, so do NOT
  -- call PCM_Source_Destroy here (that double-free crashes REAPER).
  if state.src then
    reaper.Xen_StopSourcePreview(-1)
    state.src, state.playing = nil, nil
  end
end

-- Downloads the HQ preview to the cache folder if needed; returns path or nil
local function ensure_preview(r)
  local url = r.previews and r.previews['preview-hq-mp3']
  if not url then state.status = 'No preview URL for this sound.' return nil end
  local path = CACHE .. r.id .. '_' .. safe_name(r.name or 'sound') .. '.mp3'
  if not file_exists(path) then
    state.status = 'Downloading ' .. (r.name or '') .. '...'
    if not curl('-o "' .. path .. '" "' .. url .. '"') or not file_exists(path) then
      state.status = 'Download failed.'
      return nil
    end
  end
  return path
end

local function play(r)
  stop()
  local path = ensure_preview(r)
  if not path then return end
  local src = reaper.PCM_Source_CreateFromFile(path)
  if src then
    reaper.Xen_StartSourcePreview(src, 1.0, false)
    state.src, state.playing = src, r.id
    state.status = 'Playing: ' .. (r.name or '')
  end
end

local function log_attribution(r, path)
  local f = io.open(CACHE .. 'attribution_log.txt', 'a')
  if f then
    f:write(string.format('%s | by %s | %s | %s | %s\n',
      r.name or '', r.username or '', short_license(r.license), r.url or '', path))
    f:close()
  end
end

local function insert(r)
  local path = ensure_preview(r)
  if not path then return end
  reaper.Undo_BeginBlock()
  -- mode 0: current track at edit cursor; 1: new track
  local mode = reaper.CountSelectedTracks(0) > 0 and 0 or 1
  reaper.InsertMedia(path, mode)
  reaper.Undo_EndBlock('Insert Freesound sample', -1)
  reaper.UpdateArrange()
  log_attribution(r, path)
  state.status = 'Inserted: ' .. (r.name or '')
end

---------------------------------------------------------------- UI
local ctx = reaper.ImGui_CreateContext('Freesound Search')

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 760, 520, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, 'Freesound Search', true)
  if visible then
    -- token
    reaper.ImGui_SetNextItemWidth(ctx, 300)
    local _, tok = reaper.ImGui_InputText(ctx, 'API token', state.token,
      reaper.ImGui_InputTextFlags_Password())
    state.token = tok

    -- query + filters
    reaper.ImGui_SetNextItemWidth(ctx, 300)
    local enter, q = reaper.ImGui_InputText(ctx, '##query', state.query,
      reaper.ImGui_InputTextFlags_EnterReturnsTrue())
    state.query = q
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Search') or enter then search() end

    reaper.ImGui_SetNextItemWidth(ctx, 150)
    local _, lic = reaper.ImGui_Combo(ctx, 'License', state.lic, 'CC0 only\0CC0 + CC-BY\0Any\0')
    state.lic = lic
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    local _, dur = reaper.ImGui_Combo(ctx, 'Length', state.dur, 'Any\0<= 2 s\0<= 10 s\0<= 30 s\0')
    state.dur = dur
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Stop') then stop() end

    reaper.ImGui_Text(ctx, state.status)
    reaper.ImGui_Separator(ctx)

    -- results
    local flags = reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_ScrollY()
    if reaper.ImGui_BeginTable(ctx, 'results', 5, flags) then
      reaper.ImGui_TableSetupColumn(ctx, 'Name', reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, 'Author')
      reaper.ImGui_TableSetupColumn(ctx, 'Len')
      reaper.ImGui_TableSetupColumn(ctx, 'License')
      reaper.ImGui_TableSetupColumn(ctx, '')
      reaper.ImGui_TableHeadersRow(ctx)

      for i, r in ipairs(state.results) do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, r.name or '?')
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, r.username or '')
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, string.format('%.1fs', r.duration or 0))
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, short_license(r.license))
        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Button(ctx, 'Play##' .. i) then play(r) end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, 'Insert##' .. i) then insert(r) end
      end
      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(loop)
  else
    stop()
  end
end

reaper.atexit(stop)
reaper.defer(loop)
