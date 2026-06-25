-- SecureClickOS-Cashout: shop
-- CryptoShop v2.0 - Prix dynamiques (offre/demande)
-- Plus on achete -> stock baisse -> prix monte automatiquement
-- Aucun serveur requis : le fichier stock suffit

local VERSION    = "2.0"
local SHOP_ACCT  = "shop"
local STOCK_FILE = "/cryptoshop_stock.db"
local WALLET_F   = "/cryptoshop_wallet.db"
local MARGIN     = 0.88   -- prix vente = 88% du prix achat

local w, h = term.getSize()

-- ═══════════════════════════════════════
-- CATALOGUE  (basePrice = prix au stock a moitie)
-- ═══════════════════════════════════════

local COINS = {
  { id="BTC", name="Bitcoin",         symbol="BTC", icon="B",
    color=colors.orange, basePrice=100, initStock=2000 },
  { id="RBX", name="Robux",           symbol="RBX", icon="R",
    color=colors.cyan,   basePrice=5,   initStock=2000 },
  { id="FRT", name="Fortnite VBucks", symbol="FRT", icon="F",
    color=colors.blue,   basePrice=8,   initStock=2000 },
  { id="RGR", name="Ragnar",          symbol="RGR", icon="G",
    color=colors.purple, basePrice=15,  initStock=2000 },
}

-- ═══════════════════════════════════════
-- PRIX DYNAMIQUES  (cœur du systeme)
-- ═══════════════════════════════════════
--
--  ratio = stock_actuel / stock_initial   (0.0 a 1.0)
--  multiplicateur = 2.2 - ratio * 1.4
--    stock plein  (ratio=1.0) -> x0.80  -> prix bas   (beaucoup de dispo)
--    stock moitie (ratio=0.5) -> x1.50  -> prix moyen
--    stock vide   (ratio=0.0) -> x2.20  -> prix haut  (rare = cher)
--
--  Prix vente = prix achat * MARGIN (12% de spread toujours)

local function calcPrices(coin, stockQty)
  local ratio = math.max(0, math.min(1,
    (stockQty or coin.initStock) / coin.initStock))
  local mult  = 2.2 - ratio * 1.4
  local buy   = math.max(1, math.ceil(coin.basePrice  * mult))
  local sell  = math.max(1, math.floor(buy * MARGIN))
  return buy, sell
end

