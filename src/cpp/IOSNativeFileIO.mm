// SPDX-FileCopyrightText: 2026 Sakura
// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>

#include "IOSNativeFileIO.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace IOSNativeFileIO
{
namespace
{
struct NativeFileHandle
{
	int fd = -1;
	bool dirty = false;
	std::string path;
};

static NSString* ToNSString(const char* path)
{
	return [NSString stringWithUTF8String:(path ? path : "")];
}

static NativeFileHandle* ToNativeFileHandle(void* handle)
{
	return static_cast<NativeFileHandle*>(handle);
}

static bool EnsureParentDirectory(NSString* nsPath)
{
	if (nsPath.length == 0)
		return false;

	NSString* directory = [nsPath stringByDeletingLastPathComponent];
	if (directory.length == 0)
		return true;

	NSFileManager* fileManager = [NSFileManager defaultManager];
	if ([fileManager fileExistsAtPath:directory])
		return true;

	NSError* error = nil;
	return [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
}

static int OpenFlagsToPOSIX(unsigned flags)
{
	const bool canRead = (flags & OpenRead) != 0;
	const bool canWrite = (flags & OpenWrite) != 0;
	int posixFlags = canRead && canWrite ? O_RDWR : (canWrite ? O_WRONLY : O_RDONLY);
	if (canWrite)
	{
		posixFlags |= O_CREAT;
		if ((flags & OpenUpdateExisting) == 0)
			posixFlags |= O_TRUNC;
	}
	return posixFlags;
}

static int SeekOriginToPOSIX(int origin)
{
	switch (origin)
	{
		case 1:
			return SEEK_CUR;
		case 2:
			return SEEK_END;
		default:
			return SEEK_SET;
	}
}

static ssize_t RetryPRead(int fd, void* dest, size_t size, off_t offset)
{
	ssize_t ret = 0;
	do
	{
		ret = pread(fd, dest, size, offset);
	} while (ret < 0 && errno == EINTR);
	return ret;
}

static ssize_t RetryPWrite(int fd, const void* src, size_t size, off_t offset)
{
	ssize_t ret = 0;
	do
	{
		ret = pwrite(fd, src, size, offset);
	} while (ret < 0 && errno == EINTR);
	return ret;
}

static ssize_t RetryRead(int fd, void* dest, size_t size)
{
	ssize_t ret = 0;
	do
	{
		ret = read(fd, dest, size);
	} while (ret < 0 && errno == EINTR);
	return ret;
}

static ssize_t RetryWrite(int fd, const void* src, size_t size)
{
	ssize_t ret = 0;
	do
	{
		ret = write(fd, src, size);
	} while (ret < 0 && errno == EINTR);
	return ret;
}
} // namespace

void* OpenFile(const char* path)
{
	return OpenFile(path, OpenRead | OpenWrite | OpenUpdateExisting | OpenFrequentAccess);
}

void* OpenFile(const char* path, unsigned flags)
{
	@autoreleasepool
	{
		NSString* nsPath = ToNSString(path);
		if (nsPath.length == 0)
			return nullptr;
		if ((flags & OpenWrite) != 0 && !EnsureParentDirectory(nsPath))
			return nullptr;

		int fd = -1;
		do
		{
			fd = open(nsPath.fileSystemRepresentation, OpenFlagsToPOSIX(flags), 0644);
		} while (fd < 0 && errno == EINTR);
		if (fd < 0)
			return nullptr;

#ifdef F_RDAHEAD
		if ((flags & OpenFrequentAccess) != 0)
		{
			const int enabled = 1;
			(void)fcntl(fd, F_RDAHEAD, enabled);
		}
#endif
#if defined(POSIX_FADV_SEQUENTIAL)
		if ((flags & OpenFrequentAccess) != 0 && (flags & OpenWrite) == 0)
			(void)posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);
#endif

		NativeFileHandle* handle = new NativeFileHandle();
		handle->fd = fd;
		handle->path = nsPath.fileSystemRepresentation;
		return handle;
	}
}

void CloseFile(void* handle)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle)
		return;

	Flush(handle);
	if (nativeHandle->fd >= 0)
	{
		while (close(nativeHandle->fd) < 0 && errno == EINTR)
		{
		}
	}
	delete nativeHandle;
}

bool EnsureFilePath(const char* path)
{
	@autoreleasepool
	{
		NSString* nsPath = ToNSString(path);
		if (nsPath.length == 0 || !EnsureParentDirectory(nsPath))
			return false;

		int fd = -1;
		do
		{
			fd = open(nsPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
		} while (fd < 0 && errno == EINTR);
		if (fd < 0)
			return false;

		while (close(fd) < 0 && errno == EINTR)
		{
		}
		return true;
	}
}

bool Read(void* handle, std::uint64_t offset, void* dest, std::size_t size, std::size_t* bytesRead)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0 || !dest)
	{
		if (bytesRead)
			*bytesRead = 0;
		return false;
	}

	std::size_t done = 0;
	while (done < size)
	{
		const std::size_t chunk = std::min<std::uint64_t>(size - done, SSIZE_MAX);
		const ssize_t ret = RetryPRead(nativeHandle->fd, static_cast<std::uint8_t*>(dest) + done, chunk,
			static_cast<off_t>(offset + done));
		if (ret < 0)
		{
			if (bytesRead)
				*bytesRead = done;
			return false;
		}
		if (ret == 0)
			break;
		done += static_cast<std::size_t>(ret);
	}

	if (bytesRead)
		*bytesRead = done;
	return true;
}

