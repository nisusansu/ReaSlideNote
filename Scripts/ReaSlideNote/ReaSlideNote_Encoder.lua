-- @noindex

local SLIDE_CHANNEL_1BASED = 16
local FOLLOW_BASE_NOTE_CHANNEL = true
local FIXED_BEND_CHANNEL_1BASED = 1 -- used only if FOLLOW_BASE_NOTE_CHANNEL = false
local MUTE_SLIDE_MARKERS = true
local PROCESS_ONLY_ACTIVE_TAKES = false -- safer for your case

-- RSN2:
-- 7D 'R' 'S' 'N' '2' bendChan basePitch startPitch targetPitch startVel targetVel durLo durHi
local SIG = {0x7D, string.byte("R"), string.byte("S"), string.byte("N"), string.byte("2")}

local state_by_take = {}
local last_play_state = -1
local last_tempo_sig = nil

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function round(x)
  if x >= 0 then
    return math.floor(x + 0.5)
  else
    return math.ceil(x - 0.5)
  end
end

local function human_to_reaper_channel(ch1)
  return clamp((ch1 or 1) - 1, 0, 15)
end

local function starts_with_rsn(msg)
  if not msg or #msg < 5 then return false end
  if msg:byte(1) ~= 0x7D then return false end
  if msg:byte(2) ~= string.byte("R") then return false end
  if msg:byte(3) ~= string.byte("S") then return false end
  if msg:byte(4) ~= string.byte("N") then return false end
  return true
end

local function pack_slide_sysex(bend_chan, base_pitch, start_pitch, target_pitch, start_vel, target_vel, dur_ms)
  dur_ms = clamp(round(dur_ms), 0, 16383)
  local lo = dur_ms & 0x7F
  local hi = (dur_ms >> 7) & 0x7F

  -- payload only; REAPER adds F0/F7 for type=-1 sysex events
  return string.char(
    SIG[1], SIG[2], SIG[3], SIG[4], SIG[5],
    clamp(bend_chan, 0, 15),
    clamp(base_pitch, 0, 127),
    clamp(start_pitch, 0, 127),
    clamp(target_pitch, 0, 127),
    clamp(start_vel, 0, 127),
    clamp(target_vel, 0, 127),
    lo, hi
  )
end

local function get_tempo_map_signature(proj)
  local parts = {}
  local count = reaper.CountTempoTimeSigMarkers(proj)
  parts[#parts + 1] = tostring(count)

  for i = 0, count - 1 do
    local ok, timepos, measurepos, beatpos, bpm, num, denom, lineartempo =
      reaper.GetTempoTimeSigMarker(proj, i)

    if ok then
      parts[#parts + 1] = table.concat({
        string.format("%.12f", timepos),
        tostring(measurepos),
        string.format("%.12f", beatpos),
        string.format("%.12f", bpm),
        tostring(num),
        tostring(denom),
        lineartempo and "1" or "0",
      }, "|")
    end
  end

  return table.concat(parts, "\n")
end

local function clear_old_generated_sysex(take)
  local _, _, _, text_count = reaper.MIDI_CountEvts(take)

  for i = text_count - 1, 0, -1 do
    local ok, _, _, _, typ, msg =
      reaper.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, "")
    if ok and typ == -1 and starts_with_rsn(msg) then
      reaper.MIDI_DeleteTextSysexEvt(take, i)
    end
  end
end

