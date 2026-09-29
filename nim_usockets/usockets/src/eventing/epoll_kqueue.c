/*
 * Authored by Alex Hultman, 2018-2019.
 * Intellectual property of third-party.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *     http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "libusockets.h"
#include "internal/internal.h"
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

#if defined(LIBUS_USE_EPOLL) || defined(LIBUS_USE_KQUEUE)

/* Cannot include this one on Windows */
#include <unistd.h>

#ifdef LIBUS_USE_EPOLL
#define GET_READY_POLL(loop, index) (struct us_poll_t *) loop->ready_polls[index].data.ptr
#define SET_READY_POLL(loop, index, poll) loop->ready_polls[index].data.ptr = poll
#else
#define GET_READY_POLL(loop, index) (struct us_poll_t *) loop->ready_polls[index].udata
#define SET_READY_POLL(loop, index, poll) loop->ready_polls[index].udata = poll
#endif

/* EPOLL only helper for opt-in policy flags with kernel fallback. */
#ifdef LIBUS_USE_EPOLL
static int us_epoll_apply_ctl(int epoll_fd, int op, int fd, struct epoll_event *event) {
    int requested_events = event->events;
#ifdef EPOLLEXCLUSIVE
    if (op != EPOLL_CTL_ADD) {
        event->events &= ~EPOLLEXCLUSIVE;
    }
#endif
    int rc = epoll_ctl(epoll_fd, op, fd, event);
#ifdef EPOLLEXCLUSIVE
    if (rc == -1 &&
        (requested_events & EPOLLEXCLUSIVE) &&
        (errno == EINVAL || errno == EOPNOTSUPP || errno == ENOTSUP || errno == ENOSYS)) {
        event->events &= ~EPOLLEXCLUSIVE;
        rc = epoll_ctl(epoll_fd, op, fd, event);
    }
#endif
    return rc;
}
#endif

/* Loop */
void us_loop_free(struct us_loop_t *loop) {
    us_internal_loop_data_free(loop);
    close(loop->fd);
    free(loop);
}

/* Poll */
struct us_poll_t *us_create_poll(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *p = malloc(sizeof(struct us_poll_t) + ext_size);
    if (!p) {
        return 0;
    }
    if (!fallthrough) {
        loop->num_polls++;
    }
    return p;
}

/* Todo: this one should be us_internal_poll_free */
void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop) {
    loop->num_polls--;
    free(p);
}

void *us_poll_ext(struct us_poll_t *p) {
    return p + 1;
}

/* Todo: why have us_poll_create AND us_poll_init!? libuv legacy! */
void us_poll_init(struct us_poll_t *p, LIBUS_SOCKET_DESCRIPTOR fd, int poll_type) {
    p->state.fd = fd;
    p->state.poll_type = poll_type;
}

int us_poll_events(struct us_poll_t *p) {
    return ((p->state.poll_type & POLL_TYPE_POLLING_IN) ? LIBUS_SOCKET_READABLE : 0) | ((p->state.poll_type & POLL_TYPE_POLLING_OUT) ? LIBUS_SOCKET_WRITABLE : 0);
}

LIBUS_SOCKET_DESCRIPTOR us_poll_fd(struct us_poll_t *p) {
    return p->state.fd;
}

/* Returns any of listen socket, socket, shut down socket or callback */
int us_internal_poll_type(struct us_poll_t *p) {
    return p->state.poll_type & 3;
}

/* Bug: doesn't really SET, rather read and change, so needs to be inited first! */
void us_internal_poll_set_type(struct us_poll_t *p, int poll_type) {
    p->state.poll_type = poll_type | (p->state.poll_type & 12);
}

/* Timer */
void *us_timer_ext(struct us_timer_t *timer) {
    return ((struct us_internal_callback_t *) timer) + 1;
}

struct us_loop_t *us_timer_loop(struct us_timer_t *t) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;

    return internal_cb->loop;
}

