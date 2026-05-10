// SPDX-License-Identifier: GPL-3.0+
#pragma once

#ifdef __cplusplus
#include "SakuraGamepadButtons.h"
extern "C" {
#endif

// call once after UI is up so GameController discovery runs.
void SakuraGamepadIOS_Start(void);

// port assigner bridge. gcControllerPtr is an unretained GCController*.
void SakuraGamepadIOS_SetControllerPort(void* gcControllerPtr, int port);
void SakuraGamepadIOS_ClearController(void* gcControllerPtr);
int  SakuraGamepadIOS_PortForController(void* gcControllerPtr);
bool SakuraGamepadIOS_PortOccupied(int port);

// snapshots MFi/Bluetooth input on the main thread. the core poll reads this cache.
void SakuraGamepadIOS_RefreshMainThreadCachedInput(void);

// sdlCompatibleButton uses SakuraGamepad::BUTTON_* or legacy SDL enum values.
bool SakuraGamepadIOS_ButtonPressed(int sdlCompatibleButton);
bool SakuraGamepadIOS_ButtonPressedForPort(int port, int sdlCompatibleButton);

// SDL axis indices: 0=left X, 1=left Y, 2=right X, 3=right Y, 4=L2, 5=R2. returns -1..1 (triggers 0..1).
float SakuraGamepadIOS_Axis(int sdlAxisIndex);
float SakuraGamepadIOS_AxisForPort(int port, int sdlAxisIndex);

// for settings UI. scans buttons across all controllers, sets outButton to first pressed SAKURA index or -1.
void SakuraGamepadIOS_PollCapture(int* outButton);

// when true, PumpMessagesOnCPUThread skips routing MFi/Bluetooth state into the PS1 pad.
// swift UI can still read SakuraGamepadIOS_ButtonPressed for shortcuts and navigation.
void Sakura_SetPhysicalPadToGameSuppressed(bool on);
bool Sakura_IsPhysicalPadToGameSuppressed(void);

#ifdef __cplusplus
}
#endif