local function collect_notes(take, slide_chan)
  local _, note_count = reaper.MIDI_CountEvts(take)

  local base_notes = {}
  local slide_notes = {}

  for i = 0, note_count - 1 do
    local ok, sel, muted, s, e, ch, pitch, vel =
      reaper.MIDI_GetNote(take, i)

    if ok then
      local n = {
        idx = i,
        sel = sel,
        muted = muted,
        s = s,
        e = e,
        ch = ch,
        pitch = pitch,
        vel = vel,
      }

      if ch == slide_chan then
        slide_notes[#slide_notes + 1] = n
      elseif not muted then
        base_notes[#base_notes + 1] = n
      end
    end
  end

  table.sort(base_notes, function(a, b)
    if a.s == b.s then return a.e < b.e end
    return a.s < b.s
  end)

  table.sort(slide_notes, function(a, b)
    if a.s == b.s then return a.e < b.e end
    return a.s < b.s
  end)

  return base_notes, slide_notes
end

local function maybe_mute_slide_notes(take, slide_notes)
  if not MUTE_SLIDE_MARKERS then return end

  for _, n in ipairs(slide_notes) do
    if not n.muted then
      reaper.MIDI_SetNote(
        take, n.idx,
        nil, true, nil, nil, nil, nil, nil,
        true
      )
    end
  end
end

local function encode_take(take)
  local slide_chan = human_to_reaper_channel(SLIDE_CHANNEL_1BASED)
  local take_pitch_offset = round(reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"))

  reaper.MIDI_DisableSort(take)
  clear_old_generated_sysex(take)

  local base_notes, slide_notes = collect_notes(take, slide_chan)
  maybe_mute_slide_notes(take, slide_notes)

  if #base_notes == 0 then
    reaper.MIDI_Sort(take)
    reaper.MIDI_RefreshEditors(take)
    return false
  end

  for i, base in ipairs(base_notes) do
    local next_base_start = math.huge
    if i < #base_notes then
      next_base_start = base_notes[i + 1].s
    end

    local bend_chan =
      FOLLOW_BASE_NOTE_CHANNEL
      and base.ch
      or human_to_reaper_channel(FIXED_BEND_CHANNEL_1BASED)

    local effective_base_pitch = clamp(base.pitch + take_pitch_offset, 0, 127)
    local current_pitch = effective_base_pitch
    local current_vel = base.vel

    for _, slide in ipairs(slide_notes) do
      -- 次の通常ノートが来たら、そこから先はこの base には属さない
      if slide.s >= next_base_start then
        break
      end

      -- slide の開始は、この base の開始以降で、次ノート開始より前なら有効
      -- base.e を越えていても、release 区間として扱う
      if slide.s >= base.s and slide.s < next_base_start and slide.e > slide.s then
        local seg_start = slide.s
        local seg_end = slide.e

        -- 終点は slide ノート終点を優先
        -- ただし次の通常ノート開始は越えない
        if seg_end > next_base_start then
          seg_end = next_base_start
        end

        if seg_end > seg_start then
          local t0 = reaper.MIDI_GetProjTimeFromPPQPos(take, seg_start)
          local t1 = reaper.MIDI_GetProjTimeFromPPQPos(take, seg_end)
          local dur_ms = math.max(1, (t1 - t0) * 1000.0)

          local effective_target_pitch = clamp(slide.pitch + take_pitch_offset, 0, 127)

          local payload = pack_slide_sysex(
            bend_chan,
            effective_base_pitch,
            current_pitch,
            effective_target_pitch,
            current_vel,
            slide.vel,
            dur_ms
          )

          reaper.MIDI_InsertTextSysexEvt(
            take,
            false,  -- selected
            false,  -- muted
            seg_start,
            -1,
            payload
          )

          current_pitch = effective_target_pitch
          current_vel = slide.vel
        end
      end
    end
  end

  reaper.MIDI_Sort(take)
  reaper.MIDI_RefreshEditors(take)
  return true
end

local function iter_target_takes()
  local results = {}

  local item_count = reaper.CountMediaItems(0)
  for i = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
      if PROCESS_ONLY_ACTIVE_TAKES then
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          results[#results + 1] = take
        end
      else
        local tk_count = reaper.CountTakes(item)
        for t = 0, tk_count - 1 do
          local take = reaper.GetTake(item, t)
          if take and reaper.TakeIsMIDI(take) then
            results[#results + 1] = take
          end
        end
      end
    end
  end

  return results
end

local function refresh_changed_takes(force_all)
  local takes = iter_target_takes()
  local tempo_sig = get_tempo_map_signature(0)

  for _, take in ipairs(takes) do
    local ok_guid, key = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
    if not ok_guid or key == "" then
      key = tostring(take)
    end

    local ok, hash = reaper.MIDI_GetHash(take, true, "")
    if ok then
      local prev = state_by_take[key]
      local must_encode = false

      if force_all then
        must_encode = true
      elseif not prev then
        must_encode = true
      elseif prev.note_hash ~= hash then
        must_encode = true
      elseif prev.tempo_sig ~= tempo_sig then
        must_encode = true
      end

      if must_encode then
        encode_take(take)

        local ok2, hash2 = reaper.MIDI_GetHash(take, true, "")
        state_by_take[key] = {
          note_hash = ok2 and hash2 or hash,
          tempo_sig = tempo_sig,
        }
      end
    end
  end

  last_tempo_sig = tempo_sig
end

local function is_playing_or_recording(play_state)
  if (play_state & 1) == 1 then return true end
  if (play_state & 4) == 4 then return true end
  return false
end

local function main()
  local ps = reaper.GetPlayState()
  local was_running = is_playing_or_recording(last_play_state)
  local is_running = is_playing_or_recording(ps)

  -- stopped -> play/record の瞬間だけ再生成
  if is_running and not was_running then
    refresh_changed_takes(false)
  end

  last_play_state = ps
  reaper.defer(main)
end

local function init()
  last_play_state = reaper.GetPlayState()
  refresh_changed_takes(true)
  main()
end

reaper.atexit(function()
end)

init()
