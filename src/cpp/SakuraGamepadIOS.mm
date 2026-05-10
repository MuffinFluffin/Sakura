// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include "SakuraGamepadIOS.h"

#include <atomic>
#include <cmath>

static std::atomic<double> s_pauseButtonDownUntil{0.0};
static std::atomic<bool> s_suppressPhysicalPadToGame{false};
static std::atomic<uint32_t> s_hostButtonBits[2]{};
static std::atomic<float> s_hostAxis[2][6]{};

// PS1 has two ports. each assigned controller is held as a raw ObjC pointer,
// atomic for lockless reads from the gamepad pump on main. swift keeps the
// controller alive in liveByPort so the raw pointer stays valid until
// ClearController fires on disconnect or reassign.
static std::atomic<uintptr_t> s_portController[2]{};

void SakuraGamepadIOS_SetControllerPort(void* gcControllerPtr, int port)
{
    if (!gcControllerPtr) return;
    if (port < 0 || port > 1) return;
    const uintptr_t p = (uintptr_t)gcControllerPtr;
    // If this controller currently sits on the other port, clear it there.
    const int other = port ^ 1;
    uintptr_t cur = s_portController[other].load(std::memory_order_relaxed);
    if (cur == p) {
        s_portController[other].store(0, std::memory_order_relaxed);
    }
    s_portController[port].store(p, std::memory_order_release);
}

void SakuraGamepadIOS_ClearController(void* gcControllerPtr)
{
    if (!gcControllerPtr) return;
    const uintptr_t p = (uintptr_t)gcControllerPtr;
    for (int i = 0; i < 2; i++) {
        uintptr_t cur = s_portController[i].load(std::memory_order_relaxed);
        if (cur == p) s_portController[i].store(0, std::memory_order_release);
    }
}

int SakuraGamepadIOS_PortForController(void* gcControllerPtr)
{
    if (!gcControllerPtr) return -1;
    const uintptr_t p = (uintptr_t)gcControllerPtr;
    for (int i = 0; i < 2; i++) {
        if (s_portController[i].load(std::memory_order_acquire) == p) return i;
    }
    return -1;
}

bool SakuraGamepadIOS_PortOccupied(int port)
{
    if (port < 0 || port > 1) return false;
    return s_portController[port].load(std::memory_order_acquire) != 0;
}

static double Sakura_NowSeconds(void)
{
	return [[NSDate date] timeIntervalSinceReferenceDate];
}

static BOOL Sakura_IsLikelyVirtualGameController(GCController* c)
{
	if (!c)
		return YES;
	NSString* cls = NSStringFromClass([c class]);
	return [cls rangeOfString:@"Virtual"].location != NSNotFound;
}

static void Sakura_MarkPauseButtonPressed(void)
{
	s_pauseButtonDownUntil.store(Sakura_NowSeconds() + 0.25, std::memory_order_relaxed);
}

static BOOL Sakura_PauseButtonPressed(void)
{
	return s_pauseButtonDownUntil.load(std::memory_order_relaxed) > Sakura_NowSeconds();
}

static void Sakura_InstallPauseMenuHandlerOnButton(GCControllerButtonInput *b)
{
	if (!b)
		return;
	b.preferredSystemGestureState = GCSystemGestureStateDisabled;
	b.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
		(void)button;
		(void)value;
		if (pressed)
			Sakura_MarkPauseButtonPressed();
	};
}

static void Sakura_InstallPauseHandler(GCController* c)
{
	BOOL installedMenuHandler = NO;
	if (@available(iOS 14.0, *))
	{
		// disabled (not AlwaysReceive) so iOS does not act on start/select while
		// the game runs, otherwise menu/options can race a system gesture and
		// the game drops frames of input.
		if (GCExtendedGamepad* gp = c.extendedGamepad)
		{
			gp.buttonMenu.preferredSystemGestureState = GCSystemGestureStateDisabled;
			if (gp.buttonOptions)
				gp.buttonOptions.preferredSystemGestureState = GCSystemGestureStateDisabled;
		}
		if (GCMicroGamepad* gp = c.microGamepad)
			gp.buttonMenu.preferredSystemGestureState = GCSystemGestureStateDisabled;
		// Also tag the Share/Create button (PS5/PS4/Xbox Series) so we can
		// fall back to it for Select on controllers without buttonOptions.
		GCControllerButtonInput* share = c.physicalInputProfile.buttons[@"Button Share"];
		if (share)
			share.preferredSystemGestureState = GCSystemGestureStateDisabled;

		GCControllerButtonInput *menu = c.physicalInputProfile.buttons[GCInputButtonMenu];
		if (!menu && c.extendedGamepad)
			menu = c.extendedGamepad.buttonMenu;
		if (!menu && c.microGamepad)
			menu = c.microGamepad.buttonMenu;
		if (menu) {
			Sakura_InstallPauseMenuHandlerOnButton(menu);
			installedMenuHandler = YES;
		}
	}
	if (installedMenuHandler)
		return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	c.controllerPausedHandler = ^(GCController* controller) {
		(void)controller;
		Sakura_MarkPauseButtonPressed();
	};
#pragma clang diagnostic pop
}

