#ifndef SAKURA_LIBRETRO_H
#define SAKURA_LIBRETRO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RETRO_API_VERSION 1

#define RETRO_DEVICE_JOYPAD 1
#define RETRO_DEVICE_ANALOG 5

#define RETRO_DEVICE_TYPE_SHIFT 8
#define RETRO_DEVICE_SUBCLASS(base, id) (((unsigned)((id) + 1) << RETRO_DEVICE_TYPE_SHIFT) | (unsigned)(base))
#define RETRO_DEVICE_MASK ((1 << RETRO_DEVICE_TYPE_SHIFT) - 1u)

#define RETRO_DEVICE_PS_DUALSHOCK RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1)

#define RETRO_DEVICE_INDEX_ANALOG_LEFT 0
#define RETRO_DEVICE_INDEX_ANALOG_RIGHT 1
#define RETRO_DEVICE_ID_ANALOG_X 0
#define RETRO_DEVICE_ID_ANALOG_Y 1

#define RETRO_DEVICE_ID_JOYPAD_B 0
#define RETRO_DEVICE_ID_JOYPAD_Y 1
#define RETRO_DEVICE_ID_JOYPAD_SELECT 2
#define RETRO_DEVICE_ID_JOYPAD_START 3
#define RETRO_DEVICE_ID_JOYPAD_UP 4
#define RETRO_DEVICE_ID_JOYPAD_DOWN 5
#define RETRO_DEVICE_ID_JOYPAD_LEFT 6
#define RETRO_DEVICE_ID_JOYPAD_RIGHT 7
#define RETRO_DEVICE_ID_JOYPAD_A 8
#define RETRO_DEVICE_ID_JOYPAD_X 9
#define RETRO_DEVICE_ID_JOYPAD_L 10
#define RETRO_DEVICE_ID_JOYPAD_R 11
#define RETRO_DEVICE_ID_JOYPAD_L2 12
#define RETRO_DEVICE_ID_JOYPAD_R2 13
#define RETRO_DEVICE_ID_JOYPAD_L3 14
#define RETRO_DEVICE_ID_JOYPAD_R3 15
#define RETRO_DEVICE_ID_JOYPAD_MASK 256

#define RETRO_ENVIRONMENT_GET_CAN_DUPE 3
#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS 11
#define RETRO_ENVIRONMENT_GET_VARIABLE 15
#define RETRO_ENVIRONMENT_SET_VARIABLES 16
#define RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE 17
#define RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME 18
#define RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO 32
#define RETRO_ENVIRONMENT_SET_GEOMETRY 37
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31
#define RETRO_ENVIRONMENT_EXPERIMENTAL 0x10000
#define RETRO_ENVIRONMENT_GET_INPUT_BITMASKS (51 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_VFS_INTERFACE (45 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS 44
#define RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE (47 | RETRO_ENVIRONMENT_EXPERIMENTAL)

#define RETRO_VFS_FILE_ACCESS_READ (1 << 0)
#define RETRO_VFS_FILE_ACCESS_WRITE (1 << 1)
#define RETRO_VFS_FILE_ACCESS_READ_WRITE (RETRO_VFS_FILE_ACCESS_READ | RETRO_VFS_FILE_ACCESS_WRITE)
#define RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING (1 << 2)
#define RETRO_VFS_FILE_ACCESS_HINT_NONE 0
#define RETRO_VFS_FILE_ACCESS_HINT_FREQUENT_ACCESS (1 << 0)

#define RETRO_VFS_SEEK_POSITION_START 0
#define RETRO_VFS_SEEK_POSITION_CURRENT 1
#define RETRO_VFS_SEEK_POSITION_END 2

#ifdef __cplusplus
extern "C" {
#endif

typedef bool (*retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

struct retro_vfs_file_handle;

typedef const char *(*retro_vfs_get_path_t)(struct retro_vfs_file_handle *stream);
typedef struct retro_vfs_file_handle *(*retro_vfs_open_t)(const char *path, unsigned mode, unsigned hints);
typedef int (*retro_vfs_close_t)(struct retro_vfs_file_handle *stream);
typedef int64_t (*retro_vfs_size_t)(struct retro_vfs_file_handle *stream);
typedef int64_t (*retro_vfs_truncate_t)(struct retro_vfs_file_handle *stream, int64_t length);
typedef int64_t (*retro_vfs_tell_t)(struct retro_vfs_file_handle *stream);
typedef int64_t (*retro_vfs_seek_t)(struct retro_vfs_file_handle *stream, int64_t offset, int seek_position);
typedef int64_t (*retro_vfs_read_t)(struct retro_vfs_file_handle *stream, void *s, uint64_t len);
typedef int64_t (*retro_vfs_write_t)(struct retro_vfs_file_handle *stream, const void *s, uint64_t len);
typedef int (*retro_vfs_flush_t)(struct retro_vfs_file_handle *stream);
typedef int (*retro_vfs_remove_t)(const char *path);
typedef int (*retro_vfs_rename_t)(const char *old_path, const char *new_path);

struct retro_vfs_interface {
    retro_vfs_get_path_t get_path;
    retro_vfs_open_t open;
    retro_vfs_close_t close;
    retro_vfs_size_t size;
    retro_vfs_tell_t tell;
    retro_vfs_seek_t seek;
    retro_vfs_read_t read;
    retro_vfs_write_t write;
    retro_vfs_flush_t flush;
    retro_vfs_remove_t remove;
    retro_vfs_rename_t rename;
    retro_vfs_truncate_t truncate;
};

struct retro_vfs_interface_info {
    uint32_t required_interface_version;
    struct retro_vfs_interface *iface;
};

enum retro_pixel_format {
    RETRO_PIXEL_FORMAT_0RGB1555 = 0,
    RETRO_PIXEL_FORMAT_XRGB8888 = 1,
    RETRO_PIXEL_FORMAT_RGB565 = 2,
};

struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

struct retro_variable {
    const char *key;
    const char *value;
};

#ifdef __cplusplus
}
#endif

#endif
