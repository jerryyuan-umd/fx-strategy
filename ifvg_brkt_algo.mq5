//+------------------------------------------------------------------+
//|        Inverse Fair Value Gap + London Breakout Algorithm        |
//|                        Copyright 2025, Quan Yuan                 |
//|                            Version 1.5                           |
//+------------------------------------------------------------------+
#property strict
#property copyright "Quan Yuan"
#property version   "1.57"

//BREAKOUT STRATEGY
input bool     TickVolumeFilter = true;            
input int      MinTickVolume = 1250;                
input bool     TradeJulyToOctober = false;
input bool     Trade11AMPeak = false;
input int      RangeStopTime = 11;
input int      RangeStartTime = 3;
input int      PendingCancelTime = 18;
input int      DefaultPointsForTP = 800;
input bool     DynamicPointsForTP = false;
input double   OrderSize = 2;
input double   BreakEvenAt = 100;
input double   BreakEvenStop = 20;
input double   TrailStartAt = 240;
input double   TrailDistance = 100;
input double   SLTPRatioLimit = 0.5;
input int      BRKT_MagicNumber = 6996;
input bool     TRADEBRKOUT = true;
//IFVG STRATEGY
input int      IFVG_MinFVG_Size = 15;              
input int      IFVG_LondonTradeStart = 9;
input int      IFVG_NYTradeStart = 14;
input bool     IFVG_TradeJulyToOctober = false;
input bool     IFVG_TradeHolidayBreak = false;
input bool     IFVG_SLToBreakEven = true;
input double   IFVG_OrderVolume = 3;
input double   IFVG_TrailDistMult = 1.3;
input int      IFVG_MagicNumber = 6969;
input int      IFVG_IFVGToTradeDiff = 5;
input int      IFVG_TPSLRatio = 4;
input int      IFVG_FVGToIFVGDiff = 15;
input bool     TRADEIFVG = true;
   
//GLB VAR BRKOT
double FilterBuffer = 10 * _Point;
datetime LastOrderCancelTime, LastUpdateTime;
double CurrentRangeHigh, CurrentRangeLow;
bool RangeCalculatedToday = true; //this makes sure reset logic is only run once
ulong BuyStopTicket = 0;
ulong SellStopTicket = 0;
int OrderPlaced = 0; //-1 is open sell stop; 1 is open buy stop
bool OpenOpportunity = true;
int atrHandle;  
int DSTAdjustment, numVolumeRejects = 0;
double PointsForTP = DefaultPointsForTP;               
//GLB VAR IFVG
color BullishFVG_Color = clrDarkSeaGreen;
color BearishFVG_Color = clrRosyBrown;
int emaHandle; //emaHandle2;
int londonOpen;
MqlDateTime currentTime;  
struct FVG
{
    datetime time;
    double high;
    double low;
    double retest;
    bool bullish;
    ENUM_TIMEFRAMES timeframe;
};
FVG fvgs[];

bool addFVG(datetime time, double high, double low, bool bullish, ENUM_TIMEFRAMES period) 
{
   if (fvgExists(time, period)) return false;
   FVG fvg;
   fvg.time = time;
   fvg.high = high;
   fvg.low = low;
   fvg.timeframe = period;
   fvg.bullish = bullish;
   fvg.retest = fvg.bullish? fvg.high : fvg.low;
   
   int fvgLength = ArraySize(fvgs);
   ArrayResize(fvgs, fvgLength + 1);
   fvgs[fvgLength] = fvg;
   return true;
}

bool fvgExists(datetime time, ENUM_TIMEFRAMES period) {
   for (int i = 0; i < ArraySize(fvgs); i++) {
      if (fvgs[i].time == time && fvgs[i].timeframe == period) return true;
   }
   return false;
}
//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    InitIFVG();
    InitBRKOUT();
    return(INIT_SUCCEEDED);
}

void InitIFVG() {
   // Clear previous drawings
    ObjectsDeleteAll(0, "FVG_");
    londonOpen = IFVG_LondonTradeStart;
    emaHandle = iMA(_Symbol, _Period, 30, 0, MODE_EMA, PRICE_CLOSE);
}

void InitBRKOUT() {
   DSTAdjustment = 0;
   if (DynamicPointsForTP) atrHandle = iATR(_Symbol, PERIOD_CURRENT, 48);
   CreateRangeIllustration();  
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(emaHandle);
   ObjectDelete(0, "RangeHigh");
   ObjectDelete(0, "RangeLow");
}

void OnTick()
{
   TimeCurrent(currentTime);
   if(TRADEBRKOUT) TickleBRKOUT();
   if(TRADEIFVG) TickleIFVG();
}

