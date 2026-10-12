#pragma once
int warpweb_create_shared_memory(const char *name);

#include <stddef.h>
#include <stdint.h>
// Opaque, premultiplied RGBA8 only. NULL requests the platform PNG fallback.
// The caller owns the returned malloc allocation and must free it.
uint8_t *warpweb_encode_png_rgba(const uint8_t *rgba, size_t width, size_t height,
    size_t row_bytes, const uint8_t *icc, size_t icc_size, size_t *output_size);

int warpweb_watchdog_start(uint32_t first_image, uint32_t second_image);
int warpweb_watchdog_pid(void);
int warpweb_watchdog_activate(void);
void warpweb_watchdog_finished(void);
int warpweb_watchdog_register(const char *name);
void warpweb_watchdog_unregister(const char *name);
