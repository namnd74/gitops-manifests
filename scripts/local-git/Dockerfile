# Alpine splits the Git protocol daemon into a separate package.
FROM alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26
RUN apk add --no-cache git-daemon=2.49.1-r0 \
    && test -x "$(git --exec-path)/git-daemon"