void TickleIFVG() {
   MonitorOpenPosition(); 
   
   if(!IsNewBar()) return;
   if (currentTime.mon > 6 && currentTime.mon < 11 && !IFVG_TradeJulyToOctober) return;
   if (!IFVG_TradeHolidayBreak && ((currentTime.mon == 12 && currentTime.day >= 12) || 
      (currentTime.mon == 1 && currentTime.day < 12))) return;
   int currentHour = currentTime.hour;
   if(currentHour == 0 && currentTime.min == 0) {
      londonOpen = IFVG_LondonTradeStart - IsDSTGap();
      PrintFVGs();
      ObjectsDeleteAll(0, "FVG_");
      ArrayResize(fvgs, 0);
   }
   if(currentHour <  londonOpen || currentHour > 16 || 
      (currentHour < IFVG_NYTradeStart && currentHour > 11 - IsDSTGap()))
   {
      return;
   }
   if(HasOpenPositionsCurrentChart() || OpenPosition(IsValidEntry())) return;
   
   CheckForFVG(PERIOD_M15);
   CheckForFVG(PERIOD_M5);
   ExtendFVGBoxes();
}

void TickleBRKOUT() {
   // Process trades and stops on every tick
   ManagePendingOrders();
   ManageOpenPositions();  
   
   // Only update the range per 5 sec to reduce CPU load
   if(TimeCurrent() - LastUpdateTime < 5) return;
   LastUpdateTime = TimeCurrent();
   if (currentTime.mon > 6 && currentTime.mon < 11 && !TradeJulyToOctober) return;  
   // Check if we're in a new day (after 11AM or before 3AM)
   if((currentTime.hour < RangeStartTime - DSTAdjustment) && RangeCalculatedToday)
   {
      CreateRangeIllustration();
      DSTAdjustment = IsDSTGap();
      OrderPlaced = 0;
      OpenOpportunity = true;
      RangeCalculatedToday = false;
      return;
   }
   // Cancel orders at 18:00
   if(currentTime.hour == PendingCancelTime - DSTAdjustment && currentTime.min == 0 && 
      (TimeCurrent() - LastOrderCancelTime) >= 86400) // 86400 sec = 1 day
   {
      CancelAllPendingOrders();
      Print("Number of Volume Rejects: ", numVolumeRejects);
      LastOrderCancelTime = TimeCurrent(); // Update last cancel time
   }
   // Place Orders at London Open + 1
   if(currentTime.hour >= RangeStopTime - DSTAdjustment && 
      currentTime.hour < PendingCancelTime && OpenOpportunity)
   {
      PlaceStopOrder();
      return;
   }
   // Calculate range
   if(currentTime.hour >= RangeStartTime - DSTAdjustment && 
      currentTime.hour < RangeStopTime - DSTAdjustment)
   {
      CalculateCurrentRange();
      UpdateRangeLines();
   }
}

//+------------------------------------------------------------------+
//| Function to print Fair Value Gaps (FVGs) in a formatted manner   |
//+------------------------------------------------------------------+
void PrintFVGs(string header="Previous Day FVG List", int maxGapsToPrint=20)
{
    // Print header and column titles
    Print("\n=== ", header, " ===");
    Print("=============================================================================================");
    Print("| #  | Direction | Timeframe   | Time                | High       | Low        | Retest     |");
    Print("|----|-----------|-------------|---------------------|------------|------------|------------|");
    
    // Determine how many gaps to actually print
    int totalGaps = ArraySize(fvgs);
    int gapsToPrint = (maxGapsToPrint <= 0 || maxGapsToPrint > totalGaps) ? totalGaps : maxGapsToPrint;
    
    // Print each FVG
    for(int i = 0; i < gapsToPrint; i++)
    {
        // Format the direction
        string direction = fvgs[i].bullish ? "Bullish" : "Bearish";
        
        // Format the timeframe
        string tfStr = TimeframeToString(fvgs[i].timeframe);
        
        // Format the time
        string timeStr = TimeToString(fvgs[i].time, TIME_DATE|TIME_MINUTES);
        
        // Print the formatted row
        PrintFormat("| %-2d | %-9s | %-11s | %-19s | %-10.5f | %-10.5f | %-10.5f |", 
                   i+1, 
                   direction, 
                   tfStr, 
                   timeStr, 
                   fvgs[i].high, 
                   fvgs[i].low, 
                   fvgs[i].retest);
    } 
    // Print footer and summary
    Print("=============================================================================================");
    PrintFormat("Displaying %d of %d total FVGs", gapsToPrint, totalGaps);
    Print("=============================================================================================");
}

bool IsNewBar() {
   static datetime lastCandleTime;
   datetime currentCandleTime = iTime(_Symbol, _Period, 0);
   if (lastCandleTime != currentCandleTime) {
      lastCandleTime = currentCandleTime;
      return true;
   }
   return false;
}

