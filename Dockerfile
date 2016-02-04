FROM operable/debian-base

# TODO: Remove temporary SSH hack when the repositories are publicly available.

USER root
COPY operable-readonly.pem /home/operable/.ssh/id_rsa
RUN chmod 0400 /home/operable/.ssh/id_rsa
RUN chown -R operable:operable /home/operable/.ssh
USER operable

# Setup Relay
ENV MIX_ENV prod
RUN mkdir -p /app
WORKDIR /app

COPY mix.exs mix.lock /app/
COPY config /app/config/
RUN mix deps.get && mix deps.compile

COPY . /app/

RUN mix clean && mix compile
RUN rm -f /app/.dockerignore

# TODO: Remove!
RUN rm -f /home/operable/.ssh/id_rsa