/* Loop */
struct us_loop_t *us_create_loop(void *hint, void (*wakeup_cb)(struct us_loop_t *loop), void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop), unsigned int ext_size) {
    struct us_loop_t *loop = (struct us_loop_t *) malloc(sizeof(struct us_loop_t) + ext_size);
    if (!loop) {
        return 0;
    }
    loop->num_polls = 0;
    /* These could be accessed if we close a poll before starting the loop */
    loop->num_ready_polls = 0;
    loop->current_ready_poll = 0;

#ifdef LIBUS_USE_EPOLL
    loop->fd = epoll_create1(EPOLL_CLOEXEC);
#else
    loop->fd = kqueue();
    loop->nchanges = 0;
#endif
    if (loop->fd == -1) {
        free(loop);
        return 0;
    }

    if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {
        close(loop->fd);
        free(loop);
        return 0;
    }
    return loop;
}

void us_loop_run(struct us_loop_t *loop) {
    us_loop_integrate(loop);

    /* While we have non-fallthrough polls we shouldn't fall through */
    while (loop->num_polls) {
        /* Emit pre callback */
        us_internal_loop_pre(loop);

        /* Fetch ready polls */
#ifdef LIBUS_USE_EPOLL
        loop->num_ready_polls = epoll_wait(loop->fd, loop->ready_polls, 1024, -1);
#else
        loop->num_ready_polls = kevent(loop->fd, loop->changelist, loop->nchanges, loop->ready_polls, 1024, NULL);
        loop->nchanges = 0;
#endif

        /* Iterate ready polls, dispatching them by type */
        for (loop->current_ready_poll = 0; loop->current_ready_poll < loop->num_ready_polls; loop->current_ready_poll++) {
            struct us_poll_t *poll = GET_READY_POLL(loop, loop->current_ready_poll);
            /* Any ready poll marked with nullptr will be ignored */
            if (poll) {
#ifdef LIBUS_USE_EPOLL
                int events = loop->ready_polls[loop->current_ready_poll].events;
                int error = loop->ready_polls[loop->current_ready_poll].events & (EPOLLERR | EPOLLHUP);
#else
                /* EVFILT_READ, EVFILT_TIME, EVFILT_USER are all mapped to LIBUS_SOCKET_READABLE */
                int events = LIBUS_SOCKET_READABLE;
                if (loop->ready_polls[loop->current_ready_poll].filter == EVFILT_WRITE) {
                    events = LIBUS_SOCKET_WRITABLE;
                }
                int error = loop->ready_polls[loop->current_ready_poll].flags & (EV_ERROR | EV_EOF);
#endif
                /* Always filter all polls by what they actually poll for (callback polls always poll for readable) */
                events &= us_poll_events(poll);
                if (events || error) {
                    us_internal_dispatch_ready_poll(poll, error, events);
                }
            }
        }
        /* Emit post callback */
        us_internal_loop_post(loop);
    }
}

void us_loop_stop(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    loop->num_polls = 0;
    us_wakeup_loop(loop);
}

void us_internal_loop_update_pending_ready_polls(struct us_loop_t *loop, struct us_poll_t *old_poll, struct us_poll_t *new_poll, int old_events, int new_events) {
#ifdef LIBUS_USE_EPOLL
    /* Epoll only has one ready poll per poll */
    int num_entries_possibly_remaining = 1;
#else
    /* Ready polls may contain same poll twice under kqueue, as one poll may hold two filters */
    int num_entries_possibly_remaining = 2;//((old_events & LIBUS_SOCKET_READABLE) ? 1 : 0) + ((old_events & LIBUS_SOCKET_WRITABLE) ? 1 : 0);
#endif

    /* Todo: for kqueue if we track things in us_change_poll it is possible to have a fast path with no seeking in cases of:
    * current poll being us AND we only poll for one thing */

    for (int i = loop->current_ready_poll; i < loop->num_ready_polls && num_entries_possibly_remaining; i++) {
        if (GET_READY_POLL(loop, i) == old_poll) {

            // if new events does not contain the ready events of this poll then remove (no we filter that out later on)
            SET_READY_POLL(loop, i, new_poll);

            num_entries_possibly_remaining--;
        }
    }
}

