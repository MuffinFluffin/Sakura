#pragma once

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

void Sakura_LogInit(void);
double Sakura_LogElapsedSecSignalSafe(void);
void Sakura_WriteConsoleLine(int retro_log_level, const char* message_utf8);
void Sakura_LogNative(const char* area, const char* level, const char* fmt, ...);
void Sakura_LogNativeV(const char* area, const char* level, const char* fmt, va_list ap);
void Sakura_RetroLog(int retro_log_level, const char* fmt, ...);

#ifdef __cplusplus
}
#endif