void MonitorOpenPosition() 
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == IFVG_MagicNumber)
      {
         // Get position details
         ulong ticket = PositionGetTicket(i); // Get the ticket of the position
         string symbol = PositionGetString(POSITION_SYMBOL);
         double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         int type = PositionGetInteger(POSITION_TYPE);
         
         // Calculate half of the Take Profit in price terms
         double brkEvenPrice = (type == ORDER_TYPE_BUY) ? 
            entry_price + (tp - entry_price) / IFVG_TPSLRatio : 
            entry_price - (entry_price - tp) / IFVG_TPSLRatio;
         double trlngctvtnPrice = (type == ORDER_TYPE_BUY) ? 
            entry_price + (tp - entry_price) / IFVG_TPSLRatio * 2 : 
            entry_price - (entry_price - tp) / IFVG_TPSLRatio * 2;
         
         if ((type == ORDER_TYPE_BUY && current_price >= trlngctvtnPrice) || 
            (type == ORDER_TYPE_SELL && current_price <= trlngctvtnPrice)) 
         {
            double trailingDist = IFVG_TrailDistMult * MathAbs(trlngctvtnPrice - brkEvenPrice);
            double trailingPrice = type == ORDER_TYPE_BUY ? 
               current_price - trailingDist : current_price + trailingDist;
            if (type == ORDER_TYPE_BUY && trailingPrice > sl || 
               type == ORDER_TYPE_SELL && trailingPrice < sl)  
                  ModifyStopLoss(ticket, trailingPrice);
         }
         else if (IFVG_SLToBreakEven &&
            (type == ORDER_TYPE_BUY && current_price >= brkEvenPrice || type == ORDER_TYPE_SELL && current_price <= brkEvenPrice))
         {
            if (type == ORDER_TYPE_BUY && sl < entry_price || 
               type == ORDER_TYPE_SELL && sl > entry_price) {
               // Move Stop Loss to Break Even (entry price)
               ModifyStopLoss(ticket, entry_price);
            }
         }
      }
   }
}

void ModifyStopLoss(ulong ticket, double new_sl)
{
   // Check if the ticket is valid
   if (ticket <= 0)
   {
     Print("Invalid ticket number stumbled when trying to modify sl.");
     return;
   }
   
   // Get the current order details
   if (PositionSelectByTicket(ticket))
   {
     // Prepare the modification request
     MqlTradeRequest request;
     ZeroMemory(request);
     request.position = ticket;
     request.action = TRADE_ACTION_SLTP;  
     request.volume = PositionGetDouble(POSITION_VOLUME);        
     request.symbol = PositionGetString(POSITION_SYMBOL); // Symbol of the order
     request.sl = new_sl;                       
     request.tp = PositionGetDouble(POSITION_TP);      
     request.deviation = 10;                   
   
     // Send the modification request
     MqlTradeResult result;
     ZeroMemory(result);
   
     if (OrderSend(request, result))
     {
         Print("Stop loss modified successfully. New SL: ", new_sl);
     }
     else
     {
         Print("Failed to modify stop loss. Retcode: ", result.retcode);
     }
   }
   else
   {
     Print("Failed to select order with ticket: ", ticket);
   }
}

bool OpenPosition(int fvgIndex) {
   if (fvgIndex < 0) return false;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK); 
   FVG fvg = fvgs[fvgIndex];
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.type = fvg.bullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = fvg.bullish ? ask : bid;
   request.volume = EnoughMargin(IFVG_OrderVolume, request.type, request.price) ? IFVG_OrderVolume : 
      EnoughMargin(IFVG_OrderVolume/2, request.type, request.price) ? IFVG_OrderVolume/2 : -1;
   request.sl = fvg.bullish ? 
      MathMax(fvg.retest, MathMax(fvg.low, ask - 200 * _Point)) : 
      MathMin(fvg.retest, MathMin(fvg.high, bid + 200 * _Point));
   request.tp = fvg.bullish ? 
      request.price + IFVG_TPSLRatio * (request.price - request.sl) : 
      request.price - IFVG_TPSLRatio * (request.sl - request.price);  
   request.deviation = 5;
   request.magic = IFVG_MagicNumber;
   request.comment = "IFVG trade";
   
   if (MathAbs(request.sl - fvg.retest) > 200 * _Point) {
      Print("IFVG breakout candle too long. Trade rejected.");
      return false;
   }
   if (!OrderSend(request, result))
      Print("Order failed: ", GetLastError());
      return false;
      
   return true;
}

bool HasOpenPositionsCurrentChart() 
{
    string currentSymbol = _Symbol;
    // Loop through all open positions
    for (int i = PositionsTotal() - 1; i >= 0; i--) 
    {
        ulong ticket = PositionGetTicket(i); // Get position ticket
        if (ticket > 0 && PositionGetInteger(POSITION_MAGIC) == IFVG_MagicNumber) 
        {
            return(true); // Found an open position on this chart's symbol
        }
    }
    return(false); // No positions on this symbol
}

bool EnoughMargin(double orderSize, ENUM_ORDER_TYPE orderType, double price) {
   double margin_for_trade;
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(OrderCalcMargin(
       orderType,        
       _Symbol,            
       orderSize,                  
       price, 
       margin_for_trade      
   ))
   {
       Print("Margin required for order at ", price, ": ", margin_for_trade);
       Print("Free margin: ", free_margin);
   }
   else
   {
       Print("Failed to calculate margin. Error: ", GetLastError());
   }
   return free_margin > margin_for_trade;
}

//+------------------------------------------------------------------+
//| Check for FVG at specified bar index                             |
//+------------------------------------------------------------------+
void CheckForFVG(ENUM_TIMEFRAMES period)
{
    datetime time = iTime(_Symbol, period, 2);
    double open = iOpen(_Symbol, period, 2);
    double close = iClose(_Symbol, period, 2); 
    
    double leftHigh = iHigh(_Symbol, period, 3);
    double rightLow = iLow(_Symbol, period, 1); 
    if(open < close && (rightLow - leftHigh > IFVG_MinFVG_Size * _Point))
    {
        if (!addFVG(time, rightLow, leftHigh, true, period)) return;
        DrawFVG(leftHigh, rightLow, true, time, period);
        return;
    }   
    double rightHigh = iHigh(_Symbol, period, 1);
    double leftLow = iLow(_Symbol, period, 3);
    if(open > close && (leftLow - rightHigh > IFVG_MinFVG_Size * _Point))
    {
        if (!addFVG(time, leftLow, rightHigh, false, period)) return;
        DrawFVG(rightHigh, leftLow, false, time, period);
        return;
    }
}

