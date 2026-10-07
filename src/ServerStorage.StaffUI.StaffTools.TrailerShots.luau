--!strict
-- TrailerShots -- the beta trailer reel CinematicCamera plays (Home, or Admin > Tools > Trailer)
-- and the build spots for the gameplay shots. Authored live against the hand-built Scattered Isles
-- city (2026-10-01). Sorted by time of day so most cuts need no long sky fade. Shot shape: see
-- CinematicCamera. Generated from the authoring JSON; edit there and regenerate.

return {
	reel = {
		{ name = "01_open_tilt", dur = 9, ease = "inOut", clock = 5.45, keys = { { p = { -2640, 12, -880 }, l = { -2200, 420, -840 }, fov = 42 }, { p = { -2580, 13, -870 }, l = { -1820, 80, -760 }, fov = 40 } } },
		{ name = "27_outro_dawn", dur = 10, clock = 5.6, keys = { { p = { -2700, 30, -1000 }, l = { -1850, 70, -760 }, fov = 40 }, { p = { -2660, 32, -980 }, l = { -1850, 70, -760 }, fov = 38 } } },
		{ name = "02_tower_slide", dur = 7, clock = 5.85, keys = { { p = { -1975, 62, -900 }, l = { -1840, 70, -880 }, fov = 48 }, { p = { -1975, 66, -640 }, l = { -1840, 74, -620 }, fov = 48 } }, cars = 20 },
		{ name = "03_tower_rise", dur = 7, ease = "out", clock = 6.0, keys = { { p = { -1795, 38, -875 }, l = { -1690, 70, -850 }, fov = 50 }, { p = { -1800, 195, -905 }, l = { -1250, 40, -820 }, fov = 50 } }, cars = 20 },
		{ name = "04_chant_sunrise", dur = 10, clock = 6.12, keys = { { p = { -2830, 12, -610 }, l = { -2380, 52, -400 }, fov = 34 }, { p = { -2775, 13, -585 }, l = { -2380, 52, -400 }, fov = 32 } } },
		{ name = "07_morning_street", dur = 7, clock = 7.4, keys = { { p = { -2330, 14, 800 }, l = { -2440, 12, 770 }, fov = 50 }, { p = { -2420, 16, 846 }, l = { -2530, 14, 820 }, fov = 50 } }, cars = 30 },
		{ name = "08_wind_static", dur = 7, clock = 8.0, keys = { { p = { -2462, 58, -276 }, l = { -2492, 62, -400 }, fov = 55 }, { p = { -2466, 58, -288 }, l = { -2496, 62, -410 }, fov = 55 } } },
		{ name = "05_islands_top", dur = 7, clock = 9, keys = { { p = { -2250, 1900, -600 }, l = { -2050, 0, -150 }, fov = 55 }, { p = { -1950, 1800, -550 }, l = { -1850, 0, -100 }, fov = 55 } } },
		{ name = "06_scattered", dur = 7, clock = 9.3, keys = { { p = { -1650, 700, 950 }, l = { -1850, 0, -900 }, fov = 50 }, { p = { -1780, 640, 650 }, l = { -1900, 0, -1000 }, fov = 50 } } },
		{ name = "19_rotor_spin", dur = 7, clock = 10, follow = { tag = "WindTurbineRotor", near = { -2476, 52, -300 } }, keys = { { p = { 7, -5, -18 }, l = { -3, 12, 40 }, fov = 60 }, { p = { 10, -6, -34 }, l = { -3, 12, 40 }, fov = 60 } } },
		{ name = "20_rotor_back", dur = 7, clock = 10, follow = { tag = "WindTurbineRotor", near = { -2476, 52, -300 } }, keys = { { p = { 4, 5, 13 }, l = { -5, -3, -80 }, fov = 60 }, { p = { 5, 7, 22 }, l = { -5, -3, -80 }, fov = 60 } } },
		{ name = "09_downtown_glide", dur = 7, clock = 10.5, keys = { { p = { -1800, 178, -280 }, l = { -1820, 60, -1150 }, fov = 50 }, { p = { -1805, 178, -640 }, l = { -1840, 40, -1550 }, fov = 50 } }, haze = { 0.24, 1.0 }, cars = 30 },
		{ name = "28_logo_pan", dur = 10, clock = 10.5, keys = { { p = { -2950, 520, -1350 }, l = { -1800, 0, -400 }, fov = 55 }, { p = { -2880, 500, -1290 }, l = { -1780, 0, -380 }, fov = 55 } } },
		{ name = "10_coast_bridge", dur = 7, clock = 11, keys = { { p = { -2520, 220, -1080 }, l = { -2150, 0, -1150 }, fov = 50 }, { p = { -2470, 200, -1260 }, l = { -2120, 0, -1250 }, fov = 50 } }, cars = 25 },
		{ name = "11_build_huge", dur = 7, clock = 11.5, keys = { { p = { -1100, 460, -100 }, l = { -1760, 40, -560 }, fov = 50 }, { p = { -1160, 420, -360 }, l = { -1780, 40, -680 }, fov = 50 } }, haze = { 0.24, 1.1 } },
		{ name = "29_bus_follow", dur = 7, clock = 12, follow = { folder = "Buses", near = { -1800, 20, 0 } }, keys = { { p = { 6, 16, 38 }, l = { 0, 4, -40 }, fov = 55 }, { p = { -6, 14, 30 }, l = { 0, 4, -40 }, fov = 55 } } },
		{ name = "12_junction_top", dur = 7, clock = 13, keys = { { p = { -1762, 150, 40 }, l = { -1761, 0, 41 }, fov = 50 }, { p = { -1734, 135, 64 }, l = { -1733, 0, 65 }, fov = 50 } }, cars = 40 },
		{ name = "13_junction_34", dur = 7, clock = 13, keys = { { p = { -1700, 50, 122 }, l = { -1760, 22, 40 }, fov = 50 }, { p = { -1688, 46, 98 }, l = { -1755, 22, 38 }, fov = 50 } }, cars = 40 },
		{ name = "15_industry", dur = 7, clock = 14, keys = { { p = { -1050, 130, 480 }, l = { -1500, 20, 150 }, fov = 50 }, { p = { -1340, 115, 400 }, l = { -1700, 20, 100 }, fov = 50 } }, cars = 30 },
		{ name = "16_highway", dur = 7, clock = 15, keys = { { p = { -1520, 62, 425 }, l = { -1460, 25, 497 }, fov = 50 }, { p = { -1270, 60, 432 }, l = { -1210, 25, 505 }, fov = 50 } }, cars = 40 },
		{ name = "22_golden_towers", dur = 7, clock = 17.45, keys = { { p = { -2360, 250, -480 }, l = { -1800, 60, -650 }, fov = 50 }, { p = { -2310, 240, -760 }, l = { -1790, 60, -760 }, fov = 50 } }, haze = { 0.24, 1.0 }, cars = 25 },
		{ name = "21_golden_slide", dur = 7, clock = 17.55, keys = { { p = { -2380, 70, -560 }, l = { -1900, 90, -620 }, fov = 40 }, { p = { -2370, 75, -800 }, l = { -1890, 90, -860 }, fov = 40 } }, haze = { 0.22, 1.0 }, cars = 20 },
		{ name = "17_dusk_timelapse", dur = 9, clock = 17.7, keys = { { p = { -1500, 300, 200 }, l = { -1850, 50, -800 }, fov = 50 }, { p = { -1560, 285, 140 }, l = { -1880, 50, -850 }, fov = 50 } }, haze = { 0.3, 1.4 } },
		{ name = "26_sunset_sea", dur = 8, clock = 17.85, keys = { { p = { -1000, 16, -620 }, l = { -1750, 80, -650 }, fov = 38 }, { p = { -1040, 17, -660 }, l = { -1750, 80, -680 }, fov = 38 } } },
	},
	spots = {
		{ name = "West plain by the commercial strip", p = { -3500, 140, 430 }, l = { -3608, 6, 316 }, cars = 20 },
		{ name = "West end off the highway", p = { -3530, 140, 110 }, l = { -3640, 7, -4 }, cars = 20 },
		{ name = "Between the wind farm and the suburbs", p = { -2410, 140, 270 }, l = { -2520, 5, 156 }, cars = 20 },
	},
}
