local f = io.open(os.getenv("TYPE_FILE")); local txt = f:read("a"); f:close()
txt = txt:gsub("\\n", "\n")
local lines = {}
for l in txt:gmatch("([^\n]*)\n") do lines[#lines + 1] = l .. "\n" end
local scr = manager.machine.screens:at(1)
local nxt, i = 400, 1
local snaps = {}
for f in string.gmatch(os.getenv("SNAP_FRAMES") or "", "%d+") do snaps[tonumber(f)] = true end
sub = emu.add_machine_frame_notifier(function()
  local n = scr:frame_number()
  if not manager.machine.natkeyboard.empty then nxt = n + 60   -- 1 s after the last key
  elseif i <= #lines and n >= nxt then
    manager.machine.natkeyboard:post(lines[i]); i = i + 1; nxt = n + 60
  end
  if snaps[n] then scr:snapshot(string.format("snd_f%05d.png", n)) end
end)
