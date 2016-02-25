FROM operable/docker-base

# Setup Mix Environment to use. We declare the MIX_ENV at build time
ARG MIX_ENV
ENV MIX_ENV ${MIX_ENV:-dev}

# Setup Relay
RUN mkdir -p /home/operable/relay \
             /home/operable/relay/config \
             /home/operable/relay/data/pending \
             /home/operable/relay/data/command_config

WORKDIR /home/operable/relay

COPY mix.exs mix.lock /home/operable/relay/
COPY config/helpers.exs /home/operable/relay/config/
RUN mix deps.get && mix deps.compile

COPY . /home/operable/relay/
RUN mix clean && mix compile
RUN rm -f /home/operable/.dockerignore

# Setup relayctl
RUN mkdir /home/operable/relayctl
RUN cd /home/operable/relayctl && \
    git clone https://github.com/operable/relayctl . && \
    mix escript
