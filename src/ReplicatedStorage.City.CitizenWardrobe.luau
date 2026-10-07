--!strict
-- CitizenWardrobe
-- What citizens wear: free Roblox catalog items (price 0). Clothing is all made by Roblox;
-- hair is Roblox's free classics plus popular free creator hair. Rigid accessories only:
-- layered (WrapLayer) hair does not fit an R6 head. Data only. The items themselves are baked into
-- ReplicatedStorage.CitizenAvatars: Shirts/<id> and Pants/<id> hold the clothing, and one R6
-- rig per hair entry is named Hair_<id>. Each colour is the item's average on its catalog
-- render; the plain far body wears it, so the swap to the real avatar keeps the colours.

export type Shirt = { id: number, name: string, torso: Color3, arms: Color3 }
export type Pants = { id: number, name: string, legs: Color3 }
-- `hat`: the item is a hat (HatAccessory), not hair. `long`: the far body shows long hair.
export type Hair = { id: number, name: string, color: Color3, long: boolean, hat: boolean }

local shirts: { Shirt } = {
	table.freeze({ id = 144076358, name = "Blue and Black Motorcycle Shirt", torso = Color3.fromRGB(38, 50, 58), arms = Color3.fromRGB(55, 55, 54) }),
	table.freeze({ id = 607785314, name = "ROBLOX Jacket", torso = Color3.fromRGB(44, 44, 43), arms = Color3.fromRGB(31, 31, 31) }),
	table.freeze({ id = 398633584, name = "Denim Jacket with White Hoodie", torso = Color3.fromRGB(147, 158, 168), arms = Color3.fromRGB(117, 145, 168) }),
	table.freeze({ id = 144076436, name = "Grey Striped Shirt with Denim Jacket", torso = Color3.fromRGB(75, 94, 102), arms = Color3.fromRGB(20, 60, 80) }),
	table.freeze({ id = 398634295, name = "Pastel Starburst Top with Gray Jacket", torso = Color3.fromRGB(133, 139, 140), arms = Color3.fromRGB(122, 123, 131) }),
	table.freeze({ id = 3670737444, name = "Roblox Shirt - Simple Pattern", torso = Color3.fromRGB(27, 27, 27), arms = Color3.fromRGB(58, 57, 57) }),
	table.freeze({ id = 382538059, name = "Green Jersey", torso = Color3.fromRGB(64, 85, 69), arms = Color3.fromRGB(63, 84, 67) }),
	table.freeze({ id = 398635081, name = "Blue Plaid Shirt", torso = Color3.fromRGB(61, 93, 132), arms = Color3.fromRGB(100, 104, 137) }),
	table.freeze({ id = 382537702, name = "Teal Shirt", torso = Color3.fromRGB(70, 162, 142), arms = Color3.fromRGB(42, 175, 142) }),
	table.freeze({ id = 382537085, name = "I <3 Pizza Shirt", torso = Color3.fromRGB(85, 90, 93), arms = Color3.fromRGB(49, 65, 82) }),
	table.freeze({ id = 382538295, name = "Guitar Tee with Black Jacket", torso = Color3.fromRGB(56, 65, 66), arms = Color3.fromRGB(35, 35, 35) }),
	table.freeze({ id = 4047884939, name = "My Favorite Pizza Shirt", torso = Color3.fromRGB(89, 102, 106), arms = Color3.fromRGB(67, 93, 114) }),
	table.freeze({ id = 4047884046, name = "Guitar Tee with Black Jacket", torso = Color3.fromRGB(80, 97, 100), arms = Color3.fromRGB(68, 68, 67) }),
	table.freeze({ id = 4047886060, name = "Purple and Teal Top", torso = Color3.fromRGB(63, 171, 151), arms = Color3.fromRGB(40, 181, 149) }),
}
local pants: { Pants } = {
	table.freeze({ id = 144076760, name = "Dark Green Jeans", legs = Color3.fromRGB(36, 42, 39) }),
	table.freeze({ id = 398634487, name = "Beautiful You Jeans", legs = Color3.fromRGB(80, 87, 96) }),
	table.freeze({ id = 398633812, name = "Black Jeans with White Shoes", legs = Color3.fromRGB(73, 73, 73) }),
	table.freeze({ id = 398635338, name = "Ripped Skater Pants", legs = Color3.fromRGB(31, 67, 67) }),
	table.freeze({ id = 382537806, name = "Jean Shorts", legs = Color3.fromRGB(107, 115, 123) }),
	table.freeze({ id = 382538503, name = "Black Jeans with Sneakers", legs = Color3.fromRGB(43, 45, 44) }),
	table.freeze({ id = 382537569, name = "Black Jeans", legs = Color3.fromRGB(59, 56, 52) }),
	table.freeze({ id = 382537950, name = "Jean Shorts with White Shoes", legs = Color3.fromRGB(94, 95, 100) }),
}
local femaleHair: { Hair } = {
	table.freeze({ id = 2956239660, name = "Belle Of Belfast Long Red Hair", color = Color3.fromRGB(161, 51, 27), long = true, hat = false }),
	table.freeze({ id = 376527350, name = "Black Ponytail", color = Color3.fromRGB(33, 33, 40), long = true, hat = false }),
	table.freeze({ id = 376526888, name = "Straight Blonde Hair", color = Color3.fromRGB(135, 111, 47), long = true, hat = false }),
	table.freeze({ id = 451220849, name = "Lavender Updo", color = Color3.fromRGB(183, 126, 180), long = false, hat = false }),
	table.freeze({ id = 1772336109, name = "Down to Earth Hair", color = Color3.fromRGB(72, 33, 24), long = false, hat = true }),
	table.freeze({ id = 1103003368, name = "Orange Beanie with Black Hair", color = Color3.fromRGB(59, 35, 28), long = false, hat = false }),
	table.freeze({ id = 3814476174, name = "Colorful Braids", color = Color3.fromRGB(60, 53, 45), long = false, hat = false }),
	table.freeze({ id = 120318231228497, name = "Brown Straight Long Hair", color = Color3.fromRGB(67, 51, 47), long = true, hat = false }),
	table.freeze({ id = 94899731718061, name = "Red Straight Long Hair", color = Color3.fromRGB(62, 7, 7), long = true, hat = false }),
	table.freeze({ id = 107162439448663, name = "Brown Straight Hair", color = Color3.fromRGB(67, 51, 47), long = true, hat = false }),
	table.freeze({ id = 75431530846477, name = "Black Messy Bun Hair", color = Color3.fromRGB(24, 24, 24), long = false, hat = false }),
	table.freeze({ id = 135638960503403, name = "Blonde Wavy Hair", color = Color3.fromRGB(108, 100, 96), long = true, hat = false }),
	table.freeze({ id = 84249053315576, name = "Kawaii Cute Long Hair Sweet Brown", color = Color3.fromRGB(75, 68, 63), long = true, hat = false }),
	table.freeze({ id = 15698078706, name = "Lush Long Wavy Hair with Beanie (Blonde)", color = Color3.fromRGB(173, 148, 131), long = true, hat = false }),
	table.freeze({ id = 79080950315874, name = "Long Wavy Hair w/ Clip (Honey/Dirty Blonde)", color = Color3.fromRGB(109, 89, 70), long = true, hat = false }),
	table.freeze({ id = 116445811685933, name = "Orange Wispy Messy Short Bob", color = Color3.fromRGB(217, 113, 39), long = false, hat = false }),
	table.freeze({ id = 140532173811651, name = "Short Bob with Bangs (Black)", color = Color3.fromRGB(40, 37, 41), long = false, hat = false }),
}
local maleHair: { Hair } = {
	table.freeze({ id = 1772336109, name = "Down to Earth Hair", color = Color3.fromRGB(72, 33, 24), long = false, hat = true }),
	table.freeze({ id = 1103003368, name = "Orange Beanie with Black Hair", color = Color3.fromRGB(59, 35, 28), long = false, hat = false }),
	table.freeze({ id = 376524487, name = "Blonde Spiked Hair", color = Color3.fromRGB(123, 92, 18), long = false, hat = false }),
	table.freeze({ id = 376548738, name = "Brown Charmer Hair", color = Color3.fromRGB(54, 28, 17), long = false, hat = false }),
	table.freeze({ id = 62234425, name = "Brown Hair", color = Color3.fromRGB(64, 52, 37), long = false, hat = false }),
	table.freeze({ id = 63690008, name = "Pal Hair", color = Color3.fromRGB(89, 50, 13), long = false, hat = false }),
	table.freeze({ id = 451221329, name = "True Blue Hair", color = Color3.fromRGB(28, 36, 84), long = false, hat = false }),
	table.freeze({ id = 607702162, name = "Roblox Baseball Cap", color = Color3.fromRGB(42, 42, 42), long = false, hat = true }),
	table.freeze({ id = 417457461, name = "ROBLOX 'R' Baseball Cap", color = Color3.fromRGB(93, 41, 38), long = false, hat = true }),
	table.freeze({ id = 48474313, name = "Red Roblox Cap", color = Color3.fromRGB(100, 51, 43), long = false, hat = true }),
	table.freeze({ id = 3403874988, name = "The Encierro Cap", color = Color3.fromRGB(131, 39, 39), long = false, hat = true }),
	table.freeze({ id = 107573464938767, name = "Blonde Messy Hair", color = Color3.fromRGB(162, 151, 126), long = false, hat = false }),
	table.freeze({ id = 122614899184757, name = "Black Messy Hair", color = Color3.fromRGB(7, 7, 7), long = false, hat = false }),
	table.freeze({ id = 94988620373291, name = "Brown Messy Hair", color = Color3.fromRGB(63, 45, 37), long = false, hat = false }),
	table.freeze({ id = 17791808881, name = "Swept Hair (Dark)", color = Color3.fromRGB(24, 24, 24), long = false, hat = false }),
	table.freeze({ id = 96452862500490, name = "Messy Boy Hair w Backwards Cap", color = Color3.fromRGB(31, 31, 31), long = false, hat = false }),
}

return table.freeze({
	shirts = table.freeze(shirts),
	pants = table.freeze(pants),
	femaleHair = table.freeze(femaleHair),
	maleHair = table.freeze(maleHair),
})
