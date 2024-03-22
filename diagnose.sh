#!/bin/bash

CONTAINER_NAME="unchained_worker"

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
    local container_state=$(sudo docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME")
    echo $container_state
}

# A function to check if container is restarting
isRestarting() {
    local container_state=$(sudo docker inspect --format='{{.State.Restarting}}' "$CONTAINER_NAME")
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

cecho "Making sure docker service is running..."
if ! sudo docker ps -a 2>/dev/null
then
    cecho "Docker service is not running" "red"
    cecho "Attempting to start docker service" "yellow"
    x=$( { sudo snap start docker ; } 2>&1)
    x=$( { sudo systemctl start docker ; } 2>&1)
    sleep 3
    if ! sudo docker ps -a > /dev/null 2>&1
    then
        cecho "Error: Can't start docker service" "red"
        exit 1
    else
        cecho "Docker service started successfully" "green"
    fi
fi


# Inspecting unchained container to grab the working directory
cecho "Attempting to auto-detect working directory of your node..." "yellow"
if ! sudo docker inspect "$CONTAINER_NAME" &> /dev/null; then
    cecho "Error: $CONTAINER_NAME container doesn't exist" "red"
    cecho "Attempting to locate unchained folder" "yellow"
    
    #navigating to home directory
    cd ~
    
    # Store search results in an array
    files=($(find  . -maxdepth 5 -type d -name "*unchained*" -exec find {} -type f -name "unchained.sh" -printf "%h\n" \;))

    # Check if any files were found
    if [ ${#files[@]} -eq 0 ]; then
        cecho "Error: No unchained directory was found on home directory" "red"
        #curl -s "https://github.com/KenshiTech/unchained/releases" | grep 'releases/tag/v' | grep -o '<a [^>]*href="[^"]*"'| grep -Ev 'alpha|rc' | awk -F '"' '{print $2}'| sed 's#/KenshiTech/unchained/releases/tag/\(v[0-9]\+\.[0-9]\+\.[0-9]\+\)#https://github.com/KenshiTech/unchained/releases/download/\1/unchained-\1-docker.zip#'
        #sudo docker tag f9716ec5fb27 ghcr.io/kenshitech/unchained:latest
        exit 1
    fi

    # Display options to the user
    echo "Which is your working directory of unchained node:"
    select option in "${files[@]}"; do
        if [ -n "$option" ]; then
            cecho "Navigating to directory: $option" "yellow"
            cd "$option"
            cecho "Starting the node..." "yellow"
            sudo ./unchained.sh worker up -d > /dev/null 2>&1
            # Add your command to open the selected file here (e.g., open "$option")
            break
        else
            echo "Invalid option. Please try again."
        fi
    done

    fi

# Get the Docker inspect output
docker_inspect=$(sudo docker inspect --format='{{json .Config.Labels}}' "$CONTAINER_NAME")

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
            response=$( { sudo ./unchained.sh worker up -d; } 2>&1)
            node_state=$(isRunning)
            ((start_node_escalation++))
            ;;
        2)
            echo "Starting the node attempt $start_node_escalation"
            if echo "$response" | grep -q Conflict
            then
                echo "Removing conflicting container"
                response=$( { sudo docker rm --force $CONTAINER_NAME && sudo ./unchained.sh worker up -d; } 2>&1)
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
fi
#Giving the node a time to run

#Check restarting status to determin if there is a problem with the node
cecho "Checking if the node keep restarting because of an error" "yellow"
cecho "Giving the node time to run..." "yellow"
sleep 10
node_state=$(isRestarting)
fix_node_escalation=1
response=""
while [[ $node_state == "true" ]]
do
    case $fix_node_escalation in
        1)
            cecho "Fixing the error attempt $fix_node_escalation: updating conf file." "yellow"
            node_name=$(sudo cat conf/conf.worker.yaml | grep name: | awk -F ': ' '{print $2}')
            if [[ $node_name == '<name>' ]]
            then
                read -p "Please, enter your perfered node name: " node_name
            fi
            cecho "Setting your node name to $node_name"
            sudo wget -q https://raw.githubusercontent.com/KenshiTech/unchained/master/conf.worker.yaml.template -O conf.yaml 
            sudo sed '0,/<name>/s//$node_name/' conf.yaml >/dev/null
            sudo mv conf.yaml conf/conf.worker.yaml
            sudo ./unchained.sh worker restart 2>/dev/null
            ((fix_node_escalation++))
            sleep 5
            ;;
        2)
            cecho "Fixing the error attempt $fix_node_escalation: updating the node." "yellow"
            update_response=$({ sudo ./unchained.sh worker pull;} 2>&1)
            if sudo ./unchained.sh worker up -d --force-recreate 2>/dev/null | grep "$CONTAINER_NAME"
            then
                cecho "Removing conflicting docker container" "yellow"   
                sudo docker rm --force "$CONTAINER_NAME"
                sudo ./unchained.sh worker up -d
            fi
            ((fix_node_escalation++))
            sleep 5
            ;;
        *)
            cecho "Unknown error" "red"
            exit 1
            ;;
    esac
done

cecho "Node has been repaired. Please check if your score is increasing on the leadboard." "green"
