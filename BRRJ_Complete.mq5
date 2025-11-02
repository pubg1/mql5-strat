//+------------------------------------------------------------------+
//|                                                    BRRJ v1.2.0   |
//|  Breakout + Reversion + RVOL + DOM + Volume Profile              |
//|  Complete single-file expert advisor implementation              |
//|  NOTE: no ++/-- or +=/-= usage; loops use explicit increments    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.2.0"
#property description "BRRJ: Breakout + Reversion expert advisor."

#include <Trade/Trade.mqh>

CTrade trade;

//============================ Inputs =================================
input long   Inp_Magic              = 20251102;
input double Inp_MinLot             = 0.01;
input double Inp_MaxLot             = 50.0;
input int    Inp_SlippagePoints     = 30;

input double Inp_RiskPercent        = 0.5;
input double Inp_RiskReward         = 1.2;

input bool   Inp_UseATR_Stop        = true;
input int    Inp_ATR_Period         = 14;
input double Inp_ATR_Mult           = 0.8;

input int    Inp_MaxSpreadPoints    = 450;

input bool   Inp_UseSession         = false;
input int    Inp_SessionStartHour   = 0;
input int    Inp_SessionEndHour     = 24;

input bool   Inp_TrendFilter        = false;
input ENUM_TIMEFRAMES Inp_Trend_TF  = PERIOD_H1;
input int    Inp_Trend_MA_Period    = 200;

input bool   Inp_UseRVOL            = true;
input ENUM_TIMEFRAMES Inp_RVOL_TF   = PERIOD_M15;
input int    Inp_RVOL_Period        = 20;
input double Inp_RVOL_Min           = 1.8;

input bool   Inp_UseDOM             = false;
input int    Inp_DOM_Depth          = 5;
input double Inp_DOM_Imb            = 1.30;

input bool   Inp_EnableBreakout     = true;
input int    Inp_BO_Lookback        = 80;
input int    Inp_BO_BufferPts       = 30;

input bool   Inp_EnableReversion    = true;
input int    Inp_RJ_MA_Period       = 70;
input double Inp_RJ_Band_ATRmult    = 1.6;
input bool   Inp_RJ_OnlyOnceBack    = true;

input bool   Inp_MoveToBE           = true;
input double Inp_BE_TrigRR          = 1.0;
input double Inp_BE_OffsetR         = 0.10;
input int    Inp_TimeStop_Min       = 0;
input bool   Inp_FlatAtSessionEnd   = false;
input int    Inp_MaxConcurrent      = 1;
input double Inp_DailyLossStop      = 0.0;

input bool   Inp_UseVP              = false;
input int    Inp_VP_LookbackBars    = 500;
input int    Inp_VP_Rows            = 80;
input int    Inp_VP_ValueAreaPct    = 70;
enum VPFilterMode { VP_None, VP_AllowOnlyIntoVA, VP_AvoidIntoVA, VP_TargetAtPOC };
input VPFilterMode Inp_VP_FilterMode = VP_None;

//============================ Globals =================================
int   g_atr_handle = INVALID_HANDLE;
int   g_reversion_ma_handle  = INVALID_HANDLE;
int   g_trend_ma_handle = INVALID_HANDLE;

datetime g_lastBarTime = 0;
bool  g_dom_subscribed = false;

datetime g_last_reversion_bar = 0;

datetime g_last_vp_time = 0;
double g_vp_poc = 0.0;
double g_vp_val = 0.0;
double g_vp_vah = 0.0;
bool   g_vp_valid = false;

//============================ Utils ===================================
double PointSize()
{
  double point = 0.0;
  if(!SymbolInfoDouble(_Symbol, SYMBOL_POINT, point))
  {
    point = 0.0001;
  }
  return(point);
}

int SymbolDigits()
{
  long digits = 5;
  SymbolInfoInteger(_Symbol, SYMBOL_DIGITS, digits);
  return((int)digits);
}

double NormalizeP(double price){ return(NormalizeDouble(price, SymbolDigits())); }

double PointValueMoney()
{
  double tick_value = 0.0;
  double tick_size = 0.0;
  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, tick_value);
  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size);
  if(tick_size<=0.0) tick_size = PointSize();
  double pv = tick_value / tick_size * PointSize();
  return(pv);
}