-- Indicateur de tendance (compare prix actuel a l'historique)
local function trend(history, currentBuy)
  if not history or #history < 2 then return "~", colors.lightGray end
  local prev = history[#history - 1]
  if currentBuy > prev then return "^", colors.red    end  -- prix monte
  if currentBuy < prev then return "v", colors.green  end  -- prix baisse
  return "=", colors.lightGray
end

-- ═══════════════════════════════════════
-- SAUVEGARDE
-- ═══════════════════════════════════════

local function loadT(path, def)
  if not fs.exists(path) then return def end
  local f = fs.open(path,"r"); if not f then return def end
  local d = f.readAll(); f.close()
  local ok,v = pcall(textutils.unserialize,d)
  return (ok and type(v)=="table") and v or def
end

local function saveT(path, v)
  local f = fs.open(path,"w"); if not f then return end
  f.write(textutils.serialize(v)); f.close()
end

local function loadStock()
  local s = loadT(STOCK_FILE, {})
  for _, c in ipairs(COINS) do
    if not s[c.id]         then s[c.id]         = c.initStock end
    if not s[c.id.."_hist"] then s[c.id.."_hist"] = {} end
  end
  return s
end

local function loadWallet()
  local wl = loadT(WALLET_F, {})
  for _, c in ipairs(COINS) do
    if not wl[c.id] then wl[c.id] = 0 end
  end
  return wl
end

-- Pousse le prix actuel dans l'historique (max 16 entrees)
local function pushHistory(stock, coinId, buyPrice)
  local hist = stock[coinId.."_hist"] or {}
  hist[#hist+1] = buyPrice
  if #hist > 16 then table.remove(hist,1) end
  stock[coinId.."_hist"] = hist
end

local function getCoin(id)
  for _, c in ipairs(COINS) do if c.id==id then return c end end
end

-- ═══════════════════════════════════════
-- AFFICHAGE
-- ═══════════════════════════════════════

local function cls()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear(); term.setCursorPos(1,1)
end

local function at(x,y,s,fg,bg)
  if x<1 or x>w or y<1 or y>h then return end
  term.setCursorPos(x,y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(tostring(s or ""))
end

local function fillRow(y,bg,fg)
  term.setCursorPos(1,y)
  term.setBackgroundColor(bg or colors.black)
  term.setTextColor(fg or colors.white)
  term.write(string.rep(" ",w))
end

local function mid(y,s,fg,bg)
  s=tostring(s or "")
  at(math.max(1,math.floor((w-#s)/2)+1),y,s,fg,bg)
end

local function lpad(s,n) s=tostring(s); return string.rep(" ",math.max(0,n-#s))..s end
local function rpad(s,n) s=tostring(s); return s..string.rep(" ",math.max(0,n-#s)) end

-- Mini graphique ASCII de l'historique des prix
local function drawMiniChart(x, y, cw, ch, history, col)
  if not history or #history < 2 then
    at(x,y,string.rep("-",cw),colors.gray,colors.black); return
  end
  local lo,hi=math.huge,-math.huge
  for _,v in ipairs(history) do
    if v<lo then lo=v end
    if v>hi then hi=v end
  end
  if hi==lo then hi=lo+1 end
  -- Trace les points sur une ligne
  local pts={}
  local n=math.min(#history,cw)
  for i=1,n do
    local v=history[#history-n+i]
    pts[i]=math.floor((v-lo)/(hi-lo)*(ch-1)+0.5)
  end
  -- Dessine
  for row=ch-1,0,-1 do
    term.setCursorPos(x,y+(ch-1-row))
    term.setTextColor(col or colors.green)
    term.setBackgroundColor(colors.black)
    for i=1,n do
      if pts[i]==row then
        term.write("*")
      elseif pts[i]>row then
        term.write("|")
      else
        term.write(" ")
      end
    end
    -- Remplit si moins de cw points
    if n<cw then term.write(string.rep(" ",cw-n)) end
  end
end

-- ═══════════════════════════════════════
-- BOUTONS
-- ═══════════════════════════════════════

local Btns={}
local function resetBtns() Btns={} end

local function addBtn(id,x,y,bw,bh,label,bg,fg)
  fg=fg or colors.black; label=tostring(label or "")
  for r=0,bh-1 do
    term.setCursorPos(x,y+r)
    term.setBackgroundColor(bg); term.setTextColor(fg)
    term.write(string.rep(" ",bw))
  end
  at(x+math.floor((bw-#label)/2),y+math.floor(bh/2),label,fg,bg)
  Btns[#Btns+1]={id=id,x=x,y=y,w=bw,h=bh}
end

local function clickBtn(mx,my)
  for _,b in ipairs(Btns) do
    if mx>=b.x and mx<b.x+b.w and my>=b.y and my<b.y+b.h then return b.id end
  end
end

-- ═══════════════════════════════════════
-- SAISIE TEXTE
-- ═══════════════════════════════════════

local function inputText(x,y,maxW)
  at(x,y,string.rep(" ",maxW),colors.black,colors.white)
  term.setCursorPos(x,y); term.setCursorBlink(true)
  term.setTextColor(colors.black); term.setBackgroundColor(colors.white)
  local text=""
  while true do
    local ev,k=os.pullEventRaw()
    if ev=="char" and #text<maxW then
      text=text..k
      at(x,y,string.rep(" ",maxW),colors.black,colors.white)
      at(x,y,text,colors.black,colors.white)
      term.setCursorPos(x+#text,y)
    elseif ev=="key" then
      if k==keys.enter then break
      elseif k==keys.backspace and #text>0 then
        text=text:sub(1,-2)
        at(x,y,string.rep(" ",maxW),colors.black,colors.white)
        at(x,y,text,colors.black,colors.white)
        term.setCursorPos(x+#text,y)
      end
    end
  end
  term.setCursorBlink(false); return text
end

-- ═══════════════════════════════════════
-- POPUP
-- ═══════════════════════════════════════

local function popup(title,lines,titleBg)
  titleBg=titleBg or colors.gray
  local bw=math.min(w-4,44); local bh=#lines+4
  local bx=math.floor((w-bw)/2)+1; local by=math.floor((h-bh)/2)+1
  for r=0,bh-1 do
    term.setCursorPos(bx,by+r)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ",bw))
  end
  fillRow(by,titleBg)
  mid(by,tostring(title),colors.black,titleBg)
  for i,line in ipairs(lines) do
    at(bx+2,by+1+i,tostring(line),colors.white,colors.gray)
  end
  resetBtns()
  addBtn("ok",bx+math.floor((bw-8)/2),by+bh-1,8,1,"  OK  ",colors.orange,colors.black)
  while true do
    local ev,_,mx,my=os.pullEvent()
    if ev=="mouse_click" and clickBtn(mx,my)=="ok" then resetBtns(); return end
    if ev=="key" and _==keys.enter then resetBtns(); return end
  end
end

-- ═══════════════════════════════════════
-- VERIF BANQUE
-- ═══════════════════════════════════════

local function bankOk()
  if not bank then return false,"API bank manquante" end
  if not bank.configured then return false,"bank.configured manquant" end
  if not bank.configured() then return false,"Configure Banque > Paiements" end
  return true
end

-- ═══════════════════════════════════════
-- CONFIRMATION TRANSACTION
-- ═══════════════════════════════════════

local function confirmBox(lines, accentCol)
  accentCol=accentCol or colors.orange
  local bw=40; local bx=math.floor((w-bw)/2)+1; local by=5
  local bh=#lines+4
  for r=0,bh-1 do
    term.setCursorPos(bx,by+r)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ",bw))
  end
  fillRow(by,accentCol)
  mid(by,"Confirmer ?",colors.black,accentCol)
  for i,line in ipairs(lines) do
    at(bx+2,by+1+i,tostring(line),colors.white,colors.gray)
  end
  resetBtns()
  addBtn("yes",bx+2,    by+bh-1,16,1,"Confirmer",colors.green,colors.black)
  addBtn("no", bx+22,   by+bh-1,16,1,"Annuler",  colors.red,  colors.white)
  while true do
    local ev,_,mx,my=os.pullEvent()
    if ev=="mouse_click" then
      local id=clickBtn(mx,my)
      if id=="yes" then resetBtns(); return true end
      if id=="no"  then resetBtns(); return false end
    elseif ev=="key" then
      if _==keys.enter then resetBtns(); return true end
      if _==keys.q     then resetBtns(); return false end
    end
  end
end

-- ═══════════════════════════════════════
-- ECRAN DETAIL / ACHAT / VENTE
-- ═══════════════════════════════════════

local function coinScreen(coin, stock, wallet)
  local qty=1
  local mode="buy"  -- "buy" ou "sell"

  while true do
    local stockQty = stock[coin.id] or 0
    local walletQty= wallet[coin.id] or 0
    local hist     = stock[coin.id.."_hist"] or {}
    local buy,sell = calcPrices(coin, stockQty)
    local trendChar, trendCol = trend(hist, buy)

    resetBtns()
    cls()

    -- En-tete coloree coin
    fillRow(1,coin.color)
    at(2,1,coin.icon.." "..coin.name.." ("..coin.symbol..")",colors.black,coin.color)
    at(w-9,1,"v"..VERSION,colors.black,coin.color)

    -- Prix dynamique
    fillRow(2,colors.gray)
    at(2, 2,"Achat : "..buy.."$",   colors.green, colors.gray)
    at(16,2,"Vente : "..sell.."$",  colors.cyan,  colors.gray)
    at(30,2,"Tendance : ",          colors.white, colors.gray)
    at(41,2,trendChar,              trendCol,     colors.gray)

    -- Jauge de stock (barre visuelle)
    fillRow(3,colors.black)
    local ratio=stockQty/coin.initStock
    local barW=w-24
    local filled=math.floor(ratio*barW)
    at(2, 3,"Stock: "..lpad(tostring(stockQty),4).." ",
      ratio<0.2 and colors.red or (ratio<0.5 and colors.orange or colors.white),
      colors.black)
    at(12,3,"[",colors.gray,colors.black)
    -- Barre coloree selon remplissage
    local barCol=ratio<0.2 and colors.red or (ratio<0.5 and colors.orange or colors.green)
    term.setCursorPos(13,3)
    term.setTextColor(barCol); term.setBackgroundColor(colors.black)
    term.write(string.rep("|",filled)..string.rep(".",barW-filled))
    at(13+barW,3,"]",colors.gray,colors.black)
    at(w-8,3,lpad(math.floor(ratio*100).."%",5),barCol,colors.black)

    -- Portefeuille
    at(2,4,"Ton portefeuille : "..walletQty.." "..coin.symbol,
      walletQty>0 and colors.yellow or colors.lightGray,colors.black)
    at(w-20,4,"~"..walletQty*sell.."$ (valeur)",colors.lightGray,colors.black)

    -- Mini graphique historique
    fillRow(5,colors.black)
    at(2,5,"Historique prix :",colors.lightGray,colors.black)
    if #hist>=2 then
      local chartW=math.min(#hist,w-22)
      drawMiniChart(20,5,chartW,1,hist,
        trendChar=="^" and colors.red or
        trendChar=="v" and colors.green or colors.lightGray)
      at(20+chartW+1,5,
        "min:"..math.min(table.unpack(hist)).."$ max:"..math.max(table.unpack(hist)).."$",
        colors.lightGray,colors.black)
    else
      at(20,5,"(pas encore d'historique)",colors.gray,colors.black)
    end

    -- Onglets Buy/Sell
    addBtn("tab_buy", 2,    7, math.floor((w-4)/2), 1,
      "[ ACHETER ]", mode=="buy" and colors.green or colors.gray,
      mode=="buy" and colors.black or colors.lightGray)
    addBtn("tab_sell",math.floor((w-4)/2)+4, 7, math.floor((w-4)/2), 1,
      "[ VENDRE ]", mode=="sell" and colors.cyan or colors.gray,
      mode=="sell" and colors.black or colors.lightGray)

    -- Selecteur quantite
    fillRow(9,colors.black)
    at(2,9,"Quantite :",colors.white,colors.black)
    addBtn("q1", 14,9,4,1," 1 ",  colors.gray,colors.white)
    addBtn("q5", 19,9,4,1," 5 ",  colors.gray,colors.white)
    addBtn("q10",24,9,5,1," 10 ", colors.gray,colors.white)
    addBtn("q50",30,9,5,1," 50 ", colors.gray,colors.white)
    addBtn("q-", 36,9,3,1," - ",  colors.red, colors.white)
    addBtn("q+", 40,9,3,1," + ",  colors.green,colors.black)

    fillRow(10,colors.black)
    at(2,10,"Quantite choisie : ",colors.lightGray,colors.black)
    at(22,10,tostring(qty).." "..coin.symbol,colors.yellow,colors.black)

    -- Saisie libre
    at(2,11,"Montant libre : ",colors.lightGray,colors.black)
    addBtn("manual",19,11,10,1,"[ Saisir ]",colors.gray,colors.lightGray)

    -- Total
    fillRow(12,colors.black)
    if mode=="buy" then
      local total=qty*buy
      at(2,12,"Total a PAYER : "..total.."$",colors.green,colors.black)
      at(w-22,12,"("..buy.."$ x "..qty..")",colors.lightGray,colors.black)
      addBtn("action",2,h-2,math.floor((w-4)/2),2,
        "ACHETER -> -"..total.."$",colors.green,colors.black)
    else
      local gain=qty*sell
      at(2,12,"Tu RECOIS : +"..gain.."$",colors.cyan,colors.black)
      at(w-22,12,"("..sell.."$ x "..qty..")",colors.lightGray,colors.black)
      addBtn("action",2,h-2,math.floor((w-4)/2),2,
        "VENDRE -> +"..gain.."$",colors.cyan,colors.black)
    end
    addBtn("back",math.floor((w-4)/2)+4,h-2,math.floor((w-4)/2),2,
      "Retour",colors.red,colors.white)

    fillRow(h,colors.gray)
    at(2,h,coin.symbol..
      " | Stock: "..stockQty..
      " | Prix achat: "..buy.."$ | Prix vente: "..sell.."$",
      colors.white,colors.gray)

    -- Evenements
    while true do
      local ev,_,mx,my=os.pullEvent()
      if ev=="mouse_click" then
        local id=clickBtn(mx,my)
        if not id then break end

        if id=="back"     then return
        elseif id=="tab_buy"  then mode="buy";  break
        elseif id=="tab_sell" then mode="sell"; break
        elseif id=="q1"  then qty=1;  break
        elseif id=="q5"  then qty=5;  break
        elseif id=="q10" then qty=10; break
        elseif id=="q50" then qty=50; break
        elseif id=="q-"  then qty=math.max(1,qty-1); break
        elseif id=="q+"  then qty=qty+1; break

        elseif id=="manual" then
          local raw=inputText(30,11,6)
          local n=tonumber(raw); if n and n>0 then qty=math.floor(n) end; break

        elseif id=="action" then
          -- Relit le stock (au cas ou un autre joueur aurait achete entre-temps)
          stock  = loadStock()
          wallet = loadWallet()
          stockQty  = stock[coin.id]  or 0
          walletQty = wallet[coin.id] or 0
          -- Recalcule les prix avec le stock frais
          buy,sell = calcPrices(coin, stockQty)

          if mode=="buy" then
            -- ── ACHAT ──
            if stockQty < qty then
              popup("Stock insuffisant",{
                "Stock actuel: "..stockQty.." "..coin.symbol,
                "Demande: "..qty.." | Reessaie avec moins."
              },colors.red); break
            end
            local total=qty*buy
            local ok,err=bankOk()
            if not ok then popup("Banque non prete",{err},colors.red); break end

            local confirmed=confirmBox({
              qty.." "..coin.symbol.." a "..buy.."$ / unite",
              "Total debite : "..total.."$",
              "Nouveau prix apres achat : "..
                math.ceil(coin.basePrice*(2.2-((stockQty-qty)/coin.initStock)*1.4)).."$",
            },colors.green)

            if confirmed then
              cls(); fillRow(math.floor(h/2),colors.black)
              mid(math.floor(h/2),"Paiement "..total.."$ ...",colors.yellow,colors.black)
              local ok2,res=pcall(bank.pay,SHOP_ACCT,total,
                "CryptoShop: achat "..qty.." "..coin.symbol.." a "..buy.."$")
              if ok2 and res and res.ok then
                stock[coin.id]  = stockQty  - qty
                wallet[coin.id] = walletQty + qty
                -- Enregistre le prix dans l'historique
                pushHistory(stock, coin.id, buy)
                saveT(STOCK_FILE, stock)
                saveT(WALLET_F,   wallet)
                local newBuy,_ = calcPrices(coin, stock[coin.id])
                popup("Achat confirme !",{
                  "+"..qty.." "..coin.symbol.." ajoutes !",
                  "Ton stock: "..wallet[coin.id].." "..coin.symbol,
                  "Solde restant: "..(res.balance or "?").."$",
                  "Nouveau prix: "..newBuy.."$ (etait "..buy.."$)",
                },colors.green)
              else
                popup("Paiement refuse",{
                  tostring(res and res.error or res or "?")
                },colors.red)
              end
              break
            end

          else
            -- ── VENTE ──
            if walletQty < qty then
              popup("Portefeuille insuffisant",{
                "Tu as: "..walletQty.." "..coin.symbol,
                "Vente: "..qty.." | Reessaie avec moins."
              },colors.red); break
            end
            local gain=qty*sell
            local ok,err=bankOk()
            if not ok then popup("Banque non prete",{err},colors.red); break end

            local confirmed=confirmBox({
              qty.." "..coin.symbol.." a "..sell.."$ / unite",
              "Tu recois : +"..gain.."$",
              "Nouveau prix apres vente : "..
                math.ceil(coin.basePrice*(2.2-((stockQty+qty)/coin.initStock)*1.4)).."$",
            },colors.cyan)

            if confirmed then
              cls(); fillRow(math.floor(h/2),colors.black)
              mid(math.floor(h/2),"Envoi "..gain.."$ ...",colors.yellow,colors.black)
              local ok2,res=pcall(bank.cashout,SHOP_ACCT,gain,
                "CryptoShop: vente "..qty.." "..coin.symbol.." a "..sell.."$")
              if ok2 and res and res.ok then
                wallet[coin.id] = walletQty - qty
                stock[coin.id]  = stockQty  + qty
                pushHistory(stock, coin.id, buy)
                saveT(STOCK_FILE, stock)
                saveT(WALLET_F,   wallet)
                local newBuy,_ = calcPrices(coin, stock[coin.id])
                popup("Vente confirmee !",{
                  "+"..gain.."$ envoyes sur ton compte !",
                  "Tu gardes: "..wallet[coin.id].." "..coin.symbol,
                  "Nouveau prix: "..newBuy.."$ (etait "..buy.."$)",
                },colors.cyan)
              else
                popup("Cashout refuse",{
                  tostring(res and res.error or res or "?"),
                  "Verifie que le compte '"..SHOP_ACCT.."' a des fonds."
                },colors.red)
              end
              break
            end
          end
        end -- action
      end -- mouse_click
    end -- inner while
  end -- outer while
end

-- ═══════════════════════════════════════
-- ECRAN PORTEFEUILLE
-- ═══════════════════════════════════════

local function walletScreen(stock, wallet)
  cls()
  fillRow(1,colors.orange)
  mid(1," Mon Portefeuille ",colors.black,colors.orange)
  fillRow(2,colors.gray)
  mid(2,"Valeur calculee au prix de vente actuel",colors.black,colors.gray)

  local totalVal=0
  for i,coin in ipairs(COINS) do
    local y=3+i*3
    local qty=wallet[coin.id] or 0
    local stockQty=stock[coin.id] or 0
    local buy,sell=calcPrices(coin,stockQty)
    local val=qty*sell
    totalVal=totalVal+val

    fillRow(y,coin.color)
    at(2,y,coin.icon.." "..rpad(coin.name,18),colors.black,coin.color)
    at(22,y,lpad(tostring(qty),6).." "..coin.symbol,colors.black,coin.color)
    at(w-10,y,lpad("~"..val.."$",10),colors.black,coin.color)

    fillRow(y+1,colors.gray)
    at(4,y+1,"Achat: "..buy.."$  Vente: "..sell.."$  Stock shop: "..stockQty,
      colors.white,colors.gray)
  end

  local ly=3+#COINS*3+1
  fillRow(ly,colors.orange)
  at(2,ly,"TOTAL portefeuille :",colors.black,colors.orange)
  at(w-12,ly,lpad("~"..totalVal.."$",11),colors.black,colors.orange)

  resetBtns()
  addBtn("back",math.floor((w-10)/2)+1,h-1,10,1,"  Retour  ",colors.orange,colors.black)
  while true do
    local ev,_,mx,my=os.pullEvent()
    if ev=="mouse_click" and clickBtn(mx,my)=="back" then return end
    if ev=="key" then return end
  end
end

-- ═══════════════════════════════════════
-- MENU PRINCIPAL
-- ═══════════════════════════════════════

local function drawMenu(stock, wallet)
  resetBtns()
  cls()

  fillRow(1,colors.orange)
  mid(1," CryptoShop v"..VERSION.." - Bourse Virtuelle ",colors.black,colors.orange)

  -- En-tetes
  fillRow(2,colors.gray)
  at(2, 2,rpad("Crypto",  10),colors.black,colors.gray)
  at(13,2,lpad("Achat$",  6), colors.green,colors.gray)
  at(20,2,lpad("Vente$",  6), colors.cyan, colors.gray)
  at(27,2,lpad("Stock",   6), colors.black,colors.gray)
  at(34,2,lpad("Toi",     5), colors.black,colors.gray)
  at(40,2,"Trend",           colors.black,colors.gray)
  at(w-15,2,"Actions",       colors.black,colors.gray)

  fillRow(3,colors.black)
  at(2,3,string.rep("-",w-2),colors.gray,colors.black)

  for i,coin in ipairs(COINS) do
    local y=3+i*2
    local stockQty  = stock[coin.id]  or 0
    local walletQty = wallet[coin.id] or 0
    local hist      = stock[coin.id.."_hist"] or {}
    local buy,sell  = calcPrices(coin, stockQty)
    local tc,tcolor = trend(hist, buy)
    local ratio     = stockQty/coin.initStock

    fillRow(y,  colors.black)
    fillRow(y+1,colors.black)

    -- Nom
    at(2,y,coin.icon.." "..coin.symbol,coin.color,colors.black)

    -- Prix dynamiques
    at(13,y,lpad(tostring(buy), 5),  colors.green, colors.black)
    at(20,y,lpad(tostring(sell),5),  colors.cyan,  colors.black)

    -- Stock avec couleur d'alerte
    local stockCol = ratio<0.2 and colors.red
                  or ratio<0.5 and colors.orange
                  or colors.white
    at(27,y,lpad(tostring(stockQty),5), stockCol, colors.black)

    -- Portefeuille
    at(34,y,lpad(tostring(walletQty),4),
      walletQty>0 and colors.yellow or colors.lightGray, colors.black)

    -- Tendance
    at(40,y,tc,tcolor,colors.black)

    -- Mini sparkline (si assez de place)
    if w>=52 and #hist>=2 then
      drawMiniChart(42,y,math.min(#hist,w-58),1,hist,tcolor)
    end

    -- Bouton detail (achat+vente dans le meme ecran)
    addBtn("coin:"..coin.id, w-12, y, 11, 1,
      "[ Trader ]", coin.color, colors.black)
  end

  -- Boutons bas
  addBtn("wallet",  2,       h-1, 14, 1, "Portefeuille", colors.yellow,  colors.black)
  addBtn("refresh", 18,      h-1, 12, 1, "Actualiser",   colors.gray,    colors.white)
  addBtn("quit",    w-10,    h-1, 8,  1, "Quitter",      colors.red,     colors.white)

  fillRow(h,colors.gray)
  mid(h,"Prix = offre/demande auto | + d'achats = prix monte",colors.white,colors.gray)
end

-- ═══════════════════════════════════════
-- BOUCLE PRINCIPALE
-- ═══════════════════════════════════════

local stock  = loadStock()
local wallet = loadWallet()

while true do
  drawMenu(stock, wallet)
  while true do
    local ev,_,mx,my=os.pullEvent()
    if ev=="mouse_click" then
      local id=clickBtn(mx,my)
      if not id then break end
      if id=="quit" then
        cls()
        mid(math.floor(h/2),"Merci d'avoir utilise CryptoShop !",colors.orange,colors.black)
        sleep(1); return
      elseif id=="wallet" then
        walletScreen(stock,wallet)
        stock=loadStock(); wallet=loadWallet(); break
      elseif id=="refresh" then
        stock=loadStock(); wallet=loadWallet(); break
      elseif type(id)=="string" and id:sub(1,5)=="coin:" then
        local coin=getCoin(id:sub(6))
        if coin then
          coinScreen(coin,stock,wallet)
          stock=loadStock(); wallet=loadWallet()
        end
        break
      end
    end
  end
end
