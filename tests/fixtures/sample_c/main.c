/*
 * Intentional taint path for dataflow fixture:
 *   recv_packet  (source)
 *     → parse_msg(buf)
 *       → exec_cmd(cmd)   (sink — system call)
 *
 * Expected query results:
 *   callgraph --target exec_cmd --depth 2
 *     callers: parse_msg (depth 1), recv_packet (depth 2)
 *
 *   dataflow --source recv_packet --sink exec_cmd
 *     reachable: true, hops: 3
 */
#include <string.h>
#include <stdlib.h>

/* sink */
void exec_cmd(char *cmd) {
    system(cmd);
}

/* taint propagation */
void parse_msg(char *buf) {
    char cmd[256];
    strncpy(cmd, buf, 255);
    cmd[255] = '\0';
    exec_cmd(cmd);
}

/* source: externally-supplied data enters here */
void recv_packet(char *data, int len) {
    (void)len;
    parse_msg(data);
}

int process_request(char *data, int len) {
    recv_packet(data, len);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        process_request(argv[1], (int)strlen(argv[1]));
    }
    return 0;
}
