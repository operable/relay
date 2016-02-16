#!/usr/bin/env bash

set -e

# Push current working directory onto stack so
# we can return here when we're done.
pushd $(pwd) >& /dev/null

# Clean up when we're done. For now this means
# restoring the user's working directory.
function finish {
  popd >& /dev/null
}

trap finish EXIT

function usage {
  printf "Usage: %s [start|stop|help] [[-d|--dir] <INSTALL_DIR>] [-fg|--foreground]\n" ${MYNAME}
  exit 1
}

MYNAME=`basename $0`

# Default the INSTALL_DIR to a path one level up
# from the startup script.
INSTALL_DIR=$( cd $(dirname "$0") ; cd .. ; pwd -P )

# Save the ACTION and shift it off the ARG list
# so we can process other options later.
ACTION="$1"

if [ ! "$ACTION" == "start" ] && [ ! "$ACTION" == "stop" ] && [ ! "$ACTION" == "help" ] ; then
  usage
else
  shift
fi

# Set Relay environment variables if file exists
if [ -e "${HOME}/relay.vars" ]; then
  echo "Loading environemnt variables from ${HOME}/relay.vars."
  source "${HOME}/relay.vars"
fi

while [ "$#" -gt 0 ];
do
  case "$1" in
    --foreground)
      FOREGROUND="true"
      ;;
    -fg)
      FOREGROUND="true"
      ;;
    --dir)
      shift
      INSTALL_DIR="$1"
      ;;
    -d)
      shift
      INSTALL_DIR="$1"
      ;;
  esac

  shift
done

# Make sure we can find a Relay installation at $INSTALL_DIR
if [ grep 'app: :relay' "${INSTALL_DIR}/mix.exs" >& /dev/null -gt 0 ] ; then
  echo "Unable to find Relay install at ${INSTALL_DIR}. Specify Relay directory with [-d|--dir]."
  exit 1
fi

# Setup Relay data directory path
if [ "${RELAY_DATA_DIR}" == "" ] ; then
  RELAY_DATA_DIR="${INSTALL_DIR}/data"
elif [ ! -d "${RELAY_DATA_DIR}" ] ; then
  echo "RELAY_DATA_DIR set but directory not found at ${RELAY_DATA_DIR}. Aborting."
  exit 1
fi

# Set PID file path
if [ "${RELAY_PID_FILE}" == "" ] ; then
  RELAY_PID_FILE="${RELAY_DATA_DIR}/relay.pid"
fi

function start_relay {
  cd "${INSTALL_DIR}"
  mkdir -p "${RELAY_DATA_DIR}"

  if [ "${FOREGROUND}" == "true" ] ; then
    echo "Launching Relay."
    elixir --no-halt --name "relay@127.0.0.1" -S mix
  else
    echo "Launching Relay. PID available in ${RELAY_PID_FILE}."
    elixir --detached --no-halt --name "relay@127.0.0.1" -e "File.write!('${RELAY_PID_FILE}', :os.getpid)" -S mix
  fi
}

function stop_relay {
  if [ -e "${RELAY_PID_FILE}" ] ; then
    RELAY_PID=$(cat "${RELAY_PID_FILE}")
    echo "Terminating Relay PID: ${RELAY_PID}"
    kill $RELAY_PID
  else
    echo "Relay PID file not found at ${RELAY_PID_FILE}. Unable to terminate Relay."
    exit 1
  fi
}

case "$ACTION" in
    start)
        start_relay
        ;;
    stop)
        stop_relay
        ;;
    *)
        usage
        ;;
esac
