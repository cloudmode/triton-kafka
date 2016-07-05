#!/bin/bash

if [[ -z ${CONSUL} ]]; then
  fatal "Missing CONSUL environment variable"
  exit 1
fi

zooCount() {
    # get the number of other healthy zookeeper instances currently registered with consul
    export ZK_PASSING=$(curl -s http://${CONSUL}:8500/v1/health/service/zookeeper?passing)
    export ZK_PASSING_COUNT=$( curl -s http://${CONSUL}:8500/v1/health/service/zookeeper?passing  | jq length )
    export ZK_PASSING_IPS=$( curl -s http://${CONSUL}:8500/v1/health/service/zookeeper?passing | jq '.[]' )
    if [ -z "$ZK_PASSING_COUNT" ]; then
        echo "Empty Variable ZK_PASSING, setting to zero..."
        export ZK_PASSING_COUNT=0
    fi

    # get the count of zookeeper instances as reported by the zookeeper instances themselves
    export ZK_INSTANCE=$(curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper?recurse | jq length)
    echo "first zooCount for ZK_INSTANCE:$ZK_INSTANCE, CONSUL:$CONSUL"
    if [ -z "$ZK_INSTANCE" ]; then
        
        export ZK_INSTANCE=0
    fi
    echo "zooCount for ZK_INSTANCE:$ZK_INSTANCE"
    return
}

serverID() {
    # if myid file exists, load it
    if [ -e $MYID_FILE ]; then
        echo "${MYID_FILE} exists..."
        export ZK_SERVER_ID=$(<$MYID_FILE)

    # else calculate it based on zookeeper/server* keys in consul
    else
        echo "ZK_SERVER_ID has not been set..."
        # how many servers are there
        export ZK_SERVER_ID=$(curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper?recurse | jq length)
        if [ -z "$ZK_SERVER_ID" ]; then
            # zero, so no keys, first server up
            export ZK_SERVER_ID=1
        else
            # take the next server id
            export ZK_SERVER_ID=$((ZK_SERVER_ID+1))
        fi
        echo "${ZK_SERVER_ID}" > $MYID_FILE

        # get session with consul if we don't already have one
        if [ -e $SESSION_FILE ]; then
            echo "${SESSION_FILE} exists..."
            export CONSUL_SESSION=$(<$SESSION_FILE)

        else
            export CONSUL_SESSION=$(curl -s -X PUT http://{$CONSUL}:8500/v1/session/create  | jq .ID | tr -d '"')
            echo "${CONSUL_SESSION}" > $SESSION_FILE
        fi

        # attempt to PUT the server key into consul
        export ZK_SERVER_KEY="server${ZK_SERVER_ID}"
        export FOLLOW=2888
        export ELECT=3888
        if [ "$LOCAL" = true ]; then
            FOLLOW=$((FOLLOW+ZK_SERVER_ID))
            ELECT=$((ELECT+ZK_SERVER_ID))
        fi
   
        export ZK_SERVER_VALUE="server.${ZK_SERVER_ID}=${IP_ADDRESS}:${FOLLOW}:${ELECT}"
        echo "ZK_SERVER_VALUE before put:$ZK_SERVER_VALUE, FOLLOW:$FOLLOW,${FOLLOW}, ELECT:$ELECT,${ELECT}"
        
        # get server key, see if it's ours
        export OWN_KEY=$(curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper/{$ZK_SERVER_KEY} | jq '.[] | .Session' | tr -d '"')


        echo "ZK_SERVER_VALUE:$ZK_SERVER_VALUE, OWN_KEY:$OWN_KEY CONSUL_SESSION:$CONSUL_SESSION"
        if [ "$OWN_KEY" == "$CONSUL_SESSION" ] || [ -z "$OWN_KEY" ]; then
            export UNIQUE=$(curl -s -X PUT -d ${ZK_SERVER_VALUE} http://${CONSUL}:8500/v1/kv/zookeeper/${ZK_SERVER_KEY}?acquire=${CONSUL_SESSION})
            echo "after put UNIQUE:$UNIQUE, "
        else 
            echo "${ZK_SERVER_VALUE} owned by another, calling serverID after incrementing ZK_SERVER_ID, OWN_KEY:$OWN_KEY"
            # another server already has the key set, so increment server id
            export ZK_SERVER_ID=$((ZK_SERVER_ID+1))
            echo "${ZK_SERVER_ID}" > $MYID_FILE
            serverID
        fi
    fi
    echo "ZK_SERVER_ID is set to:${ZK_SERVER_ID}"
}

generateConfig() {
  debug "Generating config"

  # if ZK_INSTANCE != ZK_PASSING go to sleep for $ZK_SERVER_ID seconds and try again.
  # this allows the any dying or starting zookeeper instances to complete
  # and update the zookeeper/count variable
  serverID
  sleep $ZK_SERVER_ID
  zooCount

  echo "instance:$ZK_INSTANCE passing:$ZK_PASSING_COUNT"
  if [ $ZK_INSTANCE != $ZK_PASSING_COUNT ]; then
      sleep $ZK_SERVER_ID
      zooCount
  fi

  if (( $ZK_INSTANCE > 1 )); then
      # if there is one healthy (restart for some reason, so scaling)
      echo "more than one healty instance:$ZK_INSTANCE CONSUL:$CONSUL"
      # save id to myid file
      echo "${ZK_SERVER_ID}" > $MYID_FILE
      consul-template -consul $CONSUL:8500 -template "/opt/zookeeper/zoo.cfg.ctmpl:/opt/zookeeper/conf/zoo.cfg" -once
  else
      echo "first zookeeper, using default:ZK_INSTANCE:$ZK_INSTANCE"
      cp /opt/zookeeper/conf/default.zoo.cfg /opt/zookeeper/conf/zoo.cfg 
  fi

  debug "----------------- Configuration -----------------"
  debug $(cat /opt/zookeeper/conf/zoo.cfg)
  debug "-----------------------------------------------------"
}

reload() {
  current_config=$(cat /opt/zookeeper/conf/zoo.cfg)

  generateConfig

  new_config=$(cat /opt/zookeeper/conf/zoo.cfg)

  if [ "$current_config" != "$new_config" ]; then
    info "******* Rebooting zookeeper *******"
    debug "******* myid:$(cat $ZOOPIDFILE) ******* "

    if [ -f $ZOOPIDFILE ]; then
      kill -SIGTERM $(cat $ZOOPIDFILE)
    fi
  else
    debug "Configs are identical. No need to reload."
  fi
}

health() {
  if [ $(echo ruok | nc 127.0.0.1 2181) != 'imok' ]; then return 0; else return 1; fi
}

start() {
  info "Bootstrapping zookeeper..."
  generateConfig

  # zookeeper doesn't have a hot-reload mechanism.
  # This hackery allows us to restart zookeeper without killing the container.
  # The `/bin/manage.sh reload` function will kill zookeeper if it detects new configuration.
  while true; do

    # check if zookeeper is already running
    pid=$(pgrep 'java')

    # If it's not running then start it
    if [ -z "$pid" ]; then

      info "******* Starting zookeeper *******"

      /opt/zookeeper/bin/zkServer.sh start
      sleep 3s
      echo $(pgrep 'java') > $ZOOPIDFILE

      exitcode=$?
      if [ $exitcode -gt 0 ]; then
        exit $exitcode
      fi
    fi

    sleep 1s
  done
}

cleanup() {
  export MYID_FILE="/opt/zookeeper/myid"
  if [ -e $MYID_FILE ]; then
      export ZK_SERVER_ID=$(<$MYID_FILE)
      export ZK_SERVER_KEY="server${ZK_SERVER_ID}"

      echo "cleanup removing zookeeper key from consul:${ZK_SERVER_KEY}"

      curl -s -X DELETE http://$CONSUL:8500/v1/kv/zookeeper/$ZK_SERVER_KEY
  fi
}

debug() {
  if [ ! -z "$DEBUG" ]; then
    echo "=======> DEBUG: $@"
  fi
}

info() {
  echo "=======> INFO: $@"
}

fatal() {
  echo "=======> FATAL: $@"
}

# make variables available for all processes/sub-processes called from manage
# get my external (within the datacenter....) IP_ADDRESS
export IP_ADDRESS=$(ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
export MYID_FILE="/opt/zookeeper/myid"
export SESSION_FILE="/opt/zookeeper/session"
export ZOOPIDFILE="/opt/zookeeper/server.pid"
export DEBUG=true

# do whatever the arg is
$1