bool IsNewBar()
{
  datetime t1 = iTime(_Symbol, PERIOD_CURRENT, 1);
  if(t1 != g_lastBarTime){ g_lastBarTime = t1; return(true); }
  return(false);
}

bool SpreadOK()
{
  double ask = 0.0;
  double bid = 0.0;
  SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask);
  SymbolInfoDouble(_Symbol, SYMBOL_BID, bid);
  if(ask<=0.0 || bid<=0.0) return(false);
  double sp = (ask - bid)/PointSize();
  return((int)sp <= Inp_MaxSpreadPoints);
}

bool SessionContainsHour(int hour)
{
  if(Inp_SessionStartHour == Inp_SessionEndHour) return(true);
  if(Inp_SessionStartHour <= Inp_SessionEndHour)
    return(hour >= Inp_SessionStartHour && hour < Inp_SessionEndHour);
  if(hour >= Inp_SessionStartHour) return(true);
  if(hour < Inp_SessionEndHour) return(true);
  return(false);
}

bool InSession()
{
  if(!Inp_UseSession) return(true);
  datetime now = TimeCurrent();
  int hour = TimeHour(now);
  return(SessionContainsHour(hour));
}

bool TrendOK(int dir)
{
  if(!Inp_TrendFilter) return(true);
  if(g_trend_ma_handle==INVALID_HANDLE) return(true);

  double ma_val[]; ArraySetAsSeries(ma_val, true);
  if(CopyBuffer(g_trend_ma_handle, 0, 1, 2, ma_val) < 2) return(true);

  double c = iClose(_Symbol, Inp_Trend_TF, 1);
  if(dir>0 && c >= ma_val[1]) return(true);
  if(dir<0 && c <= ma_val[1]) return(true);
  return(false);
}

datetime DayStart(datetime t)
{
  return(t - (t % 86400));
}

//============================ Indicators ================================
bool InitIndicators()
{
  g_atr_handle = iATR(_Symbol, PERIOD_CURRENT, Inp_ATR_Period);
  if(g_atr_handle==INVALID_HANDLE)
  {
    Print("ATR handle failed");
    return(false);
  }

  g_reversion_ma_handle = iMA(_Symbol, PERIOD_CURRENT, Inp_RJ_MA_Period, 0, MODE_SMA, PRICE_CLOSE);
  if(g_reversion_ma_handle==INVALID_HANDLE)
  {
    Print("MA handle failed");
    return(false);
  }

  if(Inp_TrendFilter)
  {
    g_trend_ma_handle = iMA(_Symbol, Inp_Trend_TF, Inp_Trend_MA_Period, 0, MODE_SMA, PRICE_CLOSE);
    if(g_trend_ma_handle==INVALID_HANDLE)
    {
      Print("Trend MA handle failed");
      return(false);
    }
  }
  else
  {
    g_trend_ma_handle = INVALID_HANDLE;
  }
  return(true);
}

double GetATR(int shift)
{
  double b[]; ArraySetAsSeries(b, true);
  if(CopyBuffer(g_atr_handle, 0, shift, 2, b)<2) return(0.0);
  return(b[1]);
}

double GetReversionMA(int shift)
{
  double b[]; ArraySetAsSeries(b, true);
  if(CopyBuffer(g_reversion_ma_handle, 0, shift, 2, b)<2) return(0.0);
  return(b[1]);
}

//============================ RVOL =====================================
double RVOL_Value(int shift)
{
  int period = Inp_RVOL_Period;
  if(period < 2) period = 2;

  MqlRates rates[];
  ArraySetAsSeries(rates, true);
  int need = period + shift + 1;
  int copied = CopyRates(_Symbol, Inp_RVOL_TF, shift, need, rates);
  if(copied <= period) return(1.0);

  double current = (double)rates[shift].tick_volume;
  double sum = 0.0;
  int count = 0;
  int idx = 1;
  while(idx <= period)
  {
    int arr_index = shift + idx;
    if(arr_index >= copied) break;
    sum = sum + (double)rates[arr_index].tick_volume;
    count = count + 1;
    idx = idx + 1;
  }
  if(count<=0 || sum<=0.0) return(1.0);
  double avg = sum / (double)count;
  if(avg<=0.0) return(1.0);
  return(current / avg);
}

