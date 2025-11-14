-- EW-SIGINT Script 2.35.08 (Fixed: heat rate,Pod status update, ELINT naval bands/time, COMINT reports; COMINT now detects all coalitions)
-- Supports A-6E, EA-6B, F-4E-45MC, F-4G, EA-18G, VSN_F35A/VSN_F35B/VSN_F35C, JF-17, F-22A.
-- Offensive: Suppresses SAM/EWR radars. Defensive: Disrupts missiles.
-- Modes: Barrage, Spot (S/X-Band), Directional (Forward/Left/Right).
-- Features: Overheating (shared heat pool), timing (300s/600s duration, 120s/60s cooldown), power drain, environmental effects, effectiveness degradation, RWR auto-tuning, dynamic HOJ (shared).
-- SIGINT: ELINT (radar) + COMINT (radio comms).
-- F10 Menu: "EW-SIGINT" > Start/Stop Defensive, Start/Stop Offensive, Set Modes, Pod Config, Jammer Info, ELINT, COMINT.
-- COMINT: Detects client aircraft, shows VHF/UHF + COM1 freq, markpoints, reports.
-- Defaults: Offensive/Defensive to barrage.
-- Messages: Player-specific, AI suppressed.
-- Auto-detects EW units at mission start (3s). Type check on slot change (3s delay).
-- Version Progression:
-- 2.35.08: Fixed pod status not updating in JAMMER status (refreshed menu); Fixed ELINT unknown band for naval units and strange time format; Fixed COMINT not creating reports/markpoints; Updated COMINT to detect all coalitions.
-- Modifications (as of November 02, 2025):
-- - Fixed undefined 'sam_type' in updateHeatAndTimers by defaulting to "EWR" outside loops.
-- - Optimized RWR auto-tuning: Moved to separate function (updateRWRTuning) scheduled every 10s instead of per-second in heat loop.
-- - Optimized radar list updates: Made incremental using event handlers for birth/death instead of full rescan every 120s.
-- - Optimized jamming checks: Replaced per-radar-per-jammer 5s schedules with per-jammer 10s timer that filters in-range radars first using mist.getUnitsInZones.
-- - In scanForELINT, scan only enemy radars (using enemyRadarLists) instead of all radars.
-- - Reports now append history (up to 5 per emitter/client) instead of overwriting; added cap to prevent memory growth.
-- - Added HOJ risk increment for defensive jamming (similar to offensive).
-- - Simplified power drain checks.
-- - Added safety to menu removals (check if path exists, but DCS API doesn't support direct check; assume remove is safe).
-- - Defined constants for magic numbers (e.g., MIN_ALTITUDE_FT, RADIO_HORIZON_FACTOR).
-- - Removed unused function EWJscript.
-- - Reduced env.info log spam; commented out non-essential logs.
-- - Batch timers: Combined heat updates with partial scans if needed; increased ELINT/COMINT to 60s.
-- - Performance: Added early exits in loops; use local vars where possible.
-- - Comments: Added explanations for changes and key sections.
-- - Fixed Lua 5.1 compatibility: Removed all goto statements and labels, restructured with if-else.
-- - Fixed syntax error: Added missing 'end' to close 'if target then' in checkJammingForJammer.
-- - Fixed undefined 'aircraft_type' in checkJammingForJammer by defining it locally.
-- - Fixed in_range_radars: Replaced incorrect mist.getUnitsInZones with manual distance filter loop for sphere check.
-- - Modified ELINT to scan all radars (both coalitions), but marks/reports are coalition-specific.
-- - Removed CSV export feature entirely (functions, calls, paths, notes in reports).
-- - Modified to create/update radar lists only if at least one ELINT is active.
-- - Added checks to skip scheduling scans if no active ELINT/COMINT.
-- - Fixed nil in Unit.getByName in samON/samOFF.
-- - Optimized menu refresh: Rebuild only on changes, but since DCS, full rebuild is fine.
-- Constants for magic numbers
local MIN_ALTITUDE_M = 304.8 -- 1000 ft
local RADIO_HORIZON_FACTOR = 4.12 -- Radio horizon calculation constant
local BURN_THROUGH_RANGE = 5000
local REPORT_HISTORY_CAP = 5 -- Max reports per emitter/client to prevent unlimited growth
local RWR_TUNING_INTERVAL = 10 -- Seconds between RWR auto-tuning checks
local JAMMING_CHECK_INTERVAL = 10 -- Seconds between per-jammer jamming checks
local SCAN_INTERVAL = 60 -- Increased ELINT/COMINT scan interval for performance
local RADAR_REFRESH_INTERVAL = 120 -- Kept for fallback full refresh if needed
-- Load MIST (assumes MIST is loaded in mission via trigger or dofile)
if not mist then
    env.error("EW-SIGINT Script 2.35.08: MIST not loaded. Please load MIST in mission.")
    return
end
-- MIST Compatibility: Ensure getHeadingDifference exists
if not mist.getHeadingDifference then
    mist.getHeadingDifference = function(h1, h2)
        local diff = h1 - h2
        while diff > 180 do diff = diff - 360 end
        while diff <= -180 do diff = diff + 360 end
        return diff
    end
    env.warning("EW-SIGINT: Using fallback getHeadingDifference")
end
-- New: Time format function
local function formatMissionTime(seconds)
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", hours, mins, secs)
end
local POD_TYPES = {
    ["AN/ALQ-99"] = {power = 1.2, max_range = 50000, name = "AN/ALQ-99 (Tactical)", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 300000, elint_success_rate = 0.85, comint_capable = true, comint_range = 250000},
    ["AN/ALQ-131"] = {power = 0.9, max_range = 40000, name = "AN/ALQ-131 (Self-Protection)", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 150000, elint_success_rate = 0.80, comint_capable = false, comint_range = 0},
    ["AN/ALQ-119"] = {power = 0.8, max_range = 35000, name = "AN/ALQ-119 (ECM Pod)", heat_rate = 0.25, cooldown_rate = 0.4, elint_range = 100000, elint_success_rate = 0.70, comint_capable = false, comint_range = 0},
    ["AN/ALQ-249"] = {power = 1.3, max_range = 60000, name = "AN/ALQ-249 (NGJ Mid-Band)", heat_rate = 0.025, cooldown_rate = 0.8, elint_range = 400000, elint_success_rate = 0.95, comint_capable = true, comint_range = 350000},
    ["AN/APG-81"] = {power = 1.0, max_range = 50000, name = "AN/APG-81 (AESA)", heat_rate = 0.031, cooldown_rate = 1.0, elint_range = 250000, elint_success_rate = 0.92, comint_capable = true, comint_range = 200000},
    ["ALQ-249+99"] = {power = 1.4, max_range = 65000, name = "AN/ALQ-249+99 (Mixed)", heat_rate = 0.16, cooldown_rate = 0.7, elint_range = 350000, elint_success_rate = 0.90, comint_capable = true, comint_range = 300000},
    ["2xALQ-131"] = {power = 1.1, max_range = 45000, name = "2x AN/ALQ-131 (Dual Self-Protection)", heat_rate = 0.22, cooldown_rate = 0.5, elint_range = 180000, elint_success_rate = 0.82, comint_capable = false, comint_range = 0},
    ["ALQ-131+119"] = {power = 1.0, max_range = 42000, name = "AN/ALQ-131+119 (Mixed)", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 120000, elint_success_rate = 0.75, comint_capable = false, comint_range = 0},
    ["2xALQ-249"] = {power = 1.5, max_range = 70000, name = "2x AN/ALQ-249 (Dual NGJ)", heat_rate = 0.027, cooldown_rate = 0.8, elint_range = 450000, elint_success_rate = 0.96, comint_capable = true, comint_range = 400000},
    ["2xALQ-249+99"] = {power = 1.45, max_range = 67500, name = "2x AN/ALQ-249+99 (Mixed Dual)", heat_rate = 0.16, cooldown_rate = 0.7, elint_range = 375000, elint_success_rate = 0.92, comint_capable = true, comint_range = 325000},
    ["3xALQ-99"] = {power = 1.3, max_range = 55000, name = "3x AN/ALQ-99 (Triple Tactical)", heat_rate = 0.19, cooldown_rate = 0.6, elint_range = 320000, elint_success_rate = 0.87, comint_capable = true, comint_range = 270000},
    ["KLJ-7A"] = {power = 1.0, max_range = 50000, name = "KLJ-7A (AESA)", heat_rate = 0.031, cooldown_rate = 1.0, elint_range = 180000, elint_success_rate = 0.85, comint_capable = true, comint_range = 150000},
    ["AN/APG-77"] = {power = 1.0, max_range = 50000, name = "AN/APG-77 (AESA)", heat_rate = 0.031, cooldown_rate = 1.0, elint_range = 400000, elint_success_rate = 0.95, comint_capable = true, comint_range = 300000},
    ["ASTAC_Tactical"] = {power = 1.0, max_range = 50000, name = "ASTAC_Tactical", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.90, comint_capable = false, comint_range = 0},
    ["ELT568_V2"] = {power = 1.0, max_range = 50000, name = "ELT568_V2", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 150000, elint_success_rate = 0.85, comint_capable = true, comint_range = 120000},
    ["ALQ99_NGJ_MB"] = {power = 1.3, max_range = 60000, name = "ALQ99_NGJ_MB", heat_rate = 0.045, cooldown_rate = 0.8, elint_range = 400000, elint_success_rate = 0.95, comint_capable = true, comint_range = 350000},
    ["SAP518_Regatta"] = {power = 1.0, max_range = 50000, name = "SAP518_Regatta", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.88, comint_capable = true, comint_range = 180000},
    ["KZ900_Thunder"] = {power = 0.8, max_range = 40000, name = "KZ900_Thunder", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 120000, elint_success_rate = 0.85, comint_capable = true, comint_range = 100000},
    ["TEREC_ALQ125"] = {power = 0.7, max_range = 35000, name = "TEREC_ALQ125", heat_rate = 0.25, cooldown_rate = 0.4, elint_range = 100000, elint_success_rate = 0.75, comint_capable = false, comint_range = 0},
    ["SOAR_MMP"] = {power = 1.1, max_range = 55000, name = "SOAR_MMP", heat_rate = 0.12, cooldown_rate = 0.9, elint_range = 300000, elint_success_rate = 0.95, comint_capable = true, comint_range = 250000},
    ["EL_L8200"] = {power = 1.0, max_range = 50000, name = "EL_L8200", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 180000, elint_success_rate = 0.93, comint_capable = true, comint_range = 160000},
    ["KG300G_China"] = {power = 0.9, max_range = 45000, name = "KG300G_China", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 150000, elint_success_rate = 0.87, comint_capable = false, comint_range = 0},
    ["Arexis_Pod"] = {power = 1.2, max_range = 55000, name = "Arexis_Pod", heat_rate = 0.14, cooldown_rate = 0.85, elint_range = 250000, elint_success_rate = 0.95, comint_capable = true, comint_range = 220000},
    ["SIGINT"] = {power = 0.8, max_range = 180000, name = "SIGINT Pod", heat_rate = 0.02, cooldown_rate = 0.7, elint_range = 180000, elint_success_rate = 0.80, comint_capable = true, comint_range = 180000},
    ["AN/ALQ-161"] = {power = 1.1, max_range = 55000, name = "AN/ALQ-161 (Radio Frequency Surveillance)", heat_rate = 0.2, cooldown_rate = 0.6, elint_range = 350000, elint_success_rate = 0.90, comint_capable = true, comint_range = 300000},
    ["AN/ALQ-165"] = {power = 1.0, max_range = 50000, name = "AN/ALQ-165 (ASPJ)", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.85, comint_capable = false, comint_range = 0},
    ["AN/ALQ-184"] = {power = 1.0, max_range = 45000, name = "AN/ALQ-184 (Self-Protection)", heat_rate = 0.19, cooldown_rate = 0.6, elint_range = 180000, elint_success_rate = 0.82, comint_capable = false, comint_range = 0},
    ["AN/ALQ-187"] = {power = 1.2, max_range = 50000, name = "AN/ALQ-187 (ASPJ Upgrade)", heat_rate = 0.17, cooldown_rate = 0.7, elint_range = 250000, elint_success_rate = 0.88, comint_capable = false, comint_range = 0},
    ["AN/ALQ-211"] = {power = 1.1, max_range = 45000, name = "AN/ALQ-211 (SIRFC)", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 200000, elint_success_rate = 0.85, comint_capable = true, comint_range = 180000},
    ["AN/ALQ-218"] = {power = 1.3, max_range = 60000, name = "AN/ALQ-218 (Receiver System)", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 300000, elint_success_rate = 0.92, comint_capable = true, comint_range = 250000},
    ["Angry_Kitten"] = {power = 1.0, max_range = 50000, name = "Angry Kitten (Cognitive EW Pod)", heat_rate = 0.12, cooldown_rate = 0.9, elint_range = 250000, elint_success_rate = 0.95, comint_capable = true, comint_range = 200000},
    ["AN/ALQ-263"] = {power = 1.2, max_range = 60000, name = "AN/ALQ-263 (P-8 SIGINT)", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 500000, elint_success_rate = 0.95, comint_capable = true, comint_range = 400000},
    ["AN/APS-154"] = {power = 1.3, max_range = 70000, name = "AN/APS-154 (AAS Radar Pod)", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 300000, elint_success_rate = 0.92, comint_capable = false, comint_range = 0},
    ["Khibiny_L-175V"] = {power = 1.1, max_range = 50000, name = "Khibiny (L-175V) ECM Pod", heat_rate = 0.031, cooldown_rate = 0.6, elint_range = 300000, elint_success_rate = 0.88, comint_capable = true, comint_range = 250000},
    ["Gardeniya-1FU"] = {power = 0.9, max_range = 40000, name = "Gardeniya-1FU ECM Pod", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 150000, elint_success_rate = 0.80, comint_capable = true, comint_range = 120000},
    ["MSP-418K"] = {power = 1.0, max_range = 45000, name = "MSP-418K ECM Pod", heat_rate = 0.17, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.85, comint_capable = true, comint_range = 180000},
    ["Porubshchik_Il-22PP"] = {power = 1.3, max_range = 60000, name = "Porubshchik (Il-22PP) SIGINT System", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 400000, elint_success_rate = 0.92, comint_capable = true, comint_range = 350000},
    ["Y-9LG"] = {power = 1.2, max_range = 55000, name = "Y-9LG Standoff Jammer", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 350000, elint_success_rate = 0.90, comint_capable = true, comint_range = 300000},
    ["J-15D_ECM"] = {power = 1.0, max_range = 50000, name = "J-15D ECM Pod", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 250000, elint_success_rate = 0.85, comint_capable = true, comint_range = 200000},
    ["Y-8G_High_New_4"] = {power = 1.1, max_range = 50000, name = "Y-8G High New 4 Jammer", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 300000, elint_success_rate = 0.88, comint_capable = true, comint_range = 250000},
    ["Y-9JB"] = {power = 1.0, max_range = 50000, name = "Y-9JB SIGINT", heat_rate = 0.15, cooldown_rate = 0.7, elint_range = 400000, elint_success_rate = 0.92, comint_capable = true, comint_range = 350000},
    ["J-16D_EW"] = {power = 1.2, max_range = 55000, name = "J-16D EW Pod", heat_rate = 0.17, cooldown_rate = 0.7, elint_range = 350000, elint_success_rate = 0.90, comint_capable = true, comint_range = 300000},
    ["ELL-8212"] = {power = 1.1, max_range = 50000, name = "ELL-8212 Jamming Pod", heat_rate = 0.16, cooldown_rate = 0.7, elint_range = 250000, elint_success_rate = 0.90, comint_capable = true, comint_range = 200000},
    ["SPEAR_AECM"] = {power = 1.0, max_range = 45000, name = "SPEAR AECM Pod", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 200000, elint_success_rate = 0.85, comint_capable = false, comint_range = 0},
    ["Light_Shield"] = {power = 0.8, max_range = 40000, name = "Light Shield SIGINT Payload", heat_rate = 0.12, cooldown_rate = 0.9, elint_range = 150000, elint_success_rate = 0.85, comint_capable = true, comint_range = 120000},
    ["Wet_Eyes"] = {power = 0.7, max_range = 35000, name = "Wet Eyes SIGINT Payload", heat_rate = 0.14, cooldown_rate = 0.8, elint_range = 120000, elint_success_rate = 0.80, comint_capable = true, comint_range = 100000},
    ["Air_Keeper"] = {power = 1.2, max_range = 55000, name = "Air Keeper SIGINT/EW System", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 300000, elint_success_rate = 0.92, comint_capable = true, comint_range = 250000},
    ["EL/L-8202"] = {power = 1.0, max_range = 45000, name = "EL/L-8202 ECM Pod", heat_rate = 0.17, cooldown_rate = 0.7, elint_range = 180000, elint_success_rate = 0.85, comint_capable = false, comint_range = 0},
    ["Peregrine_MC-55A"] = {power = 1.3, max_range = 60000, name = "Peregrine MC-55A SIGINT/EW System", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 500000, elint_success_rate = 0.95, comint_capable = true, comint_range = 400000},
    ["Leidos_Modular_Pod"] = {power = 1.1, max_range = 55000, name = "Leidos Modular EW Pod", heat_rate = 0.14, cooldown_rate = 0.85, elint_range = 300000, elint_success_rate = 0.92, comint_capable = true, comint_range = 250000},
    ["Netra_ELW-2090"] = {power = 1.2, max_range = 50000, name = "Netra EL/W-2090 AEW&C System (Indian)", heat_rate = 0.16, cooldown_rate = 0.7, elint_range = 400000, elint_success_rate = 0.90, comint_capable = true, comint_range = 350000},
    ["DRDO_AEWCS"] = {power = 1.1, max_range = 45000, name = "DRDO AEW&CS System (Indian)", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 300000, elint_success_rate = 0.88, comint_capable = true, comint_range = 250000},
    ["Rooivalk_EW"] = {power = 1.0, max_range = 40000, name = "Rooivalk EW System (South African)", heat_rate = 0.2, cooldown_rate = 0.5, elint_range = 200000, elint_success_rate = 0.85, comint_capable = true, comint_range = 180000},
    ["Erieye_ER"] = {power = 1.3, max_range = 60000, name = "Erieye ER AEW&C System (Swedish/European)", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 450000, elint_success_rate = 0.95, comint_capable = true, comint_range = 400000},
    ["GlobalEye_AESA"] = {power = 1.4, max_range = 65000, name = "GlobalEye AESA System (Swedish/European)", heat_rate = 0.031, cooldown_rate = 0.85, elint_range = 500000, elint_success_rate = 0.96, comint_capable = true, comint_range = 450000},
    ["E-99_Erieye"] = {power = 1.2, max_range = 55000, name = "E-99 Erieye System (Brazilian)", heat_rate = 0.17, cooldown_rate = 0.7, elint_range = 350000, elint_success_rate = 0.90, comint_capable = true, comint_range = 300000},
    ["R-99_SIGINT"] = {power = 1.1, max_range = 50000, name = "R-99 SIGINT System (Brazilian)", heat_rate = 0.18, cooldown_rate = 0.6, elint_range = 300000, elint_success_rate = 0.88, comint_capable = true, comint_range = 250000},
    ["Praetorian_DASS"] = {power = 1.2, max_range = 55000, name = "Praetorian DASS", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 300000, elint_success_rate = 0.92, comint_capable = true, comint_range = 250000},
    ["AN/APR-50"] = {power = 0.8, max_range = 40000, name = "AN/APR-50", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 400000, elint_success_rate = 0.95, comint_capable = true, comint_range = 300000},
    ["AN/ALQ-78"] = {power = 0.9, max_range = 40000, name = "AN/ALQ-78 (ESM Pod)", heat_rate = 0.22, cooldown_rate = 0.5, elint_range = 200000, elint_success_rate = 0.82, comint_capable = false, comint_range = 0},
["AN/ALQ-167"] = {power = 1.0, max_range = 50000, name = "AN/ALQ-167", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.85, comint_capable = false, comint_range = 0},
    ["AN/ALQ-135"] = {power = 1.0, max_range = 50000, name = "AN/ALQ-135", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 200000, elint_success_rate = 0.85, comint_capable = false, comint_range = 0},
["L402_Himalayas"] = {power = 1.3, max_range = 80000, name = "L402 Himalayas ECM Suite (Russian)", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 350000, elint_success_rate = 0.94, comint_capable = true, comint_range = 300000},
["N036_Byelka"] = {power = 1.4, max_range = 200000, name = "N036 Byelka AESA Radar (Russian)", heat_rate = 0.041, cooldown_rate = 0.85, elint_range = 400000, elint_success_rate = 0.95, comint_capable = true, comint_range = 300000},
["U22_ECM"] = {power = 1.0, max_range = 45000, name = "U22 ECM Pod (Swedish)", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 250000, elint_success_rate = 0.85, comint_capable = true, comint_range = 200000},
["AN/ALQ-164"] = {power = 1.1, max_range = 50000, name = "AN/ALQ-164 DECM Pod (US)", heat_rate = 0.17, cooldown_rate = 0.75, elint_range = 300000, elint_success_rate = 0.88, comint_capable = false, comint_range = 0},
["SPO-10"] = {power = 0.9, max_range = 40000, name = "SPO-10 Sirena RWR (Soviet)", heat_rate = 0.2, cooldown_rate = 0.6, elint_range = 200000, elint_success_rate = 0.80, comint_capable = true, comint_range = 150000},
["Sirena-3"] = {power = 0.8, max_range = 35000, name = "Sirena-3 RWR (Soviet)", heat_rate = 0.22, cooldown_rate = 0.55, elint_range = 180000, elint_success_rate = 0.78, comint_capable = true, comint_range = 120000},
["L005_Sorbtsiya"] = {power = 1.2, max_range = 55000, name = "L-005 Sorbtsiya ECM Pod (Russian)", heat_rate = 0.16, cooldown_rate = 0.75, elint_range = 300000, elint_success_rate = 0.90, comint_capable = true, comint_range = 250000},
["AN/APR-39"] = {power = 0.9, max_range = 40000, name = "AN/APR-39 RWR (US)", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 250000, elint_success_rate = 0.85, comint_capable = true, comint_range = 200000},
["AN/ALQ-144"] = {power = 1.0, max_range = 45000, name = "AN/ALQ-144 IR Jammer (US)", heat_rate = 0.19, cooldown_rate = 0.65, elint_range = 200000, elint_success_rate = 0.82, comint_capable = false, comint_range = 0},
["L140_Otklik"] = {power = 1.0, max_range = 40000, name = "L-140 Otklik EW System (Russian)", heat_rate = 0.18, cooldown_rate = 0.7, elint_range = 220000, elint_success_rate = 0.84, comint_capable = true, comint_range = 180000},
["U2_Defensive_Suite"] = {power = 1.1, max_range = 60000, name = "U-2 Enhanced Defensive Suite (US)", heat_rate = 0.16, cooldown_rate = 0.75, elint_range = 400000, elint_success_rate = 0.92, comint_capable = true, comint_range = 350000},
["SR71_ECM"] = {power = 1.3, max_range = 70000, name = "SR-71 Electronic Countermeasures System (US)", heat_rate = 0.15, cooldown_rate = 0.8, elint_range = 450000, elint_success_rate = 0.94, comint_capable = true, comint_range = 400000},
["SPO-15_Beryoza"] = {power = 0.95, max_range = 42000, name = "SPO-15 Beryoza RWR (Soviet)", heat_rate = 0.19, cooldown_rate = 0.65, elint_range = 220000, elint_success_rate = 0.82, comint_capable = true, comint_range = 170000}
}
local AIRCRAFT_PODS = {
    ["A-6E"] = {"AN/ALQ-99", "3xALQ-99"},
    ["B-1B Lancer"] = {"AN/ALQ-161"},
    ["B-2 Spirit"] = {"AN/APR-50"},
["C-130"] = {"Angry_Kitten", "AN/ALQ-131"},
    ["E-2D"] = {"AN/ALQ-218"},
    ["E-3A"] = {"AN/ALQ-161"},
    ["EA-18G"] = {"AN/ALQ-249", "AN/ALQ-99", "ALQ-249+99", "2xALQ-249", "2xALQ-249+99", "3xALQ-99", "AN/ALQ-218", "ALQ99_NGJ_MB", "AN/ALQ-165", "AN/ALQ-187", "Angry_Kitten"},
    ["EA-6B"] = {"AN/ALQ-99", "3xALQ-99"},
    ["Eurofighter Typhoon"] = {"Praetorian_DASS", "Arexis_Pod", "ELT568_V2", "SPEAR_AECM"},
    ["Embraer"] = {"Netra_ELW-2090", "E-99_Erieye", "R-99_SIGINT", "DRDO_AEWCS"},
    ["Mirage-F1CR"] = {"ELT568_V2", "ASTAC_Tactical"},
    ["Mirage-F1EE"] = {"ELT568_V2", "ASTAC_Tactical"},
    ["Mirage-F1M-EE"] = {"ELT568_V2", "ASTAC_Tactical"},
    ["F-4E-45MC"] = {"AN/ALQ-131", "AN/ALQ-119", "2xALQ-131", "ALQ-131+119", "TEREC_ALQ125"},
    ["F-4G"] = {"AN/ALQ-131", "AN/ALQ-119", "2xALQ-131", "ALQ-131+119", "TEREC_ALQ125"},
    ["F-14A-135-GR"] = {"AN/ALQ-167"},
    ["F-14B"] = {"AN/ALQ-167"},
    ["F-15C"] = {"AN/ALQ-135", "AN/ALQ-131", "AN/ALQ-184", "AN/ALQ-211"},
    ["F-15ESE"] = {"AN/ALQ-131", "AN/ALQ-135"},
    ["F-16C_50"] = {"AN/ALQ-131", "AN/ALQ-184", "AN/ALQ-165", "AN/ALQ-211"},
    ["F-22A"] = {"AN/APG-77"},
    ["VSN_F35A"] = {"AN/APG-81"},
    ["VSN_F35B"] = {"AN/APG-81"},
    ["VSN_F35C"] = {"AN/APG-81"},
    ["F-117A"] = {"AN/APR-50"},
    ["FA-18C_hornet"] = {"AN/ALQ-165", "AN/ALQ-131", "EL_L8200", "EL/L-8202"},
    ["Global 6000"] = {"Erieye_ER", "GlobalEye_AESA"},
    ["Gripen"] = {"Arexis_Pod"},
    ["Il-22PP"] = {"Porubshchik_Il-22PP"},
    ["J-15"] = {"J-15D_ECM"},
    ["J-16"] = {"J-16D_EW"},
    ["JF-17"] = {"KLJ-7A", "KZ900_Thunder"},
    ["MiG-29 Fulcrum"] = {"MSP-418K"},
    ["M-2000C"] = {"ASTAC_Tactical"},
    ["MQ-1A Predator"] = {"SIGINT"},
    ["MQ-4C Triton"] = {"AN/ALQ-263"},
    ["P-8 Poseidon"] = {"AN/ALQ-263"},
["P-3C Orion"] = {"AN/ALQ-78"},
    ["Rafale"] = {"ASTAC_Tactical"},
    ["Rooivalk"] = {"Rooivalk_EW"},
    ["Su-25"] = {"Gardeniya-1FU"},
    ["Su-25T"] = {"Gardeniya-1FU", "MSP-418K"},
    ["Su-27"] = {"SAP518_Regatta"},
    ["Su-30MKA"] = {"SAP518_Regatta"},
    ["Su-30MKI"] = {"EL/L-8202"},
    ["Su-30MKM"] = {"SAP518_Regatta"},
    ["Su-30SM"] = {"SAP518_Regatta"},
    ["Su-34"] = {"Khibiny_L-175V"},
    ["Su-35s"] = {"Khibiny_L-175V", "SAP518_Regatta", "N036_Byelka", "L402_Himalayas"},
["Su-57"] = {"N036_Byelka", "L402_Himalayas"},
    ["Tornado ECR"] = {"ELT568_V2"},
    ["Tornado GR4"] = {"Arexis_Pod", "ELT568_V2"},
    ["Tornado IDS"] = {"ELT568_V2"},
    ["V22_Osprey"] = {"AN/ALQ-211", "AN/ALQ-131"},
["AJS-37"] = {"U22_ECM"},
["AV-8B"] = {"AN/ALQ-164"},
["MiG-21bis"] = {"SPO-10"},
["MiG-25"] = {"Sirena-3"},
["MiG-31"] = {"L005_Sorbtsiya"},
["Su-33"] = {"SAP518_Regatta"},
["AH-64D"] = {"AN/APR-39", "AN/ALQ-144"},
["Ka-50"] = {"L140_Otklik"},
["Mi-24P"] = {"Sirena-3"},
["OH-58D"] = {"AN/APR-39"},
["MiG-23"] = {"SPO-15_Beryoza"},
["MiG-27"] = {"SPO-15_Beryoza"},
["CH-47"] = {"AN/APR-39"},
["U-2"] = {"U2_Defensive_Suite"},
["SR-71"] = {"SR71_ECM"},
    ["Y-8"] = {"Y-8G_High_New_4"},
    ["Y-9"] = {"Y-9LG", "Y-9JB"}
}
local always_assign_types = {"F-22A", "VSN_F35A", "VSN_F35B", "VSN_F35C", "JF-17", "EA-18G", "EA-6B"}
function table.contains(t, val)
    for _, v in ipairs(t) do
        if v == val then return true end
    end
    return false
end
local SAM_TYPES = {
    ["SA-2"] = {band = "S", hoj_chance = 0},
    ["SA-3"] = {band = "S", hoj_chance = 0},
    ["SA-6"] = {band = "X", hoj_chance = 0.1},
    ["SA-10"] = {band = "X", hoj_chance = 0.3},
    ["SA-11"] = {band = "X", hoj_chance = 0.2},
    ["EWR"] = {band = "S", hoj_chance = 0}
}
local jammerPods = {} -- Stores pod type per jammer
local jammerModes = {} -- Stores offensive jamming mode
local jammerSectors = {} -- Stores offensive directional sector
local jammerTargets = {} -- Stores offensive spot target band
local defensiveJammerModes = {} -- Stores defensive jamming mode
local defensiveJammerSectors = {} -- Stores defensive directional sector
local defensiveJammerTargets = {} -- Stores defensive spot target band
local initializedUnits = {} -- Tracks initialized jammers
local switch = {} -- Tracks defensive jamming state
local offensiveSwitch = {} -- Tracks offensive jamming state
local elintSwitch = {} -- Tracks ELINT state
local comintSwitch = {} -- Tracks COMINT state
local elintCapable = {} -- Tracks if unit is ELINT capable
local heat = {} -- Tracks heat level (0–100, shared per pod)
local defensiveTimer = {} -- Tracks defensive jamming duration
local offensiveTimer = {} -- Tracks offensive jamming duration
local defensiveCooldown = {} -- Tracks defensive cooldown time
local offensiveCooldown = {} -- Tracks offensive cooldown time
local effectiveness = {} -- Tracks jamming effectiveness (0–100%)
local hoj_risk = {} -- Tracks dynamic HOJ risk per jammer (shared)
local elintReports = {} -- Global table for ELINT reports: {radarName = {reports = {{planeName, bearing, distance, time, coalition, position, band}}}}
local comintReports = {} -- Global table for COMINT reports: {clientName = {reports = {{planeName, bearing, distance, time, coalition, position, band, freq}}}}
local markPoints = {} -- Global table for ELINT markpoints: {radarName = {id, position, coalition}}
local comintMarkPoints = {} -- Global table for COMINT markpoints: {clientName = {id, position, coalition}}
local markIdCounter = 1
local comintMarkIdCounter = 10000
local hasEWUnits = false -- Flag to track if there are any EW units
local hasActiveELINT = false -- New flag to track if at least one ELINT is active
local enemyRadarLists = { [1] = {}, [2] = {} } -- Per-coalition enemy radar lists: key 1 for red (enemy blue), key 2 for blue (enemy red)
local radarList = {} -- All radars (for legacy if needed)
function cleanupJammer(jammer)
    jammerPods[jammer] = nil
    jammerModes[jammer] = nil
    jammerSectors[jammer] = nil
    jammerTargets[jammer] = nil
    defensiveJammerModes[jammer] = nil
    defensiveJammerSectors[jammer] = nil
    defensiveJammerTargets[jammer] = nil
    initializedUnits[jammer] = nil
    switch[jammer] = nil
    offensiveSwitch[jammer] = nil
    elintSwitch[jammer] = nil
    comintSwitch[jammer] = nil
    elintCapable[jammer] = nil
    heat[jammer] = nil
    defensiveTimer[jammer] = nil
    offensiveTimer[jammer] = nil
    defensiveCooldown[jammer] = nil
    offensiveCooldown[jammer] = nil
    effectiveness[jammer] = nil
    hoj_risk[jammer] = nil
    if next(jammerPods) == nil then
        hasEWUnits = false
    end
    -- Check if still active ELINT after cleanup
    hasActiveELINT = false
    for j, _ in pairs(jammerPods) do
        if elintSwitch[j] then
            hasActiveELINT = true
            break
        end
    end
    -- env.info("EW Script: Cleaned up jammer " .. jammer) -- Commented out for reduced log spam
end
-- New: Separate RWR tuning function for optimization (called every RWR_TUNING_INTERVAL seconds)
function updateRWRTuning()
    if not hasEWUnits then return end
    for jammer, _ in pairs(jammerPods) do
        local unit = Unit.getByName(jammer)
        if unit and unit:isExist() then
            local mode = jammerModes[jammer] or "barrage"
            local def_mode = defensiveJammerModes[jammer] or "barrage"
            if (offensiveSwitch[jammer] and mode == "spot") or (switch[jammer] and def_mode == "spot") then
                local own_coal = unit:getCoalition()
                local enemy_radars = enemyRadarLists[own_coal]
                local jammer_type = POD_TYPES[jammerPods[jammer]]
                local closest_band = nil
                local min_dist = math.huge
                for _, sam in pairs(enemy_radars) do
                    local sam_unit = Unit.getByName(sam)
                    if sam_unit and sam_unit:isExist() and sam_unit:isActive() then
                        local dist = mist.utils.get3DDist(unit:getPoint(), sam_unit:getPoint())
                        if dist < jammer_type.max_range * 1.5 and dist < min_dist then
                            local sam_type = "EWR"
                            for k, v in pairs(SAM_TYPES) do
                                if string.find(sam, k) then
                                    sam_type = k
                                    break
                                end
                            end
                            closest_band = SAM_TYPES[sam_type].band
                            min_dist = dist
                        end
                    end
                end
                if closest_band then
                    if offensiveSwitch[jammer] and mode == "spot" and jammerTargets[jammer] ~= closest_band then
                        jammerTargets[jammer] = closest_band
                        trigger.action.outTextForGroup(unit:getGroup():getID(), "Jammer " .. jammer .. " auto-adjusted to " .. closest_band .. "-Band SAM threat", 10)
                    end
                    if switch[jammer] and def_mode == "spot" and defensiveJammerTargets[jammer] ~= closest_band then
                        defensiveJammerTargets[jammer] = closest_band
                        trigger.action.outTextForGroup(unit:getGroup():getID(), "Jammer " .. jammer .. " defensive auto-adjusted to " .. closest_band .. "-Band SAM threat", 10)
                    end
                end
            end
        end
    end
    timer.scheduleFunction(updateRWRTuning, {}, timer.getTime() + RWR_TUNING_INTERVAL)
end
---------------------------- HEAT, TIMING, AND EFFECTIVENESS MANAGEMENT

function updateHeatAndTimers()
    if not hasEWUnits then return end
    for jammer, _ in pairs(jammerPods) do
        local unit = Unit.getByName(jammer)
        if unit and unit:isExist() then
            local jammer_type = POD_TYPES[jammerPods[jammer]]
            local aircraft_type = unit:getTypeName()
            local cooldown_duration = (aircraft_type == "EA-18G" or aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") and 60 or 120
            local heat_rate = jammer_type.heat_rate
            local cooldown_rate = jammer_type.cooldown_rate
            local mode = jammerModes[jammer] or "barrage"
            local def_mode = defensiveJammerModes[jammer] or "barrage"
            -- Environmental effects
            local altitude = unit:getPoint().y - land.getHeight({x = unit:getPoint().x, y = unit:getPoint().z})
            local ground_temp = env.mission.weather and env.mission.weather.airTemperature or 20
            local temp_factor = (ground_temp > 30) and 0.8 or 1.0
            -- Added: Heat altitude factor (higher below 5000ft, normalizing 5000-25000ft, lower above)
            local heat_alt_factor
            if altitude < 304.8 then  -- <1000ft
                heat_alt_factor = 1.2
            elseif altitude < 1524 then  -- <5000ft
                heat_alt_factor = 1.15
            elseif altitude < 3048 then  -- <10000ft
                heat_alt_factor = 1.1
            elseif altitude < 6096 then  -- <20000ft
                heat_alt_factor = 1.05
            elseif altitude < 7620 then  -- <25000ft
                heat_alt_factor = 1.0
            elseif altitude < 9144 then  -- <30000ft
                heat_alt_factor = 0.95
            elseif altitude < 10668 then  -- <35000ft
                heat_alt_factor = 0.9
            elseif altitude < 12192 then  -- <40000ft
                heat_alt_factor = 0.85
            else
                heat_alt_factor = 0.8
            end
            -- Added: Cooling altitude factor (lower below 5000ft, normalizing 5000-25000ft, higher above)
            local cooling_alt_factor
            if altitude < 304.8 then  -- <1000ft
                cooling_alt_factor = 0.8
            elseif altitude < 1524 then  -- <5000ft
                cooling_alt_factor = 0.85
            elseif altitude < 3048 then  -- <10000ft
                cooling_alt_factor = 0.9
            elseif altitude < 6096 then  -- <20000ft
                cooling_alt_factor = 0.95
            elseif altitude < 7620 then  -- <25000ft
                cooling_alt_factor = 1.0
            elseif altitude < 9144 then  -- <30000ft
                cooling_alt_factor = 1.05
            elseif altitude < 10668 then  -- <35000ft
                cooling_alt_factor = 1.1
            elseif altitude < 12192 then  -- <40000ft
                cooling_alt_factor = 1.15
            else
                cooling_alt_factor = 1.2
            end
            -- Power drain (simplified: exclude AESA pods)
            local power_factor = 1.0
            local radar_active = unit:getRadar()
            if radar_active and not table.contains(always_assign_types, aircraft_type) then -- Simplified check using always_assign_types
                power_factor = (aircraft_type == "EA-18G") and 0.95 or 0.8
                if offensiveSwitch[jammer] or switch[jammer] then
                    trigger.action.outTextForGroup(unit:getGroup():getID(), "Jammer " .. jammer .. " power reduced due to radar usage", 5)
                end
            end
            -- Early exit if neither jamming mode active
            if not offensiveSwitch[jammer] and not switch[jammer] then
                local isAI = unit:getPlayerName() == nil
                local pod_type = jammerPods[jammer]
                if not isAI and pod_type ~= "SIGINT" then
                    heat[jammer] = math.max(0, (heat[jammer] or 0) - cooldown_rate * temp_factor * cooling_alt_factor)
                    -- env.info("Cooling for " .. jammer .. ": new heat: " .. heat[jammer]) -- Commented for reduced logs
                    effectiveness[jammer] = math.min(100, (effectiveness[jammer] or 100) + 0.2)
                end
            else
                -- Default sam_type for HOJ (fix: was undefined if no RWR tuning ran)
                local sam_type = "EWR" -- Default to EWR if no specific threat
                -- Heat and effectiveness for offensive jamming
                if offensiveSwitch[jammer] then
                    local mode_factor = (mode == "spot" and ((aircraft_type == "F-22A") and 2.0 or (aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C") and 1.7 or (aircraft_type == "JF-17") and 1.6 or (aircraft_type == "EA-18G") and 1.5 or 1.3)) or (mode == "directional" and 1.2) or 1.0
                    local heat_increment = heat_rate * mode_factor * jammer_type.power * heat_alt_factor
                    heat[jammer] = (heat[jammer] or 0) + heat_increment
                    -- env.info("Offensive heat increase for " .. jammer .. ": " .. heat_increment .. ", new heat: " .. heat[jammer]) -- Commented
                    effectiveness[jammer] = math.max(0, (effectiveness[jammer] or 100) - 0.1)
                    offensiveTimer[jammer] = (offensiveTimer[jammer] or 0) + 1
                    hoj_risk[jammer] = math.min(0.5, (hoj_risk[jammer] or SAM_TYPES[sam_type].hoj_chance) + (offensiveTimer[jammer] / 60) * 0.01)
                    if aircraft_type == "F-22A" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.3
                    elseif aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.4
                    elseif aircraft_type == "JF-17" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.5
                    elseif aircraft_type == "EA-18G" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.6
                    end
                    if heat[jammer] >= 100 then
                        stopEWjamming(jammer)
                        offensiveCooldown[jammer] = timer.getTime() + cooldown_duration
                    end
                end
                -- Heat and effectiveness for defensive jamming (added HOJ risk increment)
                if switch[jammer] then
                    local def_mode_factor = (def_mode == "spot" and ((aircraft_type == "F-22A") and 2.0 or (aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C") and 1.7 or (aircraft_type == "JF-17") and 1.6 or (aircraft_type == "EA-18G") and 1.5 or 1.3)) or (def_mode == "directional" and 1.2) or 1.0
                    local heat_increment = heat_rate * def_mode_factor * jammer_type.power * heat_alt_factor
                    heat[jammer] = (heat[jammer] or 0) + heat_increment
                    -- env.info("Defensive heat increase for " .. jammer .. ": " .. heat_increment .. ", new heat: " .. heat[jammer]) -- Commented
                    effectiveness[jammer] = math.max(0, (effectiveness[jammer] or 100) - 0.1)
                    defensiveTimer[jammer] = (defensiveTimer[jammer] or 0) + 1
                    -- Added: HOJ risk for defensive (reduced multiplier)
                    hoj_risk[jammer] = math.min(0.5, (hoj_risk[jammer] or SAM_TYPES[sam_type].hoj_chance) + (defensiveTimer[jammer] / 60) * 0.005) -- Half the offensive rate
                    if aircraft_type == "F-22A" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.3
                    elseif aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.4
                    elseif aircraft_type == "JF-17" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.5
                    elseif aircraft_type == "EA-18G" then
                        hoj_risk[jammer] = hoj_risk[jammer] * 0.6
                    end
                    if heat[jammer] >= 100 then
                        stopDjamming(jammer)
                        defensiveCooldown[jammer] = timer.getTime() + cooldown_duration
                    end
                end
            end
        else
            cleanupJammer(jammer)
        end
    end
    timer.scheduleFunction(updateHeatAndTimers, {}, timer.getTime() + 1)
end

---------------------------- GET RADARS
-- Modified: Incremental updates via events; full refresh fallback
function addRadar(unitName, coal)
    if not hasActiveELINT then return end
    if not table.contains(radarList, unitName) then
        table.insert(radarList, unitName)
    end
    local enemyCoal = (coal == 1) and 2 or 1
    if not table.contains(enemyRadarLists[enemyCoal], unitName) then
        table.insert(enemyRadarLists[enemyCoal], unitName)
    end
    -- env.info("Added radar: " .. unitName .. " to coalition " .. coal) -- Commented
end
function removeRadar(unitName)
    if not hasActiveELINT then return end
    for i, name in ipairs(radarList) do
        if name == unitName then
            table.remove(radarList, i)
            break
        end
    end
    for coal = 1, 2 do
        for i, name in ipairs(enemyRadarLists[coal]) do
            if name == unitName then
                table.remove(enemyRadarLists[coal], i)
                break
            end
        end
    end
    -- env.info("Removed radar: " .. unitName) -- Commented
end
function getAllRadars()
    local radars = {}
    for coal = 1, 2 do
        local groups = coalition.getGroups(coal)
        for _, group in ipairs(groups) do
            if group:getCategory() == Group.Category.GROUND or group:getCategory() == Group.Category.SHIP then
                for _, unit in ipairs(group:getUnits()) do
                    if unit:isExist() and unit:isActive() and unit:hasSensors(Unit.SensorType.RADAR) then
                        if unit:hasSensors(Unit.SensorType.RADAR, Unit.RadarType.AS) or unit:hasAttribute("SAM SR") or unit:hasAttribute("EWR") or unit:hasAttribute("SAM TR") or unit:hasAttribute("Armed ships") then
                            table.insert(radars, unit:getName())
                        end
                    end
                end
            end
        end
    end
    return radars
end
function getEnemyRadars(coal)
    local enemy_coal = (coal == 1) and 2 or 1
    local radars = {}
    local groups = coalition.getGroups(enemy_coal)
    for _, group in ipairs(groups) do
        if group:getCategory() == Group.Category.GROUND or group:getCategory() == Group.Category.SHIP then
            for _, unit in ipairs(group:getUnits()) do
                if unit:isExist() and unit:isActive() and unit:hasSensors(Unit.SensorType.RADAR) then
                    if unit:hasSensors(Unit.SensorType.RADAR, Unit.RadarType.AS) or unit:hasAttribute("SAM SR") or unit:hasAttribute("EWR") or unit:hasAttribute("SAM TR") or unit:hasAttribute("Armed ships") then
                        table.insert(radars, unit:getName())
                    end
                end
            end
        end
    end
    return radars
end
function updateRadarLists()
    if not hasActiveELINT then return end
    radarList = getAllRadars()
    enemyRadarLists[1] = getEnemyRadars(1)
    enemyRadarLists[2] = getEnemyRadars(2)
    -- env.info("EW-SIGINT Script 2.35.08: Radar lists updated - All: " .. #radarList .. ", Red enemy: " .. #enemyRadarLists[1] .. ", Blue enemy: " .. #enemyRadarLists[2]) -- Commented
    -- Removed: timer.scheduleFunction(updateRadarLists, {}, timer.getTime() + RADAR_REFRESH_INTERVAL) -- No periodic refresh
end
-- Modified: Conditional initialization of radar lists only if at least one ELINT is active
function initRadarListsIfNeeded()
    if hasActiveELINT and #radarList == 0 then
        updateRadarLists()
    end
end
function calculateRadioHorizon(alt1, alt2)
    return RADIO_HORIZON_FACTOR * (math.sqrt(alt1) + math.sqrt(alt2)) * 1000
end
function toDMS(deg, is_lon)
    local d = math.floor(deg)
    local min = math.floor((deg - d) * 60)
    local sec = math.floor(((deg - d) * 60 - min) * 60)
    if is_lon then
        return string.format("%03d:%02d:%02d", d, min, sec)
    else
        return string.format("%02d:%02d:%02d", d, min, sec)
    end
end
function scanForELINT()
    local activeELINT = false
    for jammer, pod_type in pairs(jammerPods) do
        if elintCapable[jammer] and elintSwitch[jammer] then
            activeELINT = true
            local unit = Unit.getByName(jammer)
            if unit and unit:isExist() then
                local altitude_m = unit:getPoint().y - land.getHeight({x = unit:getPoint().x, y = unit:getPoint().z})
                if altitude_m >= MIN_ALTITUDE_M then
                    local jammer_type = POD_TYPES[pod_type]
                    -- env.info("EW Script: Scanning for jammer " .. jammer .. " (pod: " .. pod_type .. ", elint_range: " .. (jammer_type.elint_range or 180000) .. ")") -- Commented
                    local pos = unit:getPoint()
                    local jammer_coal = unit:getCoalition()
                    local max_range = jammer_type.elint_range or 180000
                    local success_rate = jammer_type.elint_success_rate or 0.80
                    -- Modified: Scan all radars (radarList) for both coalitions
                    -- env.info("EW Script: radarList size: " .. #radarList) -- Commented
                    for _, radar in ipairs(radarList) do
                        local r_unit = Unit.getByName(radar)
                        if r_unit and r_unit:isExist() and r_unit:isActive() then
                            local r_pos = r_unit:getPoint()
                            local dist = mist.utils.get3DDist(pos, r_pos)
                            if dist <= max_range then
                                local radar_alt_m = r_pos.y - land.getHeight({x = r_pos.x, y = r_pos.z})
                                local horizon_m = calculateRadioHorizon(altitude_m, radar_alt_m or 10)
                                if dist <= horizon_m then
                                    -- env.info("EW Script: Checking radar " .. radar .. " (dist: " .. dist .. ", max_range: " .. max_range .. ", radio_horizon: " .. horizon_m .. ")") -- Commented
                                    if land.isVisible(pos, r_pos) and math.random() < success_rate then
                                        -- env.info("EW Script: Radar " .. radar .. " in range. LOS: true, Success: true") -- Commented
                                        local error_bearing = math.random(-5, 5)
                                        local error_dist_factor = 1 + math.random(-5, 5)/100
                                        local bearing = mist.utils.toDegree(mist.utils.getDir(mist.vec.sub(r_pos, pos))) + error_bearing
                                        local distance = dist * error_dist_factor
                                        local mission_time = timer.getAbsTime()
                                        local time_str = formatMissionTime(mission_time)
                                        local lat, lon, alt = coord.LOtoLL(r_pos)
                                        local lat_dms = toDMS(math.abs(lat), false) .. (lat >= 0 and "N" or "S")
                                        local lon_dms = toDMS(math.abs(lon), true) .. (lon >= 0 and "E" or "W")
                                        local pos_text = lat_dms .. " " .. lon_dms
                                        local radar_coal = r_unit:getCoalition()
                                        local band = "Unknown"
                                        local radar_type = r_unit:getTypeName()
                                        for k, v in pairs(SAM_TYPES) do
                                            if string.find(radar, k) then
                                                band = v.band
                                                break
                                            end
                                        end
                                        if band == "Unknown" then
                                            if r_unit:hasAttribute("EWR") or string.find(radar_type:lower(), "ewr") then
                                                band = "S"
                                            elseif r_unit:hasAttribute("Armed ships") then
                                                band = "X" -- Assume naval search radars are X-band
                                            elseif r_unit:hasAttribute("SAM SR") or r_unit:hasAttribute("SAM TR") then
                                                band = "X"
                                            else
                                                band = "S" -- Default for unknown
                                            end
                                        end
                                        if not elintReports[radar] then
                                            elintReports[radar] = {reports = {}}
                                        end
                                        table.insert(elintReports[radar].reports, 1, {
                                            planeName = unit:getName(),
                                            bearing = bearing,
                                            distance = distance,
                                            time = time_str,
                                            coalition = jammer_coal,
                                            position = r_pos,
                                            band = band,
                                            type = radar_type,
                                            pos_text = pos_text
                                        })
                                        if #elintReports[radar].reports > REPORT_HISTORY_CAP then
                                            table.remove(elintReports[radar].reports)
                                        end
                                        -- Remove old mark
                                        if markPoints[radar] then
                                            trigger.action.removeMark(markPoints[radar].id)
                                        end
                                        local mark_id = markIdCounter
                                        local mark_text = "ELINT ID " .. mark_id .. " - band " .. band .. " - (" .. radar_type .. ") - " .. pos_text .. " - GMT " .. time_str
                                        trigger.action.markToCoalition(mark_id, mark_text, r_pos, jammer_coal, true)
                                        markPoints[radar] = {id = mark_id, position = r_pos, coalition = jammer_coal}
                                        markIdCounter = markIdCounter + 1
                                        -- Heat penalty
                                        heat[jammer] = math.min(100, (heat[jammer] or 0) + 0.03)
                                    end
                                end
                            end
                        end
                    end
                end
            else
                cleanupJammer(jammer)
            end
        end
    end
    if activeELINT then
        timer.scheduleFunction(scanForELINT, {}, timer.getTime() + SCAN_INTERVAL)
    end
end
function scanForCOMINT()
    local activeCOMINT = false
    for jammer, pod_type in pairs(jammerPods) do
        if POD_TYPES[pod_type].comint_capable and comintSwitch[jammer] then
            activeCOMINT = true
            local unit = Unit.getByName(jammer)
            if unit and unit:isExist() then
                local altitude_m = unit:getPoint().y - land.getHeight({x = unit:getPoint().x, y = unit:getPoint().z})
                if altitude_m >= MIN_ALTITUDE_M then
                    local jammer_type = POD_TYPES[pod_type]
                    local pos = unit:getPoint()
                    local jammer_coal = unit:getCoalition()
                    local max_range = jammer_type.comint_range or 180000
                    local success_rate = jammer_type.elint_success_rate or 0.80 -- Reuse ELINT success for COMINT
                    for coal = 1, 2 do
                        local groups = coalition.getGroups(coal)
                        for _, group in ipairs(groups) do
                            for _, client_unit in ipairs(group:getUnits()) do
                                if client_unit:getPlayerName() then -- Only clients (players)
                                    local client_pos = client_unit:getPoint()
                                    local dist = mist.utils.get3DDist(pos, client_pos)
                                    if dist <= max_range then
                                        local client_alt_m = client_pos.y - land.getHeight({x = client_pos.x, y = client_pos.z})
                                        local horizon_m = calculateRadioHorizon(altitude_m, client_alt_m or 10)
                                        if dist <= horizon_m then
                                            if land.isVisible(pos, client_pos) and math.random() < success_rate then
                                                local error_bearing = math.random(-5, 5)
                                                local error_dist_factor = 1 + math.random(-5, 5)/100
                                                local bearing = mist.utils.toDegree(mist.utils.getDir(mist.vec.sub(client_pos, pos))) + error_bearing
                                                local distance = dist * error_dist_factor
                                                local mission_time = timer.getAbsTime()
                                                local time_str = formatMissionTime(mission_time)
                                                local lat, lon, alt = coord.LOtoLL(client_pos)
                                                local lat_dms = toDMS(math.abs(lat), false) .. (lat >= 0 and "N" or "S")
                                                local lon_dms = toDMS(math.abs(lon), true) .. (lon >= 0 and "E" or "W")
                                                local pos_text = lat_dms .. " " .. lon_dms
                                                local client_name = client_unit:getName()
                                                local band = "VHF/UHF" -- Placeholder, as actual radio band not accessible
                                                local freq = "Unknown" -- Placeholder, as COM1 freq not directly accessible
                                                if not comintReports[client_name] then
                                                    comintReports[client_name] = {reports = {}}
                                                end
                                                table.insert(comintReports[client_name].reports, 1, {
                                                    planeName = unit:getName(),
                                                    bearing = bearing,
                                                    distance = distance,
                                                    time = time_str,
                                                    coalition = jammer_coal,
                                                    position = client_pos,
                                                    band = band,
                                                    freq = freq,
                                                    type = client_unit:getTypeName(),
                                                    pos_text = pos_text
                                                })
                                                if #comintReports[client_name].reports > REPORT_HISTORY_CAP then
                                                    table.remove(comintReports[client_name].reports)
                                                end
                                                -- Remove old mark
                                                if comintMarkPoints[client_name] then
                                                    trigger.action.removeMark(comintMarkPoints[client_name].id)
                                                end
                                                local mark_id = comintMarkIdCounter
                                                local mark_text = "COMINT ID " .. mark_id .. " - " .. band .. " " .. freq .. " MHz - (" .. client_unit:getTypeName() .. ") - " .. pos_text .. " - GMT " .. time_str
                                                trigger.action.markToCoalition(mark_id, mark_text, client_pos, jammer_coal, true)
                                                comintMarkPoints[client_name] = {id = mark_id, position = client_pos, coalition = jammer_coal}
                                                comintMarkIdCounter = comintMarkIdCounter + 1
                                                -- Heat penalty
                                                heat[jammer] = math.min(100, (heat[jammer] or 0) + 0.03)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            else
                cleanupJammer(jammer)
            end
        end
    end
    if activeCOMINT then
        timer.scheduleFunction(scanForCOMINT, {}, timer.getTime() + SCAN_INTERVAL)
    end
end
-- Modified: Optimized jamming check - per-jammer timer, filter in-range radars
function checkJammingForJammer(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() or not offensiveSwitch[jammer] then return end
    local own_coal = unit:getCoalition()
    local enemy_radars = enemyRadarLists[own_coal] or {}
    local jammer_type = POD_TYPES[jammerPods[jammer]]
    local pos = unit:getPoint()
    local effective_range = jammer_type.max_range * math.min(1.5, 1 + ((pos.y - land.getHeight({x = pos.x, y = pos.z})) / 5000) * 0.1)
    -- Manual filter for in-range radars (since mist.getUnitsInZones needs zone names; use distance loop for simplicity)
    local in_range = {}
    for _, sam in pairs(enemy_radars) do
        local sam_unit = Unit.getByName(sam)
        if sam_unit and sam_unit:isExist() and sam_unit:isActive() then
            local dist = mist.utils.get3DDist(pos, sam_unit:getPoint())
            if dist <= effective_range * 1.2 then
                table.insert(in_range, sam_unit)
            end
        end
    end
    for _, sam_unit in pairs(in_range) do
        local samunit = sam_unit:getName()
        local UnitObject = sam_unit
        local status, target = UnitObject:getRadar()
        if target then
            local targetname = target:getName()
            local jammerobject = unit
            local distSamJammer = mist.utils.get3DDist(UnitObject:getPoint(), jammerobject:getPoint())
            local aircraft_type = jammerobject:getTypeName() -- Fixed: Define locally
            if distSamJammer <= effective_range and heat[jammer] < 100 then
                if land.isVisible(UnitObject:getPoint(), jammerobject:getPoint()) then
                    local distSamTarget = mist.utils.get3DDist(UnitObject:getPoint(), Unit.getByName(targetname):getPoint())
                    local dice = math.random(0, 100)
                    local conditiondist = 100 * distSamTarget / distSamJammer
                    local _elevation = land.getHeight({x = jammerobject:getPoint().x, y = jammerobject:getPoint().z})
                    local _height = jammerobject:getPoint().y - _elevation
                    local t_elevation = land.getHeight({x = Unit.getByName(targetname):getPoint().x, y = Unit.getByName(targetname):getPoint().z})
                    local t_height = Unit.getByName(targetname):getPoint().y - t_elevation
                    local altitude_factor = math.min(_height / 10000, 1.5)
                    local prob = dice + (_height/1000) + (_height - t_height)/1000
                    local SamPos = mist.utils.makeVec3(UnitObject:getPosition().p)
                    local JammerPos = mist.utils.makeVec3(jammerobject:getPosition().p)
                    local TargetPos = mist.utils.makeVec3(Unit.getByName(targetname):getPosition().p)
                    local AngleSamJammer = mist.utils.toDegree(mist.utils.getDir(mist.vec.sub(JammerPos, SamPos)))
                    local AngleSamTarget = mist.utils.toDegree(mist.utils.getDir(mist.vec.sub(TargetPos, SamPos)))
                    local offsetJamTar = mist.getHeadingDifference(AngleSamJammer, AngleSamTarget)
                    local offsetJamSam = mist.getHeadingDifference(AngleSamJammer, 180)
                    local TargetandOffsetJamSam = mist.getHeadingDifference(AngleSamTarget, offsetJamSam) * 2
                    if TargetandOffsetJamSam < 0 then TargetandOffsetJamSam = -TargetandOffsetJamSam end
                    local anglecondition = 2/3 * distSamJammer/1000
                    local bankr = mist.utils.toDegree(mist.getRoll(jammerobject))
                    if bankr < 0 then bankr = -bankr end
                    local bank = bankr - 30
                    local pitchr = mist.utils.toDegree(mist.getPitch(jammerobject))
                    if pitchr < 0 then pitchr = -pitchr end
                    local pitch = pitchr - 30
                    local s_elevation = land.getHeight({x = UnitObject:getPoint().x, y = UnitObject:getPoint().z})
                    local s_height = UnitObject:getPoint().y - s_elevation
                    local cateto = _height - s_height
                    local _2DDistSamJammer = mist.utils.get2DDist(UnitObject:getPoint(), jammerobject:getPoint())
                    local anglesamjam = mist.utils.toDegree(math.asin(cateto/_2DDistSamJammer))
                    local sam_type = "EWR"
                    for k, v in pairs(SAM_TYPES) do
                        if string.find(samunit, k) then
                            sam_type = k
                            break
                        end
                    end
                    local band_factor = (SAM_TYPES[sam_type].band == "S") and 1.2 or 0.8
                    local hoj_chance = hoj_risk[jammer] or SAM_TYPES[sam_type].hoj_chance
                    if math.random() < hoj_chance then
                        if not (switch[jammer] or offensiveSwitch[jammer]) then
                            trigger.action.outTextForGroup(jammerobject:getGroup():getID(), samunit .. " targeting jammer via Home-On-Jam", 10)
                            trigger.action.outSoundForGroup(jammerobject:getGroup():getID(), "RWRThreat.wav")
                        end
                        timer.scheduleFunction(samON, {samunit}, timer.getTime() + math.random(15, 25))
                    else
                        local burn_through_factor = (distSamJammer < BURN_THROUGH_RANGE) and 0.5 or 1
                        local power_factor = jammer_type.power * (effectiveness[jammer] or 100) / 100
                        if jammerobject:getRadar() and not (aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") then
                            power_factor = power_factor * ((aircraft_type == "EA-18G") and 0.95 or 0.8)
                        end
                        local stealth_factor = 1.0
                        if aircraft_type == "F-22A" then
                            stealth_factor = 1.2
                        elseif aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" then
                            stealth_factor = 1.15
                        elseif aircraft_type == "JF-17" then
                            stealth_factor = 1.1
                        end
                        if (aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") and targetname ~= jammer then
                            trigger.action.outTextForGroup(jammerobject:getGroup():getID(), "Jammer " .. jammer .. " enhanced jamming due to stealth advantage", 5)
                        end
                        local mode = jammerModes[jammer] or "barrage"
                        local spot_factor = 1.0
                        if mode == "spot" then
                            spot_factor = (SAM_TYPES[sam_type].band == jammerTargets[jammer]) and ((aircraft_type == "F-22A") and 2.0 or (aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C") and 1.7 or (aircraft_type == "JF-17") and 1.6 or (aircraft_type == "EA-18G") and 1.5 or 1.3) or 0.5
                        end
                        local directional_factor = 1.0
                        if mode == "directional" then
                            local sector = jammerSectors[jammer] or "forward"
                            local angle_diff = math.abs(offsetJamTar)
                            local directional_threshold = (sector == "forward" and 60 or 90)
                            directional_factor = (angle_diff < directional_threshold) and 1.3 or 0.8
                            if sector == "left" then
                                directional_factor = (offsetJamTar > 0) and directional_factor or 0.8
                            elseif sector == "right" then
                                directional_factor = (offsetJamTar < 0) and directional_factor or 0.8
                            end
                        end
                        local range_factor = math.max(0, 1 - (distSamJammer / effective_range))
                        local probsector1 = ((5/2) * conditiondist + 10) * range_factor * band_factor * burn_through_factor * altitude_factor * power_factor * spot_factor * directional_factor * stealth_factor
                        local probsector2 = (conditiondist + 30) * range_factor * band_factor * burn_through_factor * altitude_factor * power_factor * spot_factor * directional_factor * stealth_factor
                        local probsector3 = ((conditiondist/3) + 57) * range_factor * band_factor * burn_through_factor * power_factor * spot_factor * directional_factor * stealth_factor
                        if (conditiondist > 40.5) and (prob <= probsector3) and (anglecondition < TargetandOffsetJamSam) and (anglesamjam >= bank and anglesamjam > pitch) then
                            timer.scheduleFunction(samOFF, {samunit}, timer.getTime())
                            if not (switch[jammer] or offensiveSwitch[jammer]) then
                                trigger.action.outTextForGroup(jammerobject:getGroup():getID(), samunit .. " jammed (sector 3, prob: " .. math.floor(probsector3) .. "%)", 5)
                            end
                        elseif (conditiondist < 40.5) and (conditiondist > 13.33) and (prob <= probsector2) and (anglecondition < TargetandOffsetJamSam) and (anglesamjam >= bank and anglesamjam > pitch) then
                            timer.scheduleFunction(samOFF, {samunit}, timer.getTime())
                            if not (switch[jammer] or offensiveSwitch[jammer]) then
                                trigger.action.outTextForGroup(jammerobject:getGroup():getID(), samunit .. " jammed (sector 2, prob: " .. math.floor(probsector2) .. "%)", 5)
                            end
                        elseif (conditiondist < 13.33) and (prob <= probsector1) and (anglecondition < TargetandOffsetJamSam) and (anglesamjam >= bank and anglesamjam > pitch) then
                            timer.scheduleFunction(samOFF, {samunit}, timer.getTime())
                            if not (switch[jammer] or offensiveSwitch[jammer]) then
                                trigger.action.outTextForGroup(jammerobject:getGroup():getID(), samunit .. " jammed (sector 1, prob: " .. math.floor(probsector1) .. "%)", 5)
                            end
                        else
                            timer.scheduleFunction(samON, {samunit}, timer.getTime() + math.random(15, 25))
                        end
                    end
                else
                    timer.scheduleFunction(samON, {samunit}, timer.getTime() + math.random(15, 25))
                end
            else
                timer.scheduleFunction(samON, {samunit}, timer.getTime() + math.random(15, 25))
            end
        end
    end
    timer.scheduleFunction(checkJammingForJammer, jammer, timer.getTime() + JAMMING_CHECK_INTERVAL)
end
---------------------------- SAM ON/OFF
function samON(params)
    local groupsam = params[1]
    local sam_unit = Unit.getByName(groupsam)
    if not sam_unit then return end
    local _group = sam_unit:getGroup()
    if _group then
        local _controller = _group:getController()
        _controller:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.OPEN_FIRE)
        local suppress = false
        for _, unit in pairs(_group:getUnits()) do
            local unitName = unit:getName()
            if switch[unitName] or offensiveSwitch[unitName] then
                suppress = true
                break
            end
        end
        if not suppress then
            trigger.action.outTextForGroup(_group:getID(), groupsam .. " SAM SWITCHING ON", 10)
            trigger.action.outSoundForGroup(_group:getID(), "RWRThreat.wav")
        end
    end
end
function samOFF(params)
    local groupsam = params[1]
    local sam_unit = Unit.getByName(groupsam)
    if not sam_unit then return end
    local _group = sam_unit:getGroup()
    if _group then
        local _controller = _group:getController()
        _controller:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
        local suppress = false
        for _, unit in pairs(_group:getUnits()) do
            local unitName = unit:getName()
            if switch[unitName] or offensiveSwitch[unitName] then
                suppress = true
                break
            end
        end
        if not suppress then
            trigger.action.outTextForGroup(_group:getID(), groupsam .. " SAM SWITCHING OFF", 10)
        end
    end
end
---------------------------- GET JAMMER POD
function getJammerPod(jammer)
    return POD_TYPES[jammerPods[jammer]]
end
function startEWjamming(jammer)
    local jammerUnit = Unit.getByName(jammer)
    if not jammerUnit or not jammerUnit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: startEWjamming failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local aircraft_type = jammerUnit:getTypeName()
    local _groupID = jammerUnit:getGroup():getID()
    local cooldown_duration = (aircraft_type == "EA-18G" or aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") and 60 or 120
    if offensiveCooldown[jammer] and timer.getTime() < offensiveCooldown[jammer] then
        local time_left = math.ceil(offensiveCooldown[jammer] - timer.getTime())
        trigger.action.outTextForGroup(_groupID, "Jammer " .. jammer .. " offensive pod in cooldown for " .. time_left .. "s", 10)
        return
    end
    offensiveSwitch[jammer] = true
    offensiveTimer[jammer] = 0
    -- Modified: Start per-jammer jamming check timer instead of per-radar checks
    timer.scheduleFunction(checkJammingForJammer, jammer, timer.getTime() + 1) -- Initial quick check
    updateMenu(jammer)
end
function stopEWjamming(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: stopEWjamming failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    offensiveSwitch[jammer] = nil
    updateMenu(jammer)
end
---------------------------- SET POD TYPE
function setPodType(jammer, pod_type)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setPodType failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    if POD_TYPES[pod_type] then
        jammerPods[jammer] = pod_type
        -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " set to pod: " .. pod_type) -- Commented
        missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Pod Type"})
        trigger.action.outTextForGroup(_groupID, "Pod updated to: " .. POD_TYPES[pod_type].name, 10)
        updateMenu(jammer)
    else
        trigger.action.outTextForGroup(_groupID, "Invalid pod type: " .. pod_type, 10)
    end
end
---------------------------- SET COMBO POD
function setComboPod(jammer, pod_type)
    if type(jammer) ~= "string" or type(pod_type) ~= "string" then
        return -- Skip if invalid args
    end
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setComboPod failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    if POD_TYPES[pod_type] then
        jammerPods[jammer] = pod_type
        -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " set to pod: " .. pod_type) -- Commented
        missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Pod Configuration"})
        trigger.action.outTextForGroup(_groupID, "Pod updated to: " .. POD_TYPES[pod_type].name, 10)
        updateMenu(jammer)
    end
end
---------------------------- SET OFFENSIVE JAMMING MODE
function setJammingMode(jammer, mode)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setJammingMode failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    jammerModes[jammer] = mode
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " offensive mode set to: " .. mode) -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Offensive Mode"})
    updateMenu(jammer)
end
---------------------------- SET DEFENSIVE JAMMING MODE
function setDefensiveJammingMode(jammer, mode)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setDefensiveJammingMode failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    defensiveJammerModes[jammer] = mode
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " defensive mode set to: " .. mode) -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Defensive Mode"})
    updateMenu(jammer)
end
---------------------------- SET OFFENSIVE DIRECTIONAL SECTOR
function setDirectionalSector(jammer, sector)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setDirectionalSector failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    jammerModes[jammer] = "directional"
    jammerSectors[jammer] = sector
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " offensive directional sector set to: " .. sector) -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Offensive Mode", "Directional Mode"})
    updateMenu(jammer)
end
---------------------------- SET DEFENSIVE DIRECTIONAL SECTOR
function setDefensiveDirectionalSector(jammer, sector)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setDefensiveDirectionalSector failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    defensiveJammerModes[jammer] = "directional"
    defensiveJammerSectors[jammer] = sector
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " defensive directional sector set to: " .. sector) -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Defensive Mode", "Directional Mode"})
    updateMenu(jammer)
end
---------------------------- SET OFFENSIVE SPOT TARGET
function setSpotTarget(jammer, band)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setSpotTarget failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    jammerModes[jammer] = "spot"
    jammerTargets[jammer] = band
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " offensive spot target set to: " .. band .. "-Band") -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Offensive Mode", "Spot Mode"})
    updateMenu(jammer)
end
---------------------------- SET DEFENSIVE SPOT TARGET
function setDefensiveSpotTarget(jammer, band)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: setDefensiveSpotTarget failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _groupID = unit:getGroup():getID()
    defensiveJammerModes[jammer] = "spot"
    defensiveJammerTargets[jammer] = band
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " defensive spot target set to: " .. band .. "-Band") -- Commented
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT", "Set Defensive Mode", "Spot Mode"})
    updateMenu(jammer)
end
---------------------------- ELINT START/STOP
function startELINT(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: startELINT failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    elintSwitch[jammer] = true
    hasActiveELINT = true
    initRadarListsIfNeeded() -- Initialize lists if needed when ELINT starts
    trigger.action.outTextForGroup(unit:getGroup():getID(), "ELINT started for " .. jammer, 10)
    updateMenu(jammer)
end
function stopELINT(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: stopELINT failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    elintSwitch[jammer] = nil
    -- Check if any other jammer has ELINT active
    hasActiveELINT = false
    for j, _ in pairs(jammerPods) do
        if elintSwitch[j] then
            hasActiveELINT = true
            break
        end
    end
    trigger.action.outTextForGroup(unit:getGroup():getID(), "ELINT stopped for " .. jammer, 10)
    updateMenu(jammer)
end
---------------------------- COMINT START/STOP
function startCOMINT(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then return end
    local pod_type = jammerPods[jammer]
    if not POD_TYPES[pod_type].comint_capable then
        trigger.action.outTextForGroup(unit:getGroup():getID(), "Pod does not support COMINT", 10)
        return
    end
    comintSwitch[jammer] = true
    trigger.action.outTextForGroup(unit:getGroup():getID(), "COMINT started for " .. jammer, 10)
    updateMenu(jammer)
end
function stopCOMINT(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then return end
    comintSwitch[jammer] = nil
    trigger.action.outTextForGroup(unit:getGroup():getID(), "COMINT stopped for " .. jammer, 10)
    updateMenu(jammer)
end
---------------------------- MENU CREATION

function updateMenu(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: updateMenu failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local _group = unit:getGroup()
    if not _group then
        -- env.info("EW-SIGINT Script 2.35.08: updateMenu failed for " .. jammer .. ": Group not found") -- Commented
        return
    end
    local _groupID = _group:getID()
    local aircraft_type = unit:getTypeName()
    local jammer_type = getJammerPod(jammer)
    local cooldown_duration = (aircraft_type == "EA-18G" or aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") and 60 or 120
    local pod_type = jammerPods[jammer]
    -- env.info("EW-SIGINT Script 2.35.08: Creating menu for " .. jammer .. ", aircraft: " .. aircraft_type .. ", groupID: " .. _groupID) -- Commented
    -- Remove existing menu (added safety: assume remove is safe)
    missionCommands.removeItemForGroup(_groupID, {"EW-SIGINT"})
    -- Create new menu with specified order
    local _jammermenu = missionCommands.addSubMenuForGroup(_groupID, "EW-SIGINT", nil)
    -- Modified: Single Start/Stop Jamming (toggles both offensive and defensive)
    local jamming_active = offensiveSwitch[jammer] or switch[jammer]
    if jamming_active then
        missionCommands.addCommandForGroup(_groupID, "Stop Jamming", _jammermenu, function()
            stopEWjamming(jammer)
            stopDjamming(jammer)
        end, nil)
    else
        missionCommands.addCommandForGroup(_groupID, "Start Jamming", _jammermenu, function()
            startEWjamming(jammer)
            startDjamming(jammer)
        end, nil)
    end
    -- Set Defensive Mode (added Inactive)
    local _jammermenumodedef = missionCommands.addSubMenuForGroup(_groupID, "Set Defensive Mode", _jammermenu)
    missionCommands.addCommandForGroup(_groupID, "Barrage Mode", _jammermenumodedef, function() setDefensiveJammingMode(jammer, "barrage") end, nil)
    local _jammermenumodespotdef = missionCommands.addSubMenuForGroup(_groupID, "Spot Mode", _jammermenumodedef)
    missionCommands.addCommandForGroup(_groupID, "S-Band", _jammermenumodespotdef, function() setDefensiveSpotTarget(jammer, "S") end, nil)
    missionCommands.addCommandForGroup(_groupID, "X-Band", _jammermenumodespotdef, function() setDefensiveSpotTarget(jammer, "X") end, nil)
    local _jammermenumodedirdef = missionCommands.addSubMenuForGroup(_groupID, "Directional Mode", _jammermenumodedef)
    missionCommands.addCommandForGroup(_groupID, "Forward", _jammermenumodedirdef, function() setDefensiveDirectionalSector(jammer, "forward") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Left", _jammermenumodedirdef, function() setDefensiveDirectionalSector(jammer, "left") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Right", _jammermenumodedirdef, function() setDefensiveDirectionalSector(jammer, "right") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Inactive", _jammermenumodedef, function() stopDjamming(jammer) end, nil)
    -- Set Offensive Mode (added Inactive)
    local _jammermenumodeoff = missionCommands.addSubMenuForGroup(_groupID, "Set Offensive Mode", _jammermenu)
    missionCommands.addCommandForGroup(_groupID, "Barrage Mode", _jammermenumodeoff, function() setJammingMode(jammer, "barrage") end, nil)
    local _jammermenumodespot = missionCommands.addSubMenuForGroup(_groupID, "Spot Mode", _jammermenumodeoff)
    missionCommands.addCommandForGroup(_groupID, "S-Band", _jammermenumodespot, function() setSpotTarget(jammer, "S") end, nil)
    missionCommands.addCommandForGroup(_groupID, "X-Band", _jammermenumodespot, function() setSpotTarget(jammer, "X") end, nil)
    local _jammermenumodedir = missionCommands.addSubMenuForGroup(_groupID, "Directional Mode", _jammermenumodeoff)
    missionCommands.addCommandForGroup(_groupID, "Forward", _jammermenumodedir, function() setDirectionalSector(jammer, "forward") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Left", _jammermenumodedir, function() setDirectionalSector(jammer, "left") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Right", _jammermenumodedir, function() setDirectionalSector(jammer, "right") end, nil)
    missionCommands.addCommandForGroup(_groupID, "Inactive", _jammermenumodeoff, function() stopEWjamming(jammer) end, nil)
    -- Set Pod Configuration (if available)
    local pods = AIRCRAFT_PODS[aircraft_type] or {}
    if #pods > 1 then
        local _jammermenupod = missionCommands.addSubMenuForGroup(_groupID, "Set Pod Configuration", _jammermenu)
        for _, combo in ipairs(pods) do
            missionCommands.addCommandForGroup(_groupID, "Add " .. POD_TYPES[combo].name, _jammermenupod, function() setComboPod(jammer, combo) end, nil)
        end
    end
    -- Show ELINT options if ELINT capable
    if elintCapable[jammer] then
        -- Start/Stop ELINT
        if elintSwitch[jammer] then
            missionCommands.addCommandForGroup(_groupID, "Stop ELINT", _jammermenu, function() stopELINT(jammer) end, nil)
        else
            missionCommands.addCommandForGroup(_groupID, "Start ELINT", _jammermenu, function() startELINT(jammer) end, nil)
        end
        -- ELINT submenu
        local _elintmenu = missionCommands.addSubMenuForGroup(_groupID, "ELINT", _jammermenu)
        missionCommands.addCommandForGroup(_groupID, "EW-list", _elintmenu, function()
            local own_coal = unit:getCoalition()
            local assets_text = "EW Assets:\n"
            for unitName, _ in pairs(initializedUnits) do
                local u = Unit.getByName(unitName)
                if u and u:isExist() then
                    local u_coal = u:getCoalition()
                    if u_coal == own_coal then
                        local altitude_m = u:getPoint().y - land.getHeight({x = u:getPoint().x, y = u:getPoint().z})
                        if altitude_m >= MIN_ALTITUDE_M then
                            local typ = u:getTypeName()
                            local altitude_ft = altitude_m * 3.28084
                            local fl = math.floor(altitude_ft / 100)
                            assets_text = assets_text .. typ .. " - " .. unitName .. " - F" .. string.format("%03d", fl) .. "\n"
                        end
                    end
                end
            end
            trigger.action.outTextForGroup(_groupID, assets_text, 15)
        end, nil)
        missionCommands.addCommandForGroup(_groupID, "Reports", _elintmenu, function()
            local own_coal = unit:getCoalition()
            local reports_text = "ELINT Reports:\n"
            for radarName, data in pairs(elintReports) do
                -- Modified: Show latest report (first in list)
                local latest = data.reports[1]
                if latest and latest.coalition == own_coal then
                    reports_text = reports_text .. "ID " .. markPoints[radarName].id .. " - band " .. latest.band .. " - (" .. latest.type .. ") - " .. latest.pos_text .. " - GMT " .. latest.time .. "\n"
                end
            end
            if reports_text == "ELINT Reports:\n" then
                reports_text = reports_text .. "No reports available."
            end
            trigger.action.outTextForGroup(_groupID, reports_text, 15)
        end, nil)
    end
    -- Show COMINT options if COMINT capable
    if jammer_type.comint_capable then
        -- Start/Stop COMINT
        if comintSwitch[jammer] then
            missionCommands.addCommandForGroup(_groupID, "Stop COMINT", _jammermenu, function() stopCOMINT(jammer) end, nil)
        else
            missionCommands.addCommandForGroup(_groupID, "Start COMINT", _jammermenu, function() startCOMINT(jammer) end, nil)
        end
        -- COMINT submenu
        local _comintmenu = missionCommands.addSubMenuForGroup(_groupID, "COMINT", _jammermenu)
        missionCommands.addCommandForGroup(_groupID, "Reports", _comintmenu, function()
            local own_coal = unit:getCoalition()
            local reports_text = "COMINT Reports:\n"
            for clientName, data in pairs(comintReports) do
                local latest = data.reports[1]
                if latest and latest.coalition == own_coal then
                    reports_text = reports_text .. "ID " .. comintMarkPoints[clientName].id .. " - " .. latest.band .. " " .. latest.freq .. " MHz - (" .. latest.type .. ") - " .. latest.pos_text .. " - GMT " .. latest.time .. "\n"
                end
            end
            if reports_text == "COMINT Reports:\n" then
                reports_text = reports_text .. "No reports available."
            end
            trigger.action.outTextForGroup(_groupID, reports_text, 15)
        end, nil)
        missionCommands.addCommandForGroup(_groupID, "All Clients", _comintmenu, function()
            local clients_text = "All Clients:\n"
            for coal = 1, 2 do
                local groups = coalition.getGroups(coal)
                for _, group in ipairs(groups) do
                    for _, client_unit in ipairs(group:getUnits()) do
                        if client_unit:getPlayerName() then
                            local client_name = client_unit:getName()
                            local client_type = client_unit:getTypeName()
                            local freq = "Unknown"
                            clients_text = clients_text .. client_type .. " - " .. client_name .. " - Freq: " .. freq .. "\n"
                        end
                    end
                end
            end
            trigger.action.outTextForGroup(_groupID, clients_text, 15)
        end, nil)
    end
    -- Jammer Info (modified: combined heat/timeout/HOJ)
    missionCommands.addCommandForGroup(_groupID, "JAMMER status", _jammermenu, function()
        local jammer_type = getJammerPod(jammer)
        local heat_level = math.floor(heat[jammer] or 0)
        local heat_state = (heat_level >= 95) and "critical" or (heat_level >= 80) and "warning" or "normal"
        local power_status = (table.contains(always_assign_types, aircraft_type)) and "Normal" or (unit:getRadar() and "Reduced" or "Normal") -- Simplified
        local effectiveness_level = math.floor(effectiveness[jammer] or 100)
        local hoj_level = math.floor((hoj_risk[jammer] or 0) * 100)
        local info_text = "Jammer: " .. jammer .. "\nType: " .. jammer_type.name .. "\nMax Range: " .. math.floor(jammer_type.max_range / 1000) .. " km\nPower: " .. (jammer_type.power * 100) .. "% (" .. power_status .. ")"
        local total_cooldown = math.max((offensiveCooldown[jammer] and timer.getTime() < offensiveCooldown[jammer] and math.ceil(offensiveCooldown[jammer] - timer.getTime()) or 0), (defensiveCooldown[jammer] and timer.getTime() < defensiveCooldown[jammer] and math.ceil(defensiveCooldown[jammer] - timer.getTime()) or 0))
        if total_cooldown == 0 then total_cooldown = "N/A" end
        info_text = info_text .. "\nTotal Cooldown: " .. total_cooldown .. "s\nHeat Level: " .. heat_level .. "% " .. heat_state .. "\nEffectiveness: " .. effectiveness_level .. "%\nHOJ Risk: " .. hoj_level .. "%"
        local off_mode = jammerModes[jammer] or "barrage"
        local def_mode = defensiveJammerModes[jammer] or "barrage"
        info_text = info_text .. "\nOffensive Mode: " .. (offensiveSwitch[jammer] and off_mode or "Inactive") .. "\nDefensive Mode: " .. (switch[jammer] and def_mode or "Inactive")
        if elintCapable[jammer] then
            info_text = info_text .. "\nELINT: " .. (elintSwitch[jammer] and "Active" or "Inactive")
        end
        if jammer_type.comint_capable then
            info_text = info_text .. "\nCOMINT: " .. (comintSwitch[jammer] and "Active" or "Inactive")
        end
        trigger.action.outTextForGroup(_groupID, info_text, 15)
    end, nil)
    -- env.info("EW-SIGINT Script 2.35.08: Menu created for " .. jammer .. ", groupID: " .. _groupID) -- Commented
end

function createmenu(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: createmenu failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    updateMenu(jammer)
end
-- Removed unused: function EWJscript(...)
---------------------------- DEFENSIVE JAMMING
function startDjamming(jammer)
    local jammerUnit = Unit.getByName(jammer)
    if not jammerUnit or not jammerUnit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: startDjamming failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local aircraft_type = jammerUnit:getTypeName()
    local _groupID = jammerUnit:getGroup():getID()
    local cooldown_duration = (aircraft_type == "EA-18G" or aircraft_type == "VSN_F35A" or aircraft_type == "VSN_F35B" or aircraft_type == "VSN_F35C" or aircraft_type == "JF-17" or aircraft_type == "F-22A") and 60 or 120
    if defensiveCooldown[jammer] and timer.getTime() < defensiveCooldown[jammer] then
        local time_left = math.ceil(defensiveCooldown[jammer] - timer.getTime())
        trigger.action.outTextForGroup(_groupID, "Jammer " .. jammer .. " defensive pod in cooldown for " .. time_left .. "s", 10)
        return
    end
    switch[jammer] = true
    defensiveTimer[jammer] = 0
    updateMenu(jammer)
end
function stopDjamming(jammer)
    local unit = Unit.getByName(jammer)
    if not unit or not unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: stopDjamming failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    switch[jammer] = nil
    updateMenu(jammer)
end
function assignPodType(jammer)
    local _unit = Unit.getByName(jammer)
    if not _unit or not _unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: assignPodType failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    local aircraft_type = _unit:getTypeName()
    local _group = _unit:getGroup()
    if not _group then
        -- env.info("EW-SIGINT Script 2.35.08: assignPodType failed for " .. jammer .. ": Group not found") -- Commented
        return
    end
    local groupNameLower = string.lower(_group:getName())
    local hasEW = string.find(groupNameLower, "ew") ~= nil
    local pods = AIRCRAFT_PODS[aircraft_type]
    local pod_type
    if pods then
        if table.contains(always_assign_types, aircraft_type) or hasEW then
            pod_type = pods[1]
        else
            return
        end
    else
        if hasEW then
            pod_type = "SIGINT"
        else
            return
        end
    end
    jammerPods[jammer] = pod_type
    heat[jammer] = 0 -- Initialize heat
    effectiveness[jammer] = 100
    jammerModes[jammer] = "barrage"
    defensiveJammerModes[jammer] = "barrage"
    elintCapable[jammer] = hasEW or table.contains(always_assign_types, aircraft_type)
    if elintCapable[jammer] then
        if _unit:getPlayerName() == nil then -- AI
            elintSwitch[jammer] = true
            hasActiveELINT = true
            initRadarListsIfNeeded()
            if POD_TYPES[pod_type].comint_capable then
                comintSwitch[jammer] = true
            end
        else -- Player
            elintSwitch[jammer] = false
            comintSwitch[jammer] = false
        end
    end
    hasEWUnits = true
    initRadarListsIfNeeded() -- Ensure lists if jamming needs them, but since conditional on ELINT, assume jamming doesn't strictly need if ELINT off
    -- env.info("EW-SIGINT Script 2.35.08: Jammer " .. jammer .. " detected as " .. aircraft_type .. ", assigned pod: " .. (pod_type or "none") .. ", ELINT capable: " .. tostring(elintCapable[jammer])) -- Commented
    createmenu(jammer)
end
function EWJamming(jammer)
    local _unit = Unit.getByName(jammer)
    if not _unit or not _unit:isExist() then
        -- env.info("EW-SIGINT Script 2.35.08: EWJamming failed for " .. jammer .. ": Unit not found or does not exist") -- Commented
        return
    end
    timer.scheduleFunction(assignPodType, jammer, timer.getTime() + 3)
end
-- Auto-detect EW units at mission start
function detectEWUnits()
    for coal = 1, 2 do
        local groups = coalition.getGroups(coal)
        for _, group in ipairs(groups) do
            if group:getCategory() == Group.Category.AIRPLANE or group:getCategory() == Group.Category.HELICOPTER then
                local groupNameLower = string.lower(group:getName())
                local hasEW = string.find(groupNameLower, "ew") ~= nil
                for _, unit in ipairs(group:getUnits()) do
                    local unitName = unit:getName()
                    if not initializedUnits[unitName] then
                        local unitType = unit:getTypeName()
                        local isAlways = table.contains(always_assign_types, unitType)
                        if isAlways or hasEW then
                            initializedUnits[unitName] = true
                            EWJamming(unitName)
                            -- env.info("EW-SIGINT Script 2.35.08: Auto-detected EW unit: " .. unitName) -- Commented
                        end
                    end
                end
            end
        end
    end
end
-- Event handler for slot changes, births, and losses (added radar add/remove)
local EWHandler = {}
function EWHandler:onEvent(event)
    if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT and event.initiator then
        local jammer = event.initiator:getName()
        if not initializedUnits[jammer] then
            local unit = event.initiator
            local unitType = unit:getTypeName()
            local group = unit:getGroup()
            local groupNameLower = group and string.lower(group:getName()) or ""
            local hasEW = string.find(groupNameLower, "ew") ~= nil
            local isAlways = table.contains(always_assign_types, unitType)
            if isAlways or hasEW then
                initializedUnits[jammer] = true
                timer.scheduleFunction(assignPodType, jammer, timer.getTime() + 3)
            end
        end
    elseif event.id == world.event.S_EVENT_BIRTH and event.initiator then
        local unit = event.initiator
        local unitName = unit:getName()
        local coal = unit:getCoalition()
        if unit:hasSensors(Unit.SensorType.RADAR) and (unit:hasSensors(Unit.SensorType.RADAR, Unit.RadarType.AS) or unit:hasAttribute("SAM SR") or unit:hasAttribute("EWR") or unit:hasAttribute("SAM TR") or unit:hasAttribute("Armed ships") ) then
            addRadar(unitName, coal)
        end
        if not initializedUnits[unitName] then
            local unitType = unit:getTypeName()
            local group = unit:getGroup()
            local groupNameLower = group and string.lower(group:getName()) or ""
            local hasEW = string.find(groupNameLower, "ew") ~= nil
            local isAlways = table.contains(always_assign_types, unitType)
            if isAlways or hasEW then
                initializedUnits[unitName] = true
                timer.scheduleFunction(assignPodType, unitName, timer.getTime() + 3)
            end
        end
    elseif event.id == world.event.S_EVENT_UNIT_LOST and event.initiator then
        local unitName = event.initiator:getName()
        if initializedUnits[unitName] then
            cleanupJammer(unitName)
        end
        removeRadar(unitName) -- Remove if it was a radar
    elseif event.id == world.event.S_EVENT_DEAD and event.initiator then
        local unitName = event.initiator:getName()
        removeRadar(unitName) -- Handle dead radars
    end
end
world.addEventHandler(EWHandler)
-- Initialize radarLists with periodic refresh (initial after 10s, then every 120s), detect EW units, and start heat/timing updates
timer.scheduleFunction(detectEWUnits, {}, timer.getTime() + 3)
timer.scheduleFunction(updateHeatAndTimers, {}, timer.getTime() + 10)
timer.scheduleFunction(scanForELINT, {}, timer.getTime() + 10)
timer.scheduleFunction(scanForCOMINT, {}, timer.getTime() + 10)
timer.scheduleFunction(updateRWRTuning, {}, timer.getTime() + 10) -- New: Start RWR tuning timer
-- End of script