/* Poll */

#ifdef LIBUS_USE_KQUEUE
static void kqueue_flush(struct us_loop_t *loop) {
    if (loop->nchanges) {
        kevent(loop->fd, loop->changelist, loop->nchanges, NULL, 0, NULL);
        loop->nchanges = 0;
    }
}

static void kqueue_enqueue(struct us_loop_t *loop, struct kevent *ev) {
    if (loop->nchanges == 256) {
        kqueue_flush(loop);
    }
    loop->changelist[loop->nchanges++] = *ev;
}

int kqueue_change(struct us_loop_t *loop, int fd, int old_events, int new_events, void *user_data) {
    struct kevent ev;

    if ((new_events & LIBUS_SOCKET_READABLE) != (old_events & LIBUS_SOCKET_READABLE)) {
        EV_SET(&ev, fd, EVFILT_READ, (new_events & LIBUS_SOCKET_READABLE) ? (EV_ADD | EV_CLEAR) : EV_DELETE, 0, 0, user_data);
        kqueue_enqueue(loop, &ev);
    }

    if ((new_events & LIBUS_SOCKET_WRITABLE) != (old_events & LIBUS_SOCKET_WRITABLE)) {
        EV_SET(&ev, fd, EVFILT_WRITE, (new_events & LIBUS_SOCKET_WRITABLE) ? (EV_ADD | EV_CLEAR) : EV_DELETE, 0, 0, user_data);
        kqueue_enqueue(loop, &ev);
    }

    return 0;
}
#endif

struct us_poll_t *us_poll_resize(struct us_poll_t *p, struct us_loop_t *loop, unsigned int ext_size) {
    int events = us_poll_events(p);

    struct us_poll_t *new_p = realloc(p, sizeof(struct us_poll_t) + ext_size);
    if (!new_p) {
        return 0;
    }
    if (p != new_p && events) {
#ifdef LIBUS_USE_EPOLL
        /* Hack: forcefully update poll by stripping away already set events */
        new_p->state.poll_type = us_internal_poll_type(new_p);
        us_poll_change(new_p, loop, events);
#else
        kqueue_change(loop, new_p->state.fd, 0, events, new_p);
#endif

        /* This is needed for epoll also (us_change_poll doesn't update the old poll) */
        us_internal_loop_update_pending_ready_polls(loop, p, new_p, events, events);
    }

    return new_p;
}

void us_poll_start(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    p->state.poll_type = us_internal_poll_type(p) | ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) | ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);

#ifdef LIBUS_USE_EPOLL
    struct epoll_event event;
    event.events = events;
    event.data.ptr = p;
    us_epoll_apply_ctl(loop->fd, EPOLL_CTL_ADD, p->state.fd, &event);
#else
    kqueue_change(loop, p->state.fd, 0, events, p);
#endif
}

void us_poll_change(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    int old_events = us_poll_events(p);
    if (old_events != events) {

        p->state.poll_type = us_internal_poll_type(p) | ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) | ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);

#ifdef LIBUS_USE_EPOLL
        struct epoll_event event;
        event.events = events;
        event.data.ptr = p;
        us_epoll_apply_ctl(loop->fd, EPOLL_CTL_MOD, p->state.fd, &event);
#else
        kqueue_change(loop, p->state.fd, old_events, events, p);
#endif
        /* Set all removed events to null-polls in pending ready poll list */
        //us_internal_loop_update_pending_ready_polls(loop, p, p, old_events, events);
    }
}

