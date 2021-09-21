FROM alpine:3

LABEL maintainer="kyle@bywatersolutions.com"

ENV DO_IT 0

RUN apk add --no-cache \
    git \
    perl-file-slurp \
    perl-json \
    perl-libwww

RUN git config --global user.email "kyle@bywatersolutions.com"
RUN git config --global user.name "Kyle M Hall"

WORKDIR /app
ADD . /app

CMD cd /kohaclone && perl /app/bws_rebase_branches.pl
