//+------------------------------------------------------------------+
//| BrainBot_v1_MultiSymbol_STEP_C.mq5                                |
//| Step C: Execute Class-A using Node-RED areas + gates              |
//| v2.12 (compile-clean)                                             |
//| - SCALP strategy kept EXACTLY as-is (your current working logic)   |
//| - Added INTRADAY strategy (separate path) without changing scalp   |
//| - Optional intraday "no-overnight": flat at time + no new trades   |
//|                                                                   |
//| NOTES                                                             |
//| - STRAT_SCALP uses your existing BuildClassATrade() (M5/M1 HA).    |
//| - STRAT_INTRADAY uses D/H1/M5 ACC + M5/M1 HA (no M15 usage).      |
//| - Gates/TTL/dedup/telemetry unchanged & shared.                   |
//+------------------------------------------------------------------+
#property strict
#property version   "2.15"
#property description "BrainBot Step C: Node-RED parse + Class-A execution + USD sizing + split TTL + cooldown + dedup + intraday mode"

#define MAX_SYMS 8
#define INTRA_KEEP_ACC   30
#define INTRA_KEEP_WICK  30
#define INTRA_KEEP_GZ    30
//-------------------------
// GLOBAL RISK INPUTS (USD)
//-------------------------
input int    InpMaxTradesPerDay      = 100;
input double InpMaxDailyLossUSD      = 8000.0;

// Per-trade + profit constraints (USD)  (SCALP defaults, unchanged)
input double InpMaxLossPerTradeUSD   = 600.0;
input double InpMinProfitUSD         = 600.0;

//=====================
// PER-SYMBOL RISK DEFAULTS (Answer #3)
// Works with your 8 symbol slots (any symbol: XAUUSD, US30, US100, BTCUSD...)
//=====================
input bool   InpUsePerSymbolRisk = true;

// For each symbol slot: risk in account currency (USD) + minimum SL in points
input double InpRiskUSD_S1 = 100.0;
input int    InpSLMinPts_S1 = 200;

input double InpRiskUSD_S2 = 100.0;
input int    InpSLMinPts_S2 = 50;

input double InpRiskUSD_S3 = 100.0;
input int    InpSLMinPts_S3 = 50;

input double InpRiskUSD_S4 = 100.0;
input int    InpSLMinPts_S4 = 0;

input double InpRiskUSD_S5 = 100.0;
input int    InpSLMinPts_S5 = 0;

input double InpRiskUSD_S6 = 100.0;
input int    InpSLMinPts_S6 = 0;

input double InpRiskUSD_S7 = 100.0;
input int    InpSLMinPts_S7 = 0;

input double InpRiskUSD_S8 = 100.0;
input int    InpSLMinPts_S8 = 0;

//-------------------------
// MAX LOT PER SYMBOL SLOT
// (Required: if cap <= 0, EA will NOT trade that symbol)
//-------------------------
input double InpMaxLot_S1 = 2.00;   // Max lots for InpSym_S1
input double InpMaxLot_S2 = 0.00;   // Max lots for InpSym_S2
input double InpMaxLot_S3 = 20.00;  // Max lots for InpSym_S3
input double InpMaxLot_S4 = 20.00;  // Max lots for InpSym_S4
input double InpMaxLot_S5 = 0.00;   // Max lots for InpSym_S5
input double InpMaxLot_S6 = 0.00;   // Max lots for InpSym_S6
input double InpMaxLot_S7 = 0.00;   // Max lots for InpSym_S7
input double InpMaxLot_S8 = 0.00;   // Max lots for InpSym_S8

//-------------------------
// TIME / SESSIONS (Amman GMT+3)
//-------------------------
input bool   InpUseSessions          = false;
input bool   InpAllowAsia            = true;
input bool   InpAllowLondon          = true;
input bool   InpAllowNY              = true;
input bool   InpAllowNYExec          = true;
input int    InpPreSessionMinutes    = 120; // pre-session liquidity
input bool   InpDecideOnTimerOnly    = true;

//-------------------------
// STRUCTURE THRESHOLDS (USD -> price via ref lots)  (SCALP defaults, unchanged)
//-------------------------
input double InpRefLotsForUSDConv    = 1.0;
input double InpTouchDistanceUSD     = 0.0;  // tolerance around ACC for "touch"
input double InpSLBufferUSD          = 1.0;  // buffer beyond ACC for SL
input double InpMinRR                = 2.00;  // minimum RR for Class-A

//-------------------------
// EXECUTION SETTINGS
//-------------------------

// TRUE split freshness TTLs
input int    InpAreasTTLSeconds      = 21600;  // 6 hours
input int    InpGatesTTLSeconds      = 1800;   // 1 hour

input int    InpCooldownMinutes      = 1;      // per-symbol cooldown after trade open
input int    InpDedupHours           = 12;     // don't re-trade same ACC right_time same side within this window
input int    InpMaxSpreadPoints      = 2000;    // spread filter (points)


// Trigger/analysis TFs (SCALP defaults, unchanged)
input ENUM_TIMEFRAMES InpTriggerTF   = PERIOD_M1; // HA trigger TF
input double          InpAccOvershootPct  = 0.10;        // 10% rule: allow up to 10% overshoot beyond ACC edges (and use as edge-zone width)


//-------------------------
// STRATEGY MODE (NEW)
//-------------------------

//-------------------------
// INTRADAY STRATEGY INPUTS (REPLACED - per your "This is everything")
// - Uses BREAKOUT (A) + MITIGATION re-entry (B)
// - Independent TF signals: D / H1 / M5 (dedup includes TF+acc_right_time)
// - TP max = 50 USD move (A/B)
// - Special reversal on "GZ untouched since breakout" (reverse + TP 20 USD)
// - Early TP if "next acc border ahead" or "wick level ahead"
// - Exit if new accumulation appears OR low-volatility appears
//-------------------------
input bool   InpIntraEnable = true;
input bool   InpEnableScalp    = true;   // set FALSE to run intraday only
input bool InpEnableIntraday = true;   // set FALSE to run scalp only

// Freshness
input int    InpIntraBreakoutFreshSeconds       = 900;     // ignore very old breakout signals
input int    InpIntraMitigationFreshSeconds     = 21600;   // mitigation can happen later (up to 6h)
input int    InpIntraTimeSkewToleranceSec       = 120;     // allow small Node-RED/MT5 clock skew
input int    InpIntraAccRTToleranceSec          = 2;       // tolerant acc_right_time compare

// Risk / sizing for intraday
input double InpIntraMaxLossPerTradeUSD         = 600.0;
input double InpIntraSLBufferUSD                = 1.0;

// Scenario A/B TP caps

// Scenario B: "re-enter same trade with higher lot"
input bool   InpIntraAllowMitigationReentry     = true;

// Rule #1: GZ untouched reversal
input bool           InpIntraEnableGZReverse    = true;
input ENUM_TIMEFRAMES InpIntraGZTouchTF         = PERIOD_M5; // HA touch check TF
input int            InpIntraGZTouchLookbackBars= 200;
input double         InpIntraGZReverseTriggerUSD= 20.0;      // if price moved >= 20 USD away from GZ mid
input double         InpIntraReverseTPUSD       = 20.0;      // reverse trade TP distance
input double         InpIntraReverseSLUSD       = 20.0;      // reverse trade SL distance

// Rule #2/#3: early TP obstacles
input bool   InpIntraEnableObstacleTP           = true;   // use previous ACC border / wick ahead
input double InpIntraObstacleTouchUSD           = 1.0;    // tolerance around obstacle (USD)

// Rule #4: exit on new accumulation OR low volatility
input bool   InpIntraExitOnNewAccum             = true;
input bool   InpIntraExitOnLowVol               = true;
input int    InpIntraLowVolLookbackBars         = 5;      // M5 avg range bars
input double InpIntraLowVolRangeUSD             = 5.0;    // if avg M5 range <= 5 USD => close

// Intraday: stronger cooldown (still used by GateFailReason)
input int    InpIntraCooldownMinutes            = 2;
input bool InpIntraForceFlatDaily     = false;  // enable/disable daily force-flat
input int  InpIntraFlatHour           = 23;     // Amman hour (0-23)
input int  InpIntraFlatMinute         = 50;     // Amman minute (0-59)
input int  InpIntraNoNewTradesMinutes = 30;     // block new trades X minutes before flat

//-------------------------
// SYMBOL SLOTS
//-------------------------
input bool   InpUse_S1               = true;
input string InpSym_S1               = "XAUUSD";

input bool   InpUse_S2               = true;
input string InpSym_S2               = "BTCUSD";

input bool   InpUse_S3               = true;
input string InpSym_S3               = "US30.cash";

input bool   InpUse_S4               = true;
input string InpSym_S4               = "US100.cash";

input bool   InpUse_S5               = false;
input string InpSym_S5               = "";
input bool   InpUse_S6               = false;
input string InpSym_S6               = "";
input bool   InpUse_S7               = false;
input string InpSym_S7               = "";
input bool   InpUse_S8               = false;
input string InpSym_S8               = "";

//-------------------------
// GATES (defaults + source)
//-------------------------
input bool   InpTradeNews            = false; // if false => block when news_block==true

enum eGateSource { GATE_MANUAL_OFFLINE=0, GATE_NODERED=1 };
input eGateSource InpGateSource      = GATE_NODERED;

// Manual gates
input bool InpLiquidityOkManual      = true;
input bool InpNewsBlockManual        = true;
input bool InpRequireLiquidity       = false;

// Node-RED polling
input string InpNodeRedURLBase       = "http://127.0.0.1:1880/brain/input";
input int    InpPollSeconds          = 1;
input string InpNodeRedSecret        = "YazanAI_2025";
input int    InpWebTimeoutMs         = 2000;

// Telemetry
input bool   InpEnableTelemetry      = true;
input string InpNodeRedTelemetryURL  = "http://127.0.0.1:1880/mt5/telemetry";
input int    InpSkipTelemEverySec    = 30; // throttle skip telemetry per symbol

//-------------------------
//-------------------------
// Trade ID / debug
//-------------------------
// Separate magics so SCALP + INTRADAY can coexist on same symbol
input int    InpMagicScalp           = 250110;
input int    InpMagicIntra           = 250111;
input int    InpSlippagePoints       = 50;

input bool   InpDebugPrintGates      = false;
input int    InpGatePrintEverySec    = 60;
input bool   InpPrintBlockReasons    = true;
input bool   InpDebugPrintAreas      = false;
//=========================
// AI-LIKE LEARNING (inside EA) - simple + reliable
//=========================
input bool   InpLearnEnable              = false;

// Start adapting only after N fully closed positions (per symbol, per strategy)
input int    InpLearnMinClosedTrades     = 20;

// Bounds: never exceed these multipliers
input double InpLearnRiskMinMult         = 0.25;
input double InpLearnRiskMaxMult         = 1.25;

input double InpLearnTPMinMult           = 0.85;
input double InpLearnTPMaxMult           = 1.15;

input double InpLearnSLBufMinMult        = 1.00;
input double InpLearnSLBufMaxMult        = 1.30;

// EMA smoothing for R-multiple
input double InpLearnEmaAlpha            = 0.10;

// Optional safety: after X consecutive losses, auto-drive risk to minimum
input int    InpLearnPauseAfterLosses    = 6;

// NEW safety to prevent tiny SL on SCALP (planned risk floor, USD)
input double InpScalpMinSL_USD           = 300.0;

//-------------------------
// INTERNAL STRUCTS
//-------------------------
struct SymbolSpec {
   string symbol;
   int    digits;
   double point;

   double tick_size;
   double tick_value;
   double tick_value_profit;
   double tick_value_loss;

   double vol_min;
   double vol_max;
   double vol_step;

   bool   ok;
};

struct Gates {
   bool liquidity_ok;
   bool news_block;
   bool valid;
};

struct AccumArea {
   bool   valid;
   double high;
   double low;
   long   left_time;
   long   right_time;

   // 25% lines
   double line_top;
   double line_top25;
   double line_bot25;
   double line_bottom;
};

struct WickArea {
   bool   valid;
   long   break_time;
   double wick_level;
   int    dir; // +1 UP, -1 DOWN, 0 unknown
};

struct GoldZone {
   bool   valid;
   long   gz_time;
   long   acc_right_time;
   double upper;
   double lower;
};

struct BreakoutEvt {
   bool   valid;
   long   break_time;
   long   acc_right_time;
   double break_price;
   int    dir; // +1 UP, -1 DOWN, 0 unknown
};

struct MitigationEvt {
   bool   valid;
   long   mit_time;
   long   acc_right_time;
   double mit_price;
   int    dir;        // +1 UP, -1 DOWN, 0 unknown
   string status;     // "MITIGATED"
};

struct TFState {
   // Latest (kept for compatibility)
   AccumArea   acc;
   WickArea    wick;
   GoldZone    gz;
   BreakoutEvt brk;
   MitigationEvt mit;

   // Lists (NEW for intraday obstacles)
   int        accCount;
   AccumArea  accList[INTRA_KEEP_ACC];

   int        wickCount;
   WickArea   wickList[INTRA_KEEP_WICK];

   int        gzCount;
   GoldZone   gzList[INTRA_KEEP_GZ];
};



struct AreasSnap {
   TFState M;
   TFState W;
   TFState D;
   TFState H1;
   TFState M5;
   TFState M1;
};

//=========================
// AI Struct (MUST be declared before SymbolCtx)
//=========================
struct LearnStats
{
   int    nClosed;
   int    wins;
   int    losses;
   int    consecLoss;
   double emaR;       // EMA of R-multiple (profit / plannedRisk)
   double riskMult;   // scales USD risk -> lot sizing
   double tpMult;     // scales TP distance
   double slBufMult;  // scales SL buffer USD
};


struct SymbolCtx {
   bool enabled;
   string sym;
   SymbolSpec spec;
   Gates gates;
   
   string pendingOrderComment; // BB tag to store setup identity in the order comment
   
   AreasSnap areas;

   long areas_updated_at;   // from Node-RED: areas_updated_at
   long gates_updated_at;   // from Node-RED: gates_updated_at
   long updated_at;         // compatibility max


   bool has_initial_sync;  // becomes true after first areas+gates snapshot (manual sync)
   string news_source;

   datetime lastM1BarTime;
   bool testTradeFired;

   datetime lastGatePrint;
   datetime lastBlockPrint;
   datetime lastForceFlatDayIntra;
   datetime lastSkipTelem;
   string   lastSkipReason;

   // Separate state per strategy so they don't block each other
   datetime lastTradeTimeScalp;
   datetime lastTradeTimeIntra;

   datetime lastDedupTimeScalp;
   string   lastDedupKeyScalp;

   datetime lastDedupTimeIntra;
   string   lastDedupKeyIntra;
   

      //=========================
   // INTRADAY runtime state (NEW)
   //=========================
   string   intraActiveKey;     // TF|accRT|dir
   string   intraActiveTF;      // "D" / "H1" / "M5"
   long     intraActiveAccRT;   // acc_right_time of active setup
   int      intraActiveDir;     // +1 buy, -1 sell

   long     intraActiveEventTime;   // breakout_time or mit_time
   bool     intraActiveIsMit;       // true if entered on mitigation

   double   intraPrevLots;      // last intraday lots used for that key (for B)
   string   intraPrevKey;       // previous key TF|accRT|dir
   
   bool scalp_overshoot_lock;  // NEW

   // Baseline accumulation times at entry (rule #4)
   long     intraBaseAccRT_M;
   long     intraBaseAccRT_W;
   long     intraBaseAccRT_D;
   long     intraBaseAccRT_H1;
   long     intraBaseAccRT_M5;
   //=========================
   // LEARNING STATS (per symbol, per strategy)
   //=========================
   LearnStats learnScalp;
   LearnStats learnIntra;

   // Early TP obstacles (rule #2/#3)
   double   intraTP_AccBorder;  // 0 if none
   double   intraTP_WickLevel;  // 0 if none

   // GZ reversal tracking (rule #1)
   bool     intraGZValid;
   long     intraGZTime;
   double   intraGZLower;
   double   intraGZUpper;
   double   intraGZMid;
   bool     intraGZTouched;

   // Track last seen breakouts per TF (helps mitigation matching)
   long     intraLastBrkTime_M;
   long     intraLastBrkRT_M;

   long     intraLastBrkTime_W;
   long     intraLastBrkRT_W;

   
   long     intraLastBrkTime_D;
   long     intraLastBrkRT_D;

   long     intraLastBrkTime_H1;
   long     intraLastBrkRT_H1;

   long     intraLastBrkTime_M5;
   long     intraLastBrkRT_M5;

};

static SymbolCtx g_syms[MAX_SYMS];

// Daily / kill-switch
static int      g_tradesToday        = 0;
static double   g_dayStartEquity     = 0.0;
static bool     g_stopTrading        = false;
static int      g_dayOfYear          = -1;

//-------------------------
// BASIC HELPERS
//-------------------------
double RoundToStep(double v, double step) {
   if(step <= 0) return v;
   return MathFloor(v / step + 1e-9) * step;
}

double GetBid(const string sym){ double b=0; SymbolInfoDouble(sym, SYMBOL_BID, b); return b; }
double GetAsk(const string sym){ double a=0; SymbolInfoDouble(sym, SYMBOL_ASK, a); return a; }

// --- String helpers missing in MQL5 code above ---
string UpperStr(string s) { StringToUpper(s); return s; }

// Safe POINT getter (used for min SL points checks)
double GetSymbolPointSafe(const string sym)
{
   double p=0.0;
   if(SymbolInfoDouble(sym, SYMBOL_POINT, p) && p > 0.0) return p;
   return 0.0;
}

// Replace your MatchSym() with this version (StringUpper() does NOT exist in MQL5)
bool MatchSym(const string sym, const string key)
{
   if(sym == "" || key == "") return false;
   string A = UpperStr(sym);
   string B = UpperStr(key);
   return (StringFind(A, B) >= 0); // survives suffixes like ".cash" ".i"
}
// Normalize broker symbol into Node-RED key for polling (e.g., "US30.cash" -> "US30")
string NodeSymbolForPoll(const string tradeSym)
{
   string s = StringTrim(tradeSym);
   if(s == "") return "";

   int p = StringFind(s, ".");
   if(p >= 0) s = StringSubstr(s, 0, p);

   p = StringFind(s, "#");
   if(p > 0) s = StringSubstr(s, 0, p);

   p = StringFind(s, "$");
   if(p > 0) s = StringSubstr(s, 0, p);

   return StringTrim(s);
}

// Resolve user-entered symbol into a tradeable broker symbol (tries common suffixes)
string ResolveTradeSymbol(const string desired)
{
   string s = StringTrim(desired);
   if(s == "") return "";

   if(SymbolSelect(s, true))
      return s;

   string cand;

   cand = s + ".cash";
   if(SymbolSelect(cand, true)) return cand;

   cand = s + ".Cash";
   if(SymbolSelect(cand, true)) return cand;

   cand = s + ".CASH";
   if(SymbolSelect(cand, true)) return cand;

   cand = s + "cash";
   if(SymbolSelect(cand, true)) return cand;

   return s;
}

// Map broker symbol -> Node-RED canonical key (ONLY for US30/US100)
string NodeRedKeyFromExecSymbol(const string execSym)
{
   if(MatchSym(execSym, "US30"))  return "US30";
   if(MatchSym(execSym, "US100")) return "US100";
   return execSym; // everything else unchanged
}

// per-symbol max lot cap (slot-based)
double MaxLotForSymbol(const string sym)
{
   if(sym == "") return 0.0;

   // Match trade symbol against your enabled SLOT symbols
   if(InpUse_S1 && InpSym_S1 != "" && MatchSym(sym, InpSym_S1)) return InpMaxLot_S1;
   if(InpUse_S2 && InpSym_S2 != "" && MatchSym(sym, InpSym_S2)) return InpMaxLot_S2;
   if(InpUse_S3 && InpSym_S3 != "" && MatchSym(sym, InpSym_S3)) return InpMaxLot_S3;
   if(InpUse_S4 && InpSym_S4 != "" && MatchSym(sym, InpSym_S4)) return InpMaxLot_S4;
   if(InpUse_S5 && InpSym_S5 != "" && MatchSym(sym, InpSym_S5)) return InpMaxLot_S5;
   if(InpUse_S6 && InpSym_S6 != "" && MatchSym(sym, InpSym_S6)) return InpMaxLot_S6;
   if(InpUse_S7 && InpSym_S7 != "" && MatchSym(sym, InpSym_S7)) return InpMaxLot_S7;
   if(InpUse_S8 && InpSym_S8 != "" && MatchSym(sym, InpSym_S8)) return InpMaxLot_S8;

   return 0.0; // required: unknown symbol => do not trade
}

// do not retrade helper if losing
string MakeBBComment(const bool isIntraday, const string tf, const int dir, const long accRT)
{
   // Format: BBI|D|B|1700000000  (B=buy, S=sell)
   string strat = isIntraday ? "I" : "S";
   string side  = (dir > 0 ? "B" : "S");
   return StringFormat("BB%s|%s|%s|%I64d", strat, tf, side, accRT);
}

