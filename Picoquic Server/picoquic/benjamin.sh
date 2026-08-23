#!/bin/bash



for RATE in {0..10000..100}

do

        ./picoquicdemo & srv_pid=("$!")

        ./picoquicdemo localhost 4443 & $RATE & cli_pid=("$!")

        sleep 10

        result=$RATE

        cpu_cli=$(ps -p $cli_pid -o %cpu | head -n 2 | tail -n 1)

        cpu_srv=$(ps -p $srv_pid -o %cpu | head -n 2 | tail -n 1)

        result+=","

        result+=$cpu_cli

        result+=","

        result+=$cpu_srv

        echo $result

        echo $result >> results/cpu_amp_4.csv

        kill -9 $srv_pid

        kill -9 $cli_pid

        sleep 1

done

