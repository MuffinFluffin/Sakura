#import <UIKit/UIKit.h>
#import "SakuraBridge.h"
#import "SakuraPS1Core.h"
#import "SakuraGamepadIOS.h"

void Sakura_IOS_EarlyInit(void);
void Sakura_IOS_OnSceneReady(void);
void Sakura_IOS_SetGameRenderView(void * _Nullable view);
void Sakura_IOS_NotifyDisplayResize(int width, int height, float scale);
void Sakura_IOS_SetScreenIsCaptured(bool captured);
void Sakura_IOS_ConfigureGameAudioSession(double coreSampleRate);
