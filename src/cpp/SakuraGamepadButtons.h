// SPDX-License-Identifier: GPL-3.0+
// Numeric gamepad button indices matching SDL3's SDL_GamepadButton (after INVALID = -1).
// Button indices for GameController → Sakura INI mappings.

#pragma once

#include <cstdint>

namespace SakuraGamepad
{
	static constexpr int BUTTON_INVALID = -1;
	static constexpr int BUTTON_SOUTH = 0;
	static constexpr int BUTTON_EAST = 1;
	static constexpr int BUTTON_WEST = 2;
	static constexpr int BUTTON_NORTH = 3;
	static constexpr int BUTTON_BACK = 4;
	static constexpr int BUTTON_GUIDE = 5;
	static constexpr int BUTTON_START = 6;
	static constexpr int BUTTON_LEFT_STICK = 7;
	static constexpr int BUTTON_RIGHT_STICK = 8;
	static constexpr int BUTTON_LEFT_SHOULDER = 9;
	static constexpr int BUTTON_RIGHT_SHOULDER = 10;
	static constexpr int BUTTON_DPAD_UP = 11;
	static constexpr int BUTTON_DPAD_DOWN = 12;
	static constexpr int BUTTON_DPAD_LEFT = 13;
	static constexpr int BUTTON_DPAD_RIGHT = 14;
	// last exclusive index, same cardinality as SDL_GAMEPAD_BUTTON_COUNT.
	static constexpr int BUTTON_COUNT = 26;
} // namespace SakuraGamepad