//============================ DOM =====================================
bool DOM_OK_Buy()
{
  if(!Inp_UseDOM) return(true);
  MqlBookInfo book[]; ArraySetAsSeries(book, true);
  if(!MarketBookGet(_Symbol, book)) return(true);

  double bidSum = 0.0;
  double askSum = 0.0;
  int total = ArraySize(book);
  int countedBid = 0;
  int countedAsk = 0;

  int idx = total;
  while(idx > 0 && countedBid < Inp_DOM_Depth)
  {
    idx = idx - 1;
    if(book[idx].type == BOOK_TYPE_BID)
    {
      bidSum = bidSum + book[idx].volume;
      countedBid = countedBid + 1;
    }
  }

  idx = total;
  while(idx > 0 && countedAsk < Inp_DOM_Depth)
  {
    idx = idx - 1;
    if(book[idx].type == BOOK_TYPE_ASK)
    {
      askSum = askSum + book[idx].volume;
      countedAsk = countedAsk + 1;
    }
  }

  if(askSum<=0.0) return(true);
  return(bidSum >= askSum * Inp_DOM_Imb);
}

bool DOM_OK_Sell()
{
  if(!Inp_UseDOM) return(true);
  MqlBookInfo book[]; ArraySetAsSeries(book, true);
  if(!MarketBookGet(_Symbol, book)) return(true);

  double bidSum = 0.0;
  double askSum = 0.0;
  int total = ArraySize(book);
  int countedBid = 0;
  int countedAsk = 0;

  int idx = total;
  while(idx > 0 && countedBid < Inp_DOM_Depth)
  {
    idx = idx - 1;
    if(book[idx].type == BOOK_TYPE_BID)
    {
      bidSum = bidSum + book[idx].volume;
      countedBid = countedBid + 1;
    }
  }

  idx = total;
  while(idx > 0 && countedAsk < Inp_DOM_Depth)
  {
    idx = idx - 1;
    if(book[idx].type == BOOK_TYPE_ASK)
    {
      askSum = askSum + book[idx].volume;
      countedAsk = countedAsk + 1;
    }
  }

  if(bidSum<=0.0) return(true);
  return(askSum >= bidSum * Inp_DOM_Imb);
}

