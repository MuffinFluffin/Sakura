// SPDX-FileCopyrightText: 2026 Sakura
// SPDX-License-Identifier: GPL-3.0+

#pragma once

#include <cstddef>
#include <cstdint>

namespace IOSNativeFileIO
{
enum OpenFlags : unsigned
{
	OpenRead = 1u << 0,
	OpenWrite = 1u << 1,
	OpenUpdateExisting = 1u << 2,
	OpenFrequentAccess = 1u << 3,
};

void* OpenFile(const char* path);
void* OpenFile(const char* path, unsigned flags);
void CloseFile(void* handle);
bool EnsureFilePath(const char* path);
bool Read(void* handle, std::uint64_t offset, void* dest, std::size_t size, std::size_t* bytesRead);
bool Write(void* handle, std::uint64_t offset, const void* src, std::size_t size);
std::int64_t ReadSequential(void* handle, void* dest, std::uint64_t size);
std::int64_t WriteSequential(void* handle, const void* src, std::uint64_t size);
std::int64_t Seek(void* handle, std::int64_t offset, int origin);
std::int64_t Tell(void* handle);
bool PadWithByte(void* handle, std::uint64_t targetOffset, std::uint8_t value);
std::uint64_t GetSize(void* handle);
bool Truncate(void* handle, std::uint64_t size);
bool RemoveFile(const char* path);
bool RenameFile(const char* oldPath, const char* newPath);
const char* GetPath(void* handle);
void Flush(void* handle);
}
