#ifndef IO_URING_INTERNAL_H
#define IO_URING_INTERNAL_H

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include "liburing.h"

#ifndef LIBUS_IO_URING_MAX_CONNECTIONS
#define LIBUS_IO_URING_MAX_CONNECTIONS 4096
#endif

#define MAX_CONNECTIONS     LIBUS_IO_URING_MAX_CONNECTIONS
#define BACKLOG             512
#ifndef LIBUS_IO_URING_RECV_BUFFER_SIZE
#define LIBUS_IO_URING_RECV_BUFFER_SIZE 2048
#endif
#define MAX_MESSAGE_LEN     LIBUS_IO_URING_RECV_BUFFER_SIZE
#define REGISTERED_FILES_COUNT MAX_CONNECTIONS
#ifndef LIBUS_IO_URING_RECV_BUFFERS
#define LIBUS_IO_URING_RECV_BUFFERS 4096
#endif
#define BUFFERS_COUNT       LIBUS_IO_URING_RECV_BUFFERS
#ifndef LIBUS_IO_URING_ENTRIES
#define LIBUS_IO_URING_ENTRIES 2048
#endif

enum pointer_tags {
    SOCKET_READ,
    SOCKET_WRITE,
    LISTEN_SOCKET_ACCEPT,
    SOCKET_CONNECT,
    SOCKET_CLOSE,
    ASYNC_WAKEUP = 5,
    LOOP_TIMER = 7,
};

void us_internal_loop_link(struct us_loop_t *loop, struct us_socket_context_t *context);
void us_internal_loop_unlink(struct us_loop_t *loop, struct us_socket_context_t *context);
void us_internal_socket_context_link_socket(struct us_socket_context_t *context, struct us_socket_t *s);
void us_internal_socket_context_unlink_socket(struct us_socket_context_t *context, struct us_socket_t *s);
void us_internal_socket_context_link_listen_socket(struct us_socket_context_t *context, struct us_listen_socket_t *ls);
void us_internal_socket_context_unlink_listen_socket(struct us_socket_context_t *context, struct us_listen_socket_t *ls);
int us_internal_allocate_registered_fd_slot(struct us_loop_t *loop);
void us_internal_mark_registered_fd_slot(struct us_loop_t *loop, int slot);
void us_internal_release_registered_fd_slot(struct us_loop_t *loop, int slot);
void us_internal_queue_close_direct(struct us_loop_t *loop, int slot);
void us_internal_queue_closed_socket(struct us_loop_t *loop, struct us_socket_t *s);
void us_internal_free_closed_sockets(struct us_loop_t *loop);
void us_internal_free_closed_listen_sockets(struct us_loop_t *loop);
void us_internal_free_closed_timers(struct us_loop_t *loop);
struct io_uring_sqe *us_internal_get_sqe(struct us_loop_t *loop);
void us_internal_socket_free_write_buffer(struct us_socket_t *s);
void us_internal_timer_sweep(struct us_loop_t *loop);
int us_internal_arm_listen_socket(struct us_listen_socket_t *listen_s);
void us_internal_arm_socket_read(struct us_loop_t *loop, struct us_socket_t *s);
void us_internal_loop_pre(struct us_loop_t *loop);
void us_internal_loop_post(struct us_loop_t *loop);
int us_internal_loop_data_init(struct us_loop_t *loop, void (*wakeup_cb)(struct us_loop_t *loop),
    void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop));
void us_internal_loop_data_free(struct us_loop_t *loop);

struct us_timer_t {
    struct us_loop_t *loop;
    int fd;
    uint64_t buf;
    void (*cb)(struct us_timer_t *t);
    unsigned char closed;
    unsigned char pending;
    unsigned char fallthrough;
    unsigned char queued_for_free;
    struct us_timer_t *next_closed;
};

struct us_loop_t {
    struct io_uring ring;
    struct io_uring_buf_ring *buf_ring;
    char (*bufs)[MAX_MESSAGE_LEN];
    unsigned short buf_group_id;
    int next_registered_fd_slot;
    unsigned char registered_fd_slot_used[REGISTERED_FILES_COUNT];
    unsigned char registered_fd_slot_closing[REGISTERED_FILES_COUNT];
    unsigned char registered_fd_slot_pending_close[REGISTERED_FILES_COUNT];

    struct us_timer_t *timer;

    int async_wakeup_fd;
    uint64_t async_wakeup_buf;

    int num_polls;
    long long iteration_nr;
    int wakeup_async_pending;
    struct us_socket_t *closed_head;
    struct us_listen_socket_t *closed_listen_head;
    struct us_timer_t *closed_timer_head;
    void (*wakeup_cb)(struct us_loop_t *loop);
    void (*pre_cb)(struct us_loop_t *loop);
    void (*post_cb)(struct us_loop_t *loop);

    struct us_socket_context_t *head;
    struct us_socket_context_t *iterator;

    uint64_t next_timeout;
};

struct us_socket_context_t {
    struct us_loop_t *loop;
    uint32_t global_tick;
    unsigned char timestamp;
    unsigned char long_timestamp;
    struct us_socket_t *head_sockets;
    struct us_listen_socket_t *head_listen_sockets;
    struct us_socket_t *iterator;
    struct us_socket_context_t *prev, *next;

    LIBUS_SOCKET_DESCRIPTOR (*on_pre_open)(struct us_socket_context_t *context, LIBUS_SOCKET_DESCRIPTOR fd);
    struct us_socket_t *(*on_open)(struct us_socket_t *, int is_client, char *ip, int ip_length);
    struct us_socket_t *(*on_data)(struct us_socket_t *, char *data, int length);
    struct us_socket_t *(*on_writable)(struct us_socket_t *);
    struct us_socket_t *(*on_close)(struct us_socket_t *, int code, void *reason);
    struct us_socket_t *(*on_socket_timeout)(struct us_socket_t *);
    struct us_socket_t *(*on_socket_long_timeout)(struct us_socket_t *);
    struct us_socket_t *(*on_end)(struct us_socket_t *);
    struct us_socket_t *(*on_connect_error)(struct us_socket_t *, int code);
};

struct us_socket_t {
    struct us_socket_context_t *context;
    struct us_socket_t *prev, *next;
    unsigned char timeout;
    unsigned char long_timeout;
    unsigned char write_pending;
    unsigned char write_msg_more;
    unsigned char connect_pending;
    unsigned char read_pending;
    unsigned char close_pending;
    unsigned char queued_for_free;
    unsigned char closed;
    unsigned char write_drained_inline;
    int write_offset;
    int write_length;
    char *write_data;
    char *write_buf;
    size_t write_buf_capacity;
    int fd;
    int dd;

    char sendBuf[16 * 1024];
};

/* Listen sockets must begin with us_socket_t for the public native-handle ABI. */
struct us_listen_socket_t {
    struct us_socket_t s;
    int socket_ext_size;
    unsigned char accept_pending;
    unsigned char queued_for_free;
    struct us_listen_socket_t *next_closed;
};

#endif