static BOOL Sakura_HasAnyExtendedGamepad(NSArray<GCController*>* controllers)
{
	for (GCController* c in controllers)
		if (!Sakura_IsLikelyVirtualGameController(c) && c.extendedGamepad)
			return YES;
	return NO;
}

static float Sakura_ExtendedAxisValue(GCExtendedGamepad* gp, int sdlAxisIndex)
{
	if (!gp)
		return 0.f;
	switch (sdlAxisIndex)
	{
		case 0:
			return (float)gp.leftThumbstick.xAxis.value;
		case 1:
			return (float)-gp.leftThumbstick.yAxis.value;
		case 2:
			return (float)gp.rightThumbstick.xAxis.value;
		case 3:
			return (float)-gp.rightThumbstick.yAxis.value;
		case 4:
			return (float)gp.leftTrigger.value;
		case 5:
			return (float)gp.rightTrigger.value;
		default:
			return 0.f;
	}
}

void SakuraGamepadIOS_Start(void)
{
	for (GCController* c in [GCController controllers])
	{
		if (Sakura_IsLikelyVirtualGameController(c))
			continue;
		Sakura_InstallPauseHandler(c);
	}

	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
		                                                  object:nil
		                                                   queue:[NSOperationQueue mainQueue]
			                                              usingBlock:^(NSNotification* note) {
			                                              GCController* c = (GCController*)note.object;
			                                              if (c && !Sakura_IsLikelyVirtualGameController(c))
				                                              Sakura_InstallPauseHandler(c);
		                                              }];
	});

	[GCController startWirelessControllerDiscoveryWithCompletionHandler:^{
	}];
}

static GCControllerButtonInput* Sakura_ShareButton(GCExtendedGamepad* gp)
{
	if (!gp)
		return nil;
	GCController* c = gp.controller;
	if (!c)
		return nil;
	return c.physicalInputProfile.buttons[@"Button Share"];
}

static BOOL Sakura_ButtonOnExtended(GCExtendedGamepad* gp, int sdlBtn)
{
	if (!gp)
		return NO;
	switch (sdlBtn)
	{
		case SakuraGamepad::BUTTON_SOUTH:
			return gp.buttonA.isPressed;
		case SakuraGamepad::BUTTON_EAST:
			return gp.buttonB.isPressed;
		case SakuraGamepad::BUTTON_WEST:
			return gp.buttonX.isPressed;
		case SakuraGamepad::BUTTON_NORTH:
			return gp.buttonY.isPressed;
		case SakuraGamepad::BUTTON_BACK:
		{
			// most controllers expose select as buttonOptions, but PS5/PS4/Xbox
			// series also surface a share/create button via physicalInputProfile.
			// fall back to that when buttonOptions is nil.
			if (gp.buttonOptions && gp.buttonOptions.isPressed)
				return YES;
			GCControllerButtonInput* share = Sakura_ShareButton(gp);
			return (share && share.isPressed) ? YES : NO;
		}
		case SakuraGamepad::BUTTON_GUIDE:
			if (@available(iOS 14.0, *))
				return gp.buttonHome.isPressed;
			return NO;
		case SakuraGamepad::BUTTON_START:
			return gp.buttonMenu.isPressed || Sakura_PauseButtonPressed();
		case SakuraGamepad::BUTTON_LEFT_STICK:
			return gp.leftThumbstickButton.isPressed;
		case SakuraGamepad::BUTTON_RIGHT_STICK:
			return gp.rightThumbstickButton.isPressed;
		case SakuraGamepad::BUTTON_LEFT_SHOULDER:
			return gp.leftShoulder.isPressed;
		case SakuraGamepad::BUTTON_RIGHT_SHOULDER:
			return gp.rightShoulder.isPressed;
		case SakuraGamepad::BUTTON_DPAD_UP:
			return gp.dpad.up.isPressed;
		case SakuraGamepad::BUTTON_DPAD_DOWN:
			return gp.dpad.down.isPressed;
		case SakuraGamepad::BUTTON_DPAD_LEFT:
			return gp.dpad.left.isPressed;
		case SakuraGamepad::BUTTON_DPAD_RIGHT:
			return gp.dpad.right.isPressed;
		default:
			return NO;
	}
}

static BOOL Sakura_ButtonOnMicro(GCMicroGamepad* gp, int sdlBtn)
{
	if (!gp)
		return NO;
	switch (sdlBtn)
	{
		case SakuraGamepad::BUTTON_SOUTH:
			return gp.buttonA.isPressed;
		case SakuraGamepad::BUTTON_BACK:
			return gp.buttonX.isPressed;
		case SakuraGamepad::BUTTON_START:
			return gp.buttonMenu.isPressed;
		case SakuraGamepad::BUTTON_DPAD_UP:
			return gp.dpad.up.isPressed;
		case SakuraGamepad::BUTTON_DPAD_DOWN:
			return gp.dpad.down.isPressed;
		case SakuraGamepad::BUTTON_DPAD_LEFT:
			return gp.dpad.left.isPressed;
		case SakuraGamepad::BUTTON_DPAD_RIGHT:
			return gp.dpad.right.isPressed;
		default:
			return NO;
	}
}

