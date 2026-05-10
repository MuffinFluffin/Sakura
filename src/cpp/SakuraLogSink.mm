#include "SakuraLogSink.h"

#include <mach/mach_time.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>

static std::atomic<uint64_t> g_boot_mono_ns{0};

static mach_timebase_info_data_t Sakura_MakeMachTb()
{
	mach_timebase_info_data_t tb{};
	mach_timebase_info(&tb);
	return tb;
}

static const mach_timebase_info_data_t g_machTb = Sakura_MakeMachTb();

static uint64_t sakura_mono_ns_now(void)
{
	const uint64_t t = mach_absolute_time();
	const uint64_t numer = uint64_t(g_machTb.numer);
	const uint64_t denom = uint64_t(g_machTb.denom ? g_machTb.denom : 1);
	return (t * numer) / denom;
}

namespace {

std::mutex g_logMu;
uint64_t g_boot_ns = 0;
bool g_haveBoot = false;

void Sakura_EnsureBootClock(void)
{
	if (g_haveBoot)
		return;
	const uint64_t n = sakura_mono_ns_now();
	g_boot_ns = n;
	g_haveBoot = true;
	g_boot_mono_ns.store(n, std::memory_order_relaxed);
}

float Sakura_ElapsedSec(void)
{
	Sakura_EnsureBootClock();
	const uint64_t now = sakura_mono_ns_now();
	if (now < g_boot_ns)
		return 0.f;
	const double s = double(now - g_boot_ns) * 1e-9;
	return float(s);
}

void TrimTrailingNewlines(char* s)
{
	size_t n = strlen(s);
	while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r'))
		s[--n] = '\0';
}

const char* RetroLevelWord(int lvl)
{
	switch (lvl)
	{
	case 0: return "Debug";
	case 1: return "Info";
	case 2: return "Warning";
	case 3: return "Error";
	default: return "Info";
	}
}

std::pair<std::string, std::string> InferSubsystem(std::string body)
{
	while (!body.empty() && (body[0] == ' ' || body[0] == '\t'))
		body.erase(0, 1);

	static const struct {
		const char* prefix;
		const char* tag;
	} rules[] = {
		{"Checking if required firmware", "BIOS"},
		{"Override firmware found but has invalid SHA1", "BIOS"},
		{"Override firmware found:", "BIOS"},
		{"Override firmware is missing", "BIOS"},
		{"Override firmware found", "BIOS"},
		{"Firmware path longer than", "BIOS"},
		{"Firmware is missing:", "BIOS"},
		{"Firmware found but has invalid SHA1", "BIOS"},
		{"Firmware found:", "BIOS"},
		{"Unsupported firmware may cause", "BIOS"},
		{"Expected SHA1:", "BIOS"},
		{"Obtained SHA1:", "BIOS"},
		{"Firmware", "BIOS"},
		{"Not ISO-9660", "CD"},
		{"PVD search count limit", "CD"},
		{"Missing Primary Volume Descriptor", "CD"},
		{"Root directory table too large", "CD"},
		{"Monkey Hero FBWrite", "Core"},
		{"Invalid character in GameShark", "Core"},
		{"[Vulkan]", "GPU"},
		{"Vulkan error at", "GPU"},
		{"Vulkan]: Validation", "GPU"},
		{"Vulkan]: Other", "GPU"},
		{"Shader_init()", "GPU"},
		{"Shader compilation failed", "GPU"},
		{"Program_init()", "GPU"},
		{"glCreateProgram()", "GPU"},
		{"Granite", "GPU"},
		{"Render passes:", "GPU"},
		{"Readback:", "GPU"},
		{"Frontend does not support frame duping", "Host"},
		{"Unable to mmap on any base address", "CPU"},
		{"TextStart=0x", "CPU"},
		{"PC=0x", "CPU"},
		{"Failed to dlopen:", "Host"},
		{"Failed to create SHM:", "Host"},
	};

	for (const auto& r : rules)
	{
		const size_t n = strlen(r.prefix);
		if (body.size() >= n && body.compare(0, n, r.prefix) == 0)
		{
			body.erase(0, n);
			while (!body.empty() && (body[0] == ' ' || body[0] == ':' || body[0] == '\t'))
				body.erase(0, 1);
			return {r.tag, std::move(body)};
		}
	}
	return {"Core", std::move(body)};
}

} // namespace

extern "C" double Sakura_LogElapsedSecSignalSafe(void)
{
	const uint64_t b = g_boot_mono_ns.load(std::memory_order_relaxed);
	if (b == 0)
		return 0;
	const uint64_t n = sakura_mono_ns_now();
	if (n < b)
		return 0;
	return double(n - b) * 1e-9;
}

extern "C" void Sakura_LogInit(void)
{
	std::lock_guard<std::mutex> lk(g_logMu);
	Sakura_EnsureBootClock();
}

extern "C" void Sakura_WriteConsoleLine(int retro_log_level, const char* message_utf8)
{
	if (!message_utf8)
		return;
	char buf[16384];
	strncpy(buf, message_utf8, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = '\0';
	TrimTrailingNewlines(buf);

	std::lock_guard<std::mutex> lk(g_logMu);
	Sakura_EnsureBootClock();
	const double t = double(Sakura_ElapsedSec());

	if (strncmp(buf, "Sakura:", 7) == 0)
	{
		fprintf(stderr, "[%10.4f] %s\n", t, buf);
		fflush(stderr);
		return;
	}

	std::pair<std::string, std::string> inferred = InferSubsystem(std::string(buf));
	fprintf(stderr, "[%10.4f] %s:%s:%s\n", t, inferred.first.c_str(), RetroLevelWord(retro_log_level), inferred.second.c_str());
	fflush(stderr);
}

extern "C" void Sakura_LogNativeV(const char* area, const char* level, const char* fmt, va_list ap)
{
	char body[8192];
	vsnprintf(body, sizeof(body), fmt, ap);
	body[sizeof(body) - 1] = '\0';

	std::lock_guard<std::mutex> lk(g_logMu);
	Sakura_EnsureBootClock();
	const double t = double(Sakura_ElapsedSec());
	const char* a = area && area[0] ? area : "Core";
	const char* lv = level && level[0] ? level : "Info";
	fprintf(stderr, "[%10.4f] Sakura:%s:%s:%s\n", t, a, lv, body);
	fflush(stderr);
}

extern "C" void Sakura_LogNative(const char* area, const char* level, const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	Sakura_LogNativeV(area, level, fmt, ap);
	va_end(ap);
}

extern "C" void Sakura_RetroLog(int retro_log_level, const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	char buf[8192];
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	Sakura_WriteConsoleLine(retro_log_level, buf);
}
