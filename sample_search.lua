-- Sample Search for REAPER (Freesound + Openverse + SampleRadar link)
-- Requires: ReaImGui (ReaPack) and curl on PATH (built into Win10+/macOS/Linux)
-- Freesound needs an API token: https://freesound.org/apiv2/apply
-- Openverse works without a token (anonymous, rate-limited).
-- Insert uses the preview/streamable file, not necessarily the original download.

local SECTION = 'SampleSearch'
local FS_API = 'https://freesound.org/apiv2/'
local OV_API = 'https://api.openverse.org/v1/'
local SAMPLERADAR_URL = 'https://www.musicradar.com/news/tech/sampleradar-free-sample-downloads-217833'
local CACHE = reaper.GetResourcePath() .. '/Data/SampleSearchCache/'
reaper.RecursiveCreateDirectory(CACHE, 0)

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox('This script needs ReaImGui. Install it via ReaPack.', 'Sample Search', 0)
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
  local ret = reaper.ExecProcess('curl -s -L --max-time 30 -A "ReaperSampleSearch/0.2" ' .. args, 40000)
  if not ret then return false end
  local code = tonumber(ret:match('^(%-?%d+)'))
  return code == 0
end

local function open_url(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url) return end
  local os_name = reaper.GetOS()
  local cmd
  if os_name:find('Win') then
    cmd = 'cmd.exe /c start "" "' .. url .. '"'
  elseif os_name:find('OSX') or os_name:find('macOS') then
    cmd = 'open "' .. url .. '"'
  else
    cmd = 'xdg-open "' .. url .. '"'
  end
  reaper.ExecProcess(cmd, 5000)
end

local function safe_name(s)
  return ((s or 'sound'):gsub('[^%w%-_]', '_')):sub(1, 40)
end

local function url_ext(url)
  local path = (url or ''):gsub('%?.*$', '')
  local ext = path:match('%.(%w+)$')
  if ext and #ext <= 4 then return ext:lower() end
  return 'mp3'
end

local function fs_license(url)
  url = url or ''
  if url:find('zero') then return 'CC0' end
  if url:find('by%-nc') then return 'CC-BY-NC' end
  if url:find('/by/') then return 'CC-BY' end
  if url:find('sampling') then return 'Sampling+' end
  return url
end

local function ov_license(r)
  local l = r.license or ''
  if l == 'cc0' then return 'CC0' end
  if l == 'pdm' then return 'PDM' end
  local s = 'CC-' .. l:upper() .. ' ' .. (r.license_version or '')
  return (s:gsub('%s+$', ''))
end

---------------------------------------------------------------- state
local state = {
  source = 0,  -- 0: Freesound, 1: Openverse
  token = reaper.GetExtState(SECTION, 'fs_token'),
  query = '',
  lic = 0,     -- 0: CC0, 1: CC0 + CC-BY, 2: any
  dur = 1,     -- 0: any, 1: <=2s, 2: <=10s, 3: <=30s
  cat = 0,     -- Openverse: 0: any, 1: sound effects, 2: music
  results = {},
  status = 'Pick a source and type a search term.',
  src = nil,
}

local FS_LICENSE = {
  [0] = 'license:"Creative Commons 0"',
  [1] = 'license:("Creative Commons 0" OR "Attribution")',
}
local OV_LICENSE = { [0] = 'cc0', [1] = 'cc0,by' }
local OV_CATEGORY = { [1] = 'sound_effect', [2] = 'music' }
local DUR_MAX = { [1] = 2, [2] = 10, [3] = 30 }

---------------------------------------------------------------- search
local function fetch_json(url, extra_args)
  local tmp = CACHE .. 'search.json'
  os.remove(tmp)
  if not curl((extra_args or '') .. ' -o "' .. tmp .. '" "' .. url .. '"') then
    return nil, 'curl failed (is curl installed and are you online?)'
  end
  local ok, data = pcall(json.decode, read_file(tmp) or '')
  if not ok or type(data) ~= 'table' then return nil, 'Could not parse response.' end
  if data.detail then return nil, 'API error: ' .. tostring(data.detail) end
  return data
end