bool ParseBBComment(const string c, bool &isIntraday, string &tf, int &dir, long &accRT)
{
   isIntraday=false; tf=""; dir=0; accRT=0;

   int p = StringFind(c, "BB");
   if(p < 0) return false;

   // Expect: BB[S/I]|TF|[B/S]|accRT
   string s = StringSubstr(c, p);

   // split by '|'
   int p1 = StringFind(s, "|", 0); if(p1 < 0) return false;
   int p2 = StringFind(s, "|", p1+1); if(p2 < 0) return false;
   int p3 = StringFind(s, "|", p2+1); if(p3 < 0) return false;

   string head = StringSubstr(s, 0, p1);          // "BBS" or "BBI"
   string tfv  = StringSubstr(s, p1+1, p2-(p1+1));
   string sd   = StringSubstr(s, p2+1, p3-(p2+1));
   string rtS  = StringSubstr(s, p3+1);

   if(StringLen(head) != 3) return false;
   string strat = StringSubstr(head, 2, 1);
   if(strat == "I") isIntraday = true;
   else if(strat == "S") isIntraday = false;
   else return false;

   tf = tfv;
   if(sd == "B") dir = +1;
   else if(sd == "S") dir = -1;
   else return false;

   accRT = (long)StringToInteger(rtS);
   if(accRT <= 0) return false;

   return true;
}
// ---------------------------
// Setup-key helpers (scalp builder returns BUY|accRT|TF)
// We unify to (tf, dir, accRT) for outcome/retake gating.
// ---------------------------
bool ParseScalpDedupKey(const string key, string &tfOut, int &dirOut, long &accRTOut)
{
   string p[]; int n = StringSplit(key, '|', p);
   if(n < 3) return false;
   dirOut   = (p[0] == "BUY" ? +1 : (p[0] == "SELL" ? -1 : 0));
   accRTOut = (long)StringToInteger(p[1]);
   tfOut    = p[2];
   return (dirOut != 0 && accRTOut > 0 && tfOut != "");
}

long AccRTByTF(const AreasSnap &a, const string tf)
{
   if(tf == "M5") return NormalizeTimeMaybeMs((long)a.M5.acc.right_time);
   if(tf == "H1") return NormalizeTimeMaybeMs((long)a.H1.acc.right_time);
   if(tf == "D")  return NormalizeTimeMaybeMs((long)a.D.acc.right_time);
   if(tf == "W")  return NormalizeTimeMaybeMs((long)a.W.acc.right_time);
   if(tf == "M")  return NormalizeTimeMaybeMs((long)a.M.acc.right_time);
   return 0;
}


string SetupOutcomeKeyBase(const string sym, const bool isIntraday, const string tf, const int dir, const long accRT)
{
   string strat = isIntraday ? "INTRA" : "SCALP";
   string side  = (dir > 0 ? "BUY" : "SELL");
   return StringFormat("BB_SETUP|%s|%s|%s|%s|%I64d", sym, strat, tf, side, accRT);
}

void SaveSetupOutcome(const string sym, const bool isIntraday, const string tf, const int dir, const long accRT,
                      const int outcome, const long closeTimeSec)
{
   string base = SetupOutcomeKeyBase(sym, isIntraday, tf, dir, accRT);
   GVSetD(base + "|o", (double)outcome);        // -1 loss, 0 BE, +1 win
   GVSetD(base + "|t", (double)closeTimeSec);   // last close time (server seconds)
}

bool BlockIfPrevLoss(const string sym, const bool isIntraday, const string tf, const int dir, const long accRT,
                     string &why)
{
   why = "";
   string base = SetupOutcomeKeyBase(sym, isIntraday, tf, dir, accRT);

   int  o = (int)GVGetD(base + "|o", 0);
   long t = (long)GVGetD(base + "|t", 0);

   if(o >= 0) return false; // WIN or BE => allow retake

   // LOSS:
   if(InpDedupHours <= 0) { why = "prev_loss_blocked_forever"; return true; }

   if(t <= 0) { why = "prev_loss_blocked"; return true; }

   long age = (long)TimeCurrent() - t;
   long maxAge = (long)InpDedupHours * 3600;

   if(age < maxAge) { why = "prev_loss_blocked_recent"; return true; }
   return false; // loss is old enough -> allow
}

bool GetOpenBBCommentFromHistory(const ulong pos_id, string &bbCommentOut)
{
   bbCommentOut = "";

   datetime toT   = TimeCurrent();
   datetime fromT = toT - 60*60*24*90; // 90 days window (safe)
   HistorySelect(fromT, toT);

   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;

      ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pid != pos_id) continue;

      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN) continue;

      string cmt = HistoryDealGetString(deal, DEAL_COMMENT);
      if(StringFind(cmt, "BB") >= 0)
      {
         bbCommentOut = cmt;
         return true;
      }
   }
   return false;
}

bool LoadSymbolSpec(const string sym, SymbolSpec &out) {
   if(sym == "") return false;
   SymbolSelect(sym, true);

   out.symbol     = sym;
   out.digits     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   out.point      = SymbolInfoDouble(sym, SYMBOL_POINT);

   out.tick_size         = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   out.tick_value        = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   out.tick_value_profit = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   out.tick_value_loss   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);

   out.vol_min    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   out.vol_max    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   out.vol_step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   bool tv_ok = (out.tick_value > 0.0) || (out.tick_value_profit > 0.0) || (out.tick_value_loss > 0.0);
   out.ok = (out.tick_size > 0.0 && tv_ok && out.vol_step > 0.0);
   return out.ok;
}


double TickValueForSL(const SymbolSpec &spec)
{
   if(spec.tick_value_loss > 0.0)     return spec.tick_value_loss;
   if(spec.tick_value > 0.0)         return spec.tick_value;
   if(spec.tick_value_profit > 0.0)  return spec.tick_value_profit;
   return 0.0;
}

double TickValueForTP(const SymbolSpec &spec)
{
   if(spec.tick_value_profit > 0.0)  return spec.tick_value_profit;
   if(spec.tick_value > 0.0)         return spec.tick_value;
   if(spec.tick_value_loss > 0.0)    return spec.tick_value_loss;
   return 0.0;
}

double ClampLots(const SymbolSpec &spec, const double lotsWanted)
{
   if(!spec.ok) return 0.0;

   // Per-symbol cap is REQUIRED (slot-based max lot inputs)
   double symCap = MaxLotForSymbol(spec.symbol);
   if(symCap <= 0.0) return 0.0;

   double lots = lotsWanted;
   lots = MathMin(lots, symCap);

   lots = MathMin(lots, spec.vol_max);
   lots = MathMax(lots, spec.vol_min);

   lots = RoundToStep(lots, spec.vol_step);
   if(lots < spec.vol_min) return 0.0;
   return lots;
}

double GetRefLots(const SymbolSpec &spec)
{
   double want = InpRefLotsForUSDConv;
   if(want <= 0.0) want = 1.0;
   return ClampLots(spec, want);
}

double UsdToPriceDistance(const SymbolSpec &spec, const double usd, const double lots, const double tickValue)
{
   if(!spec.ok) return 0.0;
   if(usd <= 0.0) return 0.0;
   if(lots <= 0.0) return 0.0;
   if(tickValue <= 0.0 || spec.tick_size <= 0.0) return 0.0;

   return (usd * spec.tick_size) / (tickValue * lots);
}

double ProfitUSD_Move(const string sym, const bool isBuy, const double lots,
                      const double priceOpen, const double priceClose)
{
   double profit = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       sym, lots, priceOpen, priceClose, profit))
      return 0.0;
   return profit; // deposit currency (assumed USD in your inputs)
}

double LossUSD_ToSL_OneLot(const string sym, const bool isBuy,
                           const double entry, const double sl)
{
   // Profit for 1 lot if price goes from entry -> sl
   double p = ProfitUSD_Move(sym, isBuy, 1.0, entry, sl);
   if(p >= 0.0) return 0.0;
   return -p; // positive loss
}

double ProfitUSD_PerTick_OneLot(const string sym, const bool isBuy,
                                const double entry, const double tickSize)
{
   if(tickSize <= 0) return 0.0;
   double close = isBuy ? (entry + tickSize) : (entry - tickSize);
   double p = ProfitUSD_Move(sym, isBuy, 1.0, entry, close);
   return MathAbs(p);
}

double TP_FromMinProfitUSD(const SymbolSpec &spec, const string sym, const bool isBuy,
                           const double entry, const double lots, const double minProfitUSD)
{
   double tick = spec.tick_size;
   if(tick <= 0.0) SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE, tick);
   if(tick <= 0.0) return 0.0;

   double pPerTick1 = ProfitUSD_PerTick_OneLot(sym, isBuy, entry, tick);
   if(pPerTick1 <= 0.0) return 0.0;

   double ticksNeeded = MathCeil(minProfitUSD / (pPerTick1 * lots));
   if(ticksNeeded < 1) ticksNeeded = 1;

   double dist = ticksNeeded * tick;
   return isBuy ? (entry + dist) : (entry - dist);
}


double StructureUsdToPrice(const SymbolSpec &spec, const double usd)
{
   double refLots = GetRefLots(spec);
   double tv = TickValueForSL(spec);
   return UsdToPriceDistance(spec, usd, refLots, tv);
}


// AI helper 
int FindCtxIndexBySymbol(const string sym)
{
   for(int i=0;i<MAX_SYMS;i++)
      if(g_syms[i].enabled && g_syms[i].sym == sym)
         return i;
   return -1;
}

bool PositionIdExists(const ulong pos_id)
{
   int total = PositionsTotal();
   for(int i=total-1; i>=0; --i)
   {
      ulong ticket = (ulong)PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long id = (long)PositionGetInteger(POSITION_IDENTIFIER);
      if((ulong)id == pos_id) return true;
   }
   return false;
}


bool ReadOpenPositionById(const ulong pos_id,
                          string &symOut, long &magicOut,
                          double &volOut, double &openOut,
                          double &slOut, double &tpOut)
{
   symOut=""; magicOut=0; volOut=0; openOut=0; slOut=0; tpOut=0;

   int total = PositionsTotal();
   for(int i=total-1; i>=0; --i)
   {
      ulong ticket = (ulong)PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long id = (long)PositionGetInteger(POSITION_IDENTIFIER);
      if((ulong)id != pos_id) continue;

      symOut   = PositionGetString(POSITION_SYMBOL);
      magicOut = (long)PositionGetInteger(POSITION_MAGIC);
      volOut   = PositionGetDouble(POSITION_VOLUME);
      openOut  = PositionGetDouble(POSITION_PRICE_OPEN);
      slOut    = PositionGetDouble(POSITION_SL);
      tpOut    = PositionGetDouble(POSITION_TP);
      return true;
   }
   return false;
}

double PositionProfitFromHistory(const ulong pos_id)
{
   // Sum profit+commission+swap for ALL deals for this position id
   datetime toT   = TimeCurrent();
   datetime fromT = toT - 60*60*24*30; // last 30 days window
   HistorySelect(fromT, toT);

   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;

      ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pid != pos_id) continue;

      double p  = HistoryDealGetDouble(deal, DEAL_PROFIT);
      double c  = HistoryDealGetDouble(deal, DEAL_COMMISSION);
      double sw = HistoryDealGetDouble(deal, DEAL_SWAP);

      sum += (p + c + sw);
   }
   return sum;
}

string PosKey(const ulong pos_id, const string field)
{
   return StringFormat("BB_POS|%I64u|%s", pos_id, field);
}

void LearnOnPositionClosed(SymbolCtx &ctx, const bool isIntraday, const double profitTotal, const double plannedRisk)
{
   if(!InpLearnEnable) return;

   if(isIntraday)
   {
      ctx.learnIntra.nClosed++;
      if(profitTotal >= 0) { ctx.learnIntra.wins++; ctx.learnIntra.consecLoss=0; }
      else                 { ctx.learnIntra.losses++; ctx.learnIntra.consecLoss++; }

      double R = (plannedRisk > 0.0 ? (profitTotal / plannedRisk) : (profitTotal>=0 ? 1.0 : -1.0));
      if(ctx.learnIntra.nClosed == 1) ctx.learnIntra.emaR = R;
      else ctx.learnIntra.emaR = (1.0-InpLearnEmaAlpha)*ctx.learnIntra.emaR + InpLearnEmaAlpha*R;

      LearnRecompute(ctx.learnIntra);
      LearnSave(ctx.sym, "INTRA", ctx.learnIntra);
   }
   else
   {
      ctx.learnScalp.nClosed++;
      if(profitTotal >= 0) { ctx.learnScalp.wins++; ctx.learnScalp.consecLoss=0; }
      else                 { ctx.learnScalp.losses++; ctx.learnScalp.consecLoss++; }

      double R = (plannedRisk > 0.0 ? (profitTotal / plannedRisk) : (profitTotal>=0 ? 1.0 : -1.0));
      if(ctx.learnScalp.nClosed == 1) ctx.learnScalp.emaR = R;
      else ctx.learnScalp.emaR = (1.0-InpLearnEmaAlpha)*ctx.learnScalp.emaR + InpLearnEmaAlpha*R;

      LearnRecompute(ctx.learnScalp);
      LearnSave(ctx.sym, "SCALP", ctx.learnScalp);
   }
}

//-------------------------
// Sessions (Amman time GMT+3)
//-------------------------
datetime AmmanNow()
{
   return (datetime)(TimeGMT() + 3*3600);
}

int MinutesOfDay(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.hour*60 + dt.min;
}

bool InWindow(int nowMin, int startMin, int endMin)
{
   if(startMin <= endMin) return (nowMin >= startMin && nowMin <= endMin);
   return (nowMin >= startMin || nowMin <= endMin);
}

bool IsAllowedBySessions(string &whichSessionOut)
{
   whichSessionOut = "NONE";
   if(!InpUseSessions) { whichSessionOut = "SESSIONS_OFF"; return true; }

   MqlDateTime adt; TimeToStruct(AmmanNow(), adt);
   if(adt.day_of_week == 0 || adt.day_of_week == 6) { whichSessionOut="WEEKEND_BLOCK"; return false; }

   const int pre = (InpPreSessionMinutes < 0 ? 0 : InpPreSessionMinutes);
   int nowMin = MinutesOfDay(AmmanNow());

   int asiaStart   = 4*60,  asiaEnd     = 7*60;
   int londonStart = 10*60, londonEnd   = 13*60;
   int nyStart     = 17*60, nyEnd       = 20*60;
   int nyxStart    = 17*60 + 30, nyxEnd = 21*60;

   int aS = asiaStart - pre;   if(aS < 0) aS += 1440;
   int lS = londonStart - pre; if(lS < 0) lS += 1440;
   int nS = nyStart - pre;     if(nS < 0) nS += 1440;
   int xS = nyxStart - pre;    if(xS < 0) xS += 1440;

   if(InpAllowAsia   && InWindow(nowMin, aS, asiaEnd))     { whichSessionOut="ASIA"; return true; }
   if(InpAllowLondon && InWindow(nowMin, lS, londonEnd))   { whichSessionOut="LONDON"; return true; }
   if(InpAllowNY     && InWindow(nowMin, nS, nyEnd))       { whichSessionOut="NY"; return true; }
   if(InpAllowNYExec && InWindow(nowMin, xS, nyxEnd))      { whichSessionOut="NY_EXEC"; return true; }

   whichSessionOut="OUTSIDE_WINDOWS";
   return false;
}

//-------------------------
// Daily reset / loss
//-------------------------
void DailyResetIfNeeded() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int doy = dt.day_of_year;
   if(g_dayOfYear != doy) {
      g_dayOfYear = doy;
      g_tradesToday = 0;
      g_stopTrading = false;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("Daily reset. Start equity=", DoubleToString(g_dayStartEquity, 2));
   }
}

bool DailyLossExceeded() {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = g_dayStartEquity - eq;
   return (loss >= InpMaxDailyLossUSD);
}
//-------------------------
// AI Struct+helper

double ClampD(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

void LearnInit(LearnStats &ls)
{
   ls.nClosed=0; ls.wins=0; ls.losses=0; ls.consecLoss=0;
   ls.emaR=0.0;
   ls.riskMult=1.0;
   ls.tpMult=1.0;
   ls.slBufMult=1.0;
}

string LearnKey(const string sym, const string strat, const string field)
{
   return "BB_LEARN|" + sym + "|" + strat + "|" + field;
}

double GVGetD(const string key, const double defVal)
{
   if(!GlobalVariableCheck(key)) return defVal;
   return GlobalVariableGet(key);
}

void GVSetD(const string key, const double val)
{
   GlobalVariableSet(key, val);
}

void LearnLoad(const string sym, const string strat, LearnStats &ls)
{
   LearnInit(ls);
   if(!InpLearnEnable) return;

   ls.nClosed    = (int)GVGetD(LearnKey(sym,strat,"n"), 0);
   ls.wins       = (int)GVGetD(LearnKey(sym,strat,"w"), 0);
   ls.losses     = (int)GVGetD(LearnKey(sym,strat,"l"), 0);
   ls.consecLoss = (int)GVGetD(LearnKey(sym,strat,"cl"),0);
   ls.emaR       =      GVGetD(LearnKey(sym,strat,"emaR"), 0.0);

   ls.riskMult   =      GVGetD(LearnKey(sym,strat,"riskM"), 1.0);
   ls.tpMult     =      GVGetD(LearnKey(sym,strat,"tpM"),   1.0);
   ls.slBufMult  =      GVGetD(LearnKey(sym,strat,"slM"),   1.0);

   // clamp safety
   ls.riskMult  = ClampD(ls.riskMult,  InpLearnRiskMinMult, InpLearnRiskMaxMult);
   ls.tpMult    = ClampD(ls.tpMult,    InpLearnTPMinMult,   InpLearnTPMaxMult);
   ls.slBufMult = ClampD(ls.slBufMult, InpLearnSLBufMinMult,InpLearnSLBufMaxMult);
}

void LearnSave(const string sym, const string strat, const LearnStats &ls)
{
   if(!InpLearnEnable) return;

   GVSetD(LearnKey(sym,strat,"n"),    (double)ls.nClosed);
   GVSetD(LearnKey(sym,strat,"w"),    (double)ls.wins);
   GVSetD(LearnKey(sym,strat,"l"),    (double)ls.losses);
   GVSetD(LearnKey(sym,strat,"cl"),   (double)ls.consecLoss);
   GVSetD(LearnKey(sym,strat,"emaR"), ls.emaR);

   GVSetD(LearnKey(sym,strat,"riskM"), ls.riskMult);
   GVSetD(LearnKey(sym,strat,"tpM"),   ls.tpMult);
   GVSetD(LearnKey(sym,strat,"slM"),   ls.slBufMult);
}

void LearnRecompute(LearnStats &ls)
{
   // Default
   ls.riskMult=1.0; ls.tpMult=1.0; ls.slBufMult=1.0;

   if(!InpLearnEnable) return;
   if(ls.nClosed < InpLearnMinClosedTrades) return;

   double wr = (ls.nClosed > 0 ? (double)ls.wins / (double)ls.nClosed : 0.5);

   // Risk multiplier around winrate & streak
   double rm = 1.0 + (wr - 0.55) * 1.5;   // 55% => 1.0
   if(ls.consecLoss >= 2) rm *= 0.80;
   if(ls.consecLoss >= 3) rm *= 0.70;

   if(InpLearnPauseAfterLosses > 0 && ls.consecLoss >= InpLearnPauseAfterLosses)
      rm = InpLearnRiskMinMult;

   rm = ClampD(rm, InpLearnRiskMinMult, InpLearnRiskMaxMult);

   // SL buffer widens slightly after losses / negative EMA
   double sm = 1.0;
   if(ls.consecLoss >= 2) sm = 1.10;
   if(ls.consecLoss >= 3) sm = 1.20;
   if(ls.emaR < 0.0)      sm = MathMax(sm, 1.15);
   sm = ClampD(sm, InpLearnSLBufMinMult, InpLearnSLBufMaxMult);

   // TP distance adjusts lightly based on EMA R
   double tm = 1.0;
   if(ls.emaR < 0.20) tm = 0.95;
   if(ls.emaR < 0.00) tm = 0.90;
   if(ls.emaR > 0.70) tm = 1.05;
   if(ls.emaR > 1.00) tm = 1.10;
   tm = ClampD(tm, InpLearnTPMinMult, InpLearnTPMaxMult);

   ls.riskMult  = rm;
   ls.slBufMult = sm;
   ls.tpMult    = tm;
}

//-------------------------
// Minimal JSON helpers
//-------------------------
string ToLowerStr(string s){ StringToLower(s); return s; }

int FindMatching(const string s, int start, ushort openCh, ushort closeCh)
{
   int n = StringLen(s);
   int depth = 0;
   for(int i=start; i<n; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch == openCh) depth++;
      else if(ch == closeCh) {
         depth--;
         if(depth == 0) return i;
      }
   }
   return -1;
}

int FindValueStart(const string json, const string key, int fromPos=0)
{
   string k = "\"" + key + "\"";
   int p = StringFind(json, k, fromPos);
   if(p < 0) return -1;

   int c = StringFind(json, ":", p + StringLen(k));
   if(c < 0) return -1;

   int i = c + 1;
   while(i < StringLen(json)) {
      ushort ch = StringGetCharacter(json, i);
      if(ch!=' ' && ch!='\t' && ch!='\r' && ch!='\n') break;
      i++;
   }
   return i;
}

bool JsonGetBoolFrom(const string json, const string key, const bool defaultVal)
{
   int i = FindValueStart(json, key, 0);
   if(i < 0) return defaultVal;

   string low = ToLowerStr(json);
   if(StringSubstr(low, i, 4) == "true")  return true;
   if(StringSubstr(low, i, 5) == "false") return false;
   return defaultVal;
}