//============================ Volume Profile ===========================
bool VP_Calc(int lookback, int rows, int valueAreaPct, double &poc, double &val, double &vah)
{
  poc = 0.0; val = 0.0; vah = 0.0;
  if(!Inp_UseVP) return(false);
  if(lookback < 50 || rows < 20) return(false);

  double highest = iHigh(_Symbol, PERIOD_CURRENT, 1);
  double lowest  = iLow (_Symbol, PERIOD_CURRENT, 1);
  int bar = 2;
  while(bar <= lookback + 1)
  {
    double bh = iHigh(_Symbol, PERIOD_CURRENT, bar);
    double bl = iLow (_Symbol, PERIOD_CURRENT, bar);
    if(bh > highest) highest = bh;
    if(bl < lowest)  lowest  = bl;
    bar = bar + 1;
  }

  if(highest <= lowest) return(false);

  double span = highest - lowest;
  double step = span / (double)rows;
  if(step < PointSize()) step = PointSize();

  double hist[];
  ArrayResize(hist, rows);
  int init_idx = 0;
  while(init_idx < rows)
  {
    hist[init_idx] = 0.0;
    init_idx = init_idx + 1;
  }

  int processed = 0;
  int current = 1;
  while(current <= lookback)
  {
    double bhigh = iHigh(_Symbol, PERIOD_CURRENT, current);
    double blow  = iLow (_Symbol, PERIOD_CURRENT, current);
    long   vol   = (long)iVolume(_Symbol, PERIOD_CURRENT, current);
    if(vol < 0) vol = 0;

    if(bhigh < blow)
    {
      double temp = bhigh;
      bhigh = blow;
      blow = temp;
    }

    double range = bhigh - blow;
    if(range < step)
    {
      int grid = (int)MathFloor((bhigh - lowest) / step);
      if(grid < 0) grid = 0;
      if(grid > rows - 1) grid = rows - 1;
      hist[grid] = hist[grid] + (double)vol;
    }
    else
    {
      int segments = (int)MathCeil(range / step);
      if(segments < 1) segments = 1;
      double alloc = (double)vol / (double)segments;
      int seg = 0;
      while(seg < segments)
      {
        double priceLevel = blow + step * (double)seg;
        int grid = (int)MathFloor((priceLevel - lowest) / step);
        if(grid < 0) grid = 0;
        if(grid > rows - 1) grid = rows - 1;
        hist[grid] = hist[grid] + alloc;
        seg = seg + 1;
      }
    }

    processed = processed + 1;
    current = current + 1;
  }

  if(processed == 0) return(false);

  int pocIndex = 0;
  double maxVolume = hist[0];
  int check = 1;
  while(check < rows)
  {
    if(hist[check] > maxVolume)
    {
      maxVolume = hist[check];
      pocIndex = check;
    }
    check = check + 1;
  }
  poc = lowest + step * (double)pocIndex;

  double total = 0.0;
  int sumIdx = 0;
  while(sumIdx < rows)
  {
    total = total + hist[sumIdx];
    sumIdx = sumIdx + 1;
  }
  if(total <= 0.0)
  {
    val = lowest;
    vah = highest;
    return(true);
  }

  int left = pocIndex;
  int right = pocIndex;
  double accumulated = hist[pocIndex];
  double targetPct = (double)valueAreaPct;

  while((accumulated / total * 100.0) < targetPct)
  {
    bool expanded = false;
    if(left > 0)
    {
      left = left - 1;
      accumulated = accumulated + hist[left];
      expanded = true;
    }
    if((accumulated / total * 100.0) >= targetPct) break;
    if(right < rows - 1)
    {
      right = right + 1;
      accumulated = accumulated + hist[right];
      expanded = true;
    }
    if(!expanded) break;
  }

  val = lowest + step * (double)left;
  vah = lowest + step * (double)right;
  return(true);
}

bool VP_Get(double &poc, double &val, double &vah)
{
  poc = 0.0;
  val = 0.0;
  vah = 0.0;
  if(!Inp_UseVP) return(false);

  datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 1);
  if(barTime != g_last_vp_time)
  {
    g_vp_valid = VP_Calc(Inp_VP_LookbackBars, Inp_VP_Rows, Inp_VP_ValueAreaPct, g_vp_poc, g_vp_val, g_vp_vah);
    g_last_vp_time = barTime;
  }
  poc = g_vp_poc;
  val = g_vp_val;
  vah = g_vp_vah;
  return(g_vp_valid);
}

//============================ Signals ==================================
bool RVOL_OK()
{
  if(!Inp_UseRVOL) return(true);
  double rvol = RVOL_Value(1);
  if(rvol >= Inp_RVOL_Min) return(true);
  return(false);
}

int Signal_Breakout()
{
  if(!Inp_EnableBreakout) return(0);
  if(!RVOL_OK()) return(0);

  int lookback = Inp_BO_Lookback;
  if(lookback < 20) lookback = 20;

  double highest = iHigh(_Symbol, PERIOD_CURRENT, 1);
  double lowest  = iLow (_Symbol, PERIOD_CURRENT, 1);

  int bar = 2;
  while(bar <= lookback)
  {
    double h = iHigh(_Symbol, PERIOD_CURRENT, bar);
    double l = iLow (_Symbol, PERIOD_CURRENT, bar);
    if(h > highest) highest = h;
    if(l < lowest)  lowest  = l;
    bar = bar + 1;
  }

  double buffer = Inp_BO_BufferPts * PointSize();
  double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
  double c0 = iClose(_Symbol, PERIOD_CURRENT, 0);

  if(c1 > highest + buffer && c0 >= c1)
  {
    if(Inp_UseDOM && !DOM_OK_Buy()) return(0);
    if(!TrendOK(+1)) return(0);
    return(+1);
  }

  if(c1 < lowest - buffer && c0 <= c1)
  {
    if(Inp_UseDOM && !DOM_OK_Sell()) return(0);
    if(!TrendOK(-1)) return(0);
    return(-1);
  }

  return(0);
}