bool Write(void* handle, std::uint64_t offset, const void* src, std::size_t size)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0 || (!src && size > 0))
		return false;

	std::size_t done = 0;
	while (done < size)
	{
		const std::size_t chunk = std::min<std::uint64_t>(size - done, SSIZE_MAX);
		const ssize_t ret = RetryPWrite(nativeHandle->fd, static_cast<const std::uint8_t*>(src) + done, chunk,
			static_cast<off_t>(offset + done));
		if (ret <= 0)
			return false;
		done += static_cast<std::size_t>(ret);
	}

	nativeHandle->dirty = nativeHandle->dirty || size > 0;
	return true;
}

std::int64_t ReadSequential(void* handle, void* dest, std::uint64_t size)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0 || (!dest && size > 0))
		return -1;

	std::uint64_t done = 0;
	while (done < size)
	{
		const std::size_t chunk = static_cast<std::size_t>(std::min<std::uint64_t>(size - done, SSIZE_MAX));
		const ssize_t ret = RetryRead(nativeHandle->fd, static_cast<std::uint8_t*>(dest) + done, chunk);
		if (ret < 0)
			return done > 0 ? static_cast<std::int64_t>(done) : -1;
		if (ret == 0)
			break;
		done += static_cast<std::uint64_t>(ret);
	}
	return static_cast<std::int64_t>(done);
}

std::int64_t WriteSequential(void* handle, const void* src, std::uint64_t size)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0 || (!src && size > 0))
		return -1;

	std::uint64_t done = 0;
	while (done < size)
	{
		const std::size_t chunk = static_cast<std::size_t>(std::min<std::uint64_t>(size - done, SSIZE_MAX));
		const ssize_t ret = RetryWrite(nativeHandle->fd, static_cast<const std::uint8_t*>(src) + done, chunk);
		if (ret <= 0)
			return done > 0 ? static_cast<std::int64_t>(done) : -1;
		done += static_cast<std::uint64_t>(ret);
	}

	nativeHandle->dirty = nativeHandle->dirty || size > 0;
	return static_cast<std::int64_t>(done);
}

std::int64_t Seek(void* handle, std::int64_t offset, int origin)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0)
		return -1;

	const off_t ret = lseek(nativeHandle->fd, static_cast<off_t>(offset), SeekOriginToPOSIX(origin));
	return ret < 0 ? -1 : static_cast<std::int64_t>(ret);
}

std::int64_t Tell(void* handle)
{
	return Seek(handle, 0, 1);
}

bool PadWithByte(void* handle, std::uint64_t targetOffset, std::uint8_t value)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0)
		return false;

	const std::uint64_t currentSize = GetSize(handle);
	if (currentSize >= targetOffset)
		return true;
	if (value == 0)
		return Truncate(handle, targetOffset);

	std::array<std::uint8_t, 16384> buffer;
	buffer.fill(value);

	std::uint64_t offset = currentSize;
	while (offset < targetOffset)
	{
		const std::size_t chunk = static_cast<std::size_t>(std::min<std::uint64_t>(targetOffset - offset, buffer.size()));
		if (RetryPWrite(nativeHandle->fd, buffer.data(), chunk, static_cast<off_t>(offset)) != static_cast<ssize_t>(chunk))
			return false;
		offset += chunk;
	}

	nativeHandle->dirty = true;
	return true;
}

std::uint64_t GetSize(void* handle)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0)
		return 0;

	struct stat st;
	if (fstat(nativeHandle->fd, &st) != 0)
		return 0;
	return static_cast<std::uint64_t>(std::max<off_t>(0, st.st_size));
}

bool Truncate(void* handle, std::uint64_t size)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0)
		return false;

	if (ftruncate(nativeHandle->fd, static_cast<off_t>(size)) != 0)
		return false;
	nativeHandle->dirty = true;
	return true;
}

bool RemoveFile(const char* path)
{
	if (!path || path[0] == '\0')
		return false;
	return unlink(path) == 0;
}

bool RenameFile(const char* oldPath, const char* newPath)
{
	if (!oldPath || oldPath[0] == '\0' || !newPath || newPath[0] == '\0')
		return false;
	@autoreleasepool
	{
		NSString* nsNewPath = ToNSString(newPath);
		if (!EnsureParentDirectory(nsNewPath))
			return false;
	}
	return rename(oldPath, newPath) == 0;
}

const char* GetPath(void* handle)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	return nativeHandle ? nativeHandle->path.c_str() : "";
}

void Flush(void* handle)
{
	NativeFileHandle* nativeHandle = ToNativeFileHandle(handle);
	if (!nativeHandle || nativeHandle->fd < 0 || !nativeHandle->dirty)
		return;

	while (fsync(nativeHandle->fd) != 0 && errno == EINTR)
	{
	}
	nativeHandle->dirty = false;
}
} // namespace IOSNativeFileIO
