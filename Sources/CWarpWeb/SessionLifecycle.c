#include "CWarpWeb.h"
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <termios.h>
#include <sys/mman.h>
#include <sys/event.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

// Fork before AppKit starts. The child uses only C/POSIX operations and owns
// cleanup for this renderer, never for other warpweb or WebKit processes.
static int control_fd = -1;
static pid_t watchdog_pid = 0;
struct message { char operation; char name[32]; };
static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
static int send_message(char operation, const char *name) {
    if (control_fd < 0) return -1;
    struct message m = {0}; m.operation = operation;
    if (name) {
        size_t n = strlen(name);
        if (n >= sizeof(m.name) || strncmp(name,"/ww-",4)) return -1;
        memcpy(m.name,name,n);
    }
    ssize_t result;
    do { result = write(control_fd,&m,sizeof(m)); } while (result < 0 && errno == EINTR);
    return result == sizeof(m) ? 0 : -1;
}
int warpweb_watchdog_start(uint32_t first_image, uint32_t second_image) {
    int channel[2]; struct termios original;
    if (tcgetattr(0,&original) || pipe(channel)) return -1;
    fcntl(channel[0],F_SETFD,FD_CLOEXEC); fcntl(channel[1],F_SETFD,FD_CLOEXEC);
    pid_t renderer = getpid(); int max_fd = getdtablesize();
    // Precompute output before fork; no stdio/allocator activity in the child.
    char cleanup[256]; int cleanup_size = snprintf(cleanup,sizeof(cleanup),
        "\030\033_Ga=d,d=I,i=%u,q=2;\033\\\033_Ga=d,d=I,i=%u,q=2;\033\\"
        "\033[?2004l\033[?1006l\033[?1003l\033[?1002l\033[?1000l\033[?25h\033[0m\033[?1049l",
        first_image,second_image);
    pid_t child = fork();
    if (child < 0) { close(channel[0]); close(channel[1]); return -1; }
    if (child > 0) {
        close(channel[0]); control_fd = channel[1]; watchdog_pid = child;
        // A failed watchdog must not crash the renderer with SIGPIPE.
        signal(SIGPIPE,SIG_IGN);
        return child;
    }
    setsid();
    signal(SIGPIPE,SIG_IGN); signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN);
    signal(SIGHUP,SIG_IGN); signal(SIGTTOU,SIG_IGN);
    for (int fd=3;fd<max_fd;fd++) if (fd!=channel[0]) close(fd);
    // macOS does not report a slave PTY hangup through poll(events=0).
    // EV_EOF observes closure without reading or stealing terminal input.
    int terminal_events = kqueue();
    if (terminal_events < 0) _exit(1);
    struct kevent change;
    EV_SET(&change,0,EVFILT_READ,EV_ADD|EV_CLEAR,0,0,NULL);
    if (kevent(terminal_events,&change,1,NULL,0,NULL) < 0) _exit(1);
    char names[64][32] = {{0}};
    struct message m; size_t received=0;
    int active=0, finished=0; double deadline=0;
    for (;;) {
        struct pollfd descriptors[2] = {{channel[0],POLLIN,0},{0,0,0}};
        poll(descriptors,2,100);
        if (descriptors[0].revents & POLLIN) {
            ssize_t n=read(channel[0],(char *)&m+received,sizeof(m)-received);
            if (n>0) received+=(size_t)n;
            if (received==sizeof(m)) {
                received=0; m.name[31]=0;
                if (m.operation=='A') active=1;
                if (m.operation=='D') { finished=1; deadline=now()+3; }
                if (m.operation=='R') {
                    for (int i=0;i<64;i++) if (!names[i][0]) { memcpy(names[i],m.name,32); break; }
                }
                if (m.operation=='U') {
                    for (int i=0;i<64;i++) if (!strcmp(names[i],m.name)) names[i][0]=0;
                }
            }
            // Drain all queued registrations before handling EOF/death.
            if (n>0) continue;
        }
        if (getppid()!=renderer || (descriptors[0].revents & POLLHUP)) break;
        struct kevent event; struct timespec immediate={0,0};
        int events=kevent(terminal_events,NULL,0,&event,1,&immediate);
        if (!deadline && events>0 && (event.flags & EV_EOF)) {
            kill(renderer,SIGTERM); deadline=now()+2;
        }
        if (deadline && now()>=deadline && getppid()==renderer) kill(renderer,SIGKILL);
    }
    for (int i=0;i<64;i++) if (names[i][0]) shm_unlink(names[i]);
    if (active && !finished) {
        // Flush raw keystrokes so they cannot become shell commands.
        tcsetattr(0,TCSAFLUSH,&original);
        int flags=fcntl(1,F_GETFL); if (flags>=0) fcntl(1,F_SETFL,flags|O_NONBLOCK);
        size_t offset=0; double output_deadline=now()+0.5;
        while (flags>=0 && offset<(size_t)cleanup_size && now()<output_deadline) {
            ssize_t written=write(1,cleanup+offset,(size_t)cleanup_size-offset);
            if (written>0) offset+=(size_t)written;
            else if (written<0 && errno!=EAGAIN && errno!=EINTR) break;
            else { struct pollfd output={1,POLLOUT,0}; poll(&output,1,20); }
        }
        if (flags>=0) fcntl(1,F_SETFL,flags);
    }
    _exit(0);
}
int warpweb_watchdog_pid(void) { return watchdog_pid; }
int warpweb_watchdog_activate(void) { return send_message('A',NULL); }
void warpweb_watchdog_finished(void) { (void)send_message('D',NULL); }
int warpweb_watchdog_register(const char *name) { return send_message('R',name); }
void warpweb_watchdog_unregister(const char *name) { (void)send_message('U',name); }