void ExtendFVGBoxes() {
   string objName;
   
   for (int i = 2; i < 15; i++) {
      objName = "FVG_" + TimeToString(iTime(_Symbol, _Period, i));
      if(ObjectFind(0, objName) != -1) {
         ObjectSetInteger(0, objName, OBJPROP_TIME, 1, TimeCurrent());
      }
   }
}

//+------------------------------------------------------------------+
//| Draw FVG rectangle on chart                                      |
//+------------------------------------------------------------------+
void DrawFVG(double top, double bottom, bool isBullish, datetime startTime, ENUM_TIMEFRAMES tf)
{
   string objName = "FVG_" + TimeToString(startTime);
   
   // Create rectangle object
   if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0, iTime(_Symbol, PERIOD_CURRENT, 
      iBarShift(_Symbol, PERIOD_CURRENT, startTime) + 1), top, TimeCurrent(), bottom))
   {
     Print("Failed to create FVG object! Error: ", GetLastError());
     return;
   }
   // Set visual properties
   color fvgColor = isBullish ? BullishFVG_Color : BearishFVG_Color;
   ObjectSetInteger(0, objName, OBJPROP_COLOR, fvgColor);
   ObjectSetInteger(0, objName, OBJPROP_FILL, false);
    
   string labelName = objName + "_label";
   string labelText = TimeframeToString(tf);
   double labelPrice = (top + bottom) / 2;
   
   if(!ObjectCreate(0, labelName, OBJ_TEXT, 0, startTime, labelPrice))
   {
      Print("Failed to create label! Error: ", GetLastError());
      return;
   }
   ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, fvgColor);
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_CENTER);
   
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 6);
   ObjectSetDouble(0, labelName, OBJPROP_ANGLE, 90);
}

int IsValidEntry() {
   double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double lastOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   int numFVGs = ArraySize(fvgs);
   double ema[30];
   CopyBuffer(emaHandle, 0, 0, 30, ema);
   
   if (lastClose > lastOpen && lastClose > ema[28]) {
      return SearchForFVGCombo(numFVGs, lastClose, lastOpen, ema, true);
   } else if (lastClose < lastOpen && lastClose < ema[28]) {
      return SearchForFVGCombo(numFVGs, lastClose, lastOpen, ema, false);
   } else {
      return -1;
   }
}

int SearchForFVGCombo(int numFVGs, double lastClose, double lastOpen, double &ema[], bool bullish) {
   int foundIFVG = -1;
   int foundFVG = -1;
   for (int i = numFVGs - 1; i >= 0; i--) {
      if (foundIFVG < 0) {
         bool disrespectedIFVG = bullish ? 
            lastClose > fvgs[i].high && lastOpen < fvgs[i].high : 
            lastClose < fvgs[i].low && lastOpen > fvgs[i].low;
         bool isIFVG = bullish ? !fvgs[i].bullish : fvgs[i].bullish;
         bool correctTF = fvgs[i].timeframe == PERIOD_M5; //|| fvgs[i].timeframe == PERIOD_M3;
         bool correctTime = (iTime(_Symbol, _Period, 1) - fvgs[i].time) < 5 * IFVG_IFVGToTradeDiff * 60; 
         bool correctRange = CheckFVGRange(fvgs[i], ema, bullish, true);
          
         if (isIFVG && disrespectedIFVG && correctTF && correctTime && correctRange) {
            foundIFVG = i;
         }
      } else if (foundFVG < 0) {
         bool isFVG = bullish ? fvgs[i].bullish : !fvgs[i].bullish;
         bool isExplosion = (fvgs[i].high - fvgs[i].low) > 200 * _Point;
         bool correctTF = fvgs[i].timeframe == PERIOD_M5 || fvgs[i].timeframe == PERIOD_M15;
         bool correctTime = fvgs[foundIFVG].time - fvgs[i].time < 5 * IFVG_FVGToIFVGDiff * 60;
         bool correctRange = CheckFVGRange(fvgs[i], ema, bullish, false);
         bool respectfullyTouchedFVG = 
            IsFVGTouchedRespectfully(fvgs[foundIFVG].time, fvgs[i]);
  
         if (isFVG && !isExplosion && respectfullyTouchedFVG && correctTF && correctTime && correctRange) {
            foundFVG = i;
         }
      }
   }
   return foundFVG;
}

bool CheckFVGRange(FVG &fvg, double &ema[], bool bullish, bool ifvg) {
   bool correctRange = false;
   int startBarIndex = iBarShift(_Symbol, _Period, fvg.time);
      if (startBarIndex > 29) { 
         return false; 
      } else if (ifvg) {
         correctRange = bullish ? fvg.low > ema[29 - startBarIndex] :
            fvg.high < ema[29 - startBarIndex];
      } else {
         correctRange = bullish ? fvg.high > ema[29 - startBarIndex] :
            fvg.low < ema[29 - startBarIndex];
      }
   return correctRange;
}

