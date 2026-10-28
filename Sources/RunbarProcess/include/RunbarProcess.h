#ifndef RUNBAR_PROCESS_H
#define RUNBAR_PROCESS_H
#include <sys/types.h>
// Explicit executable/argv/environment only; creates a private process group.
int rb_spawn(const char *shell, const char *command, const char *directory,
             const char *path, pid_t *pid, int *output_fd);
// Optional bounded, non-blocking input channel. Output remains the same pipe.
int rb_spawn_interactive(const char *shell, const char *command, const char *directory,
                         const char *path, pid_t *pid, int *output_fd, int *input_fd);
int rb_send_key(int input_fd, char key);
int rb_signal(pid_t pid, int signal_number);
int rb_wait(pid_t pid, int *exit_code);
// 0: running, 1: reaped, negative errno: error.
int rb_poll(pid_t pid, int *exit_code);
// Read-only parent lookup. Returns 0 if the process is gone or unavailable.
pid_t rb_parent_process(pid_t pid);
#endif
