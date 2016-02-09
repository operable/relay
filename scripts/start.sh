#!/usr/bin/env bash

MYNAME=`basename $0`
install_dir=""

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
  exit 0
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

# Verify Relay environment variables have been set
function verify_env_vars {
  env_var=`/usr/bin/env | grep $1 | cut -d '=' -f 2`
  if [ -z ${env_var} ] ; then
    return 1
  else
    return 0
  fi
}

function verify_relay_env {
  if ! verify_env_vars "RELAY_DATA_DIR" ; then
    echo -e "\tWarning: RELAY_DATA_DIR environment variable is not set. ${install_dir}/relay/command_config will be used for command configuration files"
  fi
}

function start_relay {
  cd "${install_dir}/relay"
  # If Cog is running the /var/run/operable directory should already exist with the correct permissions
  # So this should have failed before getting to this point
  elixir --detached --no-halt --name "relay@127.0.0.1" -e "File.write! '/var/run/operable/relay.pid', :os.getpid"  -S mix
}


# Verify Relay has been installed with correct env vars set
if [ -e "${install_dir}/relay" ]; then
  echo "Relay installation detected at ${install_dir}/relay. Verifying required environment variables..."
  verify_relay_env
  if [ $? == 1 ] ; then
    echo "Relay environment variables verified."
  fi
  echo "Starting Relay"
  start_relay
fi
