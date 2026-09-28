local json = require("dkjson")

local LOG = "VKPlay: "
local unpack = table.unpack or unpack

-- Порядок предпочтения типов потоков
local LIVE_TYPES   = { "live_hls", "live_playback_hls", "hls" }
local RECORD_TYPES = { "full_hd", "high", "hls", "medium", "low", "lowest", "tiny" }

-- Опции, которые VLC применит к элементу плейлиста
-- ВАЖНО: не подменять User-Agent/Referer — ссылка подписана (sig) под
-- агента, который запрашивал API (стандартный UA VLC), иначе CDN вернёт 400.
-- LIVE: качество не фиксируем — адаптивный модуль сам меняет битрейт
local LIVE_OPTIONS = {
  ":network-caching=10000",   -- 10 с буфера против подтормаживаний CDN
  ":no-ts-trust-pcr",         -- не доверять PCR: лечит пропажу звука на разрывах
}

-- Записи отдаются одним MP4-файлом (не HLS), поэтому TS/HLS-опции тут не нужны
local RECORD_OPTIONS = {
  ":network-caching=10000",
  ":codec=avcodec,any",       -- AAC через FFmpeg: faad теряет звук на SBR/сменах конфигурации
  ":input-fast-seek",         -- перемотка на ключевой кадр без долгого preroll
}


local function match_all(str, pattern)
  local matched = {}
  for m in string.gmatch(str, pattern) do
    table.insert(matched, m)
  end
  return unpack(matched)
end


local function get_json(url)
  local stream = vlc.stream(url)
  if not stream then
    return nil, "Failed to create VLC stream"
  end

  local chunks = {}
  while true do
    local chunk = stream:read(65536)
    if not chunk or chunk == "" then break end
    table.insert(chunks, chunk)
  end

  local data, _, err = json.decode(table.concat(chunks))
  if not data then
    return nil, "JSON decode error: "..(err or "unknown error")
  end
  return data
end


local function api_call(path)
  local data, err = get_json("https://api.live.vkvideo.ru/v1/blog/"..path)
  if not data then
    vlc.msg.err(LOG.."API call failed: "..err)
    return {}
  end
  return data
end


-- Выбирает первый непустой URL по списку предпочтений
local function pick_url(player_urls, prefs)
  local by_type = {}
  for _, p in ipairs(player_urls or {}) do
    if p.type and p.url and p.url ~= "" then
      by_type[p.type] = p.url
      vlc.msg.dbg(LOG.."available: "..p.type.." -> "..p.url)
    end
  end

  for _, t in ipairs(prefs) do
    if by_type[t] then
      vlc.msg.info(LOG.."using stream type: "..t)
      return by_type[t]
    end
  end

  vlc.msg.err(LOG.."no suitable stream type found")
  return nil
end


local function broadcast(channel)
  local container = api_call(channel.."/public_video_stream?from=layer")
  local data = container and container.data
  if not data or not data[1] then
    vlc.msg.err(LOG.."Stream is currently offline or no data")
    return nil
  end

  local url = pick_url(data[1].playerUrls, LIVE_TYPES)
  if not url then return nil end

  return {
    path        = url,
    name        = container.title,
    artist      = container.user and container.user.nick,
    description = container.category and container.category.title,
    options     = LIVE_OPTIONS,
  }
end


local function records(channel, record_id)
  local container = api_call(channel.."/public_video_stream/record/"..record_id)
  local record = container and container.data and container.data.record
  if not record or not record.data or not record.data[1] then
    vlc.msg.err(LOG.."Record not found: "..record_id)
    return nil
  end

  local url = pick_url(record.data[1].playerUrls, RECORD_TYPES)
  if not url then return nil end

  return {
    path        = url,
    name        = record.title,
    artist      = record.blog and record.blog.owner and record.blog.owner.displayName,
    description = record.category and record.category.title,
    options     = RECORD_OPTIONS,
  }
end


function probe()
  return (vlc.access == "http" or vlc.access == "https") and (
    vlc.path:match("^vkplay%.live/.+") or
    vlc.path:match("^live%.vkplay%.ru/.+") or
    vlc.path:match("^live%.vkvideo%.ru/.+")
  )
end


function parse()
  local channel, _, record_id = match_all(vlc.path, "/([^/?#]+)")

  local item
  if not record_id then
    item = broadcast(channel)
  else
    item = records(channel, record_id)
  end

  return item and { item } or {}
end
