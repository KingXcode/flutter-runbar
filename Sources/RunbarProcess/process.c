#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include "RunbarProcess.h"
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <pthread.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <sys/proc.h>
#include <sys/sysctl.h>
#endif
extern char **environ;

#ifdef __APPLE__
static int group_has_no_live_processes(pid_t pgid) {
    int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid};
    size_t size = 0;
    if (sysctl(name, 4, NULL, &size, NULL, 0) < 0) return 0;
    if (size == 0) return 1;
    struct kinfo_proc *processes = malloc(size);
    if (!processes) return 0;
    // A failed or incomplete snapshot must preserve the original signal error.
    if (sysctl(name, 4, processes, &size, NULL, 0) < 0) {
        free(processes); return 0;
    }
    int no_live_processes = 1;
    for (size_t i = 0; i < size / sizeof(*processes); ++i) {
        if (processes[i].kp_proc.p_stat != SZOMB) {
            no_live_processes = 0; break;
        }
    }
    free(processes); return no_live_processes;
}
#endif

static int rb_spawn_unlocked(const char *shell, const char *command, const char *directory,
             const char *path, pid_t *pid, int *output_fd) {
    int output[2];
    if (pipe(output) < 0) return errno;
    // GUI processes can inherit closed standard descriptors. Keep pipes above 2
    // so subsequent dup/close actions cannot accidentally close redirected I/O.
    for (int i = 0; i < 2; ++i) {
        if (output[i] <= STDERR_FILENO) {
            int replacement = fcntl(output[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) { int e = errno; close(output[0]); close(output[1]); return e; }
            close(output[i]); output[i] = replacement;
        } else if (fcntl(output[i], F_SETFD, FD_CLOEXEC) < 0) {
            int e = errno; close(output[0]); close(output[1]); return e;
        }
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(output[0]); close(output[1]); return error; }
    error = posix_spawnattr_init(&attributes);
    if (error) { posix_spawn_file_actions_destroy(&actions); close(output[0]); close(output[1]); return error; }
#define CHECK(call) do { if (!error) error = (call); } while (0)
#ifdef __APPLE__
    // macOS 26 implements the standardized API; the _np spelling is deprecated.
    CHECK(posix_spawn_file_actions_addchdir(&actions, directory));
#else
    CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
#endif
    CHECK(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO));
    CHECK(posix_spawn_file_actions_addclose(&actions, output[0]));
    CHECK(posix_spawn_file_actions_addclose(&actions, output[1]));
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    sigset_t defaults, mask;
    sigemptyset(&mask); sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE);
    CHECK(posix_spawnattr_setsigmask(&attributes, &mask));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    // The user's command and PATH are positional arguments, never interpolated.
    char *argv[] = {(char *)shell, "-l", "-c", "export PATH=\"$1:$PATH\"; eval \"$2\"", "runbar", (char *)path, (char *)command, NULL};
    if (!error) error = posix_spawn(pid, shell, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    close(output[1]);
    if (error) { close(output[0]); return error; }
    *output_fd = output[0]; return 0;
}
int rb_signal(pid_t pid, int sig) {
    if (pid <= 1) return EINVAL;
    if (kill(-pid, sig) == 0) return 0;
    int error = errno;
#ifdef __APPLE__
    // Darwin returns EPERM for a group containing only unreaped zombies.
    // Keep the leader unreaped to reserve its PID, but treat that group as gone.
    // Do not hide genuine permission errors while any live member remains.
    if (error == EPERM && group_has_no_live_processes(pid)) return ESRCH;
#endif
    return error;
}
int rb_wait(pid_t pid, int *exit_code) {
    int status; pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 0;
}
int rb_poll(pid_t pid, int *exit_code) {
    int status; pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) return 0;
    if (result < 0) return errno == EINTR ? 0 : -errno;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}

// pipe()+FD_CLOEXEC is not atomic on every supported platform. Serialize the entire
// setup/spawn/close window so concurrent runners cannot inherit each other's pipe.
static pthread_mutex_t spawn_mutex = PTHREAD_MUTEX_INITIALIZER;
int rb_spawn(const char *shell, const char *command, const char *directory,
             const char *path, pid_t *pid, int *output_fd) {
    int error = pthread_mutex_lock(&spawn_mutex);
    if (error) return error;
    int result = rb_spawn_unlocked(shell, command, directory, path, pid, output_fd);
    pthread_mutex_unlock(&spawn_mutex);
    return result;
}
