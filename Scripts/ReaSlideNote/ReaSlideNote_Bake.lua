-- @noindex

local SLIDE_CHANNEL_1BASED = 16
local NEW_TRACK_SUFFIX = " [Baked]"
local DEFAULT_BEND_RANGE = 12
local BAKE_STEP_MS = 5.0

-- tiny offsets so the reset happens just before the next note
local HOLD_EPS_PPQ = 0.02
local RESET_EPS_PPQ = 0.01

local function msg(s)
  reaper.ShowMessageBox(s, "ReaSlideNote Bake", 0)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function semis_to_bend14(semis, bend_range)
  local v = 8192
  if bend_range > 0 then
    v = 8192 + (semis / bend_range) * 8192
    v = math.floor(clamp(v, 0, 16383) + 0.5)
  end
  return v
end

local function ppq_to_time(take, ppq)
  return reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
end

local function time_to_ppq(take, t)
  return reaper.MIDI_GetPPQPosFromProjTime(take, t)
end

local function insert_pitch_bend_ppq(take, ppq, chan, bend14)
  ppq = math.max(0, ppq)
  bend14 = math.floor(clamp(bend14, 0, 16383) + 0.5)
  chan = math.floor(clamp(chan, 0, 15))

  local status = 0xE0 | chan
  local lsb = bend14 % 128
  local msb = math.floor(bend14 / 128)

  local bytes = string.char(status, lsb, msb)
  reaper.MIDI_InsertEvt(take, false, false, ppq, bytes)
end

local function collect_notes(take, slide_chan0)
  local _, note_count, _, _ = reaper.MIDI_CountEvts(take)

  local base_notes = {}
  local slide_notes = {}

  for i = 0, note_count - 1 do
    local ok, sel, muted, s, e, ch, pitch, vel = reaper.MIDI_GetNote(take, i)
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

      if ch == slide_chan0 then
        -- keep slide notes even if muted: ReaSlideNote often mutes them
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

local function copy_base_notes(src_take, dst_take, base_notes)
  for _, n in ipairs(base_notes) do
    local st = ppq_to_time(src_take, n.s)
    local et = ppq_to_time(src_take, n.e)
    local ds = time_to_ppq(dst_take, st)
    local de = time_to_ppq(dst_take, et)

    reaper.MIDI_InsertNote(
      dst_take,
      n.sel,
      false,
      ds,
      de,
      n.ch,
      n.pitch,
      n.vel,
      true
    )
  end
end

local function get_track_name(track)
  local _, name = reaper.GetTrackName(track)
  if not name or name == "" then
    name = "Track"
  end
  return name
end

local function get_reaslidenote_bend_range(track)
  local fx_count = reaper.TrackFX_GetCount(track)
  local fallback = DEFAULT_BEND_RANGE

  for fx = 0, fx_count - 1 do
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx, "")
    if fx_name and fx_name:lower():find("reaslidenote", 1, true) then
      local param_count = reaper.TrackFX_GetNumParams(track, fx)

      -- First try by param name
      for p = 0, param_count - 1 do
        local _, pname = reaper.TrackFX_GetParamName(track, fx, p, "")
        if pname and pname:lower():find("bend range", 1, true) then
          local val, minval, maxval = reaper.TrackFX_GetParam(track, fx, p)
          if val ~= nil and minval ~= nil and maxval ~= nil then
            -- slider1:bend_range=12<1,48,1>...
            -- JSFX params here are returned in real parameter units for sliders
            local range = math.floor(val + 0.5)
            return clamp(range, 1, 48), fx_name
          end
        end
      end

      -- Fallback: assume first parameter is bend range
      if param_count > 0 then
        local val = reaper.TrackFX_GetParam(track, fx, 0)
        if val ~= nil then
          local range = math.floor(val + 0.5)
          return clamp(range, 1, 48), fx_name
        end
      end
    end
  end

  return fallback, nil
end