local function search_freesound()
  if state.token == '' then state.status = 'Freesound needs an API token.' return end
  reaper.SetExtState(SECTION, 'fs_token', state.token, true)

  local filters = {}
  if FS_LICENSE[state.lic] then filters[#filters + 1] = FS_LICENSE[state.lic] end
  if DUR_MAX[state.dur] then filters[#filters + 1] = 'duration:[0 TO ' .. DUR_MAX[state.dur] .. ']' end

  local url = FS_API .. 'search/text/?query=' .. urlenc(state.query)
    .. '&fields=' .. urlenc('id,name,username,license,duration,previews,url')
    .. '&page_size=30'
  if #filters > 0 then url = url .. '&filter=' .. urlenc(table.concat(filters, ' ')) end

  local data, err = fetch_json(url, '-H "Authorization: Token ' .. state.token .. '"')
  if not data then state.status = err return end

  local out = {}
  for _, r in ipairs(data.results or {}) do
    local u = r.previews and r.previews['preview-hq-mp3']
    if u then
      out[#out + 1] = {
        src = 'fs', id = tostring(r.id), name = r.name or '?', author = r.username or '',
        lic = fs_license(r.license), dur = r.duration or 0, url = u, page = r.url, ext = 'mp3',
      }
    end
  end
  state.results = out
  state.status = string.format('%d results (of %s total)', #out, tostring(data.count or '?'))
end

local function search_openverse()
  local url = OV_API .. 'audio/?q=' .. urlenc(state.query) .. '&page_size=20'
  if OV_LICENSE[state.lic] then url = url .. '&license=' .. OV_LICENSE[state.lic] end
  if OV_CATEGORY[state.cat] then url = url .. '&category=' .. OV_CATEGORY[state.cat] end

  local data, err = fetch_json(url)
  if not data then state.status = err return end

  local out, maxdur = {}, DUR_MAX[state.dur]
  for _, r in ipairs(data.results or {}) do
    local dur = (r.duration or 0) / 1000  -- Openverse reports milliseconds
    if r.url and (not maxdur or dur <= maxdur) then
      out[#out + 1] = {
        src = 'ov', id = tostring(r.id), name = r.title or '?', author = r.creator or '',
        lic = ov_license(r), dur = dur, url = r.url, page = r.foreign_landing_url,
        ext = url_ext(r.url),
      }
    end
  end
  state.results = out
  state.status = string.format('%d results shown (Openverse returns 20 per search)', #out)
end

local function search()
  if state.query == '' then state.status = 'Type a search term.' return end
  state.status = 'Searching...'
  if state.source == 0 then search_freesound() else search_openverse() end
end

---------------------------------------------------------------- playback / insert
local function stop()
  -- The preview system owns and frees the source it was given, so do NOT
  -- call PCM_Source_Destroy here (that double-free crashes REAPER).
  if state.src then
    reaper.Xen_StopSourcePreview(-1)
    state.src = nil
  end
end

-- Downloads the file to the cache folder if needed; returns path or nil
local function ensure_file(r)
  local path = CACHE .. r.src .. '_' .. r.id .. '_' .. safe_name(r.name) .. '.' .. r.ext
  if not file_exists(path) then
    state.status = 'Downloading ' .. r.name .. '...'
    if not curl('-o "' .. path .. '" "' .. r.url .. '"') or not file_exists(path) then
      state.status = 'Download failed.'
      return nil
    end
  end
  return path
end

local function play(r)
  stop()
  local path = ensure_file(r)
  if not path then return end
  local src = reaper.PCM_Source_CreateFromFile(path)
  if src then
    reaper.Xen_StartSourcePreview(src, 1.0, false)
    state.src = src
    state.status = 'Playing: ' .. r.name
  else
    state.status = 'REAPER could not open this file format.'
  end
end

local function log_attribution(r, path)
  local f = io.open(CACHE .. 'attribution_log.txt', 'a')
  if f then
    f:write(string.format('%s | by %s | %s | %s | %s | %s\n',
      r.name, r.author, r.lic, r.page or '', r.src == 'fs' and 'Freesound' or 'Openverse', path))
    f:close()
  end
end

local function insert(r)
  local path = ensure_file(r)
  if not path then return end
  reaper.Undo_BeginBlock()
  -- mode 0: current track at edit cursor; 1: new track
  local mode = reaper.CountSelectedTracks(0) > 0 and 0 or 1
  reaper.InsertMedia(path, mode)
  reaper.Undo_EndBlock('Insert sample', -1)
  reaper.UpdateArrange()
  log_attribution(r, path)
  state.status = 'Inserted: ' .. r.name
end

---------------------------------------------------------------- UI
local ctx = reaper.ImGui_CreateContext('Sample Search')

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 800, 540, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, 'Sample Search', true)
  if visible then
    -- source + token
    reaper.ImGui_SetNextItemWidth(ctx, 130)
    local _, srcidx = reaper.ImGui_Combo(ctx, 'Source', state.source, 'Freesound\0Openverse\0')
    if srcidx ~= state.source then state.source = srcidx state.results = {} end
    if state.source == 0 then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 260)
      local _, tok = reaper.ImGui_InputText(ctx, 'API token', state.token,
        reaper.ImGui_InputTextFlags_Password())
      state.token = tok
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'SampleRadar (browser)') then open_url(SAMPLERADAR_URL) end

    -- query
    reaper.ImGui_SetNextItemWidth(ctx, 320)
    local enter, q = reaper.ImGui_InputText(ctx, '##query', state.query,
      reaper.ImGui_InputTextFlags_EnterReturnsTrue())
    state.query = q
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Search') or enter then search() end

    -- filters
    reaper.ImGui_SetNextItemWidth(ctx, 140)
    local _, lic = reaper.ImGui_Combo(ctx, 'License', state.lic, 'CC0 only\0CC0 + CC-BY\0Any\0')
    state.lic = lic
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 100)
    local _, dur = reaper.ImGui_Combo(ctx, 'Length', state.dur, 'Any\0<= 2 s\0<= 10 s\0<= 30 s\0')
    state.dur = dur
    if state.source == 1 then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 120)
      local _, cat = reaper.ImGui_Combo(ctx, 'Category', state.cat, 'Any\0Sound effects\0Music\0')
      state.cat = cat
    end
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
        reaper.ImGui_Text(ctx, r.name)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, r.author)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, string.format('%.1fs', r.dur))
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, r.lic)
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