bool JsonGetStringFrom(const string json, const string key, string &out, const string defVal="")
{
   out = defVal;

   int i = FindValueStart(json, key, 0);
   if(i < 0) return false;

   if(StringGetCharacter(json, i) != '"') return false;
   i++;

   int n = StringLen(json);
   string s = "";
   bool esc = false;

   for(int j=i; j<n; j++)
   {
      ushort ch = StringGetCharacter(json, j);

      if(esc)
      {
         s += StringSubstr(json, j, 1);
         esc = false;
         continue;
      }

      if(ch == '\\') { esc = true; continue; }
      if(ch == '"')  { out = s; return true; }

      s += StringSubstr(json, j, 1);
   }
   return false;
}

double JsonGetNumberFrom(const string json, const string key, const double defaultVal)
{
   int i = FindValueStart(json, key, 0);
   if(i < 0) return defaultVal;

   int n = StringLen(json);

   // Skip whitespace
   while(i < n)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch!=' ' && ch!='\t' && ch!='\r' && ch!='\n') break;
      i++;
   }
   if(i >= n) return defaultVal;

   int j = i;
   bool started = false;

   for(; j<n; j++)
   {
      ushort ch = StringGetCharacter(json, j);

      bool ok =
         (ch >= '0' && ch <= '9') ||
         ch == '-' || ch == '+' ||
         ch == '.' || ch == 'e' || ch == 'E';

      if(ok) { started = true; continue; }
      if(started) break;
      // if not started yet, keep skipping (handles commas/quotes safely)
      break;
   }

   if(!started) return defaultVal;
   return StringToDouble(StringSubstr(json, i, j - i));
}


bool JsonExtractFirstArrayObject(const string json, const string arrKey, string &outObj)
{
   outObj = "";
   int i = FindValueStart(json, arrKey, 0);
   if(i < 0) return false;

   if(StringGetCharacter(json, i) != '[') return false;
   int closeArr = FindMatching(json, i, '[', ']');
   if(closeArr < 0) return false;

   int k = i + 1;
   while(k < closeArr)
   {
      ushort ch = StringGetCharacter(json, k);
      if(ch!=' ' && ch!='\t' && ch!='\r' && ch!='\n') break;
      k++;
   }
   if(k < closeArr && StringGetCharacter(json, k) == ']')
      return false;


   int p = StringFind(json, "{", i);
   if(p < 0 || p > closeArr) return false;

   int q = FindMatching(json, p, '{', '}');
   if(q < 0 || q > closeArr) return false;

   outObj = StringSubstr(json, p, q-p+1);
   return true;
}

bool JsonExtractObject(const string json, const string objKey, string &outObj, int fromPos=0)
{
   outObj = "";
   int i = FindValueStart(json, objKey, fromPos);
   if(i < 0) return false;

   if(StringGetCharacter(json, i) != '{') return false;
   int j = FindMatching(json, i, '{', '}');
   if(j < 0) return false;

   outObj = StringSubstr(json, i, j-i+1);
   return true;
}

// Normalize time that may arrive as ms or sec (safe for dedup + comparisons)
long NormalizeTimeMaybeMs(long t)
{
   if(t <= 0) return 0;
   if(t > 20000000000) t = (long)(t / 1000); // ms -> sec
   return t;
}

bool TimeCloseEnough(const long a, const long b, const int tolSec)
{
   if(a<=0 || b<=0) return false;
   return (MathAbs(a-b) <= tolSec);
}

bool IsFreshWithSkew(const long evtTimeSec, const int freshSec)
{
   if(evtTimeSec<=0 || freshSec<=0) return false;
   long nowG = (long)TimeGMT();
   long age  = nowG - evtTimeSec;
   if(age < 0)
   {
      if(MathAbs(age) <= InpIntraTimeSkewToleranceSec) age = 0;
      else return false;
   }
   return (age <= freshSec);
}

bool TFHasBreakoutForAccRT(const TFState &st, const long accRT)
{
   if(accRT<=0) return false;
   if(st.brk.valid)
   {
      long rt = NormalizeTimeMaybeMs((long)st.brk.acc_right_time);
      if(rt>0 && (rt==accRT || TimeCloseEnough(rt, accRT, InpIntraAccRTToleranceSec)))
         return true;
   }
   return false;
}

// Extract the latest (max timeField) object from json[arrayKey]
bool JsonExtractLatestArrayObjectByTime(const string json,
                                        const string arrayKey,
                                        const string timeField,
                                        string &outObj,
                                        long &outTime)
{
   outObj = "";
   outTime = 0;

   int i = FindValueStart(json, arrayKey, 0);
   if(i < 0) return false;

   if(StringGetCharacter(json, i) != '[') return false;

   int closeArr = FindMatching(json, i, '[', ']');
   if(closeArr < 0) return false;

   // Empty array?
   int k = i + 1;
   while(k < closeArr)
   {
      ushort ch = StringGetCharacter(json, k);
      if(ch!=' ' && ch!='\t' && ch!='\r' && ch!='\n') break;
      k++;
   }
   if(k < closeArr && StringGetCharacter(json, k) == ']')
      return false;


   long bestT = 0;
   string bestObj = "";

   int p = i + 1;
   while(true)
   {
      // find next '{' inside the array bounds
      int o = StringFind(json, "{", p);
      if(o < 0 || o > closeArr) break;

      int c = FindMatching(json, o, '{', '}');
      if(c < 0 || c > closeArr) break;

      string obj = StringSubstr(json, o, c - o + 1);

      // read time
      long t = (long)JsonGetNumberFrom(obj, timeField, 0.0);
      t = NormalizeTimeMaybeMs(t);

      if(t > bestT)
      {
         bestT = t;
         bestObj = obj;
      }

      p = c + 1;
      if(p >= closeArr) break;
   }

   if(bestT <= 0 || bestObj == "") return false;

   outObj = bestObj;
   outTime = bestT;
   return true;
}


bool JsonFindArrayBounds(const string json, const string arrayKey, int &openPos, int &closePos)
{
   openPos = -1; closePos = -1;
   int i = FindValueStart(json, arrayKey, 0);
   if(i < 0) return false;
   if(StringGetCharacter(json, i) != '[') return false;

   openPos = i;
   closePos = FindMatching(json, openPos, '[', ']');
   return (closePos >= 0);
}

bool JsonNextObjectInArray(const string json, const int closePos, int &pos, string &outObj)
{
   outObj = "";
   int o = StringFind(json, "{", pos);
   if(o < 0 || o > closePos) return false;

   int c = FindMatching(json, o, '{', '}');
   if(c < 0 || c > closePos) return false;

   outObj = StringSubstr(json, o, c - o + 1);
   pos = c + 1;
   return true;
}

void SortAccListByTimeDesc(AccumArea &arr[], int count)
{
   for(int i=0;i<count;i++)
   {
      for(int j=i+1;j<count;j++)
      {
         if(arr[j].right_time > arr[i].right_time)
         {
            AccumArea tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
         }
      }
   }
}

void SortWickListByTimeDesc(WickArea &arr[], int count)
{
   for(int i=0;i<count;i++)
   {
      for(int j=i+1;j<count;j++)
      {
         if(arr[j].break_time > arr[i].break_time)
         {
            WickArea tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
         }
      }
   }
}

void SortGZListByTimeDesc(GoldZone &arr[], int count)
{
   for(int i=0;i<count;i++)
   {
      for(int j=i+1;j<count;j++)
      {
         if(arr[j].gz_time > arr[i].gz_time)
         {
            GoldZone tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
         }
      }
   }
}

void CollectAccumsFromTFObj(const string tfObj, TFState &st)
{
   st.accCount = 0;
   st.acc.valid = false;

   int a0,a1;
   if(!JsonFindArrayBounds(tfObj, "accum", a0, a1)) return;

   int pos = a0 + 1;
   string obj;

   while(st.accCount < INTRA_KEEP_ACC && JsonNextObjectInArray(tfObj, a1, pos, obj))
   {
      AccumArea tmp;
      if(ParseAccumObj(obj, tmp))
      {
         tmp.left_time  = NormalizeTimeMaybeMs(tmp.left_time);
         tmp.right_time = NormalizeTimeMaybeMs(tmp.right_time);
         st.accList[st.accCount] = tmp;
         st.accCount++;
      }
   }

   if(st.accCount > 0)
   {
      SortAccListByTimeDesc(st.accList, st.accCount);
      st.acc = st.accList[0];
   }
}

void CollectWicksFromTFObj(const string tfObj, TFState &st)
{
   st.wickCount = 0;
   st.wick.valid = false;

   int a0,a1;
   if(!JsonFindArrayBounds(tfObj, "wicks", a0, a1)) return;

   int pos = a0 + 1;
   string obj;

   while(st.wickCount < INTRA_KEEP_WICK && JsonNextObjectInArray(tfObj, a1, pos, obj))
   {
      WickArea tmp;
      if(ParseWickObj(obj, tmp))
      {
         tmp.break_time = NormalizeTimeMaybeMs(tmp.break_time);
         st.wickList[st.wickCount] = tmp;
         st.wickCount++;
      }
   }

   if(st.wickCount > 0)
   {
      SortWickListByTimeDesc(st.wickList, st.wickCount);
      st.wick = st.wickList[0];
   }
}

void CollectGZFromTFObj(const string tfObj, TFState &st)
{
   st.gzCount = 0;
   st.gz.valid = false;

   int a0,a1;
   if(!JsonFindArrayBounds(tfObj, "gz", a0, a1)) return;

   int pos = a0 + 1;
   string obj;

   while(st.gzCount < INTRA_KEEP_GZ && JsonNextObjectInArray(tfObj, a1, pos, obj))
   {
      GoldZone tmp;
      if(ParseGzObj(obj, tmp))
      {
         tmp.gz_time        = NormalizeTimeMaybeMs(tmp.gz_time);
         tmp.acc_right_time = NormalizeTimeMaybeMs(tmp.acc_right_time);
         st.gzList[st.gzCount] = tmp;
         st.gzCount++;
      }
   }

   if(st.gzCount > 0)
   {
      SortGZListByTimeDesc(st.gzList, st.gzCount);
      st.gz = st.gzList[0];
   }
}

// Heikin-Ashi OHLC for a single bar shift (used to check "GZ touched by HA candles")
bool GetHACandleOHLC(const string sym, ENUM_TIMEFRAMES tf, int shift,
                     double &haOpen, double &haClose, double &haHigh, double &haLow)
{
   haOpen=0; haClose=0; haHigh=0; haLow=0;

   int bars = Bars(sym, tf);
   int need = shift + 30;
   if(bars <= need) return false;

   double prev_hao=0, prev_hac=0;

   for(int i=need; i>=shift; --i)
   {
      double o=iOpen(sym, tf, i);
      double h=iHigh(sym, tf, i);
      double l=iLow(sym, tf, i);
      double c=iClose(sym, tf, i);
      if(o==0 && h==0 && l==0 && c==0) continue;

      double hac = (o+h+l+c)/4.0;
      double hao;
      if(i==need) hao = (o+c)/2.0;
      else        hao = (prev_hao + prev_hac)/2.0;

      prev_hao = hao;
      prev_hac = hac;

      if(i==shift)
      {
         haOpen  = hao;
         haClose = hac;
         haHigh  = MathMax(h, MathMax(haOpen, haClose));
         haLow   = MathMin(l, MathMin(haOpen, haClose));
         return true;
      }
   }
   return false;
}

bool HATouchedRangeSince(const string sym, ENUM_TIMEFRAMES tf,
                         const long sinceEpochSec,
                         const double lo, const double hi,
                         const int maxBars)
{
   if(lo<=0 || hi<=0 || hi<=lo) return false;
   if(sinceEpochSec <= 0) return false;

   datetime sinceT = (datetime)sinceEpochSec;
   int startShift = iBarShift(sym, tf, sinceT, true);
   if(startShift < 1) startShift = MathMin(maxBars, 200);

   int checked=0;
   for(int sh=startShift; sh>=1 && checked<maxBars; --sh)
   {
      double hao,hac,hah,hal;
      if(GetHACandleOHLC(sym, tf, sh, hao, hac, hah, hal))
      {
         bool hit = !(hah < lo || hal > hi); // overlap
         if(hit) return true;
      }
      checked++;
   }
   return false;
}

// forward declarations (put these above the wrapper if needed)
void OnTradeTransaction_Legacy(const MqlTradeTransaction& trans,
                               const MqlTradeRequest& request,
                               const MqlTradeResult& result);



// the ONLY event handler
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   OnTradeTransaction_Legacy(trans, request, result);
   OnTradeTransaction_StepD(trans, request, result);
}

//-------------------------
// Parse Node-RED snapshot (gates + areas)
//-------------------------
void ClearAreas(AreasSnap &a)
{
   a.M.acc.valid=false;  a.M.wick.valid=false;  a.M.gz.valid=false;  a.M.brk.valid=false;  a.M.mit.valid=false;
   a.W.acc.valid=false;  a.W.wick.valid=false;  a.W.gz.valid=false;  a.W.brk.valid=false;  a.W.mit.valid=false;
   a.D.acc.valid=false;  a.D.wick.valid=false;  a.D.gz.valid=false;  a.D.brk.valid=false;  a.D.mit.valid=false;
   a.H1.acc.valid=false; a.H1.wick.valid=false; a.H1.gz.valid=false; a.H1.brk.valid=false; a.H1.mit.valid=false;
   a.M5.acc.valid=false; a.M5.wick.valid=false; a.M5.gz.valid=false; a.M5.brk.valid=false; a.M5.mit.valid=false;
   a.M1.acc.valid=false; a.M1.wick.valid=false; a.M1.gz.valid=false; a.M1.brk.valid=false; a.M1.mit.valid=false;

   a.M.accCount=0;  a.M.wickCount=0;  a.M.gzCount=0;
   a.W.accCount=0;  a.W.wickCount=0;  a.W.gzCount=0;
   a.D.accCount=0;  a.D.wickCount=0;  a.D.gzCount=0;
   a.H1.accCount=0; a.H1.wickCount=0; a.H1.gzCount=0;
   a.M5.accCount=0; a.M5.wickCount=0; a.M5.gzCount=0;
   a.M1.accCount=0; a.M1.wickCount=0; a.M1.gzCount=0;
}



bool ParseAccumObj(const string obj, AccumArea &acc)
{
   acc.valid=false;
   acc.high = JsonGetNumberFrom(obj, "high", 0.0);
   acc.low  = JsonGetNumberFrom(obj, "low", 0.0);
   acc.left_time  = (long)JsonGetNumberFrom(obj, "left_time", 0.0);
   acc.right_time = (long)JsonGetNumberFrom(obj, "right_time", 0.0);

   acc.line_top    = JsonGetNumberFrom(obj, "line_top",    0.0);
   acc.line_top25  = JsonGetNumberFrom(obj, "line_top25",  0.0);
   acc.line_bot25  = JsonGetNumberFrom(obj, "line_bot25",  0.0);
   acc.line_bottom = JsonGetNumberFrom(obj, "line_bottom", 0.0);

   if(acc.high>0 && acc.low>0 && acc.high>acc.low && acc.right_time>0)
   {
      double rng = acc.high - acc.low;
      if(acc.line_top <= 0.0)    acc.line_top = acc.high;
      if(acc.line_bottom <= 0.0) acc.line_bottom = acc.low;
      if(acc.line_top25 <= 0.0)  acc.line_top25 = acc.high - rng*0.25;
      if(acc.line_bot25 <= 0.0)  acc.line_bot25 = acc.low  + rng*0.25;

      acc.valid=true;
      return true;
   }
   return false;
}

bool ParseWickObj(const string obj, WickArea &w)
{
   w.valid=false;
   w.break_time = (long)JsonGetNumberFrom(obj, "break_time", 0.0);
   w.wick_level = JsonGetNumberFrom(obj, "wick_level", 0.0);

   string dir=""; JsonGetStringFrom(obj, "dir", dir, "");
   if(dir=="UP") w.dir=+1;
   else if(dir=="DOWN") w.dir=-1;
   else w.dir=0;

   if(w.break_time>0 && w.wick_level>0) { w.valid=true; return true; }
   return false;
}

bool ParseGzObj(const string obj, GoldZone &g)
{
   g.valid=false;
   g.gz_time = (long)JsonGetNumberFrom(obj, "gz_time", 0.0);
   g.acc_right_time = (long)JsonGetNumberFrom(obj, "acc_right_time", 0.0);

   g.upper = JsonGetNumberFrom(obj, "upper", 0.0);
   g.lower = JsonGetNumberFrom(obj, "lower", 0.0);
   if(g.upper <= 0.0) g.upper = JsonGetNumberFrom(obj, "goldenzone_upper", 0.0);
   if(g.lower <= 0.0) g.lower = JsonGetNumberFrom(obj, "goldenzone_lower", 0.0);

   if(g.upper>0 && g.lower>0 && g.upper>g.lower && g.gz_time>0) { g.valid=true; return true; }
   return false;
}

bool ParseBreakoutObj(const string obj, BreakoutEvt &b)
{
   b.valid=false;

   b.break_time     = (long)JsonGetNumberFrom(obj, "break_time", 0.0);
   b.acc_right_time = (long)JsonGetNumberFrom(obj, "acc_right_time", 0.0);

   // Accept multiple price field names (and allow missing)
   b.break_price    = JsonGetNumberFrom(obj, "break_price", 0.0);
   if(b.break_price <= 0.0) b.break_price = JsonGetNumberFrom(obj, "price", 0.0);

   string dir=""; JsonGetStringFrom(obj, "dir", dir, "");
   if(dir=="UP") b.dir=+1;
   else if(dir=="DOWN") b.dir=-1;
   else b.dir=0;

   b.break_time     = NormalizeTimeMaybeMs(b.break_time);
   b.acc_right_time = NormalizeTimeMaybeMs(b.acc_right_time);

   // ? DON'T require break_price>0 (Node-RED may store null)
   if(b.break_time>0 && b.acc_right_time>0 && b.dir!=0)
   {
      b.valid=true;
      return true;
   }
   return false;
}


bool ParseMitigationObj(const string obj, MitigationEvt &m)
{
   m.valid=false;

   // ? Support BOTH formats:
   // - Old EA expects: mit_time / mit_price
   // - Node-RED currently stores: time / mitigation_time + price
   m.mit_time = (long)JsonGetNumberFrom(obj, "mit_time", 0.0);
   if(m.mit_time <= 0) m.mit_time = (long)JsonGetNumberFrom(obj, "mitigation_time", 0.0);
   if(m.mit_time <= 0) m.mit_time = (long)JsonGetNumberFrom(obj, "time", 0.0);

   m.acc_right_time = (long)JsonGetNumberFrom(obj, "acc_right_time", 0.0);

   m.mit_price = JsonGetNumberFrom(obj, "mit_price", 0.0);
   if(m.mit_price <= 0.0) m.mit_price = JsonGetNumberFrom(obj, "price", 0.0);
   if(m.mit_price <= 0.0) m.mit_price = JsonGetNumberFrom(obj, "touch_price", 0.0);

   string dir=""; JsonGetStringFrom(obj, "dir", dir, "");
   if(dir=="UP") m.dir=+1;
   else if(dir=="DOWN") m.dir=-1;
   else m.dir=0;

   // status optional (default to MITIGATED)
   string st=""; 
   JsonGetStringFrom(obj, "status", st, "");
   if(st=="") st="MITIGATED";
   m.status = st;

   m.mit_time       = NormalizeTimeMaybeMs(m.mit_time);
   m.acc_right_time = NormalizeTimeMaybeMs(m.acc_right_time);

   // Keep it strict: require price (you need it for intraday logic)
   if(m.mit_time>0 && m.acc_right_time>0 && m.mit_price>0 && m.dir!=0)
   {
      m.valid=true;
      return true;
   }
   return false;
}


void ParseTFState(const string tfObj, TFState &st)
{
   st.acc.valid=false; st.wick.valid=false; st.gz.valid=false; st.brk.valid=false; st.mit.valid=false;
   st.accCount=0; st.wickCount=0; st.gzCount=0;

   // Collect full lists (NEW)
   CollectAccumsFromTFObj(tfObj, st);
   CollectWicksFromTFObj(tfObj, st);
   CollectGZFromTFObj(tfObj, st);

   // Breakout: latest break_time
   string brkObj="";
   long t=0;
   if(JsonExtractLatestArrayObjectByTime(tfObj, "breakouts", "break_time", brkObj, t))
      ParseBreakoutObj(brkObj, st.brk);

   // Mitigation: latest (support multiple time field names)
   string mitObj="";
   long tMit=0;
   
   if(JsonExtractLatestArrayObjectByTime(tfObj, "mitigations", "mit_time", mitObj, tMit))
      ParseMitigationObj(mitObj, st.mit);
   else if(JsonExtractLatestArrayObjectByTime(tfObj, "mitigations", "mitigation_time", mitObj, tMit))
      ParseMitigationObj(mitObj, st.mit);
   else if(JsonExtractLatestArrayObjectByTime(tfObj, "mitigations", "time", mitObj, tMit))
      ParseMitigationObj(mitObj, st.mit);

}


