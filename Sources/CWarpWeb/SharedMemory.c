#include "CWarpWeb.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

// Swift cannot call macOS's variadic shm_open directly.
int warpweb_create_shared_memory(const char *name) {
    return shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
}