bool IsFVGTouchedRespectfully(datetime start, FVG &fvg) 
{
   int startIndex = iBarShift(_Symbol, _Period, start);
   bool touched = false;
   double swingExtreme = iClose(_Symbol, _Period, startIndex);
   double currentExtreme, currentClose, currentOpen;
   
   for (int i = startIndex - 1; i > 0; i--) {
      currentClose = iClose(_Symbol, _Period, i);
      currentOpen = iOpen(_Symbol, _Period, i);
      currentExtreme = fvg.bullish ? iLow(_Symbol, _Period, i) : iHigh(_Symbol, _Period, i);
      fvg.retest = 
         fvg.bullish ? MathMin(fvg.retest, currentExtreme) : MathMax(fvg.retest, currentExtreme);
      touched = touched || (fvg.bullish ? currentExtreme < fvg.high : currentExtreme > fvg.low);
      swingExtreme = fvg.bullish ? 
         MathMin(MathMin(currentClose, currentOpen), swingExtreme) : 
         MathMax(MathMax(currentClose, currentOpen), swingExtreme);
   }
   bool respectful = fvg.bullish ? swingExtreme > fvg.low : swingExtreme < fvg.high;
   return respectful && touched;
}

//+------------------------------------------------------------------+
//| Convert current timeframe to string representation               |
//+------------------------------------------------------------------+
string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   string tfString;
   switch(tf)
   {
      case PERIOD_M3:    tfString = "M3";  break;
      case PERIOD_M5:    tfString = "M5";  break;
      case PERIOD_M15:   tfString = "M15"; break;
      case PERIOD_M30:   tfString = "M30"; break;
      case PERIOD_H1:    tfString = "H1";  break;
      case PERIOD_H4:    tfString = "H4";  break;
      case PERIOD_D1:    tfString = "D1";  break;
      case PERIOD_W1:    tfString = "W1";  break;
      default:           tfString = "M" + IntegerToString(tf/60); 
   }
   
   return tfString;
}

int IsDSTGap()
{   
    int year = currentTime.year;
    int month = currentTime.mon;
    int day = currentTime.day;
    
    // Calculate the second Sunday in March
    int marchSecondSunday = 8; // earliest possible is 8th (1st is Sunday)
    for(int day = 1; day <= 14; day++)
    {
        MqlDateTime testDate = {year, 3, day, 0, 0, 0};
        if(TimeToStruct(StructToTime(testDate), testDate) && testDate.day_of_week == 0)
        {
            marchSecondSunday = day + 7;
            break;
        }
    }
    // Calculate last Sunday in March
    int marchLastSunday = 31;
    for(int day = 31; day >= 25; day--)
    {
        MqlDateTime testDate = {year, 3, day, 0, 0, 0};
        if(TimeToStruct(StructToTime(testDate), testDate) && testDate.day_of_week == 0)
        {
            marchLastSunday = day;
            break;
        }
    }
    // Calculate last Sunday in October
    int octoberLastSunday = 31;
    for(int day = 31; day >= 25; day--)
    {
        MqlDateTime testDate = {year, 10, day, 0, 0, 0};
        if(TimeToStruct(StructToTime(testDate), testDate) && testDate.day_of_week == 0)
        {
            octoberLastSunday = day;
            break;
        }
    }
    // Calculate first Sunday in November
    int novemberFirstSunday = 1;
    for(int day = 1; day <= 7; day++)
    {
        MqlDateTime testDate = {year, 11, day, 0, 0, 0};
        if(TimeToStruct(StructToTime(testDate), testDate) && testDate.day_of_week == 0)
        {
            novemberFirstSunday = day;
            break;
        }
    }
    
    int inSpringDSTGap = (month == 3 && day >= marchSecondSunday && day <= marchLastSunday) ? 1 : 0;
    int inAutumnDSTGap = (month == 10 && day >= octoberLastSunday) ||
                       (month == 11 && day <= novemberFirstSunday) ? 1 : 0;
                       
    if (inSpringDSTGap + inAutumnDSTGap > 0) {
      return 1;
    }
    return 0;
}

