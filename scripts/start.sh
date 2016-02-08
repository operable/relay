#!/usr/bin/env bash

set -x

prev_start_cmd="iex --name relay@127.0.0.1 -S mix"

MYNAME=`basename $0`
install_dir=""
elixir_cmd=`which elixir`

# Clean up when we're done. For now this means
# restoring the user's working directory.
function finish {
  popd >& /dev/null
}

trap finish EXIT

# Push current working directory onto stack so
# we can return here when we're done.
pushd >& /dev/null

function usage {
  printf "%s [help|--help|-h|-?] <install_dir> \n" ${MYNAME}
  exit
}

while [ "$#" -gt 0 ];
do
  case "$1" in
    help)
      usage
      ;;
    \?)
      usage
      ;;
    -\?)
      usage
      ;;
    --help)
      usage
      ;;
    -h)
      usage
      ;;
    *)
      install_dir="$1"
      ;;
  esac
  shift
done

# Set install dir to current directory if one wasn't set.
if [ "$install_dir" == "" ]; then
  install_dir=`pwd`
fi

# Set Relay environment variables if file exists
if [ -e "${HOME}/relay.vars" ]; then
  echo "Loading environemnt variables from ${HOME}/relay.vars."
  source "${HOME}/relay.vars"
fi

function verify_relay_env {
  if [ -z "$RELAY_DATA_DIR" ]; then
    printf "\tWARNING! $RELAY_DATA_DIR is not set.\n"
    printf "Dynamic command configs will be loaded from ${install_dir}/relay/command_config."
  fi
  return 0
}

function pid_file_prep {
  if [ ! -d "/var/run/operable" ]; then
    if ! mkdir -p /var/run/operable; then
      printf "Unable to access or create /var/run/operable. Aborted startup.\n" 1>&2
      exit 1
    fi
  fi
}

function start_relay {
  cd "${install_dir}/relay"
  # If Cog is running the /var/run/operable directory should already exist with the correct permissions
  # So this should have failed before getting to this point
  #elixir --detached -e "File.write! '/var/run/operable/relay.pid', :os.getpid" --name relay@127.0.0.1 -S mix
  ${elixir_cmd} --detached --name "relay@127.0.0.1" -e "File.write! '/var/run/operable/relay.pid', :os.getpid" -S mix
}


# Verify Relay has been installed with correct env vars set
if [ ! -d "${install_dir}/relay" ]; then
  printf "Relay not found at ${install_dir}/relay. Aborted startup.\n" 1>&2
  exit 1
fi

pid_file_prep

if [ -z "${elixir_cmd}" ]; then
  printf "'elixir' command not found. Aborted startup.\n" 1>&2
  exit 1
fi

echo "Starting Relay"
start_relay