bool ParseNodeRedResponseIntoCtx(const string json, SymbolCtx &ctx)
{

   ctx.gates.liquidity_ok = JsonGetBoolFrom(json, "liquidity_ok", false);
   ctx.gates.news_block   = JsonGetBoolFrom(json, "news_block",   true);

   ctx.areas_updated_at = (long)JsonGetNumberFrom(json, "areas_updated_at", 0.0);
   ctx.gates_updated_at = (long)JsonGetNumberFrom(json, "gates_updated_at", 0.0);
   ctx.updated_at       = (long)JsonGetNumberFrom(json, "updated_at", 0.0);

   ctx.areas_updated_at = NormalizeTimeMaybeMs(ctx.areas_updated_at);
   ctx.gates_updated_at = NormalizeTimeMaybeMs(ctx.gates_updated_at);
   ctx.updated_at       = NormalizeTimeMaybeMs(ctx.updated_at);
   
   if(ctx.areas_updated_at <= 0) ctx.areas_updated_at = ctx.updated_at;
   if(ctx.gates_updated_at <= 0) ctx.gates_updated_at = ctx.updated_at;

   if(ctx.updated_at <= 0)
      ctx.updated_at = (long)MathMax((double)ctx.areas_updated_at, (double)ctx.gates_updated_at);
   string ns=""; JsonGetStringFrom(json, "news_source", ns, "unknown");
   ctx.news_source = ns;

   bool v = JsonGetBoolFrom(json, "valid", false);
   if(!v) v = (ctx.updated_at > 0);
   ctx.gates.valid = v;

   string areasObj="";
   if(!JsonExtractObject(json, "areas", areasObj, 0)) {
      ClearAreas(ctx.areas);
      return true;
   }

   string tf="";
   if(JsonExtractObject(areasObj, "M", tf, 0))  ParseTFState(tf, ctx.areas.M);
   if(JsonExtractObject(areasObj, "W", tf, 0))  ParseTFState(tf, ctx.areas.W);
   if(JsonExtractObject(areasObj, "D", tf, 0))  ParseTFState(tf, ctx.areas.D);
   if(JsonExtractObject(areasObj, "H1", tf, 0)) ParseTFState(tf, ctx.areas.H1);
   if(JsonExtractObject(areasObj, "M5", tf, 0)) ParseTFState(tf, ctx.areas.M5);
   if(JsonExtractObject(areasObj, "M1", tf, 0)) ParseTFState(tf, ctx.areas.M1);

      // After the first successful snapshot (manual sync), do not block trading on stale TTL timestamps
   if(!ctx.has_initial_sync)
   {
      bool hasAnyAcc = (ctx.areas.M.acc.valid || ctx.areas.W.acc.valid || ctx.areas.D.acc.valid ||
                        ctx.areas.H1.acc.valid || ctx.areas.M5.acc.valid || ctx.areas.M1.acc.valid);
      if(hasAnyAcc && ctx.areas_updated_at>0 && ctx.gates_updated_at>0)
         ctx.has_initial_sync = true;
   }

return true;
}

//-------------------------
// Effective gates (manual vs Node-RED)
//-------------------------
Gates GetEffectiveGates(const SymbolCtx &ctx)
{
   Gates g;
   if(InpGateSource == GATE_MANUAL_OFFLINE) {
      g.liquidity_ok = InpLiquidityOkManual;
      g.news_block   = InpNewsBlockManual;
      g.valid        = true;
   } else {
      g = ctx.gates;
   }
   return g;
}

string UrlEncodeSym(string s){
   StringReplace(s, "%", "%25");
   StringReplace(s, " ", "%20");
   StringReplace(s, "#", "%23");
   StringReplace(s, "&", "%26");
   StringReplace(s, "+", "%2B");
   return s;
}
// Return a trimmed copy (because MQL5 trim funcs work by reference)
string StringTrim(const string src)
{
   string s = src;
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

//-------------------------
// Node-RED Poll
//-------------------------
string BuildPollUrl(const string base, const string sym)
{
   string url = base;
   string qs  = UrlEncodeSym(NodeSymbolForPoll(sym));

   if(StringFind(url, "?") >= 0) url += "&symbol=" + qs;
   else                          url += "?symbol=" + qs;

   return url;
}

bool PollNodeRedForSymbol(SymbolCtx &ctx)
{
   if(InpNodeRedURLBase == "" || ctx.sym == "") return false;

   string pollSym = NodeRedKeyFromExecSymbol(ctx.sym);
   string url     = BuildPollUrl(InpNodeRedURLBase, pollSym);


   uchar data[];
   uchar result[];
   string req_headers = "X-SECRET: " + InpNodeRedSecret + "\r\n";
   string res_headers;

   ResetLastError();
   int http = WebRequest("GET", url, req_headers, InpWebTimeoutMs, data, result, res_headers);

   if(http == -1) {
      Print("WebRequest failed. Error=", GetLastError(),
            " | Whitelist base URL in MT5 Options -> Expert Advisors.");
      Print("Tried URL: ", url);
      return false;
   }

   string json = CharArrayToString(result, 0, -1);
   if(http != 200 || StringLen(json) < 2) {
      Print("Node-RED poll HTTP=", http, " symbol=", ctx.sym, " body=", json);
      Print("Tried URL: ", url);
      return false;
   }

   ParseNodeRedResponseIntoCtx(json, ctx);

   if(InpDebugPrintGates) {
      Print("Node-RED parsed [", ctx.sym, "]: liq=", ctx.gates.liquidity_ok,
            " news_block=", ctx.gates.news_block,
            " areas_updated_at=", (long)ctx.areas_updated_at,
            " gates_updated_at=", (long)ctx.gates_updated_at,
            " updated_at=", (long)ctx.updated_at,
            " news_source=", ctx.news_source,
            " | URL=", url);
   }
   return true;
}

//-------------------------
// Telemetry
//-------------------------
string JsonEscape(const string s)
{
   string out = s;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   StringReplace(out, "\n", "\\n");
   StringReplace(out, "\r", "\\r");
   StringReplace(out, "\t", "\\t");
   return out;
}

bool SendTelemetry(const string type,
                   const string symbol,
                   const string side,
                   const double lots,
                   const double entry,
                   const double sl,
                   const double tp,
                   const string rr,
                   const string reason,
                   const double profit,
                   const Gates &g)
{
   if(!InpEnableTelemetry) return false;
   if(InpNodeRedTelemetryURL == "") return false;

   string json =
      "{"
      "\"type\":\""   + JsonEscape(type)   + "\","
      "\"symbol\":\"" + JsonEscape(symbol) + "\","
      "\"side\":\""   + JsonEscape(side)   + "\","
      "\"lots\":"     + DoubleToString(lots, 2) + ","
      "\"entry\":"    + DoubleToString(entry, 10) + ","
      "\"sl\":"       + DoubleToString(sl, 10) + ","
      "\"tp\":"       + DoubleToString(tp, 10) + ","
      "\"rr\":\""     + JsonEscape(rr)     + "\","
      "\"reason\":\"" + JsonEscape(reason) + "\","
      "\"profit\":"   + DoubleToString(profit, 2) + ","
      "\"liquidity_ok\":" + (g.liquidity_ok ? "true":"false") + ","
      "\"news_block\":"   + (g.news_block  ? "true":"false") + ","
      "\"time\":"     + IntegerToString((int)TimeCurrent()) + ","
      "\"secret\":\"" + JsonEscape(InpNodeRedSecret) + "\""
      "}";

   uchar data2[];
   int len = StringToCharArray(json, data2, 0, StringLen(json), CP_UTF8);
   ArrayResize(data2, len);

   uchar result2[];
   string res_headers;
   string req_headers = "Content-Type: application/json\r\n";

   ResetLastError();
   int http = WebRequest("POST", InpNodeRedTelemetryURL, req_headers, InpWebTimeoutMs, data2, result2, res_headers);

   if(http == -1) {
      Print("Telemetry WebRequest failed. err=", GetLastError(),
            " | Add Node-RED URL to MT5 WebRequest whitelist.");
      return false;
   }

   if(http < 200 || http >= 300) {
      string body = CharArrayToString(result2, 0, -1);
      Print("Telemetry HTTP=", http, " body=", body);
      return false;
   }
   return true;
}

//-------------------------
// Trade helpers
//-------------------------
bool HasOpenPositionForMagic(const string sym, const int magic)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; --i)
   {
      ulong ticket = (ulong)PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string s = PositionGetString(POSITION_SYMBOL);
      long mg  = (long)PositionGetInteger(POSITION_MAGIC);

      if(s == sym && (int)mg == magic) return true;
   }
   return false;
}


ENUM_ORDER_TYPE_FILLING GetFillingModeFor(const string sym)
{
   long mode = 0;
   if(!SymbolInfoInteger(sym, SYMBOL_FILLING_MODE, mode))
      return ORDER_FILLING_RETURN;

   // mode values are typically:
   // 0 = FOK, 1 = IOC, 2 = RETURN
   switch((int)mode)
   {
      case 0:  return ORDER_FILLING_FOK;
      case 1:  return ORDER_FILLING_IOC;
      case 2:  return ORDER_FILLING_RETURN;
      default: return ORDER_FILLING_RETURN;
   }
}



bool OrderSendWithFillingFallback(MqlTradeRequest &req, MqlTradeResult &res)
{
   ENUM_ORDER_TYPE_FILLING pref = req.type_filling;

   ENUM_ORDER_TYPE_FILLING tries[4];
   tries[0] = pref;
   tries[1] = ORDER_FILLING_RETURN;
   tries[2] = ORDER_FILLING_IOC;
   tries[3] = ORDER_FILLING_FOK;

   for(int k = 0; k < 4; k++)
   {
      if(k > 0 && tries[k] == tries[k-1]) continue;

      req.type_filling = tries[k];

      // IMPORTANT: do NOT overwrite req.comment here.
      // Caller (PlaceMarket / CloseOnePositionByTicket) sets req.comment already.

      ResetLastError();
      bool ok = OrderSend(req, res);

      if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return true;

      // If it's NOT a filling-mode problem, stop immediately
      if(res.retcode != TRADE_RETCODE_INVALID_FILL)
         return false;
   }

   return false;
}


bool PlaceMarket(SymbolCtx &ctx, const bool isBuy, const double lots,
                 const double slPrice, const double tpPrice,
                 const Gates &gatesForTelemetry,
                 const string reasonTag,
                 const string rrStr,
                 const int magic,
                 const bool isIntraday)
{
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   req.action        = TRADE_ACTION_DEAL;
   req.symbol        = ctx.spec.symbol;
   req.magic         = magic;
   req.volume        = lots;
   req.type          = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price         = isBuy ? GetAsk(ctx.spec.symbol) : GetBid(ctx.spec.symbol);
   req.sl            = slPrice;
   req.tp            = tpPrice;
   req.deviation     = InpSlippagePoints;
   req.type_filling  = GetFillingModeFor(ctx.spec.symbol);
   
   // Store setup identity in order comment (so we can read it later from history on close)
   if(ctx.pendingOrderComment != "")
      req.comment = ctx.pendingOrderComment;

   bool ok = OrderSendWithFillingFallback(req, res);
   if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)) {
      Print("OrderSend failed sym=", ctx.spec.symbol, " retcode=", res.retcode, " comment=", res.comment);
      SendTelemetry("error", ctx.spec.symbol, (isBuy?"BUY":"SELL"), lots, req.price, slPrice, tpPrice, rrStr,
                    "order_send_failed retcode="+IntegerToString((int)res.retcode)+" "+res.comment, 0.0, gatesForTelemetry);
      return false;
   }

   g_tradesToday++;
   if(isIntraday) ctx.lastTradeTimeIntra = TimeCurrent();
   else           ctx.lastTradeTimeScalp = TimeCurrent();


   SendTelemetry("trade_open",
                 ctx.spec.symbol,
                 (isBuy ? "BUY":"SELL"),
                 lots,
                 req.price,
                 slPrice,
                 tpPrice,
                 rrStr,
                 reasonTag,
                 0.0,
                 gatesForTelemetry);
                 
   ctx.pendingOrderComment = "";              
   return true;
}

// Close position helper (NEW, used only by intraday force-flat)
bool CloseOnePositionByTicket(ulong ticket, const string exit_reason, const Gates &gatesForTelemetry, const int magic)

{
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;

   string sym = PositionGetString(POSITION_SYMBOL);
   long   mg  = (long)PositionGetInteger(POSITION_MAGIC);
   if((int)mg != magic) return false;

   long   type = (long)PositionGetInteger(POSITION_TYPE);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   if(sym == "" || vol <= 0) return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.magic        = magic;
   req.volume       = vol;
   req.position     = ticket;
   req.deviation    = InpSlippagePoints;
   req.type_filling = GetFillingModeFor(sym);

   // Put reason in comment (safe length: many brokers limit to 31 chars)
   string cmt = exit_reason;
   if(StringLen(cmt) > 31) cmt = StringSubstr(cmt, 0, 31);
   req.comment = cmt;

   bool isBuyPos = (type == POSITION_TYPE_BUY);
   req.type  = isBuyPos ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = isBuyPos ? GetBid(sym) : GetAsk(sym);

   bool ok = OrderSendWithFillingFallback(req, res);
   if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
   {
      Print("Close failed ticket=", ticket, " sym=", sym, " retcode=", res.retcode, " comment=", res.comment);

      SendTelemetry("error", sym, "CLOSE", vol, req.price, 0.0, 0.0, "n/a",
                    "force_close_failed "+exit_reason+
                    " retcode="+IntegerToString((int)res.retcode)+" "+res.comment,
                    0.0, gatesForTelemetry);
      return false;
   }

   SendTelemetry("trade_force_close", sym, "CLOSE", vol, req.price, 0.0, 0.0, "n/a", exit_reason, 0.0, gatesForTelemetry);
   return true;
}

// Close all EA positions for a symbol (NEW, intraday only)
void ForceFlatSymbol(const string sym, const string exit_reason, const Gates &gatesForTelemetry, const int magic)

{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; --i)
   {
      ulong ticket = (ulong)PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string s  = PositionGetString(POSITION_SYMBOL);
      long   mg = (long)PositionGetInteger(POSITION_MAGIC);

      if(s != sym) continue;
      if((int)mg != magic) continue;

      CloseOnePositionByTicket(ticket, exit_reason, gatesForTelemetry, magic);
   }
}


//-------------------------
// Heikin Ashi helpers
//-------------------------
bool GetHACandleOC(const string sym, ENUM_TIMEFRAMES tf, int shift, double &haOpen, double &haClose)
{
   haOpen = 0; haClose = 0;

   int bars = Bars(sym, tf);
   int need = shift + 30;
   if(bars <= need) return false;

   double prev_hao=0, prev_hac=0;

   for(int i=need; i>=shift; --i)
   {
      double o=iOpen(sym, tf, i);
      double h=iHigh(sym, tf, i);
      double l=iLow(sym, tf, i);
      double c=iClose(sym, tf, i);
      if(o==0 && h==0 && l==0 && c==0) continue;

      double hac = (o+h+l+c)/4.0;
      double hao;
      if(i==need) hao = (o+c)/2.0;
      else        hao = (prev_hao + prev_hac)/2.0;

      prev_hao = hao;
      prev_hac = hac;

      if(i==shift) { haOpen = hao; haClose = hac; return true; }
   }
   return false;
}

int HABiasDir(const string sym, ENUM_TIMEFRAMES tf, int shift = 1)
{
   double hao,hac;
   if(!GetHACandleOC(sym, tf, shift, hao, hac)) return 0;
   if(hac > hao) return +1;
   if(hac < hao) return -1;
   return 0;
}

//-------------------------
// Execution decision helpers
//-------------------------
bool SpreadOK(const SymbolSpec &spec)
{
   double a=GetAsk(spec.symbol), b=GetBid(spec.symbol);
   if(a<=0 || b<=0) return false;
   double spPoints = (a-b)/spec.point;
   return (spPoints <= InpMaxSpreadPoints);
}

// normalize timestamp seconds (handles ms/sec + clock skew)
long NormalizeEpochSec(long rawSec)
{
   long ua = rawSec;
   if(ua <= 0) return 0;

   if(ua > 20000000000) ua = (long)(ua / 1000);

   long nowSec = (long)TimeGMT();
   long age = (nowSec - ua);

   if(age < 0)
   {
      if(MathAbs(age) <= 6*3600) return ua;
      return 0;
   }
   return ua;
}

bool FreshAreasOK(SymbolCtx &ctx)
{
   if(InpGateSource != GATE_NODERED) return true;
   if(!ctx.gates.valid) return false;

   long ua = NormalizeEpochSec((long)ctx.areas_updated_at);
   if(ua <= 0) return false;
   ctx.areas_updated_at = ua;

   long nowSec = (long)TimeGMT();
   long age = (nowSec - ua);
   int ttl = (InpAreasTTLSeconds < 1 ? 1 : InpAreasTTLSeconds);
   return ((int)age <= ttl);
}

bool FreshGatesOK(SymbolCtx &ctx)
{
   if(InpGateSource != GATE_NODERED) return true;
   if(!ctx.gates.valid) return false;

   long ua = NormalizeEpochSec((long)ctx.gates_updated_at);
   if(ua <= 0) return false;
   ctx.gates_updated_at = ua;

   long nowSec = (long)TimeGMT();
   long age = (nowSec - ua);
   int ttl = (InpGatesTTLSeconds < 1 ? 1 : InpGatesTTLSeconds);
   return ((int)age <= ttl);
}

bool CooldownOK_Mode(const SymbolCtx &ctx, const bool isIntraday)
{
   int cd = isIntraday ? InpIntraCooldownMinutes : InpCooldownMinutes;
   if(cd <= 0) return true;

   datetime lastT = isIntraday ? ctx.lastTradeTimeIntra : ctx.lastTradeTimeScalp;
   if(lastT == 0) return true;

   return ((TimeCurrent() - lastT) >= (cd*60));
}


bool DedupCheckOnly(const SymbolCtx &ctx, const string dedupKey, const bool isIntraday)
{
   if(InpDedupHours <= 0) return true;

   string lastKey = isIntraday ? ctx.lastDedupKeyIntra : ctx.lastDedupKeyScalp;
   if(lastKey == "") return true;

   datetime lastT = isIntraday ? ctx.lastDedupTimeIntra : ctx.lastDedupTimeScalp;
   int age = (int)(TimeCurrent() - lastT);
   int maxAge = InpDedupHours * 3600;

   if(lastKey == dedupKey && age < maxAge)
      return false;

   return true;
}

void DedupCommit(SymbolCtx &ctx, const string dedupKey, const bool isIntraday)
{
   if(InpDedupHours <= 0) return;

   if(isIntraday)
   {
      ctx.lastDedupKeyIntra  = dedupKey;
      ctx.lastDedupTimeIntra = TimeCurrent();
   }
   else
   {
      ctx.lastDedupKeyScalp  = dedupKey;
      ctx.lastDedupTimeScalp = TimeCurrent();
   }
}


// You likely already have 8 symbol inputs (examples shown as InpSym1..InpSym8).
// Use YOUR exact symbol input names here.
bool GetPerSymbolRiskCfgBySlots(const string sym,
                                double &riskMoneyOut,
                                int &slMinPtsOut)
{
   riskMoneyOut = 0.0;
   slMinPtsOut  = 0;

   if(sym == "") return false;

   // Use your SLOT symbols (InpSym_S1..InpSym_S8) to map risk+minSL
   if(InpUse_S1 && InpSym_S1 != "" && MatchSym(sym, InpSym_S1)) { riskMoneyOut = InpRiskUSD_S1; slMinPtsOut = InpSLMinPts_S1; return true; }
   if(InpUse_S2 && InpSym_S2 != "" && MatchSym(sym, InpSym_S2)) { riskMoneyOut = InpRiskUSD_S2; slMinPtsOut = InpSLMinPts_S2; return true; }
   if(InpUse_S3 && InpSym_S3 != "" && MatchSym(sym, InpSym_S3)) { riskMoneyOut = InpRiskUSD_S3; slMinPtsOut = InpSLMinPts_S3; return true; }
   if(InpUse_S4 && InpSym_S4 != "" && MatchSym(sym, InpSym_S4)) { riskMoneyOut = InpRiskUSD_S4; slMinPtsOut = InpSLMinPts_S4; return true; }
   if(InpUse_S5 && InpSym_S5 != "" && MatchSym(sym, InpSym_S5)) { riskMoneyOut = InpRiskUSD_S5; slMinPtsOut = InpSLMinPts_S5; return true; }
   if(InpUse_S6 && InpSym_S6 != "" && MatchSym(sym, InpSym_S6)) { riskMoneyOut = InpRiskUSD_S6; slMinPtsOut = InpSLMinPts_S6; return true; }
   if(InpUse_S7 && InpSym_S7 != "" && MatchSym(sym, InpSym_S7)) { riskMoneyOut = InpRiskUSD_S7; slMinPtsOut = InpSLMinPts_S7; return true; }
   if(InpUse_S8 && InpSym_S8 != "" && MatchSym(sym, InpSym_S8)) { riskMoneyOut = InpRiskUSD_S8; slMinPtsOut = InpSLMinPts_S8; return true; }

   return false;
}


bool StopsLevelOK(const SymbolSpec &spec, double entry, double sl, double tp)
{
   long stopLevelPoints = (long)SymbolInfoInteger(spec.symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevelPoints <= 0) return true;

   double minDist = stopLevelPoints * spec.point;
   if(MathAbs(entry - sl) < minDist) return false;
   if(MathAbs(entry - tp) < minDist) return false;
   return true;
}

