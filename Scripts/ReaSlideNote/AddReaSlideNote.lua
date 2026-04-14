-- @noindex

local FX_NAME = "JS:ReaSlideNote"

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.ShowMessageBox("トラックが選択されていません。", "ReaScript", 0)
  return
end

reaper.Undo_BeginBlock()

local fx_index = reaper.TrackFX_AddByName(track, FX_NAME, false, -1000)

if fx_index < 0 then
  reaper.ShowMessageBox("FXを追加できませんでした。\nFX名を確認してください。", "ReaScript", 0)
end

reaper.Undo_EndBlock("Add specific FX to top of selected track FX chain", -1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()