void CreateRangeIllustration()
{
// Create the graphical objects
   ObjectCreate(0, "RangeHigh", OBJ_HLINE, 0, 0, 0);
   ObjectCreate(0, "RangeLow", OBJ_HLINE, 0, 0, 0);
   
   // Set line properties
   ObjectSetInteger(0, "RangeHigh", OBJPROP_COLOR, clrGreen);
   ObjectSetInteger(0, "RangeHigh", OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, "RangeHigh", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "RangeHigh", OBJPROP_BACK, true);
   
   ObjectSetInteger(0, "RangeLow", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "RangeLow", OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, "RangeLow", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "RangeLow", OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Calculate the current day's range (3AM-current time)             |
//+------------------------------------------------------------------+
void CalculateCurrentRange()
{
   // Get today's date at 00:00
   MqlDateTime todayStart = currentTime;
   todayStart.hour = 0;
   todayStart.min = 0;
   todayStart.sec = 0;
   datetime startOfDay = StructToTime(todayStart);
   
   // Calculate the start time (today at 3AM)
   MqlDateTime rangeStart = todayStart;
   rangeStart.hour = RangeStartTime - DSTAdjustment;
   datetime monitoringStart = StructToTime(rangeStart);
   
   // Get current bar time
   datetime timeArray[];
   CopyTime(NULL, 0, 0, 1, timeArray);
   datetime currentBarTime = timeArray[0];
   
   // Get today's high/low since 3AM
   double highArray[], lowArray[];
   int bars = CopyHigh(NULL, 0, monitoringStart, currentBarTime, highArray);
   CopyLow(NULL, 0, monitoringStart, currentBarTime, lowArray);
   
   if(bars <= 0) return;
   
   // Calculate the high and low for the period
   CurrentRangeHigh = highArray[ArrayMaximum(highArray)];
   CurrentRangeLow = lowArray[ArrayMinimum(lowArray)];
   
   RangeCalculatedToday = true;
}

//+------------------------------------------------------------------+
//| Update the range lines on the chart                              |
//+------------------------------------------------------------------+
void UpdateRangeLines()
{
   // Update the high line
   ObjectSetDouble(0, "RangeHigh", OBJPROP_PRICE, CurrentRangeHigh);
   
   // Update the low line
   ObjectSetDouble(0, "RangeLow", OBJPROP_PRICE, CurrentRangeLow);
   
   // Add descriptive labels
   ObjectSetString(0, "RangeHigh", OBJPROP_TEXT, "3AM-11AM High: " + DoubleToString(CurrentRangeHigh, _Digits));
   ObjectSetString(0, "RangeLow", OBJPROP_TEXT, "3AM-11AM Low: " + DoubleToString(CurrentRangeLow, _Digits));
}

//+------------------------------------------------------------------+
//| Manage open orders (apply filters and such)                      |
//+------------------------------------------------------------------+
void ManagePendingOrders()
{
    for(int i = OrdersTotal()-1; i >= 0; i--)
    {
        if(OrderGetTicket(i) <= 0 || OrderGetInteger(ORDER_MAGIC) != BRKT_MagicNumber) continue;
        
        ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        double stopPrice = OrderGetDouble(ORDER_PRICE_OPEN);
        double currentPrice = orderType == ORDER_TYPE_BUY_STOP ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) 
                                                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        // Check if price is approaching order level
        if(MathAbs(currentPrice - stopPrice) <= FilterBuffer)
        {   
            bool volumeOK = true;
            bool emaOK = true;
            
            if (TickVolumeFilter) {
               volumeOK = CheckBreakoutVolume();
            }
            if(!volumeOK || !emaOK)
            {
                OpenOpportunity = false;
                numVolumeRejects++;
                Print("Cancelling order due to insufficient volume.");
                CancelAllPendingOrders();
            }
        }
    }
}

bool CheckBreakoutVolume() {
   double secondsElapsed = (double)(TimeCurrent() - iTime(_Symbol, PERIOD_M15, 0));
   double secondsTotal = 15 * 60;        // TIMEFRAME-DEPENDENT
   double projectedVolume;
   long currentVolume = iVolume(_Symbol, PERIOD_M15, 0);
   //long sumPreceedingVolume = 0;
   //for(int j = 1; j <= 3; j++) sumPreceedingVolume += iTickVolume(_Symbol, PERIOD_CURRENT, j);
   
   if(!secondsElapsed == 0) {
      projectedVolume = (secondsTotal / secondsElapsed) * currentVolume;
      //projectedVolume += sumPreceedingVolume;
      //projectedVolume /= 4;
   } else {
      projectedVolume = iTickVolume(_Symbol, PERIOD_M15, 1); //sumPreceedingVolume / 3;
   }
   return (currentTime.mon > 6 && currentTime.mon < 11) ? 
      MinTickVolume + 500 < projectedVolume : MinTickVolume < projectedVolume;
}

//+------------------------------------------------------------------+
//| Manage open positions (modified for multiple positions)          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == BRKT_MagicNumber)
      {
         OpenOpportunity = false;
         ulong positionTicket = PositionGetInteger(POSITION_TICKET);
         long position_type = PositionGetInteger(POSITION_TYPE);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double volume = PositionGetDouble(POSITION_VOLUME);
         
         double current_price = 
            position_type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double current_profit_points = 
            position_type == POSITION_TYPE_BUY ? (current_price - open_price)/_Point : (open_price - current_price)/_Point; 
         double current_sl = PositionGetDouble(POSITION_SL);
         double current_tp = PositionGetDouble(POSITION_TP);
         
         // Check if we need to modify SL to +80 at 100 points profit
         if(current_profit_points >= BreakEvenAt)
         {
            double new_sl = 0;
            bool needsModification = false;
            
            if(position_type == POSITION_TYPE_BUY)
            {
               new_sl = open_price + (BreakEvenAt - BreakEvenStop) * _Point;
               needsModification = (current_sl < new_sl);
            }
            else if(position_type == POSITION_TYPE_SELL)
            {
               new_sl = open_price - (BreakEvenAt - BreakEvenStop) * _Point;
               needsModification = (current_sl > new_sl || current_sl == 0);
            }
            
            if(needsModification)
            {
               MqlTradeRequest request = {};
               MqlTradeResult result = {};
               request.action = TRADE_ACTION_SLTP;
               request.symbol = _Symbol;
               request.sl = NormalizeDouble(new_sl, _Digits);
               request.tp = current_tp;
               request.position = positionTicket;
               
               if(OrderSend(request, result))
                  Print("Position #", positionTicket, " SL moved to +80 points");
            }
         }
         
         // Check if we need to activate trailing stop
         if(current_profit_points >= TrailStartAt)
         {
            double new_sl = 0;
            
            if(position_type == POSITION_TYPE_BUY)
            {
               new_sl = current_price - TrailDistance * _Point;
               if(new_sl > current_sl)
               {
                  MqlTradeRequest request = {};
                  MqlTradeResult result = {};
                  request.action = TRADE_ACTION_SLTP;
                  request.symbol = _Symbol;
                  request.sl = NormalizeDouble(new_sl, _Digits);
                  request.tp = current_tp;
                  request.position = positionTicket;
                  
                  if(OrderSend(request, result))
                     Print("Position #", positionTicket, " trailing stop updated");
               }
            }
            else if(position_type == POSITION_TYPE_SELL)
            {
               new_sl = current_price + TrailDistance * _Point;
               if(new_sl < current_sl || current_sl == 0)
               {
                  MqlTradeRequest request = {};
                  MqlTradeResult result = {};
                  request.action = TRADE_ACTION_SLTP;
                  request.symbol = _Symbol;
                  request.sl = NormalizeDouble(new_sl, _Digits);
                  request.tp = current_tp;
                  request.position = positionTicket;
                  
                  if(OrderSend(request, result))
                     Print("Position #", positionTicket, " trailing stop updated");
               }
            }
         }
         if(currentTime.hour == RangeStopTime - DSTAdjustment - 2) //close yesterday's drippings
         {
            ClosePositionByTicket(positionTicket, volume, position_type);
         }
      }
   }
}