int Signal_Reversion()
{
  if(!Inp_EnableReversion) return(0);

  double ma = GetReversionMA(1);
  double atr = GetATR(1);
  if(ma<=0.0 || atr<=0.0) return(0);

  double up = ma + atr * Inp_RJ_Band_ATRmult;
  double dn = ma - atr * Inp_RJ_Band_ATRmult;

  double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
  double l1 = iLow (_Symbol, PERIOD_CURRENT, 1);
  double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);

  datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 1);

  if(h1 > up && c1 < up)
  {
    if(!TrendOK(-1)) return(0);
    if(Inp_UseDOM && !DOM_OK_Sell()) return(0);
    if(Inp_RJ_OnlyOnceBack)
    {
      if(barTime == g_last_reversion_bar) return(0);
      g_last_reversion_bar = barTime;
    }
    return(-1);
  }

  if(l1 < dn && c1 > dn)
  {
    if(!TrendOK(+1)) return(0);
    if(Inp_UseDOM && !DOM_OK_Buy()) return(0);
    if(Inp_RJ_OnlyOnceBack)
    {
      if(barTime == g_last_reversion_bar) return(0);
      g_last_reversion_bar = barTime;
    }
    return(+1);
  }

  return(0);
}

//============================ Positions =================================
int CountPositionsByMagic(int dir)
{
  int total = PositionsTotal();
  int idx = total;
  int count = 0;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = PositionGetTicket(idx);
    if(PositionSelectByTicket(ticket))
    {
      if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic && PositionGetString(POSITION_SYMBOL)==_Symbol)
      {
        long type = PositionGetInteger(POSITION_TYPE);
        if(dir>0 && type==POSITION_TYPE_BUY) count = count + 1;
        if(dir<0 && type==POSITION_TYPE_SELL) count = count + 1;
      }
    }
  }
  return(count);
}

int CountAllPositionsThisSymbol()
{
  int total = PositionsTotal();
  int idx = total;
  int count = 0;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = PositionGetTicket(idx);
    if(PositionSelectByTicket(ticket))
    {
      if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic && PositionGetString(POSITION_SYMBOL)==_Symbol)
      {
        count = count + 1;
      }
    }
  }
  return(count);
}

double StopsLevelPoints()
{
  long stopsLevel = 0;
  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL, stopsLevel);
  double stops = (double)stopsLevel;
  if(stops < 0.0) stops = 0.0;
  return(stops * PointSize());
}

double FreezeLevelPoints()
{
  long freezeLevel = 0;
  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL, freezeLevel);
  double freeze = (double)freezeLevel;
  if(freeze < 0.0) freeze = 0.0;
  return(freeze * PointSize());
}

bool AdjustStopsForLevels(int dir, double price, double &sl, double &tp)
{
  double stopLevel = StopsLevelPoints();
  double freezeLevel = FreezeLevelPoints();
  double minDist = stopLevel;
  if(freezeLevel > minDist) minDist = freezeLevel;

  if(minDist <= 0.0) return(true);

  if(dir>0)
  {
    if(price - sl < minDist) sl = price - minDist;
    if(tp - price < minDist) tp = price + minDist;
  }
  else
  {
    if(sl - price < minDist) sl = price + minDist;
    if(price - tp < minDist) tp = price - minDist;
  }
  return(true);
}

