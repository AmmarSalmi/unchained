#!/bin/bash

CONTAINER_NAME="unchained_worker_test"

#Welcome message and explanation
echo "Unchained Ironsmith"
echo "A community made tool to help diagnose and fix unchained node problem."
echo "v1 Supports only docker node and tested only on ubuntu"

#Declaring functions here
#Colored output function
cecho() {
    case $2  in
    'green')
        echo -e "\e[32m$1\e[0m"
        ;;
    'yellow')
        echo -e "\e[33m$1\e[0m"
        ;;
    'red')
        echo -e "\e[31m$1\e[0m"
        ;;
    *)
        echo "$1"
        ;;
    esac
}
# A function to check if container is running
isRunning() {
    local container_state=$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME")
    echo $container_state
}

# A function to check if container is restarting
isRestarting() {
    local container_state=$(docker inspect --format='{{.State.Restarting}}' "$CONTAINER_NAME")
    echo $container_state
}


#Checking if docker version 2 is installed
if ! command -v docker &>/dev/null; then
  cecho "Error: docker could not be found on your system!" "red"
  echo "You can refer to this guide to install docker V2"
  echo "https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04"
  exit 1
elif ! docker compose version 2>/dev/null | grep -qe '[ vV]2'; then
  cecho "Error: docker compose v2 could not be found on your system!" "red"
  echo "You can refer to this guide to install docker V2"
  echo "https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04"
  exit 1
fi


# Inspecting unchained container to grab the working directory
cecho "Attempting to auto detect working directory of your node..." "yellow"
if ! docker inspect "$CONTAINER_NAME" &> /dev/null; then
    echo "Unchained docker container doesn't exist"
    exit 1
fi

# Get the Docker inspect output
docker_inspect=$(docker inspect --format='{{json .Config.Labels}}' "$CONTAINER_NAME")

# Extract the folder path using grep and awk
folder=$(echo "$docker_inspect" | grep -o '"com.docker.compose.project.working_dir":"[^"]*' | awk -F ':"' '{print $2}')

# Change directory to the folder where the Docker container was created
cd "$folder" || exit 1
cecho "Working directory detected $(pwd)" "green"



cecho "Checking if the node is running..." "yellow"
node_state=$(isRunning)
start_node_escalation=1
response=""
while [[ $node_state == "false" ]]
do
    cecho "The node is not running" "red"
    case $start_node_escalation in 
        1)
            cecho "Starting the node attempt $start_node_escalation" "yellow"
            response=$( { ./unchained.sh worker up -d; } 2>&1)
            node_state=$(isRunning)
            ((start_node_escalation++))
            ;;
        2)
            echo "Starting the node attempt $start_node_escalation"
            if echo "$response" | grep -q Conflict
            then
                echo "Removing conflicting container"
                response=$( { sudo docker remove $CONTAINER_NAME && ./unchained.sh worker up -d; } 2>&1)
                node_state=$(isRunning)
            fi
            ((start_node_escalation++))
            ;;
        
        *)
            echo "Unknown problem while trying to run the node $response"
            exit 1
            ;;
    esac
done

if [[ $start_node_escalation -eq 1 ]]
then
    cecho "Node is running" "green"
else
    cecho "Node started successfully" "green"
    #Giving the node a time to run
    sleep 3
fi

#Check restarting status to determin if there is a problem with the node
cecho "Checking if the node keep restarting because of an error" "yellow"
node_state=$(isRestarting)
fix_node_escalation=1
response=""
#while [[ $node_state == "true" ]]
#do
#    case $fix_node_escalation in 
#        1)
#            echo "Fixing the error attempt $fix_node_escalation: updating the node."