void us_poll_stop(struct us_poll_t *p, struct us_loop_t *loop) {
    int old_events = us_poll_events(p);
    int new_events = 0;
#ifdef LIBUS_USE_EPOLL
    struct epoll_event event;
    epoll_ctl(loop->fd, EPOLL_CTL_DEL, p->state.fd, &event);
#else
    if (old_events) {
        kqueue_change(loop, p->state.fd, old_events, new_events, NULL);
    }
#endif

    /* Disable any instance of us in the pending ready poll list */
    us_internal_loop_update_pending_ready_polls(loop, p, 0, old_events, new_events);
}

unsigned int us_internal_accept_poll_event(struct us_poll_t *p) {
#ifdef LIBUS_USE_EPOLL
    int fd = us_poll_fd(p);
    uint64_t buf;
    int read_length = read(fd, &buf, 8);
    (void)read_length;
    return buf;
#else
    /* Kqueue has no underlying FD for timers or user events */
    return 0;
#endif
}

/* Timer */
#ifdef LIBUS_USE_EPOLL
struct us_timer_t *us_create_timer(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *p = us_create_poll(loop, fallthrough, sizeof(struct us_internal_callback_t) - sizeof(struct us_poll_t) + ext_size);
    if (!p) {
        return NULL;
    }
    int timerfd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
    if (timerfd == -1) {
      us_poll_free(p, loop);
      return NULL;
    }
    if (getenv("US_DBG_TIMERS")) {
      fprintf(stderr, "us_create_timer fd=%d ext_size=%u caller=%p\n",
              timerfd, ext_size, (void *) __builtin_return_address(0));
    }
    us_poll_init(p, timerfd, POLL_TYPE_CALLBACK);

    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) p;
    cb->loop = loop;
    cb->cb_expects_the_loop = 0;
    cb->leave_poll_ready = 0;

    return (struct us_timer_t *) cb;
}
#else
struct us_timer_t *us_create_timer(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_internal_callback_t *cb = malloc(sizeof(struct us_internal_callback_t) + ext_size);
    if (!cb) {
        return 0;
    }

    cb->loop = loop;
    cb->cb_expects_the_loop = 0;
    cb->leave_poll_ready = 0;

    /* Bug: us_internal_poll_set_type does not SET the type, it only CHANGES it */
    cb->p.state.poll_type = POLL_TYPE_POLLING_IN;
    us_internal_poll_set_type((struct us_poll_t *) cb, POLL_TYPE_CALLBACK);

    if (!fallthrough) {
        loop->num_polls++;
    }

    return (struct us_timer_t *) cb;
}
#endif

#ifdef LIBUS_USE_EPOLL
void us_timer_close(struct us_timer_t *timer) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) timer;

    us_poll_stop(&cb->p, cb->loop);
    close(us_poll_fd(&cb->p));

    /* (regular) sockets are the only polls which are not freed immediately */
    us_poll_free((struct us_poll_t *) timer, cb->loop);
}

void us_timer_set(struct us_timer_t *t, void (*cb)(struct us_timer_t *t), int ms, int repeat_ms) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;

    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;
    if (getenv("US_DBG_TIMERS")) {
      fprintf(stderr, "us_timer_set fd=%d cb=%p ms=%d repeat=%d caller=%p\n",
              us_poll_fd((struct us_poll_t *) t), (void *) cb, ms, repeat_ms,
              (void *) __builtin_return_address(0));
    }

    struct itimerspec timer_spec = {
        {repeat_ms / 1000, (long) (repeat_ms % 1000) * (long) 1000000},
        {ms / 1000, (long) (ms % 1000) * (long) 1000000}
    };

    timerfd_settime(us_poll_fd((struct us_poll_t *) t), 0, &timer_spec, NULL);
    us_poll_start((struct us_poll_t *) t, internal_cb->loop, LIBUS_SOCKET_READABLE);
}
#else
void us_timer_close(struct us_timer_t *timer) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) timer;

    struct kevent event;
    EV_SET(&event, (uintptr_t) internal_cb, EVFILT_TIMER, EV_DELETE, 0, 0, internal_cb);
    kqueue_enqueue(internal_cb->loop, &event);

    us_poll_free((struct us_poll_t *) timer, internal_cb->loop);
}

