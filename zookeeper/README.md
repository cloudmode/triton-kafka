
1. load zookeeper
2. load container-pilot
3. load jq


# if there are zero healthy (first one up, not scaled)
#    use default zoo.cfg

# if there is one healthy (restart for some reason, so scaling)
#   if it's me, add my address to zoo.cfg

    # else it's not me, write healthy address and my address to zoo.cfg

# if there are two healthy
    # if one is me, write healthy addresses to zoo.cfg

    # else not me, write healthy addresses and my address to zoo.cfg



alternatively, use consul-template to write out template:

1. Register with Consul as 

docker run -d --name=consul gliderlabs/consul-server
docker run -p 8400:8400 -p 8500:8500 -p 8600:53/udp -h node1 progrium/consul -server -bootstrap -ui-dir /ui

consul-template -consul http://192.168.99.100:8500 -template /opt/zookeeper/zoo.cfg.ctmpl -once


curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper?recurse | jq length

curl -X PUT -d 'test1' http://{$CONSUL}:8500/v1/kv/zookeeper/server1?acquire=8298855f-155c-5ad7-d42f-d86c2c688c23

curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper/server1?raw

curl -s -X GET http://{$CONSUL}:8500/v1/kv/zookeeper/server1 | jq '.[] | .Session'

curl -s -X PUT http://{$CONSUL}:8500/v1/session/create
curl -s -X GET http://{$CONSUL}:8500/v1/session/list

docker run -p 2182:2181 -p 2889:2888 -p 3889:3888 --env-file ./_env -h zookeeper cloudmode/zookeeper

docker run -p 2183:2181 -p 2890:2888 -p 3890:3888 --env-file ./_env -h zookeeper cloudmode/zookeeper