//-------------------------
// INTRADAY "flat time" helpers (NEW, only used in STRAT_INTRADAY)
//-------------------------
int MinutesNowAmman()
{
   return MinutesOfDay(AmmanNow());
}

int FlatTimeMinutesAmman()
{
   int h = InpIntraFlatHour;   if(h < 0) h = 0; if(h > 23) h = 23;
   int m = InpIntraFlatMinute; if(m < 0) m = 0; if(m > 59) m = 59;
   return h*60 + m;
}

bool IntradayBlockNewTradesDueToFlat(string &why)
{
   why = "";
   if(!InpIntraForceFlatDaily) return false;

   int nowM  = MinutesNowAmman();
   int flatM = FlatTimeMinutesAmman();
   int block = (InpIntraNoNewTradesMinutes < 0 ? 0 : InpIntraNoNewTradesMinutes);

   int startBlock = flatM - block;
   if(startBlock < 0) startBlock = 0;

   if(nowM >= startBlock && nowM <= flatM) {
      why = "intraday_block_new_before_flat";
      return true;
   }
   return false;
}


bool IntradayShouldForceFlatNow()
{
   if(!InpIntraForceFlatDaily) return false;

   int nowM  = MinutesNowAmman();
   int flatM = FlatTimeMinutesAmman();

   return (nowM >= flatM);
}

//======================================================
// NEW: Build SCALP trade from a specific ACC (H1 or M5)
// - Independent: NO requirement for H1/M5 alignment
// - Rule: if price near bot25 => BUY, near top25 => SELL
// - Confirmation: M1 HA must match direction + momentum (close1 vs close2)
//======================================================
bool BuildClassATrade_FromACC(SymbolCtx &ctx,
                              const AccumArea &accIn,
                              const string tfTag,          // "H1" or "M5"
                              bool &isBuy,
                              double &lotsOut,
                              double &entryOut,
                              double &slOut,
                              double &tpOut,
                              string &rrOut,
                              string &reasonOut,
                              string &dedupKeyOut)
{
   lotsOut=0; entryOut=0; slOut=0; tpOut=0;
   rrOut=""; reasonOut=""; dedupKeyOut="";

   if(!accIn.valid) { reasonOut="no_acc_"+tfTag; return false; }

   double accLow  = accIn.low;
   double accHigh = accIn.high;
   if(accLow<=0 || accHigh<=0 || accHigh<=accLow) { reasonOut="bad_acc_range_"+tfTag; return false; }

   double rng = accHigh - accLow;

   // Quartiles: use Node-RED fields if present, else compute
   double bot25 = accIn.line_bot25;
   double top25 = accIn.line_top25;

   if(bot25 <= 0 || top25 <= 0 || top25 <= bot25)
   {
      bot25 = accLow  + rng * 0.25;
      top25 = accHigh - rng * 0.25;
   }

   // Touch tolerance (USD->price)
   double tol = StructureUsdToPrice(ctx.spec, InpTouchDistanceUSD);
   if(tol < 0) tol = 0;

   double bid = GetBid(ctx.sym);
   double ask = GetAsk(ctx.sym);
   if(bid<=0 || ask<=0) { reasonOut="bad_prices"; return false; }
   double px = (bid + ask) / 2.0;

      // 10% overshoot rule: allow price to exceed ACC boundaries by up to (rng * InpAccOvershootPct)
   double edgePct  = MathMax(0.0, MathMin(0.49, InpAccOvershootPct)); // default 0.10 (10%)
   double edgeDist = rng * edgePct;

   double touchLow  = accLow  - edgeDist - tol;
   double touchHigh = accHigh + edgeDist + tol;

   bool touched = (px >= touchLow && px <= touchHigh);
   if(!touched) { reasonOut="no_touch_acc_"+tfTag; return false; }

   // Zone decision (near edge, % of range)
   double buyEdgeMax  = accLow  + edgeDist;
   double sellEdgeMin = accHigh - edgeDist;

   bool inBuyZone  = (px <= (buyEdgeMax + tol));
   bool inSellZone = (px >= (sellEdgeMin - tol));

   if(!inBuyZone && !inSellZone)
   {
      reasonOut = "not_in_edge_zone_"+tfTag;
      return false;
   }

   // If both true (very small range / huge tol), choose closer edge
   if(inBuyZone && inSellZone)
   {
      double dBuy  = MathAbs(px - bot25);
      double dSell = MathAbs(px - top25);
      if(dBuy <= dSell) inSellZone = false;
      else              inBuyZone  = false;
   }

   // M1 confirmation (Heikin Ashi direction + momentum)
   int trig     = HABiasDir(ctx.spec.symbol, InpTriggerTF, 1);
   int trigPrev = HABiasDir(ctx.spec.symbol, InpTriggerTF, 2); // default M1
   if(trig == 0) { reasonOut="m1_trigger_neutral_"+tfTag; return false; }

   double closeTrig = iClose(ctx.spec.symbol, InpTriggerTF, 1);
   double closePrev = iClose(ctx.spec.symbol, InpTriggerTF, 2);
   if(closeTrig<=0 || closePrev<=0) { reasonOut="bad_trigger_close_"+tfTag; return false; }

   if(inBuyZone)
   {
      if(trig != +1) { reasonOut="m1_not_bull_"+tfTag; return false; }
      if(trigPrev != -1) { reasonOut="m1_no_reversal_to_buy_"+tfTag; return false; }
      if(closeTrig <= closePrev) { reasonOut="m1_no_up_momentum_"+tfTag; return false; }

      isBuy    = true;
      entryOut = ask;
   }
   else // sell zone
   {
      if(trig != -1) { reasonOut="m1_not_bear_"+tfTag; return false; }
      if(trigPrev != +1) { reasonOut="m1_no_reversal_to_sell_"+tfTag; return false; }
      if(closeTrig >= closePrev) { reasonOut="m1_no_down_momentum_"+tfTag; return false; }

      isBuy    = false;
      entryOut = bid;
   }

   // SL beyond ACC with buffer
   double slBufMult = (InpLearnEnable ? ctx.learnScalp.slBufMult : 1.0);
   double slBuf = StructureUsdToPrice(ctx.spec, InpSLBufferUSD * slBufMult);

   if(slBuf < 0) slBuf = 0;

   double slBase = isBuy ? (accLow - slBuf) : (accHigh + slBuf);
   double slDist = MathAbs(entryOut - slBase);
   if(slDist <= 0) { reasonOut="intra_sl_dist_zero"; return false; }
   
   
   // --- Tick value + ticks (MUST exist before lotsWanted) ---
   double tvSL = TickValueForSL(ctx.spec);
   if(tvSL <= 0.0 || ctx.spec.tick_size <= 0.0)
   {
      reasonOut = "tick_value_not_ready_" + tfTag;
      return false;
   }
   
   double ticks = slDist / ctx.spec.tick_size;
   if(ticks <= 0.0)
   {
      reasonOut = "bad_ticks_" + tfTag;
      return false;
   }
   
   // --- Risk USD (SCALP) ---
   double baseRisk = InpMaxLossPerTradeUSD;   // <=== IMPORTANT: SCALP default
   int    slMinPts = 0;
   
   if(InpUsePerSymbolRisk)
   {
      double r=0.0; int m=0;
      if(GetPerSymbolRiskCfgBySlots(ctx.sym, r, m))
      {
         if(r > 0.0) baseRisk = r;
         slMinPts = m;
      }
   }
   
   double riskMult = (InpLearnEnable ? ctx.learnScalp.riskMult : 1.0);
   if(riskMult <= 0.0) riskMult = 1.0;
   
   double riskUSD = baseRisk * riskMult;
   if(riskUSD <= 0.0) riskUSD = InpMaxLossPerTradeUSD;
   
   double lotsWanted = riskUSD / (ticks * tvSL);

   
   double lots = ClampLots(ctx.spec, lotsWanted);
   if(lots <= 0) { reasonOut="lots_too_small"; return false; }


   // SL MIN WIDTH FIX (USD floor) - kept exactly like your logic
   double riskFloorUSD = InpMinProfitUSD / 3.0;
   if(riskFloorUSD < 0.0) riskFloorUSD = 0.0;
   if(riskFloorUSD > InpMaxLossPerTradeUSD) riskFloorUSD = InpMaxLossPerTradeUSD;

   double currRiskUSD = (slDist / ctx.spec.tick_size) * tvSL * lots;

   if(riskFloorUSD > 0.0 && currRiskUSD < riskFloorUSD)
   {
      double needTicks  = riskFloorUSD / (tvSL * lots);
      double newSlDist  = needTicks * ctx.spec.tick_size;

      double slNew = isBuy ? (entryOut - newSlDist) : (entryOut + newSlDist);
      slOut = NormalizeDouble(slNew, ctx.spec.digits);
   }
   else
   {
      slOut = NormalizeDouble(slBase, ctx.spec.digits);
   }

   // EXTRA SAFETY: prevent tiny SL on SCALP when lots are capped
   if(InpScalpMinSL_USD > 0.0)
   {
      double tvSL2 = TickValueForSL(ctx.spec);
      double minSlDist = UsdToPriceDistance(ctx.spec, InpScalpMinSL_USD, lots, tvSL2);
   
      if(minSlDist > 0)
      {
         double currSlDist = MathAbs(entryOut - slOut);
         if(currSlDist < minSlDist)
         {
            double slNew = isBuy ? (entryOut - minSlDist) : (entryOut + minSlDist);
            slOut = NormalizeDouble(slNew, ctx.spec.digits);
         }
      }
   }

   if(slOut <= 0.0) { reasonOut="bad_sl_after_floor"; return false; }

   double slDistFinal = MathAbs(entryOut - slOut);
   if(slDistFinal <= 0.0)
   {
      reasonOut = "bad_sl_final_" + tfTag;
      return false;
   }

   // Minimum SL width in points (per-symbol) - check using FINAL SL
   if(slMinPts > 0)
   {
      double pt = GetSymbolPointSafe(ctx.sym);
      if(pt > 0.0)
      {
         double slPoints = slDistFinal / pt;
         if(slPoints < slMinPts)
         {
            reasonOut = "sl_below_symbol_min_" + tfTag;
            return false;
         }
      }
   }


   // TP: satisfy RR + MinProfit, then apply learning tpMult WITHOUT breaking constraints
   // Minimum SL width in points (per-symbol)
   if(slMinPts > 0)
   {
      double pt = GetSymbolPointSafe(ctx.sym);
      if(pt > 0)
      {
         double slDistFinal = MathAbs(entryOut - slOut);
         double slPoints = slDistFinal / pt;
         if(slPoints < slMinPts)
         {
            reasonOut = "sl_below_symbol_min_" + tfTag;
            return false;
         }
      }
}

   double tpDistRR    = slDistFinal * InpMinRR;

   double tvTP = TickValueForTP(ctx.spec);
   double tpDistMinProfit = UsdToPriceDistance(ctx.spec, InpMinProfitUSD, lots, tvTP);

   // Base distance that satisfies constraints
   double tpDistBase = MathMax(tpDistRR, tpDistMinProfit);

   // Scale TP slightly (learning), but keep constraints
   double tpMult = (InpLearnEnable ? ctx.learnScalp.tpMult : 1.0);
   if(tpMult <= 0.0) tpMult = 1.0;

   double tpDistScaled = tpDistBase * tpMult;

   // Final TP distance must still satisfy RR + MinProfit
   double tpDist = MathMax(tpDistRR, MathMax(tpDistMinProfit, tpDistScaled));

   tpOut = isBuy ? (entryOut + tpDist) : (entryOut - tpDist);
   tpOut = NormalizeDouble(tpOut, ctx.spec.digits);


   if(!StopsLevelOK(ctx.spec, entryOut, slOut, tpOut)) {
      reasonOut="stops_level_too_close_"+tfTag;
      return false;
   }

   double rrCalc = (slDistFinal > 0 ? (MathAbs(tpOut - entryOut) / slDistFinal) : 0);
   rrOut = DoubleToString(rrCalc, 2);


   // Dedup includes TF so H1 + M5 don't collide
   long accRT_norm = NormalizeTimeMaybeMs((long)accIn.right_time);
   dedupKeyOut = StringFormat("%s%I64d|%s", (isBuy ? "BUY|" : "SELL|"), accRT_norm, tfTag);
   

   // ---------------------------
   // SCALP TP OBSTACLES:
   // - previous accumulation border ahead
   // - previous wick level ahead
   // ---------------------------
   double border=0, wick=0;
   int dir = (isBuy ? +1 : -1);
   long accRTn = NormalizeTimeMaybeMs((long)accIn.right_time);

   FindNearestAccBorderAhead(ctx, dir, entryOut, tfTag, accRTn, border);
   FindNearestWickAhead(ctx, dir, entryOut, wick);

   double obstacle = 0;
   if(border > 0) obstacle = border;

   if(wick > 0)
   {
      if(obstacle == 0) obstacle = wick;
      else obstacle = (dir > 0 ? MathMin(obstacle, wick) : MathMax(obstacle, wick));
   }

   if(obstacle > 0)
   {
      // only if obstacle is closer than current TP
      if((dir > 0 && obstacle < tpOut) || (dir < 0 && obstacle > tpOut))
         tpOut = NormalizeDouble(obstacle, ctx.spec.digits);
   }

   

   lotsOut = lots;
   reasonOut = "SCALP_"+tfTag+"_ACC_QUARTILE_M1_CONFIRM";
   return true;
}

//-------------------------
// BUILD TRADES
//------------------------------------------------------
// SCALP BUILDER (UPDATED): independent H1 + M5 ACC
// - Try H1 ACC scalp first, if not built then try M5 ACC
// - No H1 trend alignment requirement
//------------------------------------------------------
bool BuildClassATrade(SymbolCtx &ctx,
                      bool &isBuy,
                      double &lotsOut,
                      double &entryOut,
                      double &slOut,
                      double &tpOut,
                      string &rrOut,
                      string &reasonOut,
                      string &dedupKeyOut)
{
   lotsOut=0; entryOut=0; slOut=0; tpOut=0;
   rrOut=""; reasonOut=""; dedupKeyOut="";

   // 1) Try H1 ACC scalp
   if(ctx.areas.H1.acc.valid)
   {
      bool ok = BuildClassATrade_FromACC(ctx, ctx.areas.H1.acc, "H1",
                                         isBuy, lotsOut, entryOut, slOut, tpOut,
                                         rrOut, reasonOut, dedupKeyOut);
      if(ok) return true;
   }

   // 2) Try M5 ACC scalp
   if(ctx.areas.M5.acc.valid)
   {
      bool ok = BuildClassATrade_FromACC(ctx, ctx.areas.M5.acc, "M5",
                                         isBuy, lotsOut, entryOut, slOut, tpOut,
                                         rrOut, reasonOut, dedupKeyOut);
      if(ok) return true;
   }

   // If neither built:
   if(!ctx.areas.H1.acc.valid && !ctx.areas.M5.acc.valid)
      reasonOut = "no_h1_or_m5_acc";
   else
      reasonOut = "no_scalp_setup_h1_or_m5";

   return false;
}

//------------------------------------------------------
// INTRADAY BUILDER (NEW, does NOT touch scalp logic)
//------------------------------------------------------
struct IntraSignal
{
   bool   valid;        // used everywhere in your code
   bool   isMit;        // A/B
   int    dir;          // +1 / -1
   string tf;           // "D" / "H1" / "M5"
   long   event_time;   // breakout_time or mit_time
   long   acc_rt;       // acc_right_time
   double accHigh;      // optional (filled if ACC found)
   double accLow;       // optional (filled if ACC found)
};


