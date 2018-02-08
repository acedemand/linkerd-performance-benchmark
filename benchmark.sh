#!/bin/bash

# satoris agent related variables

INSTALL_ROOT=/Applications/satoris-2.8
AGENT=$INSTALL_ROOT/agent/satoris-javaagent.jar
CONSOLE=$INSTALL_ROOT/console/satoris.jar
CONF=$INSTALL_ROOT/conf/linkerd
SNAPSHOT=$CONF/probes.ocs
CODECACHE=$CONF/jxinsight.aspectj.cache

# benchmark related variables

SLEEP=30

# linkerd JVM (exported) variable

export LOCAL_JVM_OPTIONS="-Djxinsight.home=$CONF -javaagent:satoris-javaagent.jar -noverify"

# stress test related variables

URL=http://localhost:8080
QPS=1
CONCURRENCY=1
REQUESTS=500000

# check whether defaults have been overridden

while getopts :c:q:u:r o; do
  case "$o" in
    c)  
      CONCURRENCY=$OPTARG
      ;;
    q) 
      QPS=$OPTARG
      ;;
    u)  
      URL="$OPTARG"
      ;;
    r)
      REQUESTS=$OPTARG
      ;;
  esac
done

printf "BENCHMARK: url=%s qps=%d concurrency=%d requests=%d sleep=%d\n" "$URL" $QPS $CONCURRENCY $REQUESTS $SLEEP

# the nginx server has been configured to
# serve up a static page on localhost:9999

printf "BENCHMARK: starting nginx server\n"
nginx &
NGINX=$!
printf "BENCHMARK: nginx server [%d] started\n" $NGINX

sleep $SLEEP

# following this initial copy of the agent library the
# benchmark will on each iteration create a new version

printf "BENCHMARK: copying agent bundle to current dir\n"
cp $AGENT .

for i in {1..7}
do

   printf "BENCHMARK: iteration #%d\n" $i

   # because the instrumentation set changes across runs
   # the cache is cleared of previous instrumented bytecode

   printf "BENCHMARK: removing agent instrumentation code cache\n"
   rm $CODECACHE

   sleep $SLEEP

   # the linkerd server is configured to pass http://localhost:8080
   # onto another server listening on http://localhost:9999

   printf "BENCHMARK: starting linkerd server with agent\n"
   ./linkerd-0.9.1-exec config/linkerd.yaml &
   LINKERD=$!
   printf "BENCHMARK: linkerd server [%d] started\n" $LINKERD

   sleep $SLEEP

   printf "BENCHMARK: stopping linkerd after populating code cache\n"
   kill -SIGTERM $LINKERD

   sleep $SLEEP

   # just to be doubly sure we do not inadvertently process
   # a startup only profile snapshot of the linkerd server

   rm $SNAPSHOT

   # enable the tracking extension in the last benchmark
   # iteration for call flow/path analysis of hotspots

   if [ $i -eq 7 ]
   then
      export LOCAL_JVM_OPTIONS="$LOCAL_JVM_OPTIONS -Djxinsight.server.probes.tracking.enabled=true"
   fi

   printf "BENCHMARK: restarting linkerd server with agent\n"
   ./linkerd-0.9.1-exec config/linkerd.yaml &
   LINKERD=$!
   printf "BENCHMARK: linkerd server [%d] restarted\n" $LINKERD

   sleep $SLEEP

   # send N number of requests through the linkerd server
   # with a specified reqest rate (QPS) and concurrency

   printf "BENCHMARK: beginning http workload\n"
   ./slow_cooker_darwin -qps $QPS -concurrency $CONCURRENCY -totalRequests $REQUESTS $URL
   printf "BENCHMARK: completed http workload\n"

   # stopping the linkerd server will trigger the export of
   # a probes snapshot used to refine instrumentation set

   printf "BENCHMARK: stopping linkerd server\n"
   kill -SIGTERM $LINKERD

   sleep $SLEEP

   # the satoris client console has a command line interface that is
   # used to process a snapshot and generate new agent runtime library

   if [ $i -lt 7 ]
   then

      printf "BENCHMARK: processing exported snapshot and generating new agent\n"

      if [ $i -lt 5 ]
      then
        java -jar $CONSOLE -generate-aj-bundle --non-managed $SNAPSHOT $AGENT
      else

        # this is the last effective benchmark where instrumentation
        # is refined so disable the generation of hotspot (safe)guards

        java -jar $CONSOLE -generate-aj-bundle --non-strategy $SNAPSHOT $AGENT

        # disable the default enabled hotspot metering extension

        export LOCAL_JVM_OPTIONS="$LOCAL_JVM_OPTIONS -Djxinsight.server.probes.hotspot.enabled=false"

      fi

   fi

   # disable the hotspot extension following the fifth
   # benchmark iteration as

   printf "BENCHMARK: moving and renaming exported snapshot\n"
   mv $SNAPSHOT $CONF/qps-$QPS-con-$CONCURRENCY-itr-$i.ocs

done

printf "BENCHMARK: stopping nginx server\n"
nginx -s stop
printf "BENCHMARK: nginx server [%d] stopped\n" $NGINX