void ClosePositionByTicket(ulong position_ticket, double volume, long position_type)
{
   // Create a request and send it
   MqlTradeRequest request = {};
   request.action    = TRADE_ACTION_DEAL;
   request.position = position_ticket; // Important: Specify the ticket
   request.symbol   = _Symbol;
   request.volume   = volume;
   request.type     = (position_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price    = SymbolInfoDouble(_Symbol, (request.type == ORDER_TYPE_SELL) ? 
      SYMBOL_BID : SYMBOL_ASK);
   
   MqlTradeResult result;
   if (OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE) {
      Print("Position #", position_ticket, " closed.");
      OpenOpportunity = true;
   } else {
      Print("Close failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Place stop order at RangeStopTime AM (with filters)              |
//+------------------------------------------------------------------+
void PlaceStopOrder()
{
   if (DynamicPointsForTP) {
      double atr[2];
      if (CopyBuffer(atrHandle, 0, 0, 2, atr) < 0) return;
      PointsForTP = atr[0] / _Point * 14;
   } else {
      PointsForTP = DefaultPointsForTP;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.magic = BRKT_MagicNumber;
   request.action = TRADE_ACTION_PENDING;
   request.symbol = _Symbol;
   request.type_filling = ORDER_FILLING_IOC;
   request.deviation = 5;
   request.comment = "breakout trade";
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   double buy_stop_price = NormalizeDouble(CurrentRangeHigh + spread, _Digits);
   double sell_stop_price = NormalizeDouble(CurrentRangeLow, _Digits);
   
   if (OrderPlaced < 1 && CurrentRangeHigh - bid < bid - CurrentRangeLow) 
   {
      CancelAllPendingOrders(); //Due to the retarded anti-hedging rule
      request.type = ORDER_TYPE_BUY_STOP;
      request.price = buy_stop_price;
      request.volume = EnoughMargin(OrderSize, ORDER_TYPE_BUY, request.price) ? OrderSize : 
         EnoughMargin(OrderSize/2, request.type, request.price) ? OrderSize/2 : -1;
      request.tp = NormalizeDouble(buy_stop_price + PointsForTP * _Point, _Digits);
      request.sl = GenerateSL(0, CurrentRangeLow, buy_stop_price, spread);
      
      if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
      {
         BuyStopTicket = result.order;
         OrderPlaced = 1;
         ObjectDelete(0, "RangeHigh");
         Print("Buy Stop order placed at ", buy_stop_price);
      } 
      else if(Trade11AMPeak && result.retcode == 10015 && 
         PlaceMarketOrder(request, result) == TRADE_RETCODE_DONE) 
      {
         Print("Buy market order placed.");
      }
      else 
      {
         OpenOpportunity = false;
      }
   } 
   else if (OrderPlaced > -1 && bid - CurrentRangeLow < CurrentRangeHigh - bid) 
   {
      CancelAllPendingOrders(); //Due to the retarded anti-hedging rule
      request.type = ORDER_TYPE_SELL_STOP;
      request.price = sell_stop_price;
      request.volume = EnoughMargin(OrderSize, ORDER_TYPE_SELL, request.price) ? OrderSize : 
         EnoughMargin(OrderSize/2, request.type, request.price) ? OrderSize/2 : -1;
      request.tp = NormalizeDouble(sell_stop_price - PointsForTP * _Point, _Digits);
      request.sl = GenerateSL(1, sell_stop_price, buy_stop_price, spread);
      
      if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
      {
         SellStopTicket = result.order;
         OrderPlaced = -1;
         ObjectDelete(0, "RangeLow");
         Print("Sell Stop order placed at ", sell_stop_price);
      }  
      else if(Trade11AMPeak && result.retcode == 10015 && 
         PlaceMarketOrder(request, result) == TRADE_RETCODE_DONE) 
      {
         Print("Sell market order placed.");
      }
      else 
      {
         OpenOpportunity = false;
      }
   }
}

int PlaceMarketOrder(MqlTradeRequest &request, MqlTradeResult &result) 
{
   request.action = TRADE_ACTION_DEAL;
   if (request.type == ORDER_TYPE_BUY_STOP) {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   } else {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   if ((!TickVolumeFilter) || CheckBreakoutVolume()) OrderSend(request, result);
   return result.retcode;
}

double GenerateSL(int mode, double sell_stop_price, double buy_stop_price, double spread) 
{
   double price_range = buy_stop_price - sell_stop_price;
   if (mode == 0) {
      double partRangePrice = NormalizeDouble(sell_stop_price, _Digits);
      double halfTPPrice = buy_stop_price + spread - PointsForTP * _Point * SLTPRatioLimit;
      if (halfTPPrice > partRangePrice) {
         OpenOpportunity = false;
         return -1;
      }
      return partRangePrice;
      
   } else {
      double partRangePrice = NormalizeDouble(buy_stop_price + spread, _Digits);
      double halfTPPrice = sell_stop_price + PointsForTP * _Point * SLTPRatioLimit;
      if (halfTPPrice < partRangePrice) {
         OpenOpportunity = false;
         return -1;
      }
      return partRangePrice;
   }
}

//+------------------------------------------------------------------+
//| Cancel all pending orders                                        |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
{
   int totalOrders = OrdersTotal();
   for(int i = totalOrders-1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_REMOVE;
         request.order = orderTicket;
         
         if(OrderSend(request, result))
         {
            Print("Canceled pending order #", orderTicket);
            // Reset global tickets if they match
            if(BuyStopTicket == orderTicket) BuyStopTicket = 0;
            if(SellStopTicket == orderTicket) SellStopTicket = 0;
         }
      }
   }
   //OrdersPlaced = false; // Reset flag
}

//+------------------------------------------------------------------+
//| Get retcode description                                          |
//+------------------------------------------------------------------+
string GetRetcodeID(int retcode)
{
   switch(retcode)
   {
      case 10004: return("TRADE_RETCODE_REQUOTE");
      case 10006: return("TRADE_RETCODE_REJECT");
      case 10007: return("TRADE_RETCODE_CANCEL");
      case 10008: return("TRADE_RETCODE_PLACED");
      case 10009: return("TRADE_RETCODE_DONE");
      case 10010: return("TRADE_RETCODE_DONE_PARTIAL");
      case 10011: return("TRADE_RETCODE_ERROR");
      case 10012: return("TRADE_RETCODE_TIMEOUT");
      case 10013: return("TRADE_RETCODE_INVALID");
      case 10014: return("TRADE_RETCODE_INVALID_VOLUME");
      case 10015: return("TRADE_RETCODE_INVALID_PRICE");
      case 10016: return("TRADE_RETCODE_INVALID_STOPS");
      case 10017: return("TRADE_RETCODE_TRADE_DISABLED");
      case 10018: return("TRADE_RETCODE_MARKET_CLOSED");
      case 10019: return("TRADE_RETCODE_NO_MONEY");
      case 10020: return("TRADE_RETCODE_PRICE_CHANGED");
      case 10021: return("TRADE_RETCODE_PRICE_OFF");
      case 10022: return("TRADE_RETCODE_INVALID_EXPIRATION");
      case 10023: return("TRADE_RETCODE_ORDER_CHANGED");
      case 10024: return("TRADE_RETCODE_TOO_MANY_REQUESTS");
      case 10025: return("TRADE_RETCODE_NO_CHANGES");
      case 10026: return("TRADE_RETCODE_SERVER_DISABLES_AT");
      case 10027: return("TRADE_RETCODE_CLIENT_DISABLES_AT");
      case 10028: return("TRADE_RETCODE_LOCKED");
      case 10029: return("TRADE_RETCODE_FROZEN");
      case 10030: return("TRADE_RETCODE_INVALID_FILL");
      case 10031: return("TRADE_RETCODE_CONNECTION");
      case 10032: return("TRADE_RETCODE_ONLY_REAL");
      case 10033: return("TRADE_RETCODE_LIMIT_ORDERS");
      case 10034: return("TRADE_RETCODE_LIMIT_VOLUME");
      case 10035: return("TRADE_RETCODE_INVALID_ORDER");
      case 10036: return("TRADE_RETCODE_POSITION_CLOSED");
      default: return("UNKNOWN_RETCODE");
   }
}