// NOTE:
// - MQL5 does NOT allow pointers to structs. So we use GetTFStateByTag(..., TFState &out).
// - This version supports M/W/D/H1/M5 signals (and can be extended to M1 if you want).
//============================================================
// BuildClassATrade_Intraday (CLEAN DROP-IN)
//============================================================
bool BuildClassATrade_Intraday(SymbolCtx &ctx,
                               bool &isBuy,
                               double &lotsOut,
                               double &entryOut,
                               double &slOut,
                               double &tpOut,
                               string &rrOut,
                               string &reasonOut,
                               string &dedupKeyOut,
                               IntraSignal &sigOut)
{
   lotsOut=0; entryOut=0; slOut=0; tpOut=0;
   rrOut=""; reasonOut=""; dedupKeyOut="";

   // init output
   sigOut.valid=false;
   sigOut.isMit=false;
   sigOut.dir=0;
   sigOut.tf="";
   sigOut.event_time=0;
   sigOut.acc_rt=0;
   sigOut.accHigh=0;
   sigOut.accLow=0;

   if(!InpIntraEnable) { reasonOut="intra_disabled"; return false; }

   // best candidate = latest event_time
   IntraSignal best;
   best.valid=false;
   best.isMit=false;
   best.dir=0;
   best.tf="";
   best.event_time=0;
   best.acc_rt=0;
   best.accHigh=0;
   best.accLow=0;

   // --- TF list (no initializer to avoid parser issues) ---
   // --- TF list (MQL5-safe) ---
   string tfs[];
   ArrayResize(tfs, 5);
   tfs[0] = "M";
   tfs[1] = "W";
   tfs[2] = "D";
   tfs[3] = "H1";
   tfs[4] = "M5";
   
   for(int k=0; k<ArraySize(tfs); k++)
   {
      string tf = tfs[k];

      TFState st;
      if(!GetTFStateByTag(ctx.areas, tf, st))
         continue;

      // Track last seen breakout per TF (for mitigation matching)
      if(st.brk.valid && st.brk.break_time>0)
      {
         long bt = NormalizeTimeMaybeMs(st.brk.break_time);
         long rt = NormalizeTimeMaybeMs(st.brk.acc_right_time);

         if(tf=="M"  && bt > ctx.intraLastBrkTime_M)  { ctx.intraLastBrkTime_M=bt;  ctx.intraLastBrkRT_M=rt;  }
         if(tf=="W"  && bt > ctx.intraLastBrkTime_W)  { ctx.intraLastBrkTime_W=bt;  ctx.intraLastBrkRT_W=rt;  }
         if(tf=="D"  && bt > ctx.intraLastBrkTime_D)  { ctx.intraLastBrkTime_D=bt;  ctx.intraLastBrkRT_D=rt;  }
         if(tf=="H1" && bt > ctx.intraLastBrkTime_H1) { ctx.intraLastBrkTime_H1=bt; ctx.intraLastBrkRT_H1=rt; }
         if(tf=="M5" && bt > ctx.intraLastBrkTime_M5) { ctx.intraLastBrkTime_M5=bt; ctx.intraLastBrkRT_M5=rt; }
      }

      // Candidate A: Breakout
      if(st.brk.valid && st.brk.break_time>0 && st.brk.acc_right_time>0 && st.brk.dir!=0)
      {
         long bt = NormalizeTimeMaybeMs(st.brk.break_time);
         long rt = NormalizeTimeMaybeMs(st.brk.acc_right_time);

         if(IsFreshWithSkew(bt, InpIntraBreakoutFreshSeconds))
         {
            if(!best.valid || bt > best.event_time)
            {
               best.valid      = true;
               best.isMit      = false;
               best.tf         = tf;
               best.dir        = st.brk.dir;
               best.event_time = bt;
               best.acc_rt     = rt;
            }
         }
      }

      // Candidate B: Mitigation
      if(InpIntraAllowMitigationReentry &&
         st.mit.valid && st.mit.mit_time>0 && st.mit.acc_right_time>0 && st.mit.dir!=0)
      {
         long mt = NormalizeTimeMaybeMs(st.mit.mit_time);
         long rt = NormalizeTimeMaybeMs(st.mit.acc_right_time);

         if(IsFreshWithSkew(mt, InpIntraMitigationFreshSeconds))
         {
            bool okMatch=false;

            if(tf=="M"  && (ctx.intraLastBrkRT_M==rt  || TimeCloseEnough(ctx.intraLastBrkRT_M,  rt, InpIntraAccRTToleranceSec))) okMatch=true;
            if(tf=="W"  && (ctx.intraLastBrkRT_W==rt  || TimeCloseEnough(ctx.intraLastBrkRT_W,  rt, InpIntraAccRTToleranceSec))) okMatch=true;
            if(tf=="D"  && (ctx.intraLastBrkRT_D==rt  || TimeCloseEnough(ctx.intraLastBrkRT_D,  rt, InpIntraAccRTToleranceSec))) okMatch=true;
            if(tf=="H1" && (ctx.intraLastBrkRT_H1==rt || TimeCloseEnough(ctx.intraLastBrkRT_H1, rt, InpIntraAccRTToleranceSec))) okMatch=true;
            if(tf=="M5" && (ctx.intraLastBrkRT_M5==rt || TimeCloseEnough(ctx.intraLastBrkRT_M5, rt, InpIntraAccRTToleranceSec))) okMatch=true;

            // Also check breakout object directly
            if(!okMatch && TFHasBreakoutForAccRT(st, rt)) okMatch=true;

            if(okMatch)
            {
               if(!best.valid || mt > best.event_time)
               {
                  best.valid      = true;
                  best.isMit      = true;
                  best.tf         = tf;
                  best.dir        = st.mit.dir;
                  best.event_time = mt;
                  best.acc_rt     = rt;
               }
            }
         }
      }
   }

   if(!best.valid) { reasonOut="no_fresh_breakout_or_mit"; return false; }

   // Dedup: TF|accRT|side|A/B|event_time
   string keyCore = StringFormat("%s|%I64d|%s", best.tf, best.acc_rt, (best.dir>0 ? "BUY" : "SELL"));
   string keyFull = StringFormat("%s|%s|%I64d", keyCore, (best.isMit ? "B" : "A"), best.event_time);

   if(!DedupCheckOnly(ctx, keyFull, true))
   {
      reasonOut="dedup_same_event";
      return false;
   }

   // Find matching ACC for best.tf + best.acc_rt
   TFState st2;
   AccumArea accRef; accRef.valid=false;

   if(GetTFStateByTag(ctx.areas, best.tf, st2))
   {
      for(int i=0; i<st2.accCount; i++)
      {
         long rt = NormalizeTimeMaybeMs((long)st2.accList[i].right_time);
         if(rt == best.acc_rt || TimeCloseEnough(rt, best.acc_rt, InpIntraAccRTToleranceSec)) { accRef = st2.accList[i]; break; }
      }
      if(!accRef.valid && st2.acc.valid) accRef = st2.acc;
   }

   double bid = GetBid(ctx.sym);
   double ask = GetAsk(ctx.sym);
   if(bid<=0 || ask<=0) { reasonOut="bad_prices"; return false; }

   isBuy    = (best.dir>0);
   entryOut = isBuy ? ask : bid;

   // per-symbol risk cfg (kept)
   double baseRisk = InpIntraMaxLossPerTradeUSD;
   int    slMinPts = 0;

   if(InpUsePerSymbolRisk)
   {
      double r=0.0; int m=0;
      if(GetPerSymbolRiskCfgBySlots(ctx.sym, r, m))
      {
         if(r > 0.0) baseRisk = r;
         slMinPts = m;
      }
   }

   // Structural SL: beyond ACC edge (fallback fixed USD)
   double slBuf = StructureUsdToPrice(ctx.spec, InpIntraSLBufferUSD);
   if(slBuf < 0) slBuf = 0;

   double slBase=0.0;
   if(accRef.valid)
      slBase = isBuy ? (accRef.low - slBuf) : (accRef.high + slBuf);
   else
   {
      double slFixed = StructureUsdToPrice(ctx.spec, InpIntraReverseSLUSD);
      if(slFixed <= 0) { reasonOut="no_acc_and_sl_fixed_bad"; return false; }
      slBase = isBuy ? (entryOut - slFixed) : (entryOut + slFixed);
   }

   double slDistBase = MathAbs(entryOut - slBase);
   if(slDistBase <= 0.0) { reasonOut="intra_sl_dist_zero"; return false; }

   // optional minimum SL points
   if(slMinPts > 0)
   {
      double pt = GetSymbolPointSafe(ctx.sym);
      if(pt > 0)
      {
         double slPoints = slDistBase / pt;
         if(slPoints < slMinPts)
         {
            reasonOut="sl_below_symbol_min";
            return false;
         }
      }
   }

   // Tick value (must exist)
   double tvSL = TickValueForSL(ctx.spec);
   if(tvSL <= 0.0 || ctx.spec.tick_size <= 0.0)
   {
      reasonOut = "tick_value_not_ready_" + best.tf;
      return false;
   }

   //==============================
   // INTRADAY ONLY RULES (FINAL)
   // - Entry: breakout OR mitigation => open immediately
   // - Lots: MAX allowed for symbol (clamped by per-slot max lot + broker limits)
   // - TP: set to achieve minimum profit per trade (InpMinProfitUSD) using OrderCalcProfit
   // - SL: set so that SL distance = (TP distance) / 3, while respecting broker stop-level
   //==============================

   // (1) Max lots
   double lots = ClampLots(ctx.spec, MaxLotForSymbol(ctx.spec.symbol));
   if(lots <= 0.0) { reasonOut="lots_too_small"; return false; }

   // (2) TP to achieve minimum profit per trade (USD)
   double minP = InpMinProfitUSD;
   if(minP <= 0.0) { reasonOut="min_profit_invalid"; return false; }

   double tpCand = TP_FromMinProfitUSD(ctx.spec, ctx.spec.symbol, isBuy, entryOut, lots, minP);
   if(tpCand <= 0.0) { reasonOut="tp_calc_failed"; return false; }
   tpOut = NormalizeDouble(tpCand, ctx.spec.digits);

   // Ensure TP respects stop-level AND is large enough so that SL = TP/3 can also respect stop-level
   long stopLevelPoints = (long)SymbolInfoInteger(ctx.spec.symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevelPoints > 0)
   {
      double minDist = stopLevelPoints * ctx.spec.point;
      double tpDist  = MathAbs(tpOut - entryOut);

      // Need TP >= 3*minDist (+1 point) so SL (=TP/3) can be >= minDist
      double needTPDist = 3.0 * minDist + ctx.spec.point;

      if(tpDist < needTPDist)
      {
         tpOut = isBuy ? NormalizeDouble(entryOut + needTPDist, ctx.spec.digits)
                       : NormalizeDouble(entryOut - needTPDist, ctx.spec.digits);
      }
   }

   if(isBuy && tpOut <= entryOut)  tpOut = NormalizeDouble(entryOut + ctx.spec.point, ctx.spec.digits);
   if(!isBuy && tpOut >= entryOut) tpOut = NormalizeDouble(entryOut - ctx.spec.point, ctx.spec.digits);

   // (3) SL distance = (entry -> TP) / 3
   double tpDist2 = MathAbs(tpOut - entryOut);
   if(tpDist2 <= 0.0) { reasonOut="tp_dist_bad"; return false; }

   double slDist = tpDist2 / 3.0;

   // Respect broker stop-level minimum distance (safety)
   if(stopLevelPoints > 0)
   {
      double minDist2 = stopLevelPoints * ctx.spec.point + ctx.spec.point;
      if(slDist < minDist2) slDist = minDist2;
   }

   if(isBuy) slOut = NormalizeDouble(entryOut - slDist, ctx.spec.digits);
   else      slOut = NormalizeDouble(entryOut + slDist, ctx.spec.digits);

   if(isBuy && slOut >= entryOut) { reasonOut="sl_bad"; return false; }
   if(!isBuy && slOut <= entryOut){ reasonOut="sl_bad"; return false; }

// RR
   if(tpOut <= 0.0) rrOut = "n/a";
   else {
      double rr = (MathAbs(entryOut - slOut) > 0.0)
                  ? (MathAbs(tpOut - entryOut) / MathAbs(entryOut - slOut))
                  : 0.0;
      rrOut = DoubleToString(rr, 2);
   }
// outputs
   lotsOut     = lots;
   dedupKeyOut = keyFull;
   reasonOut   = best.isMit ? "INTRA_B_MIT_REENTRY" : "INTRA_A_BREAKOUT_ENTRY";

   sigOut = best;
   sigOut.accHigh = accRef.valid ? accRef.high : 0.0;
   sigOut.accLow  = accRef.valid ? accRef.low  : 0.0;

   return true;
}


//-------------------------
// Gate decision + reason
//-------------------------
bool GateFailReason(SymbolCtx &ctx, string &reason, const bool isIntraday)
{
   reason = "";

   if(!ctx.enabled)            { reason="symbol_disabled"; return true; }
   if(!ctx.spec.ok)            { reason="symbol_spec_not_ready"; return true; }
   if(g_stopTrading)           { reason="stop_trading_flag"; return true; }
   if(DailyLossExceeded())     { reason="daily_loss_exceeded"; return true; }
   if(g_tradesToday >= InpMaxTradesPerDay) { reason="max_trades_day"; return true; }

   string sess;
   if(!IsAllowedBySessions(sess)) { reason="timing_blocked:"+sess; return true; }

   if(!SpreadOK(ctx.spec)) { reason="spread_too_high"; return true; }

   // Intraday: block new trades near flat time (does not affect scalp)
   if(isIntraday)
   {
      string whyFlat="";
      if(IntradayBlockNewTradesDueToFlat(whyFlat)) { reason=whyFlat; return true; }
   }


   Gates g = GetEffectiveGates(ctx);

   if(InpGateSource == GATE_NODERED)
   {
      if(!g.valid) { reason="node_red_not_valid"; return true; }

      if(ctx.areas_updated_at <= 0 && !ctx.has_initial_sync) { reason="node_red_areas_not_ready"; return true; }
      if(!ctx.has_initial_sync && !FreshAreasOK(ctx)) { reason="stale_areas_data"; return true; }
   }

   if(!g.valid) { reason="no_valid_gates"; return true; }

   if(true)
   {
      if(InpGateSource == GATE_NODERED)
      {
         if(ctx.gates_updated_at <= 0 && !ctx.has_initial_sync) { reason="node_red_gates_not_ready"; return true; }
         if(!ctx.has_initial_sync && !FreshGatesOK(ctx)) { reason="stale_gates_data"; return true; }
      }

      if(InpRequireLiquidity && !g.liquidity_ok) { reason="liq_not_ok"; return true; }
      if(!InpTradeNews && g.news_block) { reason="news_blocked"; return true; }
   }

   if(!CooldownOK_Mode(ctx, isIntraday)) { reason="cooldown_active"; return true; }


   return false;
}

bool MasterGatePassed(SymbolCtx &ctx, const bool isIntraday)
{
   string r;
   return !GateFailReason(ctx, r, isIntraday);
}


//-------------------------
// Debug prints
//-------------------------
void PrintAreasSnapshot(SymbolCtx &ctx)
{
   if(!InpDebugPrintAreas) return;

   bool any =
      ctx.areas.H1.acc.valid || ctx.areas.M5.acc.valid || ctx.areas.M1.acc.valid ||
      ctx.areas.H1.gz.valid  || ctx.areas.M5.gz.valid  || ctx.areas.M1.gz.valid ||
      ctx.areas.H1.wick.valid|| ctx.areas.M5.wick.valid|| ctx.areas.M1.wick.valid;
      

   if(!any) return;

   if(ctx.areas.M5.acc.valid)
   {
      Print("AREAS[", ctx.sym, "] M5 ACC: [", DoubleToString(ctx.areas.M5.acc.low, ctx.spec.digits),
            " - ", DoubleToString(ctx.areas.M5.acc.high, ctx.spec.digits), "] rt=", (long)ctx.areas.M5.acc.right_time,
            " | top25=", DoubleToString(ctx.areas.M5.acc.line_top25, ctx.spec.digits),
            " bot25=", DoubleToString(ctx.areas.M5.acc.line_bot25, ctx.spec.digits));
      
   }

   if(ctx.areas.H1.acc.valid)
{
   double bot25 = ctx.areas.H1.acc.line_bot25;
   double top25 = ctx.areas.H1.acc.line_top25;
   if(bot25<=0 || top25<=0 || top25<=bot25)
   {
      double rng = ctx.areas.H1.acc.high - ctx.areas.H1.acc.low;
      bot25 = ctx.areas.H1.acc.low  + rng*0.25;
      top25 = ctx.areas.H1.acc.high - rng*0.25;
   }

   Print("AREAS[", ctx.sym, "] H1 ACC: [", DoubleToString(ctx.areas.H1.acc.low, ctx.spec.digits),
         " - ", DoubleToString(ctx.areas.H1.acc.high, ctx.spec.digits), "] rt=", (long)ctx.areas.H1.acc.right_time,
         " | top25=", DoubleToString(top25, ctx.spec.digits),
         " bot25=", DoubleToString(bot25, ctx.spec.digits));
         
}
    if(ctx.areas.H1.brk.valid)
      Print("AREAS[", ctx.sym, "] H1 BRK: dir=", ctx.areas.H1.brk.dir, " bt=", (long)ctx.areas.H1.brk.break_time);
   
    if(ctx.areas.H1.mit.valid)
      Print("AREAS[", ctx.sym, "] H1 MIT: dir=", ctx.areas.H1.mit.dir, " mt=", (long)ctx.areas.H1.mit.mit_time, " st=", ctx.areas.H1.mit.status);


   if(ctx.areas.M5.gz.valid)
      Print("AREAS[", ctx.sym, "] M5 GZ: [", DoubleToString(ctx.areas.M5.gz.lower, ctx.spec.digits),
            " - ", DoubleToString(ctx.areas.M5.gz.upper, ctx.spec.digits), "] t=", (long)ctx.areas.M5.gz.gz_time);

   if(ctx.areas.M5.wick.valid)
      Print("AREAS[", ctx.sym, "] M5 WICK: dir=", (ctx.areas.M5.wick.dir>0?"UP":"DOWN"),
            " lvl=", DoubleToString(ctx.areas.M5.wick.wick_level, ctx.spec.digits),
            " bt=", (long)ctx.areas.M5.wick.break_time);
}


void PrintGateStatus(SymbolCtx &ctx)
{
   if(!InpDebugPrintGates) return;

   datetime now = TimeCurrent();
   int every = (InpGatePrintEverySec < 1 ? 10 : InpGatePrintEverySec);
   if(ctx.lastGatePrint != 0 && (now - ctx.lastGatePrint) < every) return;
   ctx.lastGatePrint = now;

   Gates g = GetEffectiveGates(ctx);

   string sess;
   IsAllowedBySessions(sess);

   // For printing, show "PASSED" if either mode could pass (informational)
   bool passScalp = MasterGatePassed(ctx, false);
   bool passIntra = MasterGatePassed(ctx, true);
   string status = (passScalp || passIntra) ? "PASSED" : "BLOCKED";

   datetime anow = AmmanNow();
   MqlDateTime dt; TimeToStruct(anow, dt);
   string tstr = StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);

   long nowG = (long)TimeGMT();
   int ageAreas = (ctx.areas_updated_at>0 ? (int)(nowG - (long)ctx.areas_updated_at) : -1);
   int ageGates = (ctx.gates_updated_at>0 ? (int)(nowG - (long)ctx.gates_updated_at) : -1);

   Print("STEP_C [", ctx.sym, "] Gate=", status,
         " | Mode=DUAL",
         " | Amman=", tstr,
         " | session=", sess,
         " | src=", (InpGateSource==GATE_MANUAL_OFFLINE ? "MANUAL" : "NODERED"),
         " | valid=", (g.valid ? "1":"0"),
         " liq=", (g.liquidity_ok ? "1":"0"),
         " news_block=", (g.news_block ? "1":"0"),
         " | areas_at=", (long)ctx.areas_updated_at,
         " ageAreasSec=", ageAreas,
         " ttlAreas=", InpAreasTTLSeconds,
         " | gates_at=", (long)ctx.gates_updated_at,
         " ageGatesSec=", ageGates,
         " ttlGates=", InpGatesTTLSeconds,
         " | updated_at=", (long)ctx.updated_at,
         " news_source=", ctx.news_source);
}

void PrintBlockedReason(SymbolCtx &ctx)
{
   if(!InpPrintBlockReasons) return;

   datetime now = TimeCurrent();
   if(ctx.lastBlockPrint != 0 && (now - ctx.lastBlockPrint) < 15) return;

   string rS="", rI="";
   bool fS = GateFailReason(ctx, rS, false);
   bool fI = GateFailReason(ctx, rI, true);
   
   if(fS && fI) {
      Print("STEP_C [", ctx.sym, "] BLOCK REASON: SCALP=", rS, " | INTRA=", rI);
   }

}

datetime DayStart(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}
datetime DayStartFrom(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

datetime AmmanDayStart()
{
   return DayStartFrom(AmmanNow());
}


// Return TFState by tag
bool GetTFStateByTag(const AreasSnap &a, const string tf, TFState &out)
{
   if(tf=="M")  { out = a.M;  return true; }
   if(tf=="W")  { out = a.W;  return true; }
   if(tf=="D")  { out = a.D;  return true; }
   if(tf=="H1") { out = a.H1; return true; }
   if(tf=="M5") { out = a.M5; return true; }
   if(tf=="M1") { out = a.M1; return true; }
   return false;
}



bool GetPosByMagic(const string sym, const int magic,
                   ulong &ticketOut, bool &isBuyOut, double &lotsOut, double &openPriceOut)
{
   ticketOut=0; isBuyOut=false; lotsOut=0; openPriceOut=0;

   int total = PositionsTotal();
   for(int i=total-1;i>=0;--i)
   {
      ulong ticket = (ulong)PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string s = PositionGetString(POSITION_SYMBOL);
      long mg  = (long)PositionGetInteger(POSITION_MAGIC);
      if(s!=sym || (int)mg!=magic) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double vol= PositionGetDouble(POSITION_VOLUME);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);

      ticketOut=ticket;
      isBuyOut=(type==POSITION_TYPE_BUY);
      lotsOut=vol;
      openPriceOut=op;
      return true;
   }
   return false;
}

double AvgM5Range(const string sym, int lookback)
{
   if(lookback < 1) lookback = 1;
   double sum=0; int n=0;
   for(int i=1;i<=lookback;i++)
   {
      double h=iHigh(sym, PERIOD_M5, i);
      double l=iLow(sym, PERIOD_M5, i);
      if(h>0 && l>0 && h>=l) { sum += (h-l); n++; }
   }
   if(n<=0) return 0;
   return sum/(double)n;
}

// IMPORTANT: MQL5 cannot use pointers to structs.
// So we DO NOT do: TFState *st = GetTFStateByTag(...)
// We do: TFState st; if(!GetTFStateByTag(..., st)) continue;

bool FindNearestAccBorderAhead(SymbolCtx &ctx, const int dir, const double fromPrice,
                               const string ignoreTF, const long ignoreAccRT,
                               double &borderOut)
{
   borderOut = 0.0;
   if(fromPrice <= 0) return false;
   if(dir == 0)       return false;

   double bestDist = 1e100;
   bool found = false;

   string tfs[5] = {"M","W","D","H1","M5"};
   for(int k=0; k<ArraySize(tfs); k++)
   {
      string tf = tfs[k];

      TFState st;
      if(!GetTFStateByTag(ctx.areas, tf, st))
         continue;

      for(int i=0; i<st.accCount; i++)
      {
         AccumArea a = st.accList[i];
         if(!a.valid) continue;

         long rt = NormalizeTimeMaybeMs((long)a.right_time);
         if(tf == ignoreTF && rt == ignoreAccRT) continue;

         if(dir > 0)
         {
            // BUY: next obstacle ABOVE = nearest ACC.low above fromPrice
            if(a.low > fromPrice)
            {
               double dist = a.low - fromPrice;
               if(dist < bestDist)
               {
                  bestDist  = dist;
                  borderOut = a.low;
                  found     = true;
               }
            }
         }
         else // dir < 0
         {
            // SELL: next obstacle BELOW = nearest ACC.high below fromPrice
            if(a.high < fromPrice)
            {
               double dist = fromPrice - a.high;
               if(dist < bestDist)
               {
                  bestDist  = dist;
                  borderOut = a.high;
                  found     = true;
               }
            }
         }
      }
   }

   return found;
}

bool FindNearestWickAhead(SymbolCtx &ctx, const int dir, const double fromPrice,
                          double &wickOut)
{
   wickOut = 0.0;
   if(fromPrice <= 0) return false;
   if(dir == 0)       return false;

   double bestDist = 1e100;
   bool found = false;

   string tfs[5] = {"M","W","D","H1","M5"};
   for(int k=0; k<ArraySize(tfs); k++)
   {
      string tf = tfs[k];

      TFState st;
      if(!GetTFStateByTag(ctx.areas, tf, st))
         continue;

      for(int i=0; i<st.wickCount; i++)
      {
         WickArea w = st.wickList[i];
         if(!w.valid) continue;
         if(w.wick_level <= 0) continue;

         if(dir > 0)
         {
            // BUY: next wick ABOVE
            if(w.wick_level > fromPrice)
            {
               double dist = w.wick_level - fromPrice;
               if(dist < bestDist)
               {
                  bestDist = dist;
                  wickOut  = w.wick_level;
                  found    = true;
               }
            }
         }
         else // dir < 0
         {
            // SELL: next wick BELOW
            if(w.wick_level < fromPrice)
            {
               double dist = fromPrice - w.wick_level;
               if(dist < bestDist)
               {
                  bestDist = dist;
                  wickOut  = w.wick_level;
                  found    = true;
               }
            }
         }
      }
   }

   return found;
}

bool FindMatchingGZ(SymbolCtx &ctx, const string tf, const long accRT, GoldZone &gzOut)
{
   gzOut.valid = false;

   TFState st;
   if(!GetTFStateByTag(ctx.areas, tf, st))
      return false;

   for(int i=0; i<st.gzCount; i++)
   {
      GoldZone g = st.gzList[i];
      if(!g.valid) continue;

      long rt = NormalizeTimeMaybeMs((long)g.acc_right_time);
      if(rt == accRT)
      {
         gzOut = g;
         return true;
      }
   }
   return false;
}

// ---------------------------
// SCALP: Close if a NEW accumulation happens on the TF that created the trade
// ---------------------------
void ManageScalpPosition(SymbolCtx &ctx, const Gates &eg)
{
   ulong  ticket=0;
   bool   isBuy=false;
   double lots=0, openPrice=0;

   if(!GetPosByMagic(ctx.sym, InpMagicScalp, ticket, isBuy, lots, openPrice))
      return;

   // must be our tagged trade comment (BBI|TF|B/S|accRT)
   string cmt = PositionGetString(POSITION_COMMENT);

   bool isIntra=false;
   string tf=""; int dir=0; long accRT=0;
   if(!ParseBBComment(cmt, isIntra, tf, dir, accRT))
      return;

   // only scalp trades
   if(isIntra) return;

   long curRT = AccRTByTF(ctx.areas, tf);
   if(curRT > 0 && accRT > 0 && curRT != accRT)
   {
      CloseOnePositionByTicket(ticket, "SCALP_EXIT_NEW_ACC", eg, InpMagicScalp);
   }
}