bool ComputeSLTP(int dir, double &lot, double &sl, double &tp)
{
  lot = 0.0;
  sl = 0.0;
  tp = 0.0;

  double ask = 0.0;
  double bid = 0.0;
  SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask);
  SymbolInfoDouble(_Symbol, SYMBOL_BID, bid);
  double price = (dir>0) ? ask : bid;
  if(price<=0.0) return(false);

  double atr = GetATR(1);
  if(atr<=0.0) atr = 10.0 * PointSize();

  double riskDist = atr * Inp_ATR_Mult;
  if(!Inp_UseATR_Stop)
  {
    double fallback = (double)Inp_BO_BufferPts * PointSize();
    if(fallback <= 0.0) fallback = 20.0 * PointSize();
    riskDist = fallback;
  }
  if(riskDist < 10.0 * PointSize()) riskDist = 10.0 * PointSize();

  double balance = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney = balance * Inp_RiskPercent / 100.0;
  if(riskMoney <= 0.0) riskMoney = balance * 0.005;

  double pointValue = PointValueMoney();
  double pointCount = riskDist / PointSize();
  if(pointValue<=0.0 || pointCount<=0.0) return(false);

  lot = riskMoney / (pointCount * pointValue);
  double step = 0.0;
  double minLot = 0.0;
  double maxLot = 0.0;
  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, step);
  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, minLot);
  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, maxLot);
  if(step<=0.0) step = 0.01;
  if(minLot<=0.0) minLot = Inp_MinLot;
  if(maxLot<=0.0) maxLot = Inp_MaxLot;

  if(lot < minLot) lot = minLot;
  if(lot > maxLot) lot = maxLot;
  if(lot > Inp_MaxLot) lot = Inp_MaxLot;

  lot = MathFloor(lot/step) * step;
  if(lot < minLot) lot = minLot;

  if(dir>0)
  {
    sl = price - riskDist;
    tp = price + riskDist * Inp_RiskReward;
  }
  else
  {
    sl = price + riskDist;
    tp = price - riskDist * Inp_RiskReward;
  }

  AdjustStopsForLevels(dir, price, sl, tp);

  sl = NormalizeP(sl);
  tp = NormalizeP(tp);
  return(true);
}

bool PlaceOrder(int dir)
{
  if(CountAllPositionsThisSymbol() >= Inp_MaxConcurrent) return(false);
  if(CountPositionsByMagic(dir) > 0) return(false);

  double lot, sl, tp;
  if(!ComputeSLTP(dir, lot, sl, tp)) return(false);

  trade.SetExpertMagicNumber(Inp_Magic);
  trade.SetDeviationInPoints(Inp_SlippagePoints);

  bool result = false;
  if(dir>0) result = trade.Buy(lot, _Symbol, 0.0, sl, tp);
  else      result = trade.Sell(lot, _Symbol, 0.0, sl, tp);

  if(!result)
  {
    Print("Order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    Sleep(100);
    if(dir>0) result = trade.Buy(lot, _Symbol, 0.0, sl, tp);
    else      result = trade.Sell(lot, _Symbol, 0.0, sl, tp);
    if(!result)
    {
      Print("Retry failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
  }
  return(result);
}

//============================ Management ================================
void MoveToBreakEven()
{
  if(!Inp_MoveToBE) return;

  int total = PositionsTotal();
  int idx = total;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = PositionGetTicket(idx);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

    long type = PositionGetInteger(POSITION_TYPE);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double stopLoss = PositionGetDouble(POSITION_SL);
    double takeProfit = PositionGetDouble(POSITION_TP);
    double bid = 0.0;
    double ask = 0.0;
    SymbolInfoDouble(_Symbol, SYMBOL_BID, bid);
    SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask);
    double price = (type==POSITION_TYPE_BUY) ? bid : ask;

    double atr = GetATR(1);
    if(atr<=0.0) atr = 10.0 * PointSize();
    double risk = atr * Inp_ATR_Mult;
    if(!Inp_UseATR_Stop)
    {
      double fallback = (double)Inp_BO_BufferPts * PointSize();
      if(fallback <= 0.0) fallback = 20.0 * PointSize();
      risk = fallback;
    }
    if(risk <= 0.0) risk = 10.0 * PointSize();

    double trigger = risk * Inp_BE_TrigRR;
    double offset = risk * Inp_BE_OffsetR;

    if(type==POSITION_TYPE_BUY)
    {
      if(price - openPrice >= trigger)
      {
        double newSL = NormalizeP(openPrice + offset);
        if(newSL > stopLoss) trade.PositionModify(_Symbol, newSL, takeProfit);
      }
    }
    else
    {
      if(openPrice - price >= trigger)
      {
        double newSL = NormalizeP(openPrice - offset);
        if(newSL < stopLoss || stopLoss==0.0) trade.PositionModify(_Symbol, newSL, takeProfit);
      }
    }
  }
}

void TimeStopExit()
{
  if(Inp_TimeStop_Min <= 0) return;

  int total = PositionsTotal();
  int idx = total;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = PositionGetTicket(idx);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

    datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
    if((TimeCurrent() - openTime) >= (Inp_TimeStop_Min * 60))
    {
      trade.PositionClose(_Symbol);
    }
  }
}

