#!/usr/bin/env bash

prev_start_cmd="iex --name relay@127.0.0.1 -S mix"

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
}

while [ "$#" -gt 0 ];
do
  case "$1" in
    help)
      usage && exit 0
      ;;
    \?)
      usage && exit 0
      ;;
    -\?)
      usage && exit 0
      ;;
    --help)
      usage && exit 0
      ;;
    -h)
      usage && exit 0
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
    return 0
  else
    return 1
  fi
}

function verify_relay_env {
  verify=1
  verify_env_vars "RELAY_DATA_DIR"
  if [ $? == 0 ] ; then
    echo -e "\tWARNING! RELAY_DATA_DIR environment variable is not set. ${install_dir}/relay/command_config will be set for command configuration files"
  fi
  return ${verify}
}

function verify_cog_running {
  if [ -e "/var/run/operable/cog.pid" ]; then
    cog_pid=`cat /var/run/operable/cog.pid`
    cog=`ps -e | sed -n /${cog_pid}/p`
    echo ${cog}
    if [ "${cog:-null}" = null ]; then
      return 0
    else
      return 1
    fi
  else
    return 0
  fi
}

function start_relay {
  cd "${install_dir}/relay"
  # If Cog is running the /var/run/operable directory should already exist with the correct permissions
  # So this should have failed before getting to this point
  #elixir --detached -e "File.write! '/var/run/operable/relay.pid', :os.getpid" --name relay@127.0.0.1 -S mix
  /usr/local/bin/elixir --detached -e "File.write! '/var/run/operable/relay.pid', :os.getpid" -S mix
}


# Verify Relay has been installed with correct env vars set
if [ -e "${install_dir}/relay" ]; then
  echo "Relay installation detected at ${install_dir}/relay. Verifying required environment variables..."
  verify_relay_env
  if [ $? == 1 ] ; then
    echo "Relay environment variables verified."
  fi
  verify_cog_running
  if [ $? == 0 ] ; then
    echo "Cog is not running. Please start Cog and try starting Relay again..."
    exit 1
  else
    echo "Cog verified as running."
    echo "Starting Relay"
    start_relay
    relay_success=1
  fi
fi