bool ManageIntradayPosition(SymbolCtx &ctx, const Gates &eg)
{
   if(!InpIntraEnable) return false;

   ulong ticket=0; bool isBuy=false; double lots=0, openPrice=0;
   if(!GetPosByMagic(ctx.sym, InpMagicIntra, ticket, isBuy, lots, openPrice))
      return false;

   int dir = isBuy ? +1 : -1;

   double bid=GetBid(ctx.sym), ask=GetAsk(ctx.sym);
   if(bid<=0 || ask<=0) return true;

   double px = (bid+ask)/2.0;

   // Rule #4: exit if new accumulation happened (M/W/D/H1/M5)
   if(InpIntraExitOnNewAccum)
   {
      long rtM  = (ctx.areas.M.acc.valid  ? NormalizeTimeMaybeMs((long)ctx.areas.M.acc.right_time)  : 0);
      long rtW  = (ctx.areas.W.acc.valid  ? NormalizeTimeMaybeMs((long)ctx.areas.W.acc.right_time)  : 0);
      long rtD  = (ctx.areas.D.acc.valid  ? NormalizeTimeMaybeMs((long)ctx.areas.D.acc.right_time)  : 0);
      long rtH1 = (ctx.areas.H1.acc.valid ? NormalizeTimeMaybeMs((long)ctx.areas.H1.acc.right_time) : 0);
      long rtM5 = (ctx.areas.M5.acc.valid ? NormalizeTimeMaybeMs((long)ctx.areas.M5.acc.right_time) : 0);

      if(ctx.intraBaseAccRT_M  >0 && rtM  >0 && rtM  != ctx.intraBaseAccRT_M)  { CloseOnePositionByTicket(ticket, "INTRA_EXIT_NEW_ACC_M",  eg, InpMagicIntra); return true; }
      if(ctx.intraBaseAccRT_W  >0 && rtW  >0 && rtW  != ctx.intraBaseAccRT_W)  { CloseOnePositionByTicket(ticket, "INTRA_EXIT_NEW_ACC_W",  eg, InpMagicIntra); return true; }
      if(ctx.intraBaseAccRT_D  >0 && rtD  >0 && rtD  != ctx.intraBaseAccRT_D)  { CloseOnePositionByTicket(ticket, "INTRA_EXIT_NEW_ACC_D",  eg, InpMagicIntra); return true; }
      if(ctx.intraBaseAccRT_H1 >0 && rtH1 >0 && rtH1 != ctx.intraBaseAccRT_H1) { CloseOnePositionByTicket(ticket, "INTRA_EXIT_NEW_ACC_H1", eg, InpMagicIntra); return true; }
      if(ctx.intraBaseAccRT_M5 >0 && rtM5 >0 && rtM5 != ctx.intraBaseAccRT_M5) { CloseOnePositionByTicket(ticket, "INTRA_EXIT_NEW_ACC_M5", eg, InpMagicIntra); return true; }
   }

   // Rule #4: low volatility exit (avg M5 range)
   if(InpIntraExitOnLowVol)
   {
      double avgRange = AvgM5Range(ctx.sym, InpIntraLowVolLookbackBars);
      double thr = StructureUsdToPrice(ctx.spec, InpIntraLowVolRangeUSD);
      if(avgRange > 0 && thr > 0 && avgRange <= thr)
      {
         CloseOnePositionByTicket(ticket, "INTRA_EXIT_LOW_VOL", eg, InpMagicIntra);
         return true;
      }
   }

   // Rule #2/#3: obstacle early TP
   if(InpIntraEnableObstacleTP)
   {
      double tol = StructureUsdToPrice(ctx.spec, InpIntraObstacleTouchUSD);
      if(tol < 0) tol = 0;

      if(ctx.intraTP_AccBorder > 0)
      {
         if(dir>0 && bid >= (ctx.intraTP_AccBorder - tol)) { CloseOnePositionByTicket(ticket, "INTRA_TP_PREV_ACC_BORDER", eg, InpMagicIntra); return true; }
         if(dir<0 && ask <= (ctx.intraTP_AccBorder + tol)) { CloseOnePositionByTicket(ticket, "INTRA_TP_PREV_ACC_BORDER", eg, InpMagicIntra); return true; }
      }

      if(ctx.intraTP_WickLevel > 0)
      {
         if(dir>0 && bid >= (ctx.intraTP_WickLevel - tol)) { CloseOnePositionByTicket(ticket, "INTRA_TP_WICK_LEVEL", eg, InpMagicIntra); return true; }
         if(dir<0 && ask <= (ctx.intraTP_WickLevel + tol)) { CloseOnePositionByTicket(ticket, "INTRA_TP_WICK_LEVEL", eg, InpMagicIntra); return true; }
      }
   }

   // Rule #1: GZ untouched reversal after breakout
   if(InpIntraEnableGZReverse && ctx.intraGZValid && ctx.intraGZLower>0 && ctx.intraGZUpper>0 && ctx.intraGZMid>0 && ctx.intraActiveEventTime>0)
   {
      if(!ctx.intraGZTouched)
      {
         bool touched = HATouchedRangeSince(ctx.sym, InpIntraGZTouchTF, ctx.intraActiveEventTime,
                                            ctx.intraGZLower, ctx.intraGZUpper, InpIntraGZTouchLookbackBars);
         if(touched) ctx.intraGZTouched = true;
      }

      if(!ctx.intraGZTouched)
      {
         double distNeed = StructureUsdToPrice(ctx.spec, InpIntraGZReverseTriggerUSD);
         if(distNeed > 0 && MathAbs(px - ctx.intraGZMid) >= distNeed)
         {
            CloseOnePositionByTicket(ticket, "INTRA_GZ_UNTOUCHED_REVERSE", eg, InpMagicIntra);

            bool newBuy = !isBuy;

            double lotsMax = ClampLots(ctx.spec, MaxLotForSymbol(ctx.spec.symbol));
            if(lotsMax > 0)
            {
               double entry = newBuy ? GetAsk(ctx.sym) : GetBid(ctx.sym);
               if(entry > 0)
               {
                  double tvSL = TickValueForSL(ctx.spec);
                  double tvTP = TickValueForTP(ctx.spec);

                  // SL = maximum allowed loss per trade (USD) for the reversal trade
                  double slDist = UsdToPriceDistance(ctx.spec, InpIntraMaxLossPerTradeUSD, lotsMax, tvSL);
                  
                  // TP = reversal TP in USD profit (20 USD by your input)
                  double tpDist = UsdToPriceDistance(ctx.spec, InpIntraReverseTPUSD, lotsMax, tvTP);



                  if(slDist > 0 && tpDist > 0)
                  {
                     double sl = newBuy ? (entry - slDist) : (entry + slDist);
                     double tp = newBuy ? (entry + tpDist) : (entry - tpDist);

                     sl = NormalizeDouble(sl, ctx.spec.digits);
                     tp = NormalizeDouble(tp, ctx.spec.digits);

                     PlaceMarket(ctx, newBuy, lotsMax, sl, tp, eg,
                                 "INTRA_REVERSE_GZ_UNTOUCHED_MAXLOT", "n/a", InpMagicIntra, true);

                     ctx.intraGZTouched = true;
                     ctx.intraGZValid   = false;
                  }
               }
            }
            return true;
         }
      }
   }

   return true;
}


//==============================================================
// NEW (Retake rule)
// - Block re-taking the SAME setup key if last outcome was LOSS
// - Allow re-taking if last outcome was WIN or unknown
// - Uses a GlobalVariable per (symbol + magic + setupKey)
//   Value:  1 = last outcome WIN
//          -1 = last outcome LOSS
//           0 = unknown / not set
//==============================================================
string LastOutcomeKey(const string sym, const long magic, const string setupKey)
{
   if(setupKey == "") return "";
   return StringFormat("BB_LAST_OUTCOME|%s|%I64d|%s", sym, (long)magic, setupKey);
}

bool RetakeAllowedByLastOutcome(const string outcomeKey, string &why)
{
   why = "";
   if(outcomeKey == "") return true;

   double v = GVGetD(outcomeKey, 0.0);     // default 0 = unknown
   if(v < 0.0)
   {
      why = "PREV_LOSS_BLOCK";
      return false;
   }
   return true; // WIN or unknown
}

//-------------------------
// Per-symbol processing (MODE: SCALP / INTRADAY toggles)
//-------------------------
void ProcessSymbol(SymbolCtx &ctx)
{
   if(!ctx.enabled) return;

   if(!ctx.spec.ok)
      LoadSymbolSpec(ctx.sym, ctx.spec);

   PrintGateStatus(ctx);

   if(InpGateSource == GATE_NODERED)
      PrintAreasSnapshot(ctx);

   if(!ctx.spec.ok) { PrintBlockedReason(ctx); return; }

   Gates eg = GetEffectiveGates(ctx);

   //=========================
   // MODE TOGGLES (settings)
   //=========================
   const bool allowScalp = InpEnableScalp;
   const bool allowIntra = InpEnableIntraday;

   // If a mode is disabled, try to force-flat any leftover positions of that mode
   // (prevents "old" positions from staying open when you switch modes)
   if(!allowScalp && HasOpenPositionForMagic(ctx.sym, InpMagicScalp))
      ForceFlatSymbol(ctx.sym, "SCALP_MODE_DISABLED", eg, InpMagicScalp);

   if(!allowIntra && HasOpenPositionForMagic(ctx.sym, InpMagicIntra))
      ForceFlatSymbol(ctx.sym, "INTRADAY_MODE_DISABLED", eg, InpMagicIntra);



   //=========================
   // Step C execution
   //=========================

   // Intraday force-flat: ONLY when intraday mode is enabled
   if(allowIntra && IntradayShouldForceFlatNow())
   {
      datetime today0 = AmmanDayStart();
      if(ctx.lastForceFlatDayIntra != today0)
      {
         ctx.lastForceFlatDayIntra = today0;
         ForceFlatSymbol(ctx.sym, "INTRADAY_FORCE_FLAT_TIME", eg, InpMagicIntra);
      }
   }

   // Check open positions separately (separate magics) but only if that mode is enabled
   bool scalpOpen = (allowScalp ? HasOpenPositionForMagic(ctx.sym, InpMagicScalp) : false);
   bool intraOpen = (allowIntra ? HasOpenPositionForMagic(ctx.sym, InpMagicIntra) : false);

   //=========================
   // SCALP (only if enabled)
   //=========================
   if(allowScalp)
   {
      // SCALP open management: close on new accumulation
      if(scalpOpen)
      {
         ManageScalpPosition(ctx, eg);
         scalpOpen = HasOpenPositionForMagic(ctx.sym, InpMagicScalp); // refresh after possible close
      }

      // SCALP attempt (if not open)
      if(!scalpOpen)
      {
         string gateReason = "";
         if(GateFailReason(ctx, gateReason, false))
         {
            datetime now = TimeCurrent();
            if(InpEnableTelemetry && (ctx.lastSkipTelem==0 || (now-ctx.lastSkipTelem) >= InpSkipTelemEverySec))
            {
               ctx.lastSkipTelem  = now;
               ctx.lastSkipReason = "SCALP:" + gateReason;
               SendTelemetry("trade_skip", ctx.sym, "N/A", 0.0, 0.0, 0.0, 0.0, "n/a", "SCALP:"+gateReason, 0.0, eg);
            }
            PrintBlockedReason(ctx);
         }
         else
         {
            bool   isBuy=false;
            double lots=0, entry=0, sl=0, tp=0;
            string rr="", buildReason="", dedupKey="";

            bool built = BuildClassATrade(ctx, isBuy, lots, entry, sl, tp, rr, buildReason, dedupKey);

            if(built && lots>0 && entry>0 && sl>0 && tp>0)
            {
               // --- RETAKE RULE (SCALP): do not retake same setup if last outcome was LOSS ---
               string tfK=""; int dirK=0; long accRT=0;
               string why="";

               if(ParseScalpDedupKey(dedupKey, tfK, dirK, accRT))
               {
                  if(BlockIfPrevLoss(ctx.sym, false, tfK, dirK, accRT, why))
                  {
                     buildReason = "prev_loss_same_setup";
                     if(InpEnableTelemetry)
                        SendTelemetry("trade_skip", ctx.sym, "N/A", 0,0,0,0, "n/a", "SCALP:"+buildReason, 0.0, eg);
                  }
                  else
                  {
                     // tag order comment so we can store outcome on CLOSE
                     ctx.pendingOrderComment = MakeBBComment(false, tfK, dirK, accRT);

                     if(InpEnableTelemetry)
                        SendTelemetry("trade_attempt", ctx.sym, (isBuy?"BUY":"SELL"), lots, entry, sl, tp, rr, "SCALP:"+buildReason, 0.0, eg);

                     PlaceMarket(ctx, isBuy, lots, sl, tp, eg, "SCALP:"+buildReason, rr, InpMagicScalp, false);
                  }
               }
               else
               {
                  // fallback if parsing fails (still allow trade)
                  if(InpEnableTelemetry)
                     SendTelemetry("trade_attempt", ctx.sym, (isBuy?"BUY":"SELL"), lots, entry, sl, tp, rr, "SCALP:"+buildReason, 0.0, eg);

                  PlaceMarket(ctx, isBuy, lots, sl, tp, eg, "SCALP:"+buildReason, rr, InpMagicScalp, false);
               }
            }
         }
      }
   } // end allowScalp

   //=========================
   // INTRADAY (only if enabled)
   //=========================
   if(!allowIntra)
      return;

   if(intraOpen)
   {
      // Manage open intraday position (rule #1/#2/#3/#4)
      ManageIntradayPosition(ctx, eg);
   }
   else
   {
      string gateReason = "";
      if(GateFailReason(ctx, gateReason, true))
      {
         datetime now = TimeCurrent();
         if(InpEnableTelemetry && (ctx.lastSkipTelem==0 || (now-ctx.lastSkipTelem) >= InpSkipTelemEverySec))
         {
            ctx.lastSkipTelem  = now;
            ctx.lastSkipReason = "INTRA:" + gateReason;
            SendTelemetry("trade_skip", ctx.sym, "N/A", 0.0, 0.0, 0.0, 0.0, "n/a", "INTRA:"+gateReason, 0.0, eg);
         }
         PrintBlockedReason(ctx);
      }
      else
      {
         bool   isBuy=false;
         double lots=0, entry=0, sl=0, tp=0;
         string rr="", buildReason="", dedupKey="";
         IntraSignal sig; sig.valid=false;

         bool built = BuildClassATrade_Intraday(ctx, isBuy, lots, entry, sl, tp, rr, buildReason, dedupKey, sig);

         if(built && sig.valid && lots>0 && entry>0 && sl>0 && tp>=0)
         {
            // Stable setup identity (used for B re-entry tracking + telemetry)
            string keyCore = StringFormat("%s|%I64d|%s", sig.tf, sig.acc_rt, (sig.dir>0?"BUY":"SELL"));

            // BLOCK re-taking same setup if last OUTCOME was LOSS
            string whyLoss = "";
            if(BlockIfPrevLoss(ctx.sym, true, sig.tf, sig.dir, sig.acc_rt, whyLoss))
            {
               datetime now = TimeCurrent();
               if(InpEnableTelemetry && (ctx.lastSkipTelem==0 || (now-ctx.lastSkipTelem) >= InpSkipTelemEverySec))
               {
                  ctx.lastSkipTelem  = now;
                  ctx.lastSkipReason = "INTRA:" + whyLoss;
                  SendTelemetry("trade_skip", ctx.sym, "N/A", 0.0, 0.0, 0.0, 0.0, "n/a",
                                "INTRA:"+whyLoss+"|"+keyCore, 0.0, eg);
               }
               Print("STEP_C [", ctx.sym, "] BLOCK REASON: INTRA ", whyLoss,
                     " (tf=", sig.tf, " accRT=", sig.acc_rt, " dir=", sig.dir, ")");
               return;
            }

            // Existing dedup (separate from retake rule)
            if(DedupCheckOnly(ctx, dedupKey, true))
            {
               // RULE: intraday signal => close any open SCALP positions before opening INTRADAY
               if(HasOpenPositionForMagic(ctx.sym, InpMagicScalp))
               {
                  Print("INTRA signal => closing SCALP first | sym=", ctx.sym, " | reason=", buildReason);
                  ForceFlatSymbol(ctx.sym, "switch_to_intraday:"+buildReason, eg, InpMagicScalp);

                  if(HasOpenPositionForMagic(ctx.sym, InpMagicScalp))
                  {
                     Print("INTRA entry blocked: scalp still open after close attempt | sym=", ctx.sym);
                     return;
                  }
               }

               if(InpEnableTelemetry)
                  SendTelemetry("trade_attempt", ctx.sym, (isBuy?"BUY":"SELL"), lots, entry, sl, tp, rr, "INTRA:"+buildReason, 0.0, eg);

               ctx.pendingOrderComment = MakeBBComment(true, sig.tf, sig.dir, sig.acc_rt);

               bool ok = PlaceMarket(ctx, isBuy, lots, sl, tp, eg, "INTRA:"+buildReason, rr, InpMagicIntra, true);
               if(ok)
               {
                  if(dedupKey != "") DedupCommit(ctx, dedupKey, true);

                  ctx.intraPrevKey  = keyCore;
                  ctx.intraPrevLots = lots;

                  ctx.intraActiveKey       = keyCore;
                  ctx.intraActiveTF        = sig.tf;
                  ctx.intraActiveAccRT     = sig.acc_rt;
                  ctx.intraActiveDir       = sig.dir;
                  ctx.intraActiveEventTime = sig.event_time;
                  ctx.intraActiveIsMit     = sig.isMit;

                  ctx.intraBaseAccRT_D  = NormalizeTimeMaybeMs((long)ctx.areas.D.acc.right_time);
                  ctx.intraBaseAccRT_H1 = NormalizeTimeMaybeMs((long)ctx.areas.H1.acc.right_time);
                  ctx.intraBaseAccRT_M5 = NormalizeTimeMaybeMs((long)ctx.areas.M5.acc.right_time);
                  ctx.intraBaseAccRT_M  = NormalizeTimeMaybeMs((long)ctx.areas.M.acc.right_time);
                  ctx.intraBaseAccRT_W  = NormalizeTimeMaybeMs((long)ctx.areas.W.acc.right_time);

                  ctx.intraTP_AccBorder = 0;
                  ctx.intraTP_WickLevel = 0;

                  if(InpIntraEnableObstacleTP)
                  {
                     double border=0, wick=0;
                     FindNearestAccBorderAhead(ctx, sig.dir, entry, sig.tf, sig.acc_rt, border);
                     FindNearestWickAhead(ctx, sig.dir, entry, wick);
                     ctx.intraTP_AccBorder = (border>0 ? border : 0);
                     ctx.intraTP_WickLevel = (wick>0 ? wick : 0);
                  }

                  ctx.intraGZValid=false;
                  ctx.intraGZTouched=false;
                  ctx.intraGZLower=0; ctx.intraGZUpper=0; ctx.intraGZMid=0; ctx.intraGZTime=0;

                  if(InpIntraEnableGZReverse)
                  {
                     GoldZone gz;
                     if(FindMatchingGZ(ctx, sig.tf, sig.acc_rt, gz))
                     {
                        ctx.intraGZValid=true;
                        ctx.intraGZTime=gz.gz_time;
                        ctx.intraGZLower=gz.lower;
                        ctx.intraGZUpper=gz.upper;
                        ctx.intraGZMid=(gz.lower+gz.upper)/2.0;
                        ctx.intraGZTouched=false;
                     }
                  }
               }
            }
         }
         else
         {
            if(InpEnableTelemetry)
               SendTelemetry("trade_skip", ctx.sym, "N/A", 0.0, 0.0, 0.0, 0.0, "n/a",
                             "INTRA_BUILD_FAIL:"+buildReason, 0.0, eg);
         }
      }
   }
}

//==============================================================
// STEP D (NEW):
// - Track trade ENTRY + EXIT via OnTradeTransaction
// - Store plannedRiskUSD at entry (for learning R-multiple)
// - On full close: compute total position P/L, save outcome (win/loss/be)
// - This is REQUIRED for BlockIfPrevLoss() + LearnOnPositionClosed() to actually work
//==============================================================
//==============================================================
// STEP D (NEW):
// - Track trade ENTRY + EXIT via OnTradeTransaction
// - Store plannedRiskUSD at entry (for learning R-multiple)
// - On full close: compute total position P/L, save outcome (win/loss/be)
// - This is REQUIRED for BlockIfPrevLoss() + LearnOnPositionClosed() to actually work
//==============================================================

int TFToCode(const string tf)
{
   if(tf=="M")  return 1;
   if(tf=="W")  return 2;
   if(tf=="D")  return 3;
   if(tf=="H1") return 4;
   if(tf=="M5") return 5;
   if(tf=="M1") return 6;
   return 0;
}

string CodeToTF(const int code)
{
   if(code==1) return "M";
   if(code==2) return "W";
   if(code==3) return "D";
   if(code==4) return "H1";
   if(code==5) return "M5";
   if(code==6) return "M1";
   return "";
}