bool DailyLossLimitReached(double &lossAmount)
{
  lossAmount = 0.0;
  if(Inp_DailyLossStop <= 0.0) return(false);

  datetime now = TimeCurrent();
  datetime start = DayStart(now);
  if(!HistorySelect(start, now)) return(false);

  int total = HistoryDealsTotal();
  int idx = total;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = HistoryDealGetTicket(idx);
    if(ticket==0) continue;
    string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
    if(symbol != _Symbol) continue;
    datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
    if(dealTime < start) continue;
    double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
    if(profit < 0.0)
    {
      lossAmount = lossAmount - profit;
    }
  }
  if(lossAmount >= Inp_DailyLossStop && Inp_DailyLossStop > 0.0) return(true);
  return(false);
}

void CloseAllPositions()
{
  int total = PositionsTotal();
  int idx = total;
  while(idx > 0)
  {
    idx = idx - 1;
    ulong ticket = PositionGetTicket(idx);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    trade.PositionClose(_Symbol);
  }
}

void DailyLossStopCheck()
{
  double lossAmount = 0.0;
  if(DailyLossLimitReached(lossAmount))
  {
    CloseAllPositions();
  }
}

void FlatAtSessionEndCheck()
{
  if(!Inp_FlatAtSessionEnd) return;
  if(!Inp_UseSession) return;

  datetime now = TimeCurrent();
  int hour = TimeHour(now);

  bool sessionNow = SessionContainsHour(hour);
  if(sessionNow) return;

  CloseAllPositions();
}

void ManagePositions()
{
  MoveToBreakEven();
  TimeStopExit();
  DailyLossStopCheck();
  FlatAtSessionEndCheck();
}

bool DailyLossBlocksNewTrades()
{
  double loss = 0.0;
  if(DailyLossLimitReached(loss)) return(true);
  return(false);
}

//============================ Events ===================================
int OnInit()
{
  trade.SetExpertMagicNumber(Inp_Magic);
  if(!InitIndicators()) return(INIT_FAILED);

  if(Inp_UseDOM)
  {
    if(MarketBookAdd(_Symbol)) g_dom_subscribed = true;
    else
    {
      Print("MarketBookAdd failed; DOM disabled.");
      g_dom_subscribed = false;
    }
  }

  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  if(g_dom_subscribed)
  {
    MarketBookRelease(_Symbol);
    g_dom_subscribed = false;
  }
}

void OnTick()
{
  ManagePositions();

  if(!SpreadOK()) return;
  if(!InSession()) return;
  if(DailyLossBlocksNewTrades()) return;

  bool newBar = IsNewBar();
  if(!newBar) return;

  double poc = 0.0;
  double val = 0.0;
  double vah = 0.0;
  bool vpok = VP_Get(poc, val, vah);

  int breakoutSig = Signal_Breakout();
  int reversionSig = Signal_Reversion();

  int signal = 0;
  if(breakoutSig!=0) signal = breakoutSig;
  else if(reversionSig!=0) signal = reversionSig;
  if(signal==0) return;

  if(!TrendOK(signal)) return;

  if(vpok && Inp_VP_FilterMode == VP_AllowOnlyIntoVA)
  {
    double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    if(signal>0 && !(c1 < vah)) return;
    if(signal<0 && !(c1 > val)) return;
  }

  if(vpok && Inp_VP_FilterMode == VP_AvoidIntoVA)
  {
    double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    if(signal>0 && (c1 >= val && c1 <= vah)) return;
    if(signal<0 && (c1 >= val && c1 <= vah)) return;
  }

  if(!PlaceOrder(signal)) return;

  if(vpok && Inp_VP_FilterMode == VP_TargetAtPOC)
  {
    if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC)==Inp_Magic)
    {
      long type = PositionGetInteger(POSITION_TYPE);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double entryClose = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(type==POSITION_TYPE_BUY && poc > entryClose)
      {
        trade.PositionModify(_Symbol, sl, NormalizeP(poc));
      }
      if(type==POSITION_TYPE_SELL && poc < entryClose)
      {
        trade.PositionModify(_Symbol, sl, NormalizeP(poc));
      }
    }
  }
}
//+------------------------------------------------------------------+