local function bake_pitch_bend(src_take, dst_take, base_notes, slide_notes, bend_range, step_ms)
  if #base_notes == 0 then return end

  local item = reaper.GetMediaItemTake_Item(src_take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end_time = item_pos + item_len
  local item_end_ppq_src = time_to_ppq(src_take, item_end_time)

  local step_sec = step_ms / 1000.0

  for i, base in ipairs(base_notes) do
    local next_base_start_ppq = item_end_ppq_src
    if i < #base_notes then
      next_base_start_ppq = base_notes[i + 1].s
    end
    if next_base_start_ppq > item_end_ppq_src then
      next_base_start_ppq = item_end_ppq_src
    end

    local base_pitch = base.pitch
    local current_pitch = base.pitch
    local base_start_time = ppq_to_time(src_take, base.s)
    local base_start_ppq_dst = time_to_ppq(dst_take, base_start_time)
    local chan = base.ch

    -- Start centered at the base note start
    insert_pitch_bend_ppq(dst_take, base_start_ppq_dst, chan, 8192)

    for _, slide in ipairs(slide_notes) do
      if slide.s >= next_base_start_ppq then
        break
      end

      -- release slides are valid too:
      -- after base note start, before next base note start
      if slide.s >= base.s and slide.s < next_base_start_ppq and slide.e > slide.s then
        local seg_start_ppq = slide.s
        local seg_end_ppq = math.min(slide.e, next_base_start_ppq)

        if seg_end_ppq > seg_start_ppq then
          local seg_start_time = ppq_to_time(src_take, seg_start_ppq)
          local seg_end_time = ppq_to_time(src_take, seg_end_ppq)
          local seg_start_ppq_dst = time_to_ppq(dst_take, seg_start_time)

          -- hold current pitch until the slide starts
          local hold_bend = semis_to_bend14(current_pitch - base_pitch, bend_range)
          insert_pitch_bend_ppq(dst_take, seg_start_ppq_dst, chan, hold_bend)

          local start_pitch = current_pitch
          local target_pitch = slide.pitch
          local dur = seg_end_time - seg_start_time

          if dur <= 0 then
            local target_bend = semis_to_bend14(target_pitch - base_pitch, bend_range)
            insert_pitch_bend_ppq(dst_take, seg_start_ppq_dst, chan, target_bend)
          else
            local t = seg_start_time
            while t < seg_end_time do
              local frac = (t - seg_start_time) / dur
              frac = clamp(frac, 0, 1)
              local p = start_pitch + (target_pitch - start_pitch) * frac
              local bend = semis_to_bend14(p - base_pitch, bend_range)
              local ppq_dst = time_to_ppq(dst_take, t)
              insert_pitch_bend_ppq(dst_take, ppq_dst, chan, bend)
              t = t + step_sec
            end

            local end_bend = semis_to_bend14(target_pitch - base_pitch, bend_range)
            local seg_end_ppq_dst = time_to_ppq(dst_take, seg_end_time)
            insert_pitch_bend_ppq(dst_take, seg_end_ppq_dst, chan, end_bend)
          end

          current_pitch = target_pitch
        end
      end
    end

    local region_end_time = ppq_to_time(src_take, next_base_start_ppq)
    local region_end_ppq_dst = time_to_ppq(dst_take, region_end_time)
    local final_bend = semis_to_bend14(current_pitch - base_pitch, bend_range)

    if i < #base_notes then
      -- keep the current bend right up to the next note,
      -- then reset just before the next note starts
      local hold_ppq = math.max(base_start_ppq_dst, region_end_ppq_dst - HOLD_EPS_PPQ)
      local reset_ppq = math.max(base_start_ppq_dst, region_end_ppq_dst - RESET_EPS_PPQ)

      insert_pitch_bend_ppq(dst_take, hold_ppq, chan, final_bend)
      insert_pitch_bend_ppq(dst_take, reset_ppq, chan, 8192)
    else
      -- last region: keep the final bend through the item end
      insert_pitch_bend_ppq(dst_take, region_end_ppq_dst, chan, final_bend)
    end
  end
end

local function get_or_create_baked_track(src_track, track_map)
  local key = tostring(src_track)
  if track_map[key] then
    return track_map[key]
  end

  local src_track_num = math.floor(reaper.GetMediaTrackInfo_Value(src_track, "IP_TRACKNUMBER"))
  reaper.InsertTrackInProject(0, src_track_num, 0)
  local baked_track = reaper.GetTrack(0, src_track_num)

  reaper.GetSetMediaTrackInfo_String(
    baked_track,
    "P_NAME",
    get_track_name(src_track) .. NEW_TRACK_SUFFIX,
    true
  )

  track_map[key] = baked_track
  return baked_track
end

local function get_selected_midi_items()
  local items = {}
  local cnt = reaper.CountSelectedMediaItems(0)

  for i = 0, cnt - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item) or nil
    if take and reaper.TakeIsMIDI(take) then
      items[#items + 1] = item
    end
  end

  table.sort(items, function(a, b)
    local ta = reaper.GetMediaItemTrack(a)
    local tb = reaper.GetMediaItemTrack(b)
    local na = reaper.GetMediaTrackInfo_Value(ta, "IP_TRACKNUMBER")
    local nb = reaper.GetMediaTrackInfo_Value(tb, "IP_TRACKNUMBER")
    if na == nb then
      local pa = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
      local pb = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
      return pa < pb
    end
    return na < nb
  end)

  return items
end

local function main()
  local items = get_selected_midi_items()
  if #items == 0 then
    msg("Select one or more MIDI items first.")
    return
  end

  local slide_chan0 = SLIDE_CHANNEL_1BASED - 1
  local baked_track_map = {}
  local track_bend_range_cache = {}
  local warnings = {}

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local baked_count = 0

  for _, item in ipairs(items) do
    local src_take = reaper.GetActiveTake(item)
    if src_take and reaper.TakeIsMIDI(src_take) then
      local src_track = reaper.GetMediaItemTrack(item)
      local src_key = tostring(src_track)

      local bend_range = track_bend_range_cache[src_key]
      if not bend_range then
        local found_range, fx_name = get_reaslidenote_bend_range(src_track)
        bend_range = found_range
        track_bend_range_cache[src_key] = bend_range

        if not fx_name then
          warnings[#warnings + 1] =
            string.format("Track '%s': ReaSlideNote not found, using bend range %d.",
              get_track_name(src_track), bend_range)
        end
      end

      local baked_track = get_or_create_baked_track(src_track, baked_track_map)

      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_pos + item_len

      local new_item = reaper.CreateNewMIDIItemInProj(baked_track, item_pos, item_end, false)
      local dst_take = new_item and reaper.GetActiveTake(new_item) or nil

      if dst_take and reaper.TakeIsMIDI(dst_take) then
        local base_notes, slide_notes = collect_notes(src_take, slide_chan0)

        reaper.MIDI_DisableSort(dst_take)
        copy_base_notes(src_take, dst_take, base_notes)
        bake_pitch_bend(src_take, dst_take, base_notes, slide_notes, bend_range, BAKE_STEP_MS)
        reaper.MIDI_Sort(dst_take)

        baked_count = baked_count + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("ReaSlideNote: bake selected items to new track (auto bend range, no FX copy)", -1)

  if baked_count == 0 then
    msg("No MIDI items were baked.")
    return
  end

  if #warnings > 0 then
    msg(table.concat(warnings, "\n"))
  end
end

main()