void GVDel(const string key)
{
   if(GlobalVariableCheck(key)) GlobalVariableDel(key);
}

double CalcPlannedRiskUSD(const string sym, const double lots, const double entryPrice, const double slPrice)
{
   if(sym=="" || lots<=0.0 || entryPrice<=0.0 || slPrice<=0.0) return 0.0;

   SymbolSpec sp;
   ZeroMemory(sp);
   if(!LoadSymbolSpec(sym, sp)) return 0.0;

   double tv = TickValueForSL(sp);
   if(tv<=0.0 || sp.tick_size<=0.0) return 0.0;

   double dist  = MathAbs(entryPrice - slPrice);
   double ticks = dist / sp.tick_size;
   if(ticks<=0.0) return 0.0;

   return ticks * tv * lots;
}

void StorePosMeta(const ulong pos_id, const string sym, const long magic,
                  const double lots, const double entryPrice, const double slPrice,
                  const string comment)
{
   if(pos_id==0) return;

   // Planned risk
   double risk = CalcPlannedRiskUSD(sym, lots, entryPrice, slPrice);
   if(risk > 0.0) GVSetD(PosKey(pos_id, "risk"), risk);

   // Setup identity parsed from BB comment (BBI/BBS)
   bool isIntra=false; string tf=""; int dir=0; long accRT=0;
   if(ParseBBComment(comment, isIntra, tf, dir, accRT))
   {
      GVSetD(PosKey(pos_id, "i"),   isIntra ? 1.0 : 0.0);
      GVSetD(PosKey(pos_id, "tf"),  (double)TFToCode(tf));
      GVSetD(PosKey(pos_id, "dir"), (double)dir);
      GVSetD(PosKey(pos_id, "rt"),  (double)accRT);
   }

   // Remember magic (debug / sanity)
   GVSetD(PosKey(pos_id, "mg"), (double)magic);

   // Mark that we saw ENTRY
   GVSetD(PosKey(pos_id, "seen_in"), 1.0);
}

bool LoadPosMeta(const ulong pos_id,
                 bool &isIntra, string &tf, int &dir, long &accRT,
                 double &plannedRisk)
{
   isIntra=false; tf=""; dir=0; accRT=0; plannedRisk=0.0;
   if(pos_id==0) return false;

   plannedRisk = GVGetD(PosKey(pos_id,"risk"), 0.0);

   int tfCode = (int)GVGetD(PosKey(pos_id,"tf"), 0.0);
   tf = CodeToTF(tfCode);

   dir   = (int)GVGetD(PosKey(pos_id,"dir"), 0.0);
   accRT = (long)GVGetD(PosKey(pos_id,"rt"),  0.0);

   isIntra = (GVGetD(PosKey(pos_id,"i"), 0.0) > 0.5);

   return (tf!="" && dir!=0 && accRT>0);
}

bool CloseAlreadyProcessed(const ulong pos_id)
{
   return (GVGetD(PosKey(pos_id,"done"), 0.0) > 0.5);
}

void MarkCloseProcessed(const ulong pos_id)
{
   GVSetD(PosKey(pos_id,"done"), 1.0);
   GVSetD(PosKey(pos_id,"done_at"), (double)TimeCurrent());
}

// Optional: clean up most keys (keep done/done_at to prevent duplicates)
void CleanupPosKeys(const ulong pos_id)
{
   GVDel(PosKey(pos_id,"risk"));
   GVDel(PosKey(pos_id,"i"));
   GVDel(PosKey(pos_id,"tf"));
   GVDel(PosKey(pos_id,"dir"));
   GVDel(PosKey(pos_id,"rt"));
   GVDel(PosKey(pos_id,"mg"));
   GVDel(PosKey(pos_id,"seen_in"));
   // keep "done" + "done_at"
}

// ---- LEGACY handler (safe no-op if you don't use it) ----
void OnTradeTransaction_Legacy(const MqlTradeTransaction& trans,
                               const MqlTradeRequest& request,
                               const MqlTradeResult& result)
{
   // Keep empty (or paste your older legacy tracking here if you had any)

   // Only care about new deals
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(deal==0) return;

   if(!HistoryDealSelect(deal)) return;

   long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
   ulong pos_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(pos_id==0) return;

   string sym   = HistoryDealGetString(deal, DEAL_SYMBOL);
   long   mg    = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
   double vol   = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal, DEAL_PRICE);

   string cmt = HistoryDealGetString(deal, DEAL_COMMENT);
   if(cmt=="" && request.comment!="") cmt = request.comment;

   // Only our strategies
   bool ourScalp = ((int)mg == InpMagicScalp);
   bool ourIntra = ((int)mg == InpMagicIntra);
   if(!ourScalp && !ourIntra) return;

   //========================
   // ENTRY: store plannedRisk + setup identity
   //========================
   if(entry == DEAL_ENTRY_IN)
   {
      // Prefer request.sl, fallback to trans.price_sl
      double sl = request.sl;
      if(sl <= 0.0) sl = trans.price_sl;

      StorePosMeta(pos_id, sym, mg, vol, price, sl, cmt);
      return;
   }

   //========================
   // EXIT: only when position fully CLOSED
   //========================
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      if(CloseAlreadyProcessed(pos_id)) return;

      // If still open -> partial close (skip)
      if(PositionIdExists(pos_id)) return;

      // Fully closed: total P/L from all deals
      double profitTotal = PositionProfitFromHistory(pos_id);

      // Load meta (preferred)
      bool isIntra=false; string tf=""; int dir=0; long accRT=0; double plannedRisk=0.0;
      bool haveMeta = LoadPosMeta(pos_id, isIntra, tf, dir, accRT, plannedRisk);

      // Fallback: parse from entry-deal comment history
      if(!haveMeta)
      {
         string bb="";
         if(GetOpenBBCommentFromHistory(pos_id, bb))
         {
            bool ii=false; string tff=""; int dd=0; long rt=0;
            if(ParseBBComment(bb, ii, tff, dd, rt))
            {
               isIntra = ii; tf = tff; dir = dd; accRT = rt;
               haveMeta = true;
            }
         }
      }

      // If risk missing, approximate (still allows learning + outcome)
      if(plannedRisk <= 0.0)
         plannedRisk = MathMax(1.0, MathAbs(profitTotal));

      // Outcome
      int outcome = 0;
      if(profitTotal > 0.01) outcome = +1;
      else if(profitTotal < -0.01) outcome = -1;
      else outcome = 0;

      long closeTimeSec = (long)TimeCurrent();

      if(haveMeta)
         SaveSetupOutcome(sym, isIntra, tf, dir, accRT, outcome, closeTimeSec);

      // Learning update (per symbol context)
      int idx = FindCtxIndexBySymbol(sym);
      if(idx >= 0)
         LearnOnPositionClosed(g_syms[idx], isIntra, profitTotal, plannedRisk);

      MarkCloseProcessed(pos_id);
      CleanupPosKeys(pos_id);

      return;
   }
}


//=========================
// TRADE JOURNAL CSV
//=========================
input bool   InpLogTradesToCSV   = true;
input string InpTradeLogFileName = "BrainBot_Trades.csv"; // saved in MQL5/Files

int g_logHandle = INVALID_HANDLE;

bool OpenTradeLog()
{
   if(!InpLogTradesToCSV) return true;

   // FILE_COMMON -> common terminal folder (survives across terminals)
   // You can remove FILE_COMMON if you prefer this terminal only.
   g_logHandle = FileOpen(InpTradeLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(g_logHandle == INVALID_HANDLE)
   {
      Print("CSV log open failed. err=", GetLastError(), " file=", InpTradeLogFileName);
      return false;
   }

   // If file is empty, write header
   if(FileSize(g_logHandle) == 0)
   {
      FileWrite(g_logHandle,
         "time_server",
         "time_local",
         "symbol",
         "magic",
         "deal_ticket",
         "position_id",
         "entry_type",     // IN/OUT
         "side",           // BUY/SELL
         "lots",
         "price",
         "sl",
         "tp",
         "profit",
         "commission",
         "swap",
         "comment",
         "reason"
      );
      FileFlush(g_logHandle);
   }

   // Move to end for appending
   FileSeek(g_logHandle, 0, SEEK_END);
   return true;
}

void CloseTradeLog()
{
   if(g_logHandle != INVALID_HANDLE)
   {
      FileFlush(g_logHandle);
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }
}

string DealSideToStr(long deal_type)
{
   // DEAL_TYPE_BUY / DEAL_TYPE_SELL
   if(deal_type == DEAL_TYPE_BUY)  return "BUY";
   if(deal_type == DEAL_TYPE_SELL) return "SELL";
   return "N/A";
}

string EntryTypeToStr(long entry)
{
   if(entry == DEAL_ENTRY_IN)  return "IN";
   if(entry == DEAL_ENTRY_OUT) return "OUT";
   if(entry == DEAL_ENTRY_INOUT) return "INOUT";
   return "OTHER";
}

string TimeToStr(datetime t)
{
   return TimeToString(t, TIME_DATE|TIME_SECONDS);
}

// This fires for every deal (open/close/partial/SL/TP/etc.)
void OnTradeTransaction_StepD(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Only log actual deals added
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(deal == 0) return;

   // Ensure the deal is accessible in history
   if(!HistoryDealSelect(deal)) return;

   // --- Deal fields (FIXED: define all vars you used later) ---
   datetime tserv   = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   string   sym     = HistoryDealGetString(deal, DEAL_SYMBOL);
   long     magic   = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
   long     entry   = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
   ulong    pos_id  = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);

   long   dtype   = (long)HistoryDealGetInteger(deal, DEAL_TYPE);
   double lots    = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double price   = HistoryDealGetDouble(deal, DEAL_PRICE);
   double sl      = HistoryDealGetDouble(deal, DEAL_SL);
   double tp      = HistoryDealGetDouble(deal, DEAL_TP);
   double profit  = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double comm    = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double swap    = HistoryDealGetDouble(deal, DEAL_SWAP);
   string comment = HistoryDealGetString(deal, DEAL_COMMENT);

// ---------------------------
// LEARN: record planned risk at ENTRY IN
// ---------------------------
if(InpLearnEnable && entry == DEAL_ENTRY_IN && pos_id > 0)
{
   string psym; long pmagic; double pvol,popen,psl,ptp;
   if(ReadOpenPositionById(pos_id, psym, pmagic, pvol, popen, psl, ptp))
   {
      SymbolSpec spec;
      if(LoadSymbolSpec(psym, spec) && psl > 0 && popen > 0 && pvol > 0 && spec.tick_size > 0)
      {
         double slDist = MathAbs(popen - psl);
         double tvSL   = TickValueForSL(spec);
         double ticks  = (slDist / spec.tick_size);

         double plannedRisk = 0.0;
         if(tvSL > 0 && ticks > 0) plannedRisk = ticks * tvSL * pvol;

         if(plannedRisk > 0.0)
            GVSetD(PosKey(pos_id,"risk"), plannedRisk);

         GVSetD(PosKey(pos_id,"magic"), (double)pmagic);
      }
   }
}

// ---------------------------
// LEARN: update stats ONLY when position fully closed
// ---------------------------
if(InpLearnEnable && entry == DEAL_ENTRY_OUT && pos_id > 0)
{
   // If still exists -> partial close, skip learning update (but continue to CSV logging)
   if(!PositionIdExists(pos_id))
   {
      // prevent double-processing
      string doneKey = PosKey(pos_id,"done");
      if(!GlobalVariableCheck(doneKey))
      {
         GVSetD(doneKey, 1.0);

         double totalProfit = PositionProfitFromHistory(pos_id);
         double plannedRisk = GVGetD(PosKey(pos_id,"risk"), 0.0);
         
                  // ---------------------------
         // RECORD SETUP OUTCOME (needed for "no retake after loss")
         // ---------------------------
         string bbComment="";
         if(GetOpenBBCommentFromHistory(pos_id, bbComment))
         {
            bool isIntra2=false;
            string tf="";
            int dir=0;
            long accRT=0;
         
            if(ParseBBComment(bbComment, isIntra2, tf, dir, accRT))
            {
               int outcome = (totalProfit > 0.0 ? 1 : (totalProfit < 0.0 ? -1 : 0));
               SaveSetupOutcome(sym, isIntra2, tf, dir, accRT, outcome, (long)tserv);
            }
         }



         int idx = FindCtxIndexBySymbol(sym);
         if(idx >= 0)
         {
            bool isIntra = ((int)magic == InpMagicIntra);
            bool isScalp = ((int)magic == InpMagicScalp);

            if(isIntra || isScalp)
               LearnOnPositionClosed(g_syms[idx], isIntra, totalProfit, plannedRisk);
         }

         GlobalVariableDel(PosKey(pos_id,"risk"));
         GlobalVariableDel(PosKey(pos_id,"magic"));

         // NOTE: keeping your original behavior (you were deleting it).
         // If you want true dedup against multiple OUT deals, you should NOT delete doneKey here.
         // GlobalVariableDel(doneKey); // IMPORTANT: keep it to avoid double-processing same position close

      }
   }
}
   
  
   // ---------------------------
   // CSV logging
   // ---------------------------
   if(!InpLogTradesToCSV) return;
   
   if(g_logHandle == INVALID_HANDLE)
      if(!OpenTradeLog()) return;
   
   // Add deal reason code so CLOSE shows if it was SL/TP/Manual/etc.
   long deal_reason = (long)HistoryDealGetInteger(deal, DEAL_REASON);
   string reason = (entry == DEAL_ENTRY_OUT ? "CLOSE" : "OPEN");
   reason += "|reason=" + IntegerToString((int)deal_reason);
   
   // Digits for nicer price formatting (per-symbol)
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(dg < 0) dg = 2;
   
   FileSeek(g_logHandle, 0, SEEK_END);
   FileWrite(g_logHandle,
      TimeToStr(tserv),                 // time_server
      TimeToStr(TimeLocal()),           // time_local
      sym,                              // symbol
      (int)magic,                       // magic
      (ulong)deal,                      // deal_ticket
      (ulong)pos_id,                    // position_id
      EntryTypeToStr(entry),            // entry_type (IN/OUT)
      DealSideToStr(dtype),             // side (BUY/SELL)
      DoubleToString(lots, 2),          // lots
      DoubleToString(price, dg),        // price
      DoubleToString(sl, dg),           // sl
      DoubleToString(tp, dg),           // tp
      DoubleToString(profit, 2),        // profit
      DoubleToString(comm, 2),          // commission
      DoubleToString(swap, 2),          // swap
      comment,                          // comment
      reason                            // reason
   );
   
   FileFlush(g_logHandle);
   }


//=========================
// INIT + EVENT LOOP (FIXED)
// - No ArrayInitialize on struct arrays
// - No '&' references (MQL5 restriction)
// - Proper event handlers exist
// - Always DUAL mode: scalp + intraday processed every cycle
//=========================

void ResetSymbolCtx(SymbolCtx &c)
{
   c.enabled = false;
   c.sym = "";
   c.lastForceFlatDayIntra = 0;
   c.spec.symbol = "";
   c.spec.digits = 0;
   c.spec.point  = 0;

   c.spec.tick_size = 0;
   c.spec.tick_value = 0;
   c.spec.tick_value_profit = 0;
   c.spec.tick_value_loss = 0;

   c.spec.vol_min = 0;
   c.spec.vol_max = 0;
   c.spec.vol_step = 0;
   c.spec.ok = false;

   c.gates.liquidity_ok = false;
   c.gates.news_block   = true;
   c.gates.valid        = false;

   ClearAreas(c.areas);

   c.areas_updated_at = 0;
   c.gates_updated_at = 0;
   c.updated_at       = 0;


   c.has_initial_sync = false;
   c.news_source = "unknown";

   c.lastM1BarTime   = 0;
   c.testTradeFired  = false;

   c.lastGatePrint   = 0;
   c.lastBlockPrint  = 0;

   c.lastSkipTelem   = 0;
   c.lastSkipReason  = "";

   c.lastTradeTimeScalp = 0;
   c.lastTradeTimeIntra = 0;

   c.lastDedupTimeScalp = 0;
   c.lastDedupKeyScalp  = "";

   c.lastDedupTimeIntra = 0;
   c.lastDedupKeyIntra  = "";
   
   c.intraActiveKey="";
   c.intraActiveTF="";
   c.intraActiveAccRT=0;
   c.intraActiveDir=0;
   c.intraActiveEventTime=0;
   c.intraActiveIsMit=false;

   c.intraPrevLots=0;
   c.intraPrevKey="";

   c.intraBaseAccRT_D=0;
   c.intraBaseAccRT_H1=0;
   c.intraBaseAccRT_M5=0;

   c.intraTP_AccBorder=0;
   c.intraTP_WickLevel=0;

   c.intraGZValid=false;
   c.intraGZTime=0;
   c.intraGZLower=0;
   c.intraGZUpper=0;
   c.intraGZMid=0;
   c.intraGZTouched=false;
   
   c.intraBaseAccRT_M=0;
   c.intraBaseAccRT_W=0;

   c.intraLastBrkTime_M=0;  c.intraLastBrkRT_M=0;
   c.intraLastBrkTime_W=0;  c.intraLastBrkRT_W=0;

   c.intraLastBrkTime_D=0;  c.intraLastBrkRT_D=0;
   c.intraLastBrkTime_H1=0; c.intraLastBrkRT_H1=0;
   c.intraLastBrkTime_M5=0; c.intraLastBrkRT_M5=0;

   LearnInit(c.learnScalp);
   LearnInit(c.learnIntra);
   
   c.pendingOrderComment = "";

}

void SetupSymbolSlots()
{
   // reset all
   for(int i=0;i<MAX_SYMS;i++)
      ResetSymbolCtx(g_syms[i]);

   int idx = 0;

   // Slot 1
   if(InpUse_S1 && InpSym_S1 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S1);
      // load learning stats
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);

      idx++;
   }
   // Slot 2
   if(InpUse_S2 && InpSym_S2 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S2);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 3
   if(InpUse_S3 && InpSym_S3 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S3);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 4
   if(InpUse_S4 && InpSym_S4 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S4);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 5
   if(InpUse_S5 && InpSym_S5 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S5);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 6
   if(InpUse_S6 && InpSym_S6 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S6);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 7
   if(InpUse_S7 && InpSym_S7 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S7);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }
   // Slot 8
   if(InpUse_S8 && InpSym_S8 != "" && idx < MAX_SYMS) {
      g_syms[idx].enabled = true;
      g_syms[idx].sym = ResolveTradeSymbol(InpSym_S8);
      LearnLoad(g_syms[idx].sym, "SCALP", g_syms[idx].learnScalp);
      LearnLoad(g_syms[idx].sym, "INTRA", g_syms[idx].learnIntra);
      idx++;
   }

   // Pre-load specs (optional but helpful)
   for(int i=0;i<MAX_SYMS;i++)
   {
      if(!g_syms[i].enabled) continue;
      if(g_syms[i].sym == "") continue;

      LoadSymbolSpec(g_syms[i].sym, g_syms[i].spec);
      Print("INIT symbol slot#", i, " sym=", g_syms[i].sym, " spec_ok=", (g_syms[i].spec.ok?"1":"0"));
   }
}

void StepLoop()
{
   DailyResetIfNeeded();

   for(int i=0;i<MAX_SYMS;i++)
   {
      if(!g_syms[i].enabled) continue;
      if(g_syms[i].sym == "") continue;

      // ensure symbol is selected
      SymbolSelect(g_syms[i].sym, true);

      // poll Node-RED if used
      if(InpGateSource == GATE_NODERED)
         PollNodeRedForSymbol(g_syms[i]);

      // DUAL processing happens inside ProcessSymbol()
      ProcessSymbol(g_syms[i]);
   }
}


//-------------------------
// REQUIRED EVENT HANDLERS
//-------------------------
int OnInit()
{
   // Setup slots + defaults
   SetupSymbolSlots();
   OpenTradeLog();

   // Timer mode
   if(InpDecideOnTimerOnly)
   {
      int sec = (InpPollSeconds < 1 ? 1 : InpPollSeconds);
      EventSetTimer(sec);
      Print("OnInit: timer enabled every ", sec, " sec");
   }
   else
   {
      Print("OnInit: running OnTick (timer disabled)");
   }

   // Initialize daily equity baseline
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday = 0;
   g_stopTrading = false;

   return(INIT_SUCCEEDED);
}

string UninitReasonText(const int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM:     return "REASON_PROGRAM";
      case REASON_REMOVE:      return "REASON_REMOVE";
      case REASON_RECOMPILE:   return "REASON_RECOMPILE";
      case REASON_CHARTCHANGE: return "REASON_CHARTCHANGE";
      case REASON_CHARTCLOSE:  return "REASON_CHARTCLOSE";
      case REASON_PARAMETERS:  return "REASON_PARAMETERS";
      case REASON_ACCOUNT:     return "REASON_ACCOUNT";
      case REASON_TEMPLATE:    return "REASON_TEMPLATE";
      case REASON_INITFAILED:  return "REASON_INITFAILED";
      case REASON_CLOSE:       return "REASON_CLOSE";
      default:                 return "REASON_UNKNOWN";
   }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("OnDeinit reason=", reason, " (", UninitReasonText(reason), ")");
   CloseTradeLog();
}


void OnTick()
{
   if(InpDecideOnTimerOnly) return;
   StepLoop();
}

void OnTimer()
{
   StepLoop();
}