void SakuraGamepadIOS_RefreshMainThreadCachedInput(void)
{
	@autoreleasepool {
		uint32_t mask[2] = {0, 0};
		float axes[2][6] = {};

		NSArray<GCController*>* controllers = [GCController controllers];
		for (GCController* c in controllers)
		{
			if (Sakura_IsLikelyVirtualGameController(c))
				continue;
			int port = SakuraGamepadIOS_PortForController((__bridge void*)c);
			if (port < 0 || port > 1)
				continue;

			if (GCExtendedGamepad* ex = c.extendedGamepad)
			{
				for (int b = 0; b < SakuraGamepad::BUTTON_COUNT; b++)
				{
					if (Sakura_ButtonOnExtended(ex, b))
						mask[port] |= (1u << b);
				}
				for (int ax = 0; ax < 6; ax++)
				{
					float v = Sakura_ExtendedAxisValue(ex, ax);
					if (fabsf(v) > fabsf(axes[port][ax]))
						axes[port][ax] = v;
				}
			}
			else if (GCMicroGamepad* micro = c.microGamepad)
			{
				for (int b = 0; b < SakuraGamepad::BUTTON_COUNT; b++)
				{
					if (Sakura_ButtonOnMicro(micro, b))
						mask[port] |= (1u << b);
				}
				float dx = (float)micro.dpad.xAxis.value;
				if (fabsf(dx) > fabsf(axes[port][0])) axes[port][0] = dx;
				float dy = (float)-micro.dpad.yAxis.value;
				if (fabsf(dy) > fabsf(axes[port][1])) axes[port][1] = dy;
			}
		}

		for (int p = 0; p < 2; p++)
		{
			s_hostButtonBits[p].store(mask[p], std::memory_order_relaxed);
			for (int ax = 0; ax < 6; ax++)
				s_hostAxis[p][ax].store(axes[p][ax], std::memory_order_relaxed);
		}
	}
}

bool SakuraGamepadIOS_ButtonPressed(int sdlCompatibleButton) { return SakuraGamepadIOS_ButtonPressedForPort(0, sdlCompatibleButton); }
bool SakuraGamepadIOS_ButtonPressedForPort(int port, int sdlCompatibleButton)
{
	if (port < 0 || port > 1) return false;
	if (sdlCompatibleButton < 0 || sdlCompatibleButton >= SakuraGamepad::BUTTON_COUNT)
		return false;
	const uint32_t bits = s_hostButtonBits[port].load(std::memory_order_relaxed);
	return (bits & (1u << sdlCompatibleButton)) != 0;
}

float SakuraGamepadIOS_Axis(int sdlAxisIndex) { return SakuraGamepadIOS_AxisForPort(0, sdlAxisIndex); }
float SakuraGamepadIOS_AxisForPort(int port, int sdlAxisIndex)
{
	if (port < 0 || port > 1) return 0.f;
	if (sdlAxisIndex < 0 || sdlAxisIndex > 5)
		return 0.f;
	return s_hostAxis[port][sdlAxisIndex].load(std::memory_order_relaxed);
}

void Sakura_SetPhysicalPadToGameSuppressed(bool on)
{
	s_suppressPhysicalPadToGame.store(on, std::memory_order_relaxed);
}

bool Sakura_IsPhysicalPadToGameSuppressed(void)
{
	return s_suppressPhysicalPadToGame.load(std::memory_order_relaxed);
}

void SakuraGamepadIOS_PollCapture(int* outButton)
{
	@autoreleasepool {
		if (!outButton)
			return;
		*outButton = -1;
		NSArray<GCController*>* controllers = [GCController controllers];
		if (Sakura_HasAnyExtendedGamepad(controllers))
		{
			for (GCController* c in controllers)
			{
				if (Sakura_IsLikelyVirtualGameController(c))
					continue;
				GCExtendedGamepad* ex = c.extendedGamepad;
				if (!ex)
					continue;
				for (int b = 0; b < SakuraGamepad::BUTTON_COUNT; b++)
				{
					if (Sakura_ButtonOnExtended(ex, b))
					{
						*outButton = b;
						return;
					}
				}
			}
			return;
		}
		for (GCController* c in controllers)
		{
			if (Sakura_IsLikelyVirtualGameController(c))
				continue;
			GCMicroGamepad* micro = c.microGamepad;
			if (!micro)
				continue;
			for (int b = 0; b < SakuraGamepad::BUTTON_COUNT; b++)
			{
				if (Sakura_ButtonOnMicro(micro, b))
				{
					*outButton = b;
					return;
				}
			}
		}
	}
}
