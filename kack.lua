-- install_os.lua - Installateur d'OS depuis disque floppy CC
-- A placer sur le disque avec le nouveau startup.lua

local function cls()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function println(text, color)
  term.setTextColor(color or colors.white)
  print(text)
  term.setTextColor(colors.white)
end

local function confirm(question)
  term.setTextColor(colors.yellow)
  io.write(question .. " (oui/non) : ")
  term.setTextColor(colors.white)
  local rep = read()
  return rep == "oui" or rep == "o"
end

-- Trouve le disque
local function findDisk()
  local sides = {"top","bottom","left","right","front","back"}
  for _, side in ipairs(sides) do
    if disk and disk.isPresent(side) and disk.hasData(side) then
      return disk.getMountPath(side)
    end
  end
  return nil
end

-- ==================
-- INSTALLATION
-- ==================

cls()
println("=== INSTALLATEUR OS - ComputerCraft ===", colors.cyan)
print("")

local diskPath = findDisk()
if not diskPath then
  println("Aucun disque detecte !", colors.red)
  println("Insere un disque floppy avec le nouvel OS.", colors.yellow)
  sleep(3)
  return
end

-- Verifie que le nouvel OS est present sur le disque
if not fs.exists(diskPath .. "/startup.lua") then
  println("Erreur : startup.lua absent du disque !", colors.red)
  sleep(3)
  return
end

println("Disque detecte : " .. diskPath, colors.green)
println("Nouvel OS trouve sur le disque.", colors.green)
print("")
println("Ce script va :", colors.white)
println("  1. Supprimer l'ancien OS (/startup.lua, /secureos)", colors.orange)
println("  2. Installer le nouvel OS depuis le disque", colors.orange)
println("  3. Redemarrer", colors.orange)
print("")

if not confirm("Confirmer l'installation ?") then
  println("Annule.", colors.red)
  sleep(1)
  return
end

if not confirm("Derniere confirmation - ecraser l'OS actuel ?") then
  println("Annule.", colors.red)
  sleep(1)
  return
end

print("")
println("Installation en cours...", colors.yellow)

-- Supprime l'ancien OS
if fs.exists("/startup.lua") then
  fs.delete("/startup.lua")
  println("Ancien startup.lua supprime.", colors.lightGray)
end

-- Supprime les donnees de l'ancien OS si present
if fs.exists("/secureos") then
  if confirm("Supprimer aussi les donnees /secureos ?") then
    fs.delete("/secureos")
    println("/secureos supprime.", colors.lightGray)
  end
end

-- Copie le nouvel OS
fs.copy(diskPath .. "/startup.lua", "/startup.lua")

if fs.exists("/startup.lua") then
  println("Nouvel OS installe avec succes !", colors.green)
else
  println("ERREUR : installation echouee !", colors.red)
  sleep(3)
  return
end

print("")
println("Installation terminee. Redemarrage dans 3s...", colors.cyan)
println("(Retire le disque maintenant si necessaire)", colors.yellow)
sleep(3)
os.reboot()