void us_timer_set(struct us_timer_t *t, void (*cb)(struct us_timer_t *t), int ms, int repeat_ms) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;

    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;

    struct kevent event;
    EV_SET(&event, (uintptr_t) internal_cb, EVFILT_TIMER, EV_ADD | (repeat_ms ? 0 : EV_ONESHOT), 0, ms, internal_cb);
    kqueue_enqueue(internal_cb->loop, &event);
}
#endif

/* Async (internal helper for loop's wakeup feature) */
#ifdef LIBUS_USE_EPOLL
struct us_internal_async *us_internal_create_async(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *p = us_create_poll(loop, fallthrough, sizeof(struct us_internal_callback_t) - sizeof(struct us_poll_t) + ext_size);
    if (!p) {
        return 0;
    }
    int eventfd_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (eventfd_fd == -1) {
        us_poll_free(p, loop);
        return 0;
    }
    us_poll_init(p, eventfd_fd, POLL_TYPE_CALLBACK);

    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) p;
    cb->loop = loop;
    cb->cb_expects_the_loop = 1;
    cb->leave_poll_ready = 0;

    return (struct us_internal_async *) cb;
}

// identical code as for timer, make it shared for "callback types"
void us_internal_async_close(struct us_internal_async *a) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) a;

    us_poll_stop(&cb->p, cb->loop);
    close(us_poll_fd(&cb->p));

    /* (regular) sockets are the only polls which are not freed immediately */
    us_poll_free((struct us_poll_t *) a, cb->loop);
}

void us_internal_async_set(struct us_internal_async *a, void (*cb)(struct us_internal_async *)) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;

    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;

    us_poll_start((struct us_poll_t *) a, internal_cb->loop, LIBUS_SOCKET_READABLE);
}

void us_internal_async_wakeup(struct us_internal_async *a) {
    uint64_t one = 1;
    int written = write(us_poll_fd((struct us_poll_t *) a), &one, 8);
    (void)written;
}
#else
struct us_internal_async *us_internal_create_async(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_internal_callback_t *cb = malloc(sizeof(struct us_internal_callback_t) + ext_size);
    if (!cb) {
        return 0;
    }

    cb->loop = loop;
    cb->cb_expects_the_loop = 1;
    cb->leave_poll_ready = 0;

    /* Bug: us_internal_poll_set_type does not SET the type, it only CHANGES it */
    cb->p.state.poll_type = POLL_TYPE_POLLING_IN;
    us_internal_poll_set_type((struct us_poll_t *) cb, POLL_TYPE_CALLBACK);

    if (!fallthrough) {
        loop->num_polls++;
    }

    return (struct us_internal_async *) cb;
}

// identical code as for timer, make it shared for "callback types"
void us_internal_async_close(struct us_internal_async *a) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;

    struct kevent event;
    EV_SET(&event, (uintptr_t) internal_cb, EVFILT_USER, EV_DELETE, 0, 0, internal_cb);
    kqueue_enqueue(internal_cb->loop, &event);

    us_poll_free((struct us_poll_t *) a, internal_cb->loop);
}

void us_internal_async_set(struct us_internal_async *a, void (*cb)(struct us_internal_async *)) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;

    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;
}

void us_internal_async_wakeup(struct us_internal_async *a) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;

    struct kevent event;
    EV_SET(&event, (uintptr_t) internal_cb, EVFILT_USER, EV_ADD | EV_ONESHOT, NOTE_TRIGGER, 0, internal_cb);
    kqueue_enqueue(internal_cb->loop, &event);
}
#endif